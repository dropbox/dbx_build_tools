// +build linux

// Only build on Linux, since the use of procfs is platform specific.
package procfs

import (
	"bytes"
	"errors"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"strconv"
	"sync"
	"syscall"
	"time"
)

// Incomplete interpretation of the /proc/pid/stat file.
type ProcStat struct {
	Pid       int
	Cmd       string
	State     string
	Ppid      int
	Pgrp      int
	SessionId int
}

func ReadProcStats(pid int) (*ProcStat, error) {
	fname := fmt.Sprintf("/proc/%v/stat", pid)
	data, err := ioutil.ReadFile(fname)
	if err != nil {
		return nil, err
	}

	i := bytes.Index(data, []byte(" ("))
	j := bytes.Index(data, []byte(") "))
	stats := ProcStat{}
	stats.Pid, err = strconv.Atoi(string(data[:i]))
	if err != nil {
		return nil, fmt.Errorf("invalid pid in %v %v", fname, err)
	}
	stats.Cmd = string(data[i+2 : j])
	fields := string(data[j+2:])
	_, err = fmt.Sscanf(fields, "%s %d %d %d",
		&stats.State, &stats.Ppid, &stats.Pgrp, &stats.SessionId)
	if err != nil {
		return nil, fmt.Errorf("invalid scan in %v %v \"%v\"", fname, err, fields)
	}
	return &stats, nil
}

// Is there no better way to scan child / group processes?
// For now, we have to load everything we can read see if it
// matches.
func readAllProcStats() ([]*ProcStat, error) {
	dir, fErr := os.Open("/proc")
	if fErr != nil {
		return nil, fErr
	}
	dirEntries, dirErr := dir.Readdirnames(-1)
	if dirErr != nil {
		return nil, dirErr
	}
	groupStats := make([]*ProcStat, 0, len(dirEntries))
	for _, ent := range dirEntries {
		if pid, convErr := strconv.Atoi(ent); convErr == nil {
			pidStats, err := ReadProcStats(pid)
			if err != nil {
				if os.IsNotExist(err) {
					// NOTE(msolo) There are inherent races here. If a process
					// disappears betweenthe time you read the directory and you
					// manage to read the proc stats, don't panic. Soldier on.
					continue
				}
				// Under certain circumstances, the error returned for the
				// underlying read is ESRCH. It seems mostly likely to be a
				// race inside the procfs.
				if errors.Is(err, syscall.ESRCH) {
					continue
				}
				// If there is some random error, skip for now.
				log.Printf("WARNING: unexpected error reading procfs %v", err)
				continue
			}
			groupStats = append(groupStats, pidStats)
		}
	}
	if len(groupStats) == 0 {
		return nil, fmt.Errorf("unable to read any procfs stats")
	}
	return groupStats, nil
}

var (
	cacheMu        sync.Mutex
	cacheTime      time.Time
	cacheProcStats []*ProcStat
)

func cachedReadAllProcStats(staleAllowed time.Duration) ([]*ProcStat, error) {
	now := time.Now()
	cacheMu.Lock()
	defer cacheMu.Unlock()
	if now.Sub(cacheTime) > staleAllowed {
		ps, err := readAllProcStats()
		if err != nil {
			return nil, err
		}
		cacheProcStats = ps
		cacheTime = now
	}
	return cacheProcStats, nil
}

// GetPgrpPids returns a list of all pids in a given process group.
// Not as cheap as you think, you have to scan all the pids on the system.
// deadcode: GetPgrpPids is grandfathered in as legacy code
func GetPgrpPids(pgrp int, staleAllowed time.Duration) ([]int, error) {
	stats, err := cachedReadAllProcStats(staleAllowed)
	if err != nil {
		return nil, err
	}
	pids := make([]int, 0, 32)
	for _, st := range stats {
		if st.Pgrp == pgrp {
			pids = append(pids, st.Pid)
		}
	}
	if len(pids) == 0 {
		return nil, syscall.ESRCH
	}
	return pids, nil
}

// GetSessionIdPids return a list of all pids in a given session.
// Not as cheap as you think, you have to scan all the pids on the system.
func GetSessionIdPids(sessionId int, staleAllowed time.Duration) ([]int, error) {
	stats, err := cachedReadAllProcStats(staleAllowed)
	// stats, err := readAllProcStats()
	if err != nil {
		return nil, err
	}
	pids := make([]int, 0, 32)
	for _, st := range stats {
		if st.SessionId == sessionId {
			pids = append(pids, st.Pid)
		}
	}
	if len(pids) == 0 {
		return nil, syscall.ESRCH
	}
	return pids, nil
}

// GetProcessTreePids returns a list of all pids in process trees
// rooted within the given session.
func GetProcessTreePids(sessionId int, staleAllowed time.Duration) ([]int, error) {
	stats, err := cachedReadAllProcStats(staleAllowed)
	if err != nil {
		return nil, err
	}

	pidSet := make(map[int]struct{}, 32)
	for _, st := range stats {
		if st.SessionId == sessionId {
			pidSet[st.Pid] = struct{}{}
		}
	}

	if len(pidSet) == 0 {
		return nil, syscall.ESRCH
	}

	// Walk the trees for processes in the session and collect all descendants.
	pidToChildren := getChildPidMap(stats)
	toProcess := toIntSlice(pidSet)
	for len(toProcess) > 0 {
		pid := toProcess[0]
		toProcess = toProcess[1:]
		for _, child := range pidToChildren[pid] {
			if _, ok := pidSet[child]; !ok {
				pidSet[child] = struct{}{}
				toProcess = append(toProcess, child)
			}
		}
	}

	return toIntSlice(pidSet), nil
}

func GetProcessDescendents(parentPid int) ([]int, error) {
	stats, err := readAllProcStats()
	if err != nil {
		return nil, err
	}

	pidSet := map[int]struct{}{
		parentPid: struct{}{},
	}
	pidToChildren := getChildPidMap(stats)
	toProcess := toIntSlice(pidSet)
	for len(toProcess) > 0 {
		pid := toProcess[0]
		toProcess = toProcess[1:]
		for _, child := range pidToChildren[pid] {
			if _, ok := pidSet[child]; !ok {
				pidSet[child] = struct{}{}
				toProcess = append(toProcess, child)
			}
		}
	}
	return toIntSlice(pidSet), nil
}

// getChildPidMap creates a map of pid -> children pids with this ppid.
func getChildPidMap(stats []*ProcStat) map[int][]int {
	result := make(map[int][]int, len(stats))
	for _, st := range stats {
		result[st.Ppid] = append(result[st.Ppid], st.Pid)
	}
	return result
}

func toIntSlice(intSet map[int]struct{}) []int {
	result := make([]int, 0, len(intSet))
	for i := range intSet {
		result = append(result, i)
	}
	return result
}

var eqByte = []byte{'='}

type ProcEnv struct {
	Env    string
	EnvMap map[string]string
	Pid    int
}

func ReadProcEnv(pid int) (*ProcEnv, error) {
	env, err := ioutil.ReadFile(fmt.Sprintf("/proc/%v/environ", pid))
	if err != nil {
		return nil, err
	}
	envMap := make(map[string]string)
	for _, ep := range bytes.Split(env, []byte{0}) {
		if len(ep) == 0 {
			continue
		}
		kv := bytes.SplitN(ep, eqByte, 2)
		if len(kv) == 2 {
			envMap[string(kv[0])] = string(kv[1])
		}
	}
	return &ProcEnv{string(env), envMap, pid}, nil
}

func ReadAllProcEnv() ([]*ProcEnv, error) {
	dirEntries, dirErr := ioutil.ReadDir("/proc")
	if dirErr != nil {
		return nil, dirErr
	}
	procEnvs := make([]*ProcEnv, 0, len(dirEntries))
	for _, ent := range dirEntries {
		pid, err := strconv.Atoi(ent.Name())
		if err != nil {
			// Only scan the pid directories.
			continue
		}
		procEnv, err := ReadProcEnv(pid)
		if err != nil {
			if os.IsNotExist(err) {
				// NOTE(msolo) There are inherent races here. If a process
				// disappears betweenthe time you read the directory and you
				// manage to read the proc stats, don't panic. Soldier on.
				continue
			}
			// Under certain circumstances, the error returned for the
			// underlying read is ESRCH. It seems mostly likely to be a
			// race inside the procfs.
			if pathErr, ok := err.(*os.PathError); ok && pathErr.Err == syscall.ESRCH {
				continue
			}
			if os.IsPermission(err) {
				log.Printf("WARNING: %s", err)
				continue
			}
			return nil, err
		}
		procEnvs = append(procEnvs, procEnv)
	}
	return procEnvs, nil
}

// Return all immediate child process for a pid
func ChildPids(pid int) ([]int, error) {
	// we can get the all immediate childs for a pid
	// from /proc/<pid>/task/{tid}/children file (since linux 3.5)
	// check `man 5 proc` for more details
	childPids := []int{}

	// find all tasks with in a pid
	tasks, err := ioutil.ReadDir(
		fmt.Sprintf("/proc/%d/task", pid))
	if err != nil {
		return []int{}, err
	}

	// if there are more than one tasks, get child of that too
	for _, taskFile := range tasks {
		chBytes, err := ioutil.ReadFile(
			fmt.Sprintf("/proc/%d/task/%s/children",
				pid, taskFile.Name()))
		if err != nil {
			if os.IsNotExist(err) {
				// file seems to be missing, which means
				// task might have ended
				continue
			}
			return []int{}, err
		}

		// /proc/<pid>/task/<tid>/children contains pids
		// of all immediate child process
		childrens := string(chBytes)
		start := 0
		for i := range childrens {
			ch := childrens[i]
			if ch == ' ' {
				childPid, err := strconv.Atoi(childrens[start:i])
				if err != nil {
					return []int{}, err
				}

				childPids = append(childPids, childPid)
				start = i + 1
			}
		}
	}

	return childPids, nil
}
