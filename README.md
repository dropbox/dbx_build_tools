# `dbx_build_tools`
`dbx_build_tools` is a collection of Bazel rules and associated tooling to build and test applications deployed to Linux servers.

The build rules support hermetic Python binaries. This includes the ability use packages from PyPI and link with c libraries built with Bazel’s built-in C/C++ rules. Python binaries include a Python interpreter built with Bazel.  The `BUILD` file generator can automatically generated dependencies for Python libraries and binaries, saving you from the drudgery of updating the deps every time you add or remove an import.

We also have Go rules. Our `BUILD` file generator supports generating rules entirety from Go source files on the filesystem.

We also include the tooling to generate a custom build and runtime environment. This isolates the build environment from system tools to make remote caching and execution more reliable. It also isolates your binaries outputs from the host system, making major OS upgrades much simpler.

# Lightning tour
## Install Bazel
Follow the [installation instructions](https://docs.bazel.build/versions/master/install.html) making sure Bazel is on your path.

## Create a new `WORKSPACE`

```console
$ mkdir ~/dbx_build_tools_guide
$ cd ~/dbx_build_tools_guide

$ cat > .bazelrc
build --experimental_strict_action_env
build --platforms @dbx_build_tools//build_tools/cc:linux-x64-drte-off
build --host_platform @dbx_build_tools//build_tools/cc:linux-x64-drte-off
build --sandbox_fake_username
build --modify_execution_info=TestRunner=+block-network

# Work around https://github.com/bazelbuild/bazel/issues/6293 by setting a
# dummy lcov.
coverage --test_env=LCOV_MERGER=/bin/true

$ cat > WORKSPACE
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")


# Real use cases should pin a commit and set the sha256.
http_archive(
    name = "dbx_build_tools",
    urls = ["https://github.com/dropbox/dbx_build_tools/archive/master.tar.gz"],
    strip_prefix = "dbx_build_tools-master",
)

load('@dbx_build_tools//build_tools/bazel:external_workspace.bzl', 'drte_deps')

drte_deps()

register_toolchains(
    "@dbx_build_tools//thirdparty/cpython:drte-off-27-toolchain",
    "@dbx_build_tools//thirdparty/cpython:drte-off-38-toolchain",
)
```
## Install `bzl`
```console
$ bazel build @dbx_build_tools//build_tools:bzl
$ sudo cp -rL bazel-bin/external/dbx_build_tools/build_tools/bzl{,.runfiles} /usr/bin/
```

## Create an application
```console
$ mkdir -p python/website
$ cat > python/website/hello.py
import random


def say_hello():
    return 'Hello'

$ cat > python/website/main.py
import sys

from wsgiref.simple_server import make_server

from python.website.hello import say_hello


def hello_app(environ, start_response):
    start_response('200 OK', [('Content-type', 'text/html')])

    return [
        '<html><strong>',
        say_hello(),
        '</strong></html>',
    ]


def main(port):
    server = make_server('localhost', port, hello_app)
    server.serve_forever()


if __name__ == '__main__':
    main(int(sys.argv[1]))

$ cat > python/website/BUILD.in
load('@dbx_build_tools//build_tools/services:svc.bzl', 'dbx_service_daemon')


dbx_py_library(
    name = "hello",
    srcs = ["hello.py"],
)

dbx_py_binary(
    name = "website",
    main = 'main.py',
)

dbx_service_daemon(
    name = "website_service",
    owner = "web_site_team",
    exe = ":website",
    args = ['5432'],
    http_health_check = 'http://localhost:5432',
)

$ bzl gen //python/website/...
```

## Run an interactive development environment
```console
$ bzl itest-start //python/website:website_service
$ curl http://localhost:5432
<html><strong>Hello</strong></html>
$ bzl itest-stop //python/website:website_service
```

## Write some tests
```console
$ cat > python/website/unit_test.py
from python.website.hello import say_hello


def test_say_hello():
    assert say_hello() == 'Hello'

$ cat > python/website/itest.py
try:
    from urllib2 import urlopen
except ImportError:
    from urllib.request import urlopen


def test_hello():
    assert b'Hello' in urlopen('http://localhost:5432').read()

$ cat >> python/website/BUILD.in

dbx_py_pytest_test(
    name ='unit_test',
    srcs = ['unit_test.py'],
)

dbx_py_pytest_test(
    name ='itest',
    srcs = ['itest.py'],
    services = [":website_service"],
)

$ bzl gen //python/website/...
$ bazel test //python/website/...
INFO: Elapsed time: 46.494s, Critical Path: 40.22s
INFO: 1618 processes: 1578 linux-sandbox, 40 local.
INFO: Build completed successfully, 1825 total actions
//python/website:itest                                                   PASSED in 1.3s
//python/website:itest-python2                                           PASSED in 1.3s
//python/website:unit_test                                               PASSED in 1.1s
//python/website:unit_test-python2                                       PASSED in 1.1s
//python/website:website_service_service_test                            PASSED in 0.5s

INFO: Build completed successfully, 1825 total actions
```

# Using external packages

External packages can be specified using `dbx_py_pypi_piplib`, which can be imported from `@dbx_build_tools//build_tools/py:py.bzl`. Consider a python file which uses `import some_library`, and you wish for this to be retrieved through PyPI. When `bzl` reads this import, it will try to find its definition at `//pip/some_library`; if it finds it, it will be added to the `deps` list of the `dbx_py_binary` or `dbx_py_library` that depends on it in the corresponding `BUILD` file.

## If the external package has no dependencies
If `some_library` has no external dependencies, you can thus create a file at `[project_root]/pip/some_library/BUILD` containing
```
load("@dbx_build_tools//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "some_library",
    pip_version = "1.2.3", #replace with the required version
    visibility = ["//visibility:public"],
)
```
and the build of your project will download and install the correct version, making it available to your code.

## If the external package has runtime dependencies
If, however, the external project has an external runtime dependency on a library called `another_library`, you should also create `[project_root]/pip/another_library/BUILD` along the same lines as the previous example. Then you can add it to a `deps` parameter to the `dbx_py_pypi_piplib` function for `some_library`:
```
# [project_root]/pip/another_library/BUILD:

load("@dbx_build_tools//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "some_library",
    pip_version = "2.3.4", #replace with the required version
    visibility = ["//visibility:public"],
)

# [project_root]/pip/some_library/BUILD:

load("@dbx_build_tools//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "some_library",
    pip_version = "1.2.3", #replace with the required version
    deps = ['//pip/another_library'],
    visibility = ["//visibility:public"],
)
```

## If the external package has setup dependencies
The installation of some libraries requires other python packages to be installed. For example, `numpy` requires `cython` during the setup phase. In these circumstances, you should add those libraries in `setup_requires` list.

Consider that `some_library` requires `some_setup_library`. Then, following the previous steps, you can write

```
# [project_root]/pip/some_setup_library/BUILD:

load("@dbx_build_tools//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "some_setup_library",
    pip_version = "3.4.5", #replace with the required version
    visibility = ["//visibility:public"],
)

# [project_root]/pip/some_library/BUILD:

load("@dbx_build_tools//build_tools/py:py.bzl", "dbx_py_pypi_piplib")

dbx_py_pypi_piplib(
    name = "some_library",
    pip_version = "1.2.3", #replace with the required version
    setup_requires = ['//pip/another_library'],
    visibility = ["//visibility:public"],
)
```
