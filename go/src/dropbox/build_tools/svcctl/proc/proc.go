package proc

import (
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
)

const (
	stateInitial = iota
	stateRunning = iota
	stateExited  = iota
)

// a thin wrapper around exec.Cmd to better keep track of its state
type Pcmd struct {
	Cmd         *exec.Cmd
	stateChange *sync.Cond

	sanitizerLogsDir string

	// guarded by lock
	lock            sync.Mutex
	state           int
	exitErr         error
	sanitizerErrors []string
}

func New(name string, args ...string) *Pcmd {
	process := &Pcmd{
		Cmd: exec.Command(name, args...),
	}
	process.stateChange = sync.NewCond(&process.lock)
	process.state = stateInitial
	return process
}

func (process *Pcmd) collectSanitizerErrors() error {
	if process.sanitizerLogsDir == "" {
		return nil
	}
	defer func() {
		if err := os.RemoveAll(process.sanitizerLogsDir); err != nil {
			log.Printf("error removing sanitizer logs directory: %s", err)
		}
	}()
	fis, err := ioutil.ReadDir(process.sanitizerLogsDir)
	if err != nil {
		return fmt.Errorf("reading sanitizer logs directory: %w", err)
	}
	for _, fi := range fis {
		path := filepath.Join(process.sanitizerLogsDir, fi.Name())
		b, err := ioutil.ReadFile(path)
		if err != nil {
			return fmt.Errorf("reading sanitizer log file: %w", err)
		}
		process.sanitizerErrors = append(process.sanitizerErrors, string(b))
	}
	return nil
}

// updateSanitizerEnv checks for GORACE and EXTRA_COMMON_SAN_OPTIONS variables
// and replaces it with one which stores logs separately for each service.
func (process *Pcmd) updateSanitizerEnv() error {
	var newEnv []string
	// filter out old sanitizer environment variable if there is one set
	for _, v := range process.Cmd.Env {
		if strings.HasPrefix(v, "GORACE=") {
			continue
		}
		if strings.HasPrefix(v, "EXTRA_COMMON_SAN_OPTIONS=") {
			continue
		}
		newEnv = append(newEnv, v)
	}

	tmpDir, err := ioutil.TempDir(os.Getenv("TEST_TMPDIR"), "sanitizer-")
	if err != nil {
		return fmt.Errorf("creating temp dir for sanitizers: %w", err)
	}
	process.sanitizerLogsDir = tmpDir
	racePrefix := filepath.Join(process.sanitizerLogsDir, "race_log")
	newEnv = append(newEnv, fmt.Sprintf("GORACE=halt_on_error=1 log_path=%s", racePrefix))
	sanPrefix := filepath.Join(process.sanitizerLogsDir, "sanitizer")
	newEnv = append(newEnv, fmt.Sprintf("EXTRA_COMMON_SAN_OPTIONS=log_path=%s:print_suppressions=false", sanPrefix))

	process.Cmd.Env = newEnv
	return nil
}

func (process *Pcmd) Start() error {
	if err := process.updateSanitizerEnv(); err != nil {
		return err
	}
	startErr := process.Cmd.Start()
	if startErr != nil {
		return startErr
	}
	process.lock.Lock()
	defer process.lock.Unlock()
	process.state = stateRunning
	process.stateChange.Broadcast()
	go func() {
		waitErr := process.Cmd.Wait()

		process.lock.Lock()
		defer process.lock.Unlock()
		process.state = stateExited
		process.exitErr = waitErr
		if sanitizerErr := process.collectSanitizerErrors(); sanitizerErr != nil {
			log.Printf("failed to collect sanitizer logs: %s", sanitizerErr)
		}
		process.stateChange.Broadcast()
	}()
	return nil
}

// unlike with exec.Cmd, this is safe to call multiple times
func (process *Pcmd) Wait() error {
	process.lock.Lock()
	defer process.lock.Unlock()
	for process.state != stateExited {
		process.stateChange.Wait()
	}
	return process.exitErr
}

// this doesn't block
func (process *Pcmd) Exited() bool {
	process.lock.Lock()
	defer process.lock.Unlock()
	return process.state == stateExited
}

func (process *Pcmd) SanitizerErrors() []string {
	process.lock.Lock()
	defer process.lock.Unlock()
	return process.sanitizerErrors
}
