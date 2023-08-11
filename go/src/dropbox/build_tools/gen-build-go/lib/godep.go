package lib

import (
	"encoding/json"
	"io"
	"os"
)

const (
	GoDepDefJsonPath = "build_tools/go/dbx/dbx_go_dependencies.json"
)

type DbxGoDependency struct {
	Importpath    string   `json:"importpath"`
	Name          string   `json:"name"`
	Version       string   `json:"version"`
	Sum           string   `json:"sum"`
	Commit        string   `json:"commit"`
	Url           string   `json:"url"`
	Sha256        string   `json:"sha256"`
	Patches       []string `json:"patches,omitempty"`
	PackageSource string   `json:"packagesource,omitempty"`
}

func LoadGoDepDefJson(depDefPath string) ([]DbxGoDependency, error) {
	jsonFile, err := os.Open(depDefPath)
	if err != nil {
		return nil, err
	}
	depDefJsonByteValue, _ := io.ReadAll(jsonFile)

	var dbxGoDependencies []DbxGoDependency
	err = json.Unmarshal(depDefJsonByteValue, &dbxGoDependencies)
	if err != nil {
		return nil, err
	}
	return dbxGoDependencies, nil
}
