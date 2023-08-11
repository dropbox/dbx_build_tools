module dropbox/build_tools/gen-build-go

go 1.18

exclude github.com/prometheus/prometheus v2.5.0+incompatible

require (
	github.com/bazelbuild/buildtools v0.0.0-20230317132445-9c3c1fc0106e
	github.com/stretchr/testify v1.8.4
	golang.org/x/mod v0.12.0
)

require (
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/kr/pretty v0.3.1 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	gopkg.in/check.v1 v1.0.0-20201130134442-10cb98267c6c // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)
