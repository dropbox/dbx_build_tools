package cputime

// #include <unistd.h>
import "C"

import (
	"fmt"
	"sync"
	"time"

	goprocinfo "github.com/c9s/goprocinfo/linux"

	"dropbox/procfs"
)

var (
	hz         int
	initHzOnce = &sync.Once{}
)

func RecursiveCPUTime(rootPID int) (time.Duration, error) {
	// Note: this can probably result in double counting if a process
	// terminates while we're iterating.
	pids, err := procfs.GetProcessDescendents(rootPID)
	if err != nil {
		return 0, err
	}

	var cpuTime time.Duration
	for _, pid := range pids {
		t, err := CPUTime(pid)
		if err != nil {
			return 0, err
		}
		cpuTime += t
	}
	return cpuTime, nil
}

func CPUTime(pid int) (time.Duration, error) {
	initHzOnce.Do(func() {
		hz = int(C.sysconf(C._SC_CLK_TCK))
	})

	if hz <= 0 {
		return 0, fmt.Errorf("failed to fetch hertz")
	}

	stat, err := goprocinfo.ReadProcessStat(fmt.Sprintf("/proc/%v/stat", pid))
	if err != nil {
		return 0, err
	}

	ticks := int64(stat.Utime+stat.Stime) + stat.Cutime + stat.Cstime

	// Note: the units here are odd. We convert to nanos first to prevent
	// truncation.
	cpuTime := (time.Second * time.Duration(ticks)) / time.Duration(hz)
	return cpuTime, nil
}
