package genbuildgolib

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMarshalJSON_EmbedConfig(t *testing.T) {
	// Create an EmbedConfig struct with some test data
	ec := EmbedConfig{
		Patterns: map[string][]string{
			"foo": {"a", "b"},
			"bar": {"c"},
		},
		Files: map[string]string{
			"a": "full_path_a",
			"c": "full_path_c",
			"b": "full_path_b",
		},
	}

	b, err := ec.MarshalJSON()
	require.NoError(t, err)
	// Check that the JSON content AND ordering is correct
	expected := `{"Patterns":{"bar":["c"],"foo":["a","b"]},"Files":{"a":"full_path_a","b":"full_path_b","c":"full_path_c"}}`
	require.Exactly(t, expected, string(b))
}
