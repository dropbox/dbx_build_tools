package genbuildgolib

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestExtractBuildTags(t *testing.T) {
	testCases := []struct {
		name         string
		goSRC        string
		expectedTags []string
	}{
		{
			name:         "empty source file",
			goSRC:        "",
			expectedTags: []string{},
		},
		{
			name: "no build directive",
			goSRC: `
		    package main

		    import "fmt"

		    func main() {
		        fmt.Println("Hello, world!")
		    }
		    `,
			expectedTags: []string{},
		},
		{
			name: "simple single build directive go toolchain",
			goSRC: `
		    //go:build go1.14`,
			expectedTags: []string{"go1.14"},
		},
		{
			name:         "single build directive go toolchain",
			goSRC:        `//go:build go1.14 && !go1.16`,
			expectedTags: []string{"go1.14 && !go1.16"},
		},
		{
			name:         "single build directives not go toolchain",
			goSRC:        `//go:build cgo && !nosqlite`,
			expectedTags: []string{},
		},
		{
			name: "multiple build directives with go toolchain",
			goSRC: `
            //go:build cgo && !nosqlite
			//go:build go1.14 && !go1.16`,
			expectedTags: []string{"go1.14 && !go1.16"},
		},
		// This would be very odd and not recommended...
		{
			name: "multiple build tags for go toolchains separately",
			goSRC: `
			//go:build go1.14
            //go:build !go1.16`,
			expectedTags: []string{"go1.14", "!go1.16"},
		},
		// We also support the old style tags
		{
			name:         "old style tags single",
			goSRC:        `// +build go1.5`,
			expectedTags: []string{"go1.5"},
		},
		{
			name:         "old style tags single with NOT",
			goSRC:        `//+build !go1.9`,
			expectedTags: []string{"!go1.9"},
		},
		{
			name:         "old style tags",
			goSRC:        `// +build go1.14,!go1.16`,
			expectedTags: []string{"go1.14 && !go1.16"},
		},
		{
			name:         "old style tags with incorrect format",
			goSRC:        `//+build go1.14,!go1.16`,
			expectedTags: []string{"go1.14 && !go1.16"},
		},
		{
			name:         "old style tags with OR (no support)",
			goSRC:        `// +build go1.14 !go1.16`,
			expectedTags: []string{},
		},
		{
			name:         "old style tags with AND of non-supported tag",
			goSRC:        `// +build linux,!go1.16`,
			expectedTags: []string{"!go1.16"},
		},
	}

	// Run the test cases
	for _, tc := range testCases {
		require.Equal(t, tc.expectedTags, extractBuildTags(tc.goSRC), "Failed for test case: '%s' with source code `%s`", tc.name, tc.goSRC)
	}
}

func TestExtractIdentifiers(t *testing.T) {
	testCases := []struct {
		name     string
		input    string
		expected []string
	}{
		{
			name:     "Identifiers are not negated",
			input:    "nosqldb",
			expected: []string{"nosqldb"},
		},
		{
			name:     "Identifiers are not negated",
			input:    "go1.14 && go1.16",
			expected: []string{"go1.14", "go1.16"},
		},
		{
			name:     "Identifiers are separated by &&",
			input:    "go1.14 && !go1.16",
			expected: []string{"go1.14", "!go1.16"},
		},
		{
			name:     "Identifiers are separated by ||",
			input:    "go1.14 || !go1.16",
			expected: []string{"go1.14", "!go1.16"},
		},
		{
			name:     "String contains no identifiers",
			input:    "",
			expected: []string{},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(tr *testing.T) {
			actual := extractIdentifiers(tc.input)
			require.ElementsMatch(tr, tc.expected, actual, tc.name+"-- FAILED")
		})
	}
}

func TestWriteTagmapToBuildFile(t *testing.T) {

	tm := TagMap{
		"bolt-piece.go": []string{"go1.14 && !go1.16"},
		"sql-piece.go":  []string{"go1.4"},
	}
	b := strings.Builder{}
	WriteTagMap(tm, &b)
	require.Equal(
		t,
		`tagmap={"bolt-piece.go":["go1.14","!go1.16"],"sql-piece.go":["go1.4"],},`+"\n",
		b.String(),
	)
	// empty case
	b = strings.Builder{}
	WriteTagMap(nil, &b)
	require.Equal(t, ``, b.String())
}
