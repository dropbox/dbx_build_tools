package codegen

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestGen(t *testing.T) {
	lw := NewLineWriter("  ")
	lw.Line("Hello %d!", 55)
	lw.PushIndent()
	lw.Line("Indented!")
	lw.PushIndent()
	lw.Line("More!")
	lw.PopIndent()
	lw.PopIndent()
	lw.Line(".. and back.")
	expected := `Hello 55!
  Indented!
    More!
.. and back.
`
	assert.Equal(t, lw.String(), expected)
}
