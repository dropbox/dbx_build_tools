// Accepts multiple arguments to merge, in batches of 3. Inputs are merged in the same order
// they appear in the argument list.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io/ioutil"
	"os"
	"sort"
	"strings"

	"github.com/bazelbuild/buildtools/build"
	"github.com/bazelbuild/buildtools/warn"
)

type mergeable struct {
	stmt   build.Expr
	merged bool

	targetName string
}

type parsed struct {
	*build.File

	stmts []*mergeable

	pkg      *mergeable
	loads    map[string][]*mergeable
	licenses *mergeable

	calls map[string]*mergeable
}

func parse(name string) *parsed {
	data, err := ioutil.ReadFile(name)
	if err != nil {
		fmt.Println("Failed to read:", name)
		fmt.Println(err)
		os.Exit(1)
	}

	file, err := build.ParseBuild(name, data)
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}

	p := &parsed{
		File:  file,
		loads: make(map[string][]*mergeable),
		calls: make(map[string]*mergeable),
	}

	for _, stmt := range file.Stmt {
		m := &mergeable{stmt, false, ""}
		p.stmts = append(p.stmts, m)

		switch t := m.stmt.(type) {
		case *build.CallExpr:
			method, ok := t.X.(*build.Ident)
			if !ok {
				continue
			}

			switch method.Name {
			case "package":
				p.pkg = m
			case "licenses":
				p.licenses = m
			default:
				for _, expr := range t.List {
					assign, ok := expr.(*build.AssignExpr)
					if !ok {
						continue
					}

					lhs, ok := assign.LHS.(*build.Ident)
					if !ok {
						continue
					}

					if lhs.Name != "name" {
						continue
					}

					rhs, ok := assign.RHS.(*build.StringExpr)
					if !ok {
						continue
					}

					m.targetName = rhs.Value
					p.calls[rhs.Value] = m
					break
				}
			}
		case *build.LoadStmt:
			p.loads[t.Module.Value] = append(p.loads[t.Module.Value], m)
		}
	}

	return p
}

func maybeMergeAdditionalArg(
	name string,
	assign *build.AssignExpr,
	additionalArgs map[string]*build.AssignExpr,
	used map[string]struct{}) error {

	additional, ok := additionalArgs["additional_"+name]
	if !ok {
		return nil
	}

	used["additional_"+name] = struct{}{}

	switch t := assign.RHS.(type) {
	case *build.ListExpr:
		l, ok := additional.RHS.(*build.ListExpr)
		if !ok {
			return fmt.Errorf(
				"Cannot merge %s with addition_%s",
				name,
				name)
		}

		assign.RHS = &build.BinaryExpr{
			X:         t,
			Op:        "+",
			LineBreak: true,
			Y:         l,
		}
	case *build.DictExpr:
		d, ok := additional.RHS.(*build.DictExpr)
		if !ok {
			return fmt.Errorf(
				"Cannot merge %s with addition_%s",
				name,
				name)
		}

		assign.RHS = &build.CallExpr{
			X: &build.DotExpr{
				X:    t,
				Name: "update",
			},
			List: []build.Expr{d},
		}
	case *build.CallExpr:
		identExpr, identExprOk := t.X.(*build.Ident)
		if !identExprOk {
			return fmt.Errorf(
				"Cannot merge %s with addition_%s",
				name,
				name)
		}
		if identExpr.Name != "glob" {
			return fmt.Errorf(
				"Cannot merge %s with addition_%s",
				name,
				name)
		}
		l, ok := additional.RHS.(*build.ListExpr)
		if !ok {
			return fmt.Errorf(
				"Cannot merge %s with addition_%s",
				name,
				name)
		}

		assign.RHS = &build.BinaryExpr{
			X:         t,
			Op:        "+",
			LineBreak: true,
			Y:         l,
		}

	default:
		return fmt.Errorf(
			"Cannot merge %s with additional_%s",
			name,
			name)
	}

	return nil
}

func mergeCallExpr(m1 *mergeable, m2 *mergeable) (*build.CallExpr, error) {
	call1 := m1.stmt.(*build.CallExpr)
	call2 := m2.stmt.(*build.CallExpr)

	// assumption call1.X == call2.X

	out := &build.CallExpr{}
	*out = *call1
	out.List = nil

	out.Comments.Before = append(
		out.Comments.Before,
		call2.Comments.Before...)

	out.Comments.Suffix = append(
		out.Comments.Suffix,
		call2.Comments.Suffix...)

	out.Comments.After = append(
		out.Comments.After,
		call2.Comments.After...)

	overrideArgs := make(map[string]*build.AssignExpr)
	additionalArgs := make(map[string]*build.AssignExpr)
	for _, arg := range call2.List {
		assign, ok := arg.(*build.AssignExpr)
		if !ok {
			continue
		}

		name, ok := assign.LHS.(*build.Ident)
		if !ok {
			continue
		}

		if strings.HasPrefix(name.Name, "additional_") {
			additionalArgs[name.Name] = assign
		} else {
			overrideArgs[name.Name] = assign
		}
	}

	used := make(map[string]struct{})
	for _, arg := range call1.List {
		assign, ok := arg.(*build.AssignExpr)
		if !ok {
			out.List = append(out.List, arg)
			continue
		}

		name, ok := assign.LHS.(*build.Ident)
		if !ok {
			out.List = append(out.List, arg)
			continue
		}

		override, ok := overrideArgs[name.Name]
		if ok {
			used[name.Name] = struct{}{}
			assign = override
		}

		err := maybeMergeAdditionalArg(name.Name, assign, additionalArgs, used)
		if err != nil {
			return nil, err
		}

		out.List = append(out.List, assign)
	}

	for name, assign := range overrideArgs {
		_, ok := used[name]
		if ok {
			continue
		}

		err := maybeMergeAdditionalArg(name, assign, additionalArgs, used)
		if err != nil {
			return nil, err
		}

		out.List = append(out.List, assign)
	}

	for name, assign := range additionalArgs {
		_, ok := used[name]
		if ok {
			continue
		}

		entry := &build.AssignExpr{}
		*entry = *assign

		argName := &build.Ident{}
		*argName = *(assign.LHS.(*build.Ident))
		argName.Name = name[len("additional_"):]

		entry.LHS = argName

		out.List = append(out.List, entry)
	}

	m1.merged = true
	m2.merged = true
	return out, nil
}

// Check if two license() calls are equivalent. May also return false
// if the licenses() calls are malformed in any way.
func mergeLicenses(licenses1Expr, licenses2Expr *mergeable) *build.CallExpr {
	// Check if we can trivially use one or the other.
	if licenses1Expr == nil {
		return licenses2Expr.stmt.(*build.CallExpr)
	}
	if licenses2Expr == nil {
		return licenses1Expr.stmt.(*build.CallExpr)
	}
	licenses1 := licenses1Expr.stmt.(*build.CallExpr)
	licenses2 := licenses2Expr.stmt.(*build.CallExpr)
	// We compare the suffix comments, since they conventionally contain the exact license.
	comments1 := licenses1.Comment().Suffix
	comments2 := licenses2.Comment().Suffix
	if len(comments1) != len(comments2) {
		return nil
	}
	for i := 0; i < len(comments1); i++ {
		if comments1[i].Token != comments2[i].Token {
			return nil
		}
	}
	if len(licenses1.List) != 1 {
		return nil
	}
	if len(licenses2.List) != 1 {
		return nil
	}
	license1List, ok := licenses1.List[0].(*build.ListExpr)
	if !ok {
		return nil
	}
	license2List, ok := licenses2.List[0].(*build.ListExpr)
	if !ok {
		return nil
	}
	if len(license1List.List) != len(license2List.List) {
		return nil
	}
	for i := 0; i < len(license1List.List); i++ {
		license1Str, ok := license1List.List[i].(*build.StringExpr)
		if !ok {
			return nil
		}
		license2Str, ok := license2List.List[i].(*build.StringExpr)
		if !ok {
			return nil
		}
		if license1Str.Value != license2Str.Value {
			return nil
		}
	}
	return licenses1
}

func merge(
	input1 *parsed,
	input2 *parsed,
	outputName string,
) (
	*build.File,
	error) {

	output := &build.File{
		Path:     outputName,
		Comments: input1.Comments,
		Stmt:     nil,
		Type:     build.TypeBuild,
	}

	// Merge file level comments
	output.Comments.Before = append(
		output.Comments.Before,
		input2.Comments.Before...)

	output.Comments.Suffix = append(
		output.Comments.Suffix,
		input2.Comments.Suffix...)

	output.Comments.After = append(
		output.Comments.After,
		input2.Comments.After...)

	// Keep leading comment blocks at the top
	input1Comments := make([]build.Expr, 0)
	input2Comments := make([]build.Expr, 0)

	for _, m := range input1.stmts {
		_, ok := m.stmt.(*build.CommentBlock)
		if !ok {
			break
		}
		input1Comments = append(input1Comments, m.stmt)
		m.merged = true
	}

	for _, m := range input2.stmts {
		_, ok := m.stmt.(*build.CommentBlock)
		if !ok {
			break
		}
		input2Comments = append(input2Comments, m.stmt)
		m.merged = true
	}

	output.Stmt = append(output.Stmt, input1Comments...)
	output.Stmt = append(output.Stmt, input2Comments...)

	if input1.pkg != nil {
		if input2.pkg != nil {
			pkg, err := mergeCallExpr(input1.pkg, input2.pkg)
			if err != nil {
				return nil, err
			}
			output.Stmt = append(output.Stmt, pkg)
		} else {
			output.Stmt = append(output.Stmt, input1.pkg.stmt)
			input1.pkg.merged = true
		}
	} else if input2.pkg != nil {
		output.Stmt = append(output.Stmt, input2.pkg.stmt)
		input2.pkg.merged = true
	}

	for file, entries := range input2.loads {
		input1.loads[file] = append(input1.loads[file], entries...)
	}

	sortedLoads := []string{}
	uniqLoads := make(map[string]struct{})
	for file, _ := range input1.loads {
		_, ok := uniqLoads[file]
		if ok {
			continue
		}

		uniqLoads[file] = struct{}{}
		sortedLoads = append(sortedLoads, file)
	}

	sort.Strings(sortedLoads)
	for _, file := range sortedLoads {
		entries := input1.loads[file]

		load := *entries[0].stmt.(*build.LoadStmt)
		load.From = nil
		load.To = nil

		sortedImports := []string{}
		fromTo := make(map[string]string)

		for _, entry := range entries {
			origLoad := entry.stmt.(*build.LoadStmt)
			for i, from := range origLoad.From {
				if _, dup := fromTo[from.Name]; dup {
					continue
				}
				fromTo[from.Name] = origLoad.To[i].Name
				sortedImports = append(sortedImports, from.Name)
			}

			entry.merged = true
		}

		sort.Strings(sortedImports)
		for _, from := range sortedImports {
			load.From = append(load.From, &build.Ident{Name: from})
			load.To = append(load.To, &build.Ident{Name: fromTo[from]})
		}

		output.Stmt = append(output.Stmt, &load)
	}

	if input1.licenses != nil || input2.licenses != nil {
		licenses := mergeLicenses(input1.licenses, input2.licenses)
		if licenses == nil {
			return nil, errors.New("conflicting licenses() invocations")
		}
		if input1.licenses != nil {
			input1.licenses.merged = true
		}
		if input2.licenses != nil {
			input2.licenses.merged = true
		}
		output.Stmt = append(output.Stmt, licenses)
	}

	// Keep variable assignment at the top
	input1Assignments := make([]build.Expr, 0)
	input2Assignments := make([]build.Expr, 0)

	for _, m := range input1.stmts {
		_, ok := m.stmt.(*build.AssignExpr)
		if !ok {
			continue
		}
		input1Assignments = append(input1Assignments, m.stmt)
		m.merged = true
	}

	for _, m := range input2.stmts {
		_, ok := m.stmt.(*build.AssignExpr)
		if !ok {
			continue
		}
		input2Assignments = append(input2Assignments, m.stmt)
		m.merged = true
	}

	output.Stmt = append(output.Stmt, input1Assignments...)
	output.Stmt = append(output.Stmt, input2Assignments...)

	input1Rules := make([]build.Expr, 0)
	input2Rules := make([]build.Expr, 0)

	for _, m := range input1.stmts {
		if m.merged {
			continue
		}

		if m.targetName != "" {
			other, ok := input2.calls[m.targetName]
			if ok {
				call, err := mergeCallExpr(m, other)
				if err != nil {
					return nil, err
				}
				input1Rules = append(input1Rules, call)
				continue
			}
		}

		input1Rules = append(input1Rules, m.stmt)
		m.merged = true
	}

	for _, m := range input2.stmts {
		if m.merged {
			continue
		}

		input2Rules = append(input2Rules, m.stmt)
		m.merged = true
	}

	output.Stmt = append(output.Stmt, input1Rules...)
	output.Stmt = append(output.Stmt, input2Rules...)

	return output, nil
}

func main() {
	flag.Parse()

	args := flag.Args()
	if len(args)%3 != 0 {
		fmt.Printf("USAGE: %s [args] [<input1> <input2> <output>]+\n", args)
		os.Exit(2)
	}

	for i := 0; i < len(args)/3; i++ {
		input1 := parse(args[3*i])
		input2 := parse(args[3*i+1])
		outputFile := args[3*i+2]

		output, err := merge(input1, input2, outputFile)
		if err != nil {
			fmt.Println("Failed to merge:", outputFile)
			fmt.Println(err)
			os.Exit(1)
		}

		warn.FixWarnings(output, []string{"load"}, false, nil) // Remove unused loads.
		build.Rewrite(output)
		data := build.Format(output)

		err = ioutil.WriteFile(outputFile, data, 0644)
		if err != nil {
			fmt.Println("Failed to write:", outputFile)
			fmt.Println(err)
			os.Exit(1)
		}
	}
}
