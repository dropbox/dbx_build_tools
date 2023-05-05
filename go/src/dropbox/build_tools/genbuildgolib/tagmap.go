package genbuildgolib

import (
	"io"
	"io/ioutil"
	"os"
	"path"
	"regexp"
	"sort"
	"strings"

	"godropbox/errors"
)

const (
	oldBuildTagPrefix = "+build"
	buildTagPrefix    = "//go:build"
	tokenOr           = "||"
	tokenAnd          = "&&"
)

var (
	patternGoToolchain = regexp.MustCompile(`(go\d+\.\d+)`)
	patternIdentifier  = regexp.MustCompile(`([^&|\s]+)`)
)

type TagMap = map[string][]string

func BuildTagmapForPkg(dirPath string) (TagMap, error) {
	tm := TagMap{}

	// Note that we can't use the 'ast/parser' package because it ignores go directives like
	// go:build, go:generate etc.
	// So we resort to just reading the files manually
	files, err := os.ReadDir(dirPath)
	if err != nil {
		return nil, errors.Wrapf(err, "Failed while reading %s", dirPath)
	}
	for _, di := range files {
		// Also note that we don't recursively walk directories
		if di.IsDir() || !isGoFile(di.Name()) {
			continue
		}
		p := path.Join(dirPath, di.Name())
		b, readErr := ioutil.ReadFile(p)
		if readErr != nil {
			return nil, readErr
		}

		bts := extractBuildTags(string(b))
		if len(bts) > 0 {
			tm[di.Name()] = bts
		}
	}
	return tm, nil
}

func isOldBuildTag(line string) bool {
	// Without the space is not techinically correct, but we support it 🤷
	return strings.HasPrefix(line, "// "+oldBuildTagPrefix) || strings.HasPrefix(line, "//"+oldBuildTagPrefix)
}

func convertBuildDirective(oldDirective string) string {
	needleStart := strings.Index(oldDirective, oldBuildTagPrefix)
	needleEnd := needleStart + len(oldBuildTagPrefix) + 1
	tagsPortion := oldDirective[needleEnd:]
	tagsPortion = strings.ReplaceAll(tagsPortion, " ", " || ")
	tagsPortion = strings.ReplaceAll(tagsPortion, ",", " && ")

	return "//go:build " + tagsPortion
}

// note: I consider the "!" as part of the identifier to make my life easier
// but this will probably bite me later
func extractIdentifiers(goBuildDirective string) []string {
	idents := patternIdentifier.FindAllString(goBuildDirective, -1)
	return idents
}

func isOnlyGoToolchains(constraint string) bool {
	return patternGoToolchain.MatchString(constraint)
}

func reconstructTags(tags []string) string {
	tagString := ""
	if len(tags) == 1 {
		tagString += tags[0]
	} else {
		for _, t := range tags {
			tagString += t + " && "
		}
		tagString = strings.TrimSuffix(tagString, " && ")
	}

	return tagString
}

func extractBuildTags(goSRC string) []string {
	buildTags := []string{}
	lines := strings.Split(goSRC, "\n")
	for _, line := range lines {
		line = strings.Trim(line, " \t")
		if isOldBuildTag(line) {
			line = convertBuildDirective(line)
		}

		if !strings.HasPrefix(line, buildTagPrefix) {
			continue
		}

		line = strings.TrimPrefix(line, buildTagPrefix)
		// Validations: Discard things we don't support
		// 1. Our bzl rule does not support OR logic
		if strings.Contains(line, tokenOr) {
			continue
		}

		// 2. We only support build tags for go toolchains ATM
		// We do this by filtering out identifiers we don't support
		idents := extractIdentifiers(line)
		tags := []string{}
		for _, ident := range idents {
			if isOnlyGoToolchains(ident) {
				tags = append(tags, ident)
			}
		}
		// Re-construct the tags with only the things we support
		buildTagsString := reconstructTags(tags)
		if buildTagsString == "" {
			continue
		}

		buildTags = append(buildTags, buildTagsString)
		// If there is a new style and old style go build directive, we can just de-dupe them here
		buildTags = Uniq(buildTags)
	}

	return buildTags
}

// WriteTagMap serializes the tagMap into the format meant for BUILD files
// It's parsed by our custom bazel rules to determine whether to skip files or not
// NOTE: Formatting is not an issue because we run "buildifier" on the merged output of the BUILD
// files at the end
func WriteTagMap(tm TagMap, b io.StringWriter) {
	if len(tm) == 0 {
		return
	}

	// Bazel syntax is slightly different than JSON so this is less painful then using an encoder
	_, _ = b.WriteString(`tagmap={`)
	// Sort them for deterministic output
	keys := make([]string, 0, len(tm))
	for k := range tm {
		keys = append(keys, k)
	}
	sort.Sort(sort.StringSlice(keys))

	// NOTE: That our bzl rule for tagmap is fairly rudimentary and only handles a single tag per entry,
	// and can only handle AND and NOT logic.
	// So when we write to the BUILD file we have to simplify and throw away any OR logic
	for _, filename := range keys {
		_, _ = b.WriteString(`"` + filename + `":["`)
		buildTags := tm[filename]

		flattenedBT := []string{}
		for _, bt := range buildTags {
			bt = strings.ReplaceAll(bt, " ", "")
			flattenedBT = append(flattenedBT, strings.Split(bt, tokenAnd)...)
		}

		_, _ = b.WriteString(strings.Join(flattenedBT, `","`))
		_, _ = b.WriteString(`"],`)
	}
	b.WriteString("},\n")
}

// keepEntries is a function for keeping entries of a map based on a given "toKeep" slice
// updates are done in-place
func keepEntries[K comparable, V any](m map[K]V, toKeep []K) {
	// Drop any tags for files that aren't in "srcs"
	for k := range m {
		found := false
		for _, tk := range toKeep {
			if tk == k {
				found = true
				break
			}
		}
		if !found {
			// In Go it's safe to delete keys during iteration because they are just marked as empty
			delete(m, k)
		}
	}
}
