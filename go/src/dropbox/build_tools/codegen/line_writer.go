package codegen

import (
	"fmt"
)

type LineWriter interface {
	PushIndent()
	PopIndent()
	Line(format string, values ...interface{})
	String() string
}

func NewLineWriter(indentStr string) LineWriter {
	return &lineWriter{
		indentStr: indentStr,
		indent:    0,
		content:   nil,
	}
}

type line struct {
	indentStr string
	indent    int
	format    string
	values    []interface{}
}

func (l *line) String() string {
	if l.format == "" {
		return "\n"
	}

	s := ""
	for i := 0; i < l.indent; i++ {
		s += l.indentStr
	}

	// format at the very end to allow for late binding
	s += fmt.Sprintf(l.format, l.values...) + "\n"

	return s
}

type lineWriter struct {
	indentStr string
	indent    int
	content   []*line
}

func (w *lineWriter) PushIndent() {
	w.indent += 1
}

func (w *lineWriter) PopIndent() {
	w.indent -= 1
}

func (w *lineWriter) Line(format string, values ...interface{}) {
	w.content = append(
		w.content,
		&line{
			indentStr: w.indentStr,
			indent:    w.indent,
			format:    format,
			values:    values,
		})
}

func (w *lineWriter) String() string {
	s := ""
	for _, l := range w.content {
		s += l.String()
	}

	return s
}
