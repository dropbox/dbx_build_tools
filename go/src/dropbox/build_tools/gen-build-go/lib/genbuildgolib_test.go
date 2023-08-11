package lib

import "testing"

func TestPathToExtRepoName(t *testing.T) {
	type test struct {
		input  string
		output string
	}

	testCases := []test{
		{"golang.org/x/crypto", "org_golang_x_crypto"},
		{"golang.org/x/crypto/ssh/terminal", "org_golang_x_crypto_ssh_terminal"},
		{"github.com/mattn/go-runewidth", "com_github_mattn_go_runewidth"},
		{"ht_sr_git_~sbinet_gg", "ht_sr_git__sbinet_gg"},
	}

	for _, tc := range testCases {
		extRepoName := PathToExtRepoName(tc.input, "")
		if tc.output != extRepoName {
			t.Errorf("got %s, wanted %s", extRepoName, tc.output)
		}
	}
}
