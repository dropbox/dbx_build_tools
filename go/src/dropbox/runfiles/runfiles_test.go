package runfiles

import (
	"io/ioutil"
	"log"
	"os"
	"strings"
	"testing"
)

func TestRunfiles(t *testing.T) {
	if _, err := DataPath("/"); err == nil {
		t.Fatal(`expected bad bazel path for "/"`)
	}

	if _, err := DataPath("//:data_target"); err == nil {
		t.Fatal(`expected bad bazel target for "//:data_target"`)
	}

	if _, err := DataPath("//my/../relative/thing"); err == nil {
		t.Fatal(`expected bad relative path for "//my/../relative/thing"`)
	}

	if _, err := DataPath("@workspace/package"); err != nil {
		t.Fatal(`expected valid result for @workspace/package`)
	}

	isBazelTest := os.Getenv("TEST_SRCDIR") != ""
	if isBazelTest {
		dataPath1, err := DataPath("//go/src/dropbox/runfiles/test_data.empty")
		if err != nil {
			t.Fatalf("expected valid path: %v", err)
		}
		dataPath2, err := DataPath("//go/src/dropbox/runfiles/test_data.empty")
		if err != nil {
			t.Fatalf("expected valid path: %v", err)
		}
		if dataPath1 != dataPath2 {
			t.Fatalf("subsequent calls yield different paths: %v != %v", dataPath1, dataPath2)
		}

		folderPath, err := FolderPath()
		if err != nil {
			t.Fatalf("unable to get folder path: %v", err)
		}
		if _, err = os.Stat(folderPath); err != nil {
			t.Fatalf("runfiles folder does not exist")
		}
		if !strings.HasSuffix(folderPath, ".runfiles") {
			t.Fatalf("runfiles folder does not end in .runfiles")
		}
	} else {
		log.Printf("the test environment is incomplete - please run under Bazel")
	}
}

func TestCompiledStandalone(t *testing.T) {
	savedSetting := compiledStandalone
	defer func() { compiledStandalone = savedSetting }()
	compiledStandalone = "yes"
	if _, err := DataPath("//something"); err != errStandalone {
		t.Fatal("expected error when compiledStandalone is set")
	}
}

func TestConfigRunfiles(t *testing.T) {
	baseDir, err := DataPath("//go/src/dropbox/runfiles/data")
	if err != nil {
		t.Fatalf("failed to resolve config base: %v", err)
	}

	path, err := ConfigDataPath("//test.json", baseDir+"/config")
	if err != nil {
		t.Fatalf("failed to resolve //test.json: %v", err)
	}
	content, err := ioutil.ReadFile(path)
	if err != nil {
		t.Fatalf("failed to read //test.json: %v", err)
	}
	if string(content) != "[1, 2]\n" {
		t.Fatalf("unexpected content for //test.json: %v", content)
	}
	path, err = ConfigDataPath("//subdir/another.json", baseDir+"/config")
	if err != nil {
		t.Fatalf("failed to resolve //subdir/another.json: %v", err)
	}
	content, err = ioutil.ReadFile(path)
	if err != nil {
		t.Fatalf("failed to read //subdir/another.json: %v", err)
	}
	if string(content) != "\"another\"\n" {
		t.Fatalf("unexpected content for //subdir/another.json: %v", content)
	}
	_, err = ConfigDataPath("/test.json", baseDir+"/config")
	if err == nil {
		t.Fatalf("resolving of path didn't fail: /test.json")
	}
	_, err = ConfigDataPath("test.json", baseDir+"/config")
	if err == nil {
		t.Fatalf("resolving of path didn't fail: test.json")
	}
	_, err = ConfigDataPath("//../test.json", baseDir+"/config")
	if err == nil {
		t.Fatalf("resolving of path didn't fail: //../test.json")
	}
	_, err = ConfigDataPath("//test.json", baseDir+"/config2")
	if err == nil {
		t.Fatalf("resolving of path didn't fail: config2://test.json")
	}
}
