package codegen

import (
	"fmt"
	"sort"
	"strings"
)

type ImportName struct {
	name  string
	alias string
}

func (n *ImportName) String() string {
	return n.alias
}

type nestedImport struct {
	importName *ImportName
	message    string
}

func (n *nestedImport) String() string {
	return n.importName.alias + "." + n.message
}

func NewNestedImport(importName *ImportName, message string) *nestedImport {
	return &nestedImport{
		importName: importName,
		message:    message,
	}
}

type PythonPkgMap struct {
	// package -> name
	imports map[string]map[string]*ImportName
	locals  []string
}

func NewPythonPkgMap() *PythonPkgMap {
	return &PythonPkgMap{
		imports: make(map[string]map[string]*ImportName),
		locals:  make([]string, 0),
	}
}

func (m *PythonPkgMap) From(path string, name string) *ImportName {
	if strings.HasSuffix(path, ".py") {
		path = path[:len(path)-3]
	} else if strings.HasSuffix(path, ".proto") {
		path = path[:len(path)-6] + "_pb2"
	}

	path = strings.Replace(path, "/", ".", -1)

	if _, ok := m.imports[path]; !ok {
		m.imports[path] = make(map[string]*ImportName)
	}

	entry := m.imports[path][name]

	if entry == nil {
		entry = &ImportName{
			name: name,
		}

		m.imports[path][name] = entry
	}

	return entry
}

func (m *PythonPkgMap) RegisterLocal(name string) {
	m.locals = append(m.locals, name)
}

func (m *PythonPkgMap) AssignAliases() {
	used := make(map[string]struct{})

	for _, local := range m.locals {
		used[local] = struct{}{}
	}

	// Sort the imports for stability
	var keys []string
	for key := range m.imports {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	for _, key := range keys {
		nameEntries := m.imports[key]

		var names []string
		for name := range nameEntries {
			names = append(names, name)
		}
		sort.Strings(names)

		for _, name := range names {
			entry := nameEntries[name]
			if name == "" {
				name = key
			}
			count := 0
			for {
				alias := name
				if count > 0 {
					alias = fmt.Sprintf("%s%d", name, count)
				}

				_, ok := used[alias]
				if !ok {
					entry.alias = alias
					used[alias] = struct{}{}
					break
				}

				count++
			}
		}
	}
}

func (m *PythonPkgMap) String() string {
	if len(m.imports) == 0 {
		return ""
	}

	m.AssignAliases()

	pylang := []string{}
	dropbox := []string{}

	for path, _ := range m.imports {
		if strings.HasPrefix(path, "dropbox") {
			dropbox = append(dropbox, path)
		} else {
			pylang = append(pylang, path)
		}
	}

	sort.Strings(pylang)
	sort.Strings(dropbox)

	hdr := NewLineWriter("    ")
	l := hdr.Line

	m.writeImports(hdr, pylang)
	if len(pylang) > 0 {
		l("")
	}

	m.writeImports(hdr, dropbox)
	if len(dropbox) > 0 {
		l("")
	}

	l("")

	return hdr.String()
}

func (m *PythonPkgMap) writeImports(
	w LineWriter,
	paths []string) {

	l := w.Line
	push := w.PushIndent
	pop := w.PopIndent

	for _, path := range paths {
		names := []string{}
		for name, _ := range m.imports[path] {
			if name == "" {
				l("import %s", path)
			} else {
				names = append(names, name)
			}
		}
		sort.Strings(names)

		if len(names) == 0 {
			continue
		}

		l("from %s import (", path)
		push()

		for _, name := range names {
			entry := m.imports[path][name]
			if entry.alias == entry.name {
				l("%s,", entry.name)
			} else {
				l("%s as %s,", entry.name, entry.alias)
			}
		}

		pop()
		l(")")
	}
}
