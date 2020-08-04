package codegen

import (
	"fmt"
	"strings"
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

func (l *line) writeTo(s *strings.Builder) {
	if l.format == "" {
		s.WriteByte('\n')
		return
	}
	for i := 0; i < l.indent; i++ {
		s.WriteString(l.indentStr)
	}
	// format at the very end to allow for late binding
	fmt.Fprintf(s, l.format, l.values...)
	s.WriteByte('\n')
}

type lineWriter struct {
	indentStr string
	indent    int
	content   []line
}

func (w *lineWriter) PushIndent() {
	w.indent += 1
}

func (w *lineWriter) PopIndent() {
	w.indent -= 1
}

func (w *lineWriter) Line(format string, values ...interface{}) {
	w.content = append(w.content,
		line{
			indentStr: w.indentStr,
			indent:    w.indent,
			format:    format,
			values:    values,
		})
}

func (w *lineWriter) String() string {
	var b strings.Builder
	for _, l := range w.content {
		l.writeTo(&b)
	}
	return b.String()
}
