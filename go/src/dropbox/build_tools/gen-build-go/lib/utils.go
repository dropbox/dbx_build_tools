package lib

import (
	"io"
	"sort"
	"strings"
)

const (
	suffixGoFile = ".go"
	// The suffix we use for testing bzl gen stuff
	suffixMockGoFile = ".go.txt"
)

func WriteListToBuild(
	attributeName string,
	lst []string,
	buffer io.StringWriter,
	writeIfEmpty bool, // Note: Make this an options struct if there are more options later
) {
	if len(lst) == 0 && !writeIfEmpty {
		return
	}

	_, _ = buffer.WriteString(attributeName + " = [\n")
	for _, element := range lst {
		_, _ = buffer.WriteString("'" + element + "',\n")
	}
	_, _ = buffer.WriteString("],\n")
}

type SliceType interface {
	~string | ~int | ~float64 // add more *comparable* types as needed
}

// Uniq removes duplicates from the given slice
func Uniq[T SliceType](items []T) []T {
	keys := make(map[T]struct{})
	deduped := make([]T, 0, len(items))

	for _, item := range items {
		if _, ok := keys[item]; ok {
			continue
		}

		keys[item] = struct{}{}
		deduped = append(deduped, item)
	}

	return deduped
}
func UniqSort(items []string) []string {
	keys := make(map[string]struct{})
	deduped := make(TargetList, 0, len(items))

	for _, item := range items {
		if _, ok := keys[item]; ok {
			continue
		}

		keys[item] = struct{}{}
		deduped = append(deduped, item)
	}

	sort.Sort(deduped)

	return deduped
}

func isGoFile(name string) bool {
	return strings.HasSuffix(name, suffixGoFile) || strings.HasSuffix(name, suffixMockGoFile)
}
