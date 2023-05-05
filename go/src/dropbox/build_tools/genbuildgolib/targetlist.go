package genbuildgolib

import "strings"

type TargetList []string

func (s TargetList) Len() int {
	return len(s)
}

func (s TargetList) Swap(i int, j int) {
	s[i], s[j] = s[j], s[i]
}

func (s TargetList) Less(i int, j int) bool {
	p1 := s.priority(s[i])
	p2 := s.priority(s[j])

	if p1 < p2 {
		return true
	}
	if p2 < p1 {
		return false
	}

	return s[i] < s[j]
}

func (s TargetList) priority(target string) int {
	if strings.HasPrefix(target, "//") {
		return 3
	}
	if strings.HasPrefix(target, ":") {
		return 2
	}
	return 1
}
