// +build linux

// Only build on Linux, since the use of procfs is platform specific.
package procfs

import (
	"bytes"
	"fmt"
	"io/ioutil"
	"os"
	"strconv"
	"syscall"
	"time"
)

func GetVszRssBytes(pid int) (vszBytes int64, rssBytes int64, err error) {
	data, err := ioutil.ReadFile(fmt.Sprintf("/proc/%v/statm", pid))
	if err != nil {
		if os.IsNotExist(err) {
			err = syscall.ESRCH
		}
		// Under certain circumstances, the error returned for the
		// underlying read is ESRCH. It seems mostly likely to be a
		// race inside the procfs.
		if pathErr, ok := err.(*os.PathError); ok && pathErr.Err == syscall.ESRCH {
			err = syscall.ESRCH
		}
		return 0, 0, err
	}
	fields := bytes.Fields(data)

	vszPages, err := atoi(fields[0])
	if err != nil {
		return 0, 0, err
	}

	rssPages, err := atoi(fields[1])
	if err != nil {
		return 0, 0, err
	}
	pageSize := int64(os.Getpagesize())
	return vszPages * pageSize, rssPages * pageSize, nil
}

// Return the naive sum of the RSS for all processes in a session.
// deadcode: GetSessionVszRssBytes is grandfathered in as legacy code
func GetSessionVszRssBytes(sid int) (vsz int64, rss int64, err error) {
	pids, err := GetSessionIdPids(sid, 1*time.Second)
	if err != nil {
		return 0, 0, err
	}
	return getTotalVszRssBytes(pids)
}

// GetProcessTreeVszRssBytes returns the naive sum of the RSS for all processes
// in process trees rooted within the given session.
func GetProcessTreeVszRssBytes(sid int) (vsz int64, rss int64, err error) {
	pids, err := GetProcessTreePids(sid, 1*time.Second)
	if err != nil {
		return 0, 0, err
	}
	return getTotalVszRssBytes(pids)
}

// GetProcessDescendantsVszRssBytes returns the naive sum of the RSS for all
// subprocesses of the given pid.
func GetProcessDescendantsVszRssBytes(pid int) (vsz int64, rss int64, err error) {
	pids, err := GetProcessDescendents(pid)
	if err != nil {
		return 0, 0, err
	}
	return getTotalVszRssBytes(pids)
}

func getTotalVszRssBytes(pids []int) (vsz int64, rss int64, err error) {
	vszSum := int64(0)
	rssSum := int64(0)
	for _, pid := range pids {
		vszBytes, rssBytes, pErr := GetVszRssBytes(pid)
		if pErr != nil {
			if pErr == syscall.ESRCH {
				continue
			}
			return 0, 0, pErr
		}
		vszSum += vszBytes
		rssSum += rssBytes
	}
	return vszSum, rssSum, nil
}

type IOStats struct {
	// Rchar, Wchar, Syscr int64
	Syscw int64
	// ReadBytes int64
	WriteBytes int64
	// CanceledWriteBytes int64
}

func GetProcessTreeIOStats(sid int) (IOStats, error) {
	pids, err := GetProcessTreePids(sid, 1*time.Second)
	if err != nil {
		return IOStats{}, err
	}
	return getTotalIOStats(pids)
}

func GetIOStats(pid int) (IOStats, error) {
	data, err := ioutil.ReadFile(fmt.Sprintf("/proc/%v/io", pid))
	retval := IOStats{}
	if err != nil {
		if os.IsNotExist(err) {
			err = syscall.ESRCH
		}
		// Under certain circumstances, the error returned for the
		// underlying read is ESRCH. It seems mostly likely to be a
		// race inside the procfs.
		if pathErr, ok := err.(*os.PathError); ok && pathErr.Err == syscall.ESRCH {
			err = syscall.ESRCH
		}
		return retval, err
	}
	/*
		rchar: 85301016264
		wchar: 151716602206
		syscr: 18366586
		syscw: 31406930
		read_bytes: 30196035072
		write_bytes: 39384674304
		cancelled_write_bytes: 3170988032
	*/
	fields := bytes.Fields(data)
	for i, v := range fields {
		if i%2 == 0 {
			continue
		}
		k := fields[i-1]
		u, err := atoi(v)
		if err != nil {
			return retval, fmt.Errorf("Error parsing proc/%v/io @ %v: %v", pid, k, err)
		}
		switch string(k) {
		// case "rchar:":
		// 	retval.Rchar += u
		// case "wchar:":
		// 	retval.Wchar += u
		// case "syscr:":
		// 	retval.Syscr += u
		case "syscw:":
			retval.Syscw += u
		// case "read_bytes:":
		// 	retval.ReadBytes += u
		case "write_bytes:":
			retval.WriteBytes += u
			// case "cancelled_write_bytes:":
			// 	retval.CanceledWriteBytes += u
		}
	}
	return retval, nil
}

func getTotalIOStats(pids []int) (IOStats, error) {
	stats := IOStats{}
	for _, pid := range pids {
		stat, err := GetIOStats(pid)
		if err != nil {
			if err == syscall.ESRCH {
				continue
			}
			return IOStats{}, err
		}
		// stats.Rchar += stat.Rchar
		// stats.Wchar += stat.Wchar
		// stats.Syscr += stat.Syscr
		stats.Syscw += stat.Syscw
		// stats.ReadBytes += stat.ReadBytes
		stats.WriteBytes += stat.WriteBytes
		// stats.CanceledWriteBytes += stat.CanceledWriteBytes

	}
	return stats, nil
}

func atoi(b []byte) (int64, error) {
	return strconv.ParseInt(string(b), 10, 64)
}
