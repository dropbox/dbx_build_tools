// +build linux

// Only build on Linux, since the use of procfs is platform specific.
package procfs

import (
	"os"
	"os/exec"
	"testing"

	. "gopkg.in/check.v1"
)

func Test(t *testing.T) { TestingT(t) }

type ProcfsTestSuite struct{}

var _ = Suite(&ProcfsTestSuite{})

func (p *ProcfsTestSuite) TestChildPids(c *C) {
	// get the current pid
	pid := os.Getpid()
	// spin up a child process
	cmd := exec.Command("sleep", "infinity")
	err := cmd.Start()
	if err != nil {
		c.Fatal(err)
	}

	cpids, cpidErr := ChildPids(pid)
	if cpidErr != nil {
		c.Fatal(cpidErr)
	}

	// make sure that our child pid list is not empty
	c.Assert(cpids, Not(DeepEquals), []int{})

	// check if we did get the child pid during lookup
	var foundPid bool
	for _, pid := range cpids {
		if pid == cmd.Process.Pid {
			foundPid = true
		}
	}
	c.Assert(foundPid, Equals, true)

	// tear down the child process
	cmd.Process.Kill()
	cmd.Wait()
}
