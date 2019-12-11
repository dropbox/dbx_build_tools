// Convert go coverage profiles to cobertura.

package main

import (
	"bufio"
	"encoding/xml"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"dropbox/devtools/coverage/cobertura/coberturaxml"
)

type coverFile struct {
	mode   string
	blocks []coverBlock
}

type coverBlock struct {
	line0 int
	col0  int
	line1 int
	col1  int
	stmts int
	count int
}

func toInt(s string) int {
	i, err := strconv.Atoi(s)
	if err != nil {
		panic(err)
	}
	return i
}

var lineRe = regexp.MustCompile(`^(.+):([0-9]+).([0-9]+),([0-9]+).([0-9]+) ([0-9]+) ([0-9]+)$`)

func parseProfile(pf io.Reader) (map[string]*coverFile, error) {
	files := make(map[string]*coverFile)
	buf := bufio.NewReader(pf)
	// First line is "mode: foo", where foo is "set", "count", or "atomic".
	// Rest of file is in the format
	//	encoding/base64/base64.go:34.44,37.40 3 1
	// where the fields are: name.go:line.column,line.column numberOfStatements count
	s := bufio.NewScanner(buf)
	mode := ""
	for s.Scan() {
		line := s.Text()
		if mode == "" {
			const p = "mode: "
			if !strings.HasPrefix(line, p) || line == p {
				return nil, fmt.Errorf("bad mode line: %v", line)
			}
			mode = line[len(p):]
			continue
		}
		m := lineRe.FindStringSubmatch(line)
		if m == nil {
			return nil, fmt.Errorf("line %q doesn't match expected format: %v", m, lineRe)
		}
		fn := m[1]
		p := files[fn]
		if p == nil {
			p = &coverFile{
				mode: mode,
			}
			files[fn] = p
		}
		p.blocks = append(p.blocks, coverBlock{
			line0: toInt(m[2]),
			col0:  toInt(m[3]),
			line1: toInt(m[4]),
			col1:  toInt(m[5]),
			stmts: toInt(m[6]),
			count: toInt(m[7]),
		})
	}
	if err := s.Err(); err != nil {
		return nil, err
	}
	return files, nil
}

func main() {
	flag.Parse()

	coverage, err := parseProfile(os.Stdin)
	if err != nil {
		log.Fatal(err)
	}

	// Results are stored in a single "package". We don't attempt to split up results by Go
	// package boundaries.
	pkg := &coberturaxml.Package{}

	// For any line that is part of 1/more coverage block, compute total number of "hits" for that line.
	for fName, profile := range coverage {
		// Each file is represented as a class in coverage output.
		cls := &coberturaxml.Class{Filename: fName}
		pkg.Classes = append(pkg.Classes, cls)

		// Sum up hits for each line across all coverage blocks. We assume that a coverage
		// block of the form {Line0: l0, Line1: l1} includes all lines l0...l1 inclusive of
		// both ends. For simplicity in conforming to the Cobertura per-line-hits format, we
		// don't attempt to differentiate blocks which span the same code line.
		lineHits := map[int]int{}
		for _, block := range profile.blocks {
			hits := block.count
			for lineNo := block.line0; lineNo <= block.line1; lineNo++ {
				lineHits[lineNo] += hits
			}
		}

		// Extract unique line numbers for sorting
		lineNos := []int{}
		for lineNo := range lineHits {
			lineNos = append(lineNos, lineNo)
		}
		sort.Ints(lineNos)

		// Generate one "Line" entry per line
		for _, lineNo := range lineNos {
			cls.Lines = append(cls.Lines, &coberturaxml.Line{
				Hits:   int64(lineHits[lineNo]),
				Number: lineNo,
			})
		}
	}
	enc := xml.NewEncoder(os.Stdout)
	if encErr := enc.Encode(&coberturaxml.Coverage{Packages: []*coberturaxml.Package{pkg}}); encErr != nil {
		log.Fatal(encErr)
	}
}
