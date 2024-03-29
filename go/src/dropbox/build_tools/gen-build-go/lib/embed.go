package lib

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"go/build"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	bazelAttributeConfig = "embed_config"
	// Note: That if the data attribute is already being used then use "additional_data" in BUILD.in
	bazelAttributeSRCs = "data"
)

// EmbedConfigWrapper is useful because we can keep all associated data for go:embedded directives in one place
type EmbedConfigWrapper struct {
	EC     EmbedConfig
	TestEC EmbedConfig
}

// From the go.1.19 source code
// https://cs.opensource.google/go/go/+/refs/tags/go1.19:src/cmd/compile/internal/base/flag.go;l=131;drc=0b2ad1d815ea8967c49b32d848b2992d0c588d88;bpv=1;bpt=1
// NOTE: This is an undocumented parameter and is subject to CHANGE! Basically not an API we can rely on
type EmbedConfig struct {
	Patterns map[string][]string
	Files    map[string]string
	// These SRCs are added to the "data" attribute
	SRCs []string `json:"-"`
}

func BuildEmbedConfigForPkg(pkg *build.Package, workspace string, useAbsoluteFilepaths bool) (EmbedConfigWrapper, error) {
	ecw := EmbedConfigWrapper{
		EC: EmbedConfig{
			Patterns: map[string][]string{},
			Files:    map[string]string{},
		},
		TestEC: EmbedConfig{
			Patterns: map[string][]string{},
			Files:    map[string]string{},
		},
	}
	if len(pkg.EmbedPatterns) == 0 && len(pkg.TestEmbedPatterns) == 0 {
		return ecw, nil
	}

	dir, err := filepath.Abs(pkg.Dir)
	if err != nil {
		return ecw, err
	}
	ecw.EC, err = generateEmbedConfig(pkg.EmbedPatterns, workspace, dir, useAbsoluteFilepaths)
	if err != nil {
		return ecw, err
	}
	ecw.TestEC, err = generateEmbedConfig(pkg.TestEmbedPatterns, workspace, dir, useAbsoluteFilepaths)
	if err != nil {
		return ecw, err
	}

	return ecw, nil
}

func generateEmbedConfig(patterns []string, workspace, dir string, useAbsoluteFilepaths bool) (EmbedConfig, error) {
	ec := EmbedConfig{
		Patterns: map[string][]string{},
		Files:    map[string]string{},
	}
	for _, p := range patterns {
		fullPattern := filepath.Join(dir, p)
		globMatches, globErr := filepath.Glob(fullPattern)
		if globErr != nil {
			return ec, fmt.Errorf("could not glob pattern %s, err: %w", fullPattern, globErr)
		}

		for _, fp := range globMatches {
			// workspace and dir are already absolute paths as given by the
			// caller, but fp is not necessarily an absolute path. let's make
			// it one.
			fp, err := filepath.Abs(fp)
			if err != nil {
				return ec, err
			}

			stat, err := os.Stat(fp)
			if err != nil {
				return ec, err
			}

			var filePaths []string
			if stat.IsDir() {
				err = filepath.WalkDir(fp, func(filePath string, entry fs.DirEntry, err error) error {
					if err != nil {
						return err
					}
					if strings.HasPrefix(filePath, ".") || strings.HasPrefix(filePath, "-") {
						return nil
					}
					if !entry.IsDir() {
						filePaths = append(filePaths, filePath)
					}
					return nil
				})
				if err != nil {
					return ec, err
				}
			} else {
				filePaths = []string{fp}
			}

			for _, fp := range filePaths {
				fpRelDir, err := filepath.Rel(dir, fp)
				if err != nil {
					return ec, err
				}

				ec.Patterns[p] = append(ec.Patterns[p], fpRelDir)

				if useAbsoluteFilepaths {
					// if requested, use an absolute path to point to the file.
					// this is mostly used to make sure Bazel can for sure find
					// the exact path.
					ec.Files[fpRelDir] = fp
				} else {
					if workspace == "" {
						return ec, errors.New("embed: workspace not found but required")
					}
					fpRelWorkspace, err := filepath.Rel(workspace, fp)
					if err != nil {
						return ec, err
					}
					// otherwise, use a relative path from WORKSPACE.
					ec.Files[fpRelDir] = fpRelWorkspace
				}

				// for SRCs, use a relative path from the current directory because
				// that's where the generated BUILD file will be and paths are
				// relative to that.
				ec.SRCs = append(ec.SRCs, fpRelDir)
			}
		}
	}
	return ec, nil
}

// WriteEmbedConfig serializes the embed patterns and files into a dictionary
// NOTE: Formatting is not an issue because we run "buildifier" on the merged output of the BUILD
// files at the end
func WriteEmbedConfig(ec EmbedConfig, b io.StringWriter) {
	if len(ec.Files) == 0 || len(ec.Patterns) == 0 {
		return
	}
	// To make sure it's all deterministic we write out the JSON by hand
	res, _ := json.MarshalIndent(ec, "", " ")
	_, _ = b.WriteString(bazelAttributeConfig + `="""` + string(res) + `""",`)
}

func (ecw EmbedConfigWrapper) WriteToBUILD(name string, buffer io.StringWriter) {
	var ec EmbedConfig
	if strings.HasSuffix(name, suffixGoTest) && len(ecw.TestEC.Files) > 0 {
		ec = ecw.TestEC
	} else if len(ecw.EC.Files) > 0 {
		ec = ecw.EC
	}
	WriteEmbedConfig(ec, buffer)
	WriteListToBuild(bazelAttributeSRCs, ec.SRCs, buffer, false)
}

func (ec EmbedConfig) MarshalJSON() ([]byte, error) {
	// Create a buffer to hold the JSON object
	var buf bytes.Buffer

	buf.WriteByte('{')

	buf.WriteString(`"Patterns":{`)
	keys := make([]string, 0, len(ec.Patterns))
	for key := range ec.Patterns {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for i, key := range keys {
		buf.WriteString(`"` + key + `":`)
		patterns := ec.Patterns[key]
		patternsString := strings.Join(patterns, `","`)
		buf.WriteString(`["` + patternsString + `"]`)
		if i < len(keys)-1 {
			buf.WriteByte(',')
		}
	}
	buf.WriteByte('}')
	buf.WriteByte(',')

	buf.WriteString(`"Files":{`)
	keys = keys[:0]
	for key := range ec.Files {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for i, key := range keys {
		buf.WriteString(`"` + key + `":`)
		file := ec.Files[key]
		buf.WriteString(`"` + file + `"`)
		if i < len(keys)-1 {
			buf.WriteByte(',')
		}
	}
	buf.WriteByte('}')

	// Close JSON object
	buf.WriteByte('}')

	return buf.Bytes(), nil
}
