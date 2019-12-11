package svcctl

import (
	"io/ioutil"
	"log"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"dropbox/build_tools/svcctl/state_machine"
	svclib_proto "dropbox/proto/build_tools/svclib"
	"dropbox/runfiles"
)

var logger = log.New(os.Stderr, "service ", log.LstdFlags|log.Lmicroseconds)

func TestServiceStart(t *testing.T) {
	s := &serviceDef{
		LaunchCmd: &Command{
			Cmd: runfiles.MustDataPath("@dbx_build_tools//dropbox/build_tools/echo_server/echo_server") + " --port 1234",
		},
		VerifyCmds: []*Command{
			&Command{
				Cmd: runfiles.MustDataPath("@dbx_build_tools//dropbox/build_tools/echo_server/echo_client") + " --port 1234 hello_world",
			},
		},
		logger:       logger,
		StateMachine: state_machine.New(svclib_proto.StatusResp_STOPPED),
		Stdout:       os.Stdout,
		Stderr:       os.Stderr,
	}

	require.NoError(t, s.Start())
	defer func() {
		require.NoError(t, s.Stop())
	}()

	require.NoError(t, s.waitTillHealthy())
}

func TestServiceLaunchFailed(t *testing.T) {
	s := &serviceDef{
		LaunchCmd: &Command{
			Cmd: "exit 0", // exit 0 is not acceptable, since we expect a service to be running
		},
		VerifyCmds: []*Command{
			&Command{
				Cmd: runfiles.MustDataPath("@dbx_build_tools//dropbox/build_tools/echo_server/echo_client") + " --port 1234 hello_world",
			},
		},
		logger:       logger,
		StateMachine: state_machine.New(svclib_proto.StatusResp_STOPPED),
		Stdout:       os.Stdout,
		Stderr:       os.Stderr,
	}

	require.NoError(t, s.Start())

	require.Error(t, s.waitTillHealthy())
	require.Equal(t, svclib_proto.StatusResp_ERROR, s.StateMachine.GetState())
}

func TestServiceStartHealthCheckCommandFailed(t *testing.T) {
	s := &serviceDef{
		LaunchCmd: &Command{
			Cmd: runfiles.MustDataPath("@dbx_build_tools//dropbox/build_tools/echo_server/echo_server") + " --port 1237",
		},
		logger: logger,
		VerifyCmds: []*Command{
			&Command{
				Cmd: "exit 1",
			},
		},
		StateMachine: state_machine.New(svclib_proto.StatusResp_STOPPED),
		Stdout:       os.Stdout,
		Stderr:       os.Stderr,
	}

	require.NoError(t, s.Start())
	defer func() {
		require.NoError(t, s.Stop())
	}()

	time.Sleep(50 * time.Millisecond)
	s.lock.Lock()
	status := s.StateMachine.GetState()
	s.lock.Unlock()
	require.Equal(t, status, svclib_proto.StatusResp_STARTING)
}

func TestServiceUnexpectedlyStopped(t *testing.T) {
	s := &serviceDef{
		LaunchCmd: &Command{
			Cmd: "sleep infinity",
		},
		VerifyCmds: []*Command{
			&Command{
				Cmd: "true",
			},
		},
		logger:       logger,
		StateMachine: state_machine.New(svclib_proto.StatusResp_STOPPED),
		Stdout:       os.Stdout,
		Stderr:       os.Stderr,
	}

	require.NoError(t, s.Start())

	require.NoError(t, s.waitTillHealthy())
	require.Equal(t, svclib_proto.StatusResp_STARTED, s.StateMachine.GetState())

	// kill process
	require.NoError(t, s.Process.Cmd.Process.Kill())

	// wait till the process is marked as exited by svcctl
	// don't call wait - we expect svcctl to do that itself and cleanup any resources
	start := time.Now()
	for s.StateMachine.GetState() == svclib_proto.StatusResp_STARTED {
		time.Sleep(100 * time.Millisecond)
		if time.Since(start) > 1*time.Second {
			t.Fatal("Timeout waiting for process to die")
		}
	}
	require.Equal(t, svclib_proto.StatusResp_ERROR, s.StateMachine.GetState())
	require.NoError(t, s.Stop())
}

func TestSynchronousService(t *testing.T) {
	tempFile, fileErr := ioutil.TempFile("", "test-blocking-service")
	require.NoError(t, fileErr)
	require.NoError(t, tempFile.Close())
	defer func() {
		require.NoError(t, os.Remove(tempFile.Name()))
	}()
	s := &serviceDef{
		ServiceType: svclib_proto.Service_TASK,
		LaunchCmd: &Command{
			Cmd: "echo testing > " + tempFile.Name(),
		},
		StateMachine: state_machine.New(svclib_proto.StatusResp_STOPPED),
		Stderr:       os.Stderr,
		Stdout:       os.Stdout,
		logger:       logger,
	}

	require.NoError(t, s.Start())
	defer func() {
		require.NoError(t, s.Stop())
	}()

	require.NoError(t, s.waitTillHealthy())

	content, err := ioutil.ReadFile(tempFile.Name())
	require.NoError(t, err)
	require.Equal(t, "testing\n", string(content))
}

func TestSynchronousServiceWithError(t *testing.T) {
	s := &serviceDef{
		LaunchCmd: &Command{
			Cmd: "exit 1",
		},
		ServiceType:  svclib_proto.Service_TASK,
		StateMachine: state_machine.New(svclib_proto.StatusResp_STOPPED),
		Stderr:       os.Stderr,
		Stdout:       os.Stdout,
		logger:       logger,
	}

	require.NoError(t, s.Start())
	defer func() {
		require.NoError(t, s.Stop())
	}()

	require.Error(t, s.waitTillHealthy())

	require.Equal(t, svclib_proto.StatusResp_ERROR, s.StateMachine.GetState())
}

func TestNeedsRestart(t *testing.T) {
	s := &serviceDef{logger: logger}
	readAndSetVersionFile := func() {
		version, err := s.readVersionFiles()
		require.NoError(t, err)
		s.version.Store(version)
	}
	defaultVersion := []byte{}
	s.version.Store(defaultVersion)
	require.False(t, s.needsRestart()) // no version file

	// non-existent version file should be ok
	s.versionFiles = []string{"/doesnotexist"}
	require.False(t, s.needsRestart())

	// simple case of a single version file
	versionFile, fileErr := ioutil.TempFile(os.Getenv("TEST_TMPDIR"), "version-file")
	require.NoError(t, fileErr)
	require.NoError(t, versionFile.Close())
	s.versionFiles = []string{versionFile.Name()}

	readAndSetVersionFile()
	require.False(t, s.needsRestart())

	require.NoError(t, ioutil.WriteFile(versionFile.Name(), []byte("foo"), 0666))
	require.True(t, s.needsRestart())

	readAndSetVersionFile()
	require.False(t, s.needsRestart())

	// support multiple version files
	versionFile2, fileErr2 := ioutil.TempFile(os.Getenv("TEST_TMPDIR"), "version-file2")
	require.NoError(t, fileErr2)
	require.NoError(t, versionFile2.Close())
	s.versionFiles = []string{versionFile.Name(), versionFile2.Name()}

	readAndSetVersionFile()
	require.False(t, s.needsRestart())

	require.NoError(t, ioutil.WriteFile(versionFile.Name(), []byte("bar"), 0666))
	require.True(t, s.needsRestart())

	readAndSetVersionFile()
	require.False(t, s.needsRestart())

	require.NoError(t, ioutil.WriteFile(versionFile2.Name(), []byte("bar"), 0666))
	require.True(t, s.needsRestart())

	readAndSetVersionFile()
	require.False(t, s.needsRestart())

	require.NoError(t, ioutil.WriteFile(versionFile.Name(), []byte("bar2"), 0666))
	require.NoError(t, ioutil.WriteFile(versionFile2.Name(), []byte("bar2"), 0666))
	require.True(t, s.needsRestart())

	readAndSetVersionFile()
	require.False(t, s.needsRestart())
}
