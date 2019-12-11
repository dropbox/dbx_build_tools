package logwriter

import (
	"bufio"
	"bytes"
	"io"
	"log"
)

type logWriter struct {
	logger *log.Logger
}

func New(logger *log.Logger) io.Writer {
	return &logWriter{logger: logger}
}

// This is clearly approximate and assumes unfragmented writes.
// This probably works in most cases, but may mangle output in others.
func (lw *logWriter) Write(p []byte) (n int, err error) {
	scanner := bufio.NewScanner(bytes.NewReader(p))
	for scanner.Scan() {
		lw.logger.Print(string(scanner.Text()))
	}
	return len(p), scanner.Err()
}
