package svclib

import (
	"fmt"
	"net"
	"testing"

	"github.com/stretchr/testify/require"

	svclib_proto "dropbox/proto/build_tools/svclib"
	"dropbox/runfiles"
)

func isPortListening(port uint32) bool {
	if conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port)); err == nil {
		_ = conn.Close()
		return true
	}
	return false
}

func tcpService(port int) *svclib_proto.Service {
	tcpCmd := fmt.Sprintf("%s --port %d", runfiles.MustDataPath("@dbx_build_tools//dropbox/build_tools/echo_server/echo_server"), port)
	checkCmd := fmt.Sprintf("%s --port %d test", runfiles.MustDataPath("@dbx_build_tools//dropbox/build_tools/echo_server/echo_client"), port)
	serviceName := fmt.Sprintf("nc_%d", port)
	return &svclib_proto.Service{
		ServiceName: &serviceName,
		LaunchCmd: &svclib_proto.Command{
			Cmd: &tcpCmd,
		},
		HealthChecks: []*svclib_proto.HealthCheck{
			CmdHealthCheck(checkCmd),
		},
	}
}

func TestServiceCreation(t *testing.T) {
	serviceDef := tcpService(1234)

	require.False(t, isPortListening(1234))
	service, createErr := CreateService(serviceDef)
	if createErr != nil {
		t.Fatal(createErr)
	}
	defer func() {
		require.NoError(t, service.Remove())
	}()

	require.NoError(t, service.Start())

	require.True(t, isPortListening(1234))

	require.NoError(t, service.Stop())

	require.False(t, isPortListening(1234))
}

func TestServiceCreationNoStop(t *testing.T) {
	serviceDef := tcpService(2345)

	require.False(t, isPortListening(2345))
	service, createErr := CreateService(serviceDef)
	if createErr != nil {
		t.Fatal(createErr)
	}

	require.NoError(t, service.Start())

	require.True(t, isPortListening(2345))

	require.NoError(t, service.Remove())

	require.False(t, isPortListening(2345))
}
