// Bare bones Go testing support for Bazel.

package main

import (
	"flag"
	"go/ast"
	"unicode"
	"go/doc"
	"go/parser"
	"go/token"
	"log"
	"unicode/utf8"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"
	"text/template"
)

// Holds template data.
type TestsContext struct {
	HasTests       bool
	HasExamples    bool
	Package        string
	Names          []string
	BenchmarkNames []string
	Examples       []*doc.Example
	CoverEnabled   bool
	CoverVars      map[string]string
	TestMain bool
}

func isTest(name, prefix string) bool {
	if !strings.HasPrefix(name, prefix) {
		return false
	}
	if len(name) == len(prefix) { // "Test" is ok
		return true
	}
	rune, _ := utf8.DecodeRuneInString(name[len(prefix):])
	return !unicode.IsLower(rune)
}

func isTestFunc(fn *ast.FuncDecl, arg string) bool {
	if fn.Type.Results != nil && len(fn.Type.Results.List) > 0 ||
		fn.Type.Params.List == nil ||
		len(fn.Type.Params.List) != 1 ||
		len(fn.Type.Params.List[0].Names) > 1 {
		return false
	}
	ptr, ok := fn.Type.Params.List[0].Type.(*ast.StarExpr)
	if !ok {
		return false
	}
	// We can't easily check that the type is *testing.M
	// because we don't know how testing has been imported,
	// but at least check that it's *M or *something.M.
	// Same applies for B and T.
	if name, ok := ptr.X.(*ast.Ident); ok && name.Name == arg {
		return true
	}
	if sel, ok := ptr.X.(*ast.SelectorExpr); ok && sel.Sel.Name == arg {
		return true
	}
	return false
}

func main() {
	pkg := flag.String("package", "", "package from which to import test methods.")
	cover := flag.Bool("cover", false, "if set, enable test coverage.")
	out := flag.String("output", "", "output file to write. Defaults to stdout.")
	flag.Parse()

	if *pkg == "" {
		log.Fatal("must set --package.")
	}

	outFile := os.Stdout
	if *out != "" {
		var err error
		outFile, err = os.Create(*out)
		if err != nil {
			log.Fatalf("os.Create(%q): %v", *out, err)
		}

		defer func() {
			if err := outFile.Close(); err != nil {
				log.Fatalf("Error closing file: %v", err)
			}
		}()
	}

	context := TestsContext{
		Package:      *pkg,
		CoverEnabled: *cover,
	}
	testFileSet := token.NewFileSet()
	coverFiles := make([]string, 0, len(flag.Args()))
	for _, f := range flag.Args() {
		isTestFile := strings.HasSuffix(f, "_test.go")
		if !isTestFile && !(*cover && strings.HasSuffix(f, ".go")) {
			log.Fatalf("Not expecting file %q.", f)
		}
		if !isTestFile {
			coverFiles = append(coverFiles, f)
			continue
		}
		parse, err := parser.ParseFile(testFileSet, f, nil, parser.ParseComments)
		if err != nil {
			log.Fatalf("ParseFile(%q): %v", f, err)
		}

		for _, d := range parse.Decls {
			n, ok := d.(*ast.FuncDecl)
			if !ok {
				continue
			}
			if n.Recv != nil {
				continue
			}
			name := n.Name.String()
			switch {
			case name == "TestMain":
				if isTestFunc(n, "T") {
					context.Names = append(context.Names, name)
					context.HasTests = true
					continue
				}
				if context.TestMain {
					log.Fatal("multiple definitions of TestMain")
				}
				context.TestMain = true
			case isTest(name, "Test"):
				context.Names = append(context.Names, name)
				context.HasTests = true
			case isTest(name, "Benchmark"):
				context.BenchmarkNames = append(context.BenchmarkNames, name)
			}
		}
		ex := doc.Examples(parse)
		sort.Slice(ex, func(i, j int) bool { return ex[i].Order < ex[j].Order })
		for _, e := range ex {
			if e.Output == "" && !e.EmptyOutput {
				continue
			}
			context.Examples = append(context.Examples, e)
		}
	}


	if !context.HasTests && len(context.Examples) == 0 && len(context.BenchmarkNames) == 0 {
		log.Fatalf("No test methods (functions with prefix `Test`) or benchmarks (functions with prefix `Benchmark`) found in files %s", flag.Args())
	}

	if len(coverFiles) > 0 {
		sort.Strings(coverFiles)
		seq := 0
		context.CoverVars = make(map[string]string, len(coverFiles))
		for _, f := range coverFiles {
			context.CoverVars[f] = "GoCover_" + strconv.Itoa(seq)
			seq++
		}
	}

	tpl := template.Must(template.ParseFiles(path.Join(os.Getenv("RUNFILES"), "build_tools/go/test_main.go.tmpl")))
	if err := tpl.Execute(outFile, &context); err != nil {
		log.Fatalf("template.Execute(%v): %v", context, err)
	}
}
