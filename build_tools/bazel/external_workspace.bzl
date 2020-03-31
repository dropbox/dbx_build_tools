load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")

# Retrieve a filename from given label. This is useful when the target is used in other repos, in
# which case the relative path for filename cannot be found but the label conversion works.
def filename_from_label(label):
    return str(Label(label))

DEFAULT_EXTERNAL_URLS = {
    "abseil_py": "https://github.com/abseil/abseil-py/archive/pypi-v0.7.1.tar.gz",
    "bazel_skylib": "https://github.com/bazelbuild/bazel-skylib/releases/download/1.0.2/bazel-skylib-1.0.2.tar.gz",
    "com_github_plougher_squashfs-tools": "https://github.com/plougher/squashfs-tools/archive/4.4.tar.gz",
    "cpython_27": "https://www.python.org/ftp/python/2.7.17/Python-2.7.17.tar.xz",
    "cpython_37": "https://www.python.org/ftp/python/3.7.5/Python-3.7.5.tar.xz",
    "cpython_38": "https://www.python.org/ftp/python/3.8.1/Python-3.8.1.tar.xz",
    "go_1_12_17_linux_amd64_tar_gz": "https://dl.google.com/go/go1.12.17.linux-amd64.tar.gz",
    "io_pypa_pip_whl": "https://pypi.python.org/packages/b6/ac/7015eb97dc749283ffdec1c3a88ddb8ae03b8fad0f0e611408f196358da3/pip-9.0.1-py2.py3-none-any.whl",
    "io_pypa_setuptools_whl": "https://files.pythonhosted.org/packages/ec/51/f45cea425fd5cb0b0380f5b0f048ebc1da5b417e48d304838c02d6288a1e/setuptools-41.0.1-py2.py3-none-any.whl",
    "io_pypa_wheel_whl": "https://files.pythonhosted.org/packages/bb/10/44230dd6bf3563b8f227dbf344c908d412ad2ff48066476672f3a72e174e/wheel-0.33.4-py2.py3-none-any.whl",
    "net_zlib": "http://zlib.net/zlib-1.2.11.tar.gz",
    "org_bzip_bzip2": "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz",
    "org_gnu_ncurses": "https://invisible-mirror.net/archives/ncurses/ncurses-6.1.tar.gz",
    "org_gnu_readline": "https://ftp.gnu.org/gnu/readline/readline-8.0.tar.gz",
    "org_openssl": "https://www.openssl.org/source/openssl-1.1.1f.tar.gz",
    "org_sourceware_libffi": "https://github.com/libffi/libffi/releases/download/v3.3/libffi-3.3.tar.gz",
    "org_sqlite": "https://sqlite.org/2020/sqlite-amalgamation-3310100.zip",
    "org_tukaani": "https://tukaani.org/xz/xz-5.2.4.tar.gz",
    "rules_pkg": "https://github.com/bazelbuild/rules_pkg/archive/2f09779667f0d6644c2ca5914d6113a82666ec63.zip",
    "six_archive": "https://pypi.python.org/packages/b3/b2/238e2590826bfdd113244a40d9d3eb26918bd798fc187e2360a8367068db/six-1.10.0.tar.gz",
}

def drte_deps(urls = DEFAULT_EXTERNAL_URLS):
    http_archive(
        name = "go_1_12_17_linux_amd64_tar_gz",
        urls = [urls["go_1_12_17_linux_amd64_tar_gz"]],
        sha256 = "a53dd476129d496047487bfd53d021dd17e0c96895865a0e7d0469ce3db8c8d2",
        build_file = filename_from_label("//build_tools/go:BUILD.go-dist"),
    )

    http_archive(
        name = "org_sourceware_libffi",
        urls = [urls["org_sourceware_libffi"]],
        sha256 = "72fba7922703ddfa7a028d513ac15a85c8d54c8d67f55fa5a4802885dc652056",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/libffi:BUILD.libffi"),
        strip_prefix = "libffi-3.3",
    )

    http_archive(
        name = "org_python_cpython_27",
        urls = [urls["cpython_27"]],
        sha256 = "4d43f033cdbd0aa7b7023c81b0e986fd11e653b5248dac9144d508f11812ba41",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/cpython:BUILD.python27"),
        strip_prefix = "Python-2.7.17",
    )

    http_archive(
        name = "org_python_cpython_37",
        urls = [urls["cpython_37"]],
        sha256 = "e85a76ea9f3d6c485ec1780fca4e500725a4a7bbc63c78ebc44170de9b619d94",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/cpython:BUILD.python37"),
        strip_prefix = "Python-3.7.5",
    )

    http_archive(
        name = "org_python_cpython_38",
        urls = [urls["cpython_38"]],
        sha256 = "75894117f6db7051c1b34f37410168844bbb357c139a8a10a352e9bf8be594e8",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/cpython:BUILD.python38"),
        strip_prefix = "Python-3.8.1",
    )

    http_archive(
        name = "com_github_plougher_squashfs-tools",
        urls = [urls["com_github_plougher_squashfs-tools"]],
        sha256 = "a7fa4845e9908523c38d4acf92f8a41fdfcd19def41bd5090d7ad767a6dc75c3",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/squashfs-tools:BUILD.squashfs-tools"),
        strip_prefix = "squashfs-tools-4.4",
    )

    http_archive(
        name = "bazel_skylib",
        urls = [urls["bazel_skylib"]],
        sha256 = "97e70364e9249702246c0e9444bccdc4b847bed1eb03c5a3ece4f83dfe6abc44",
    )

    pypi_core_deps(urls)

    cpython_deps(urls)

def cpython_deps(urls = DEFAULT_EXTERNAL_URLS):
    http_archive(
        name = "rules_pkg",
        urls = [urls["rules_pkg"]],
        sha256 = "3bc6bf7982e5ab0c89a5a3e0895cf32d63d234db54e9e9211c8c4d511b845f7a",
        strip_prefix = "rules_pkg-2f09779667f0d6644c2ca5914d6113a82666ec63/pkg",
    )

    http_archive(
        name = "abseil_py",
        urls = [urls["abseil_py"]],
        strip_prefix = "abseil-py-pypi-v0.7.1",
        sha256 = "3d0f39e0920379ff1393de04b573bca3484d82a5f8b939e9e83b20b6106c9bbe",
    )

    http_archive(
        name = "org_gnu_readline",
        urls = [urls["org_gnu_readline"]],
        sha256 = "e339f51971478d369f8a053a330a190781acb9864cf4c541060f12078948e461",
        build_file = filename_from_label("//thirdparty/readline:BUILD.readline"),
        strip_prefix = "readline-8.0",
    )

    http_archive(
        name = "six_archive",
        build_file = filename_from_label("@abseil_py//third_party:six.BUILD"),
        sha256 = "105f8d68616f8248e24bf0e9372ef04d3cc10104f1980f54d57b2ce73a5ad56a",
        strip_prefix = "six-1.10.0",
        urls = [urls["six_archive"]],
    )

    http_archive(
        name = "org_gnu_ncurses",
        urls = [urls["org_gnu_ncurses"]],
        sha256 = "aa057eeeb4a14d470101eff4597d5833dcef5965331be3528c08d99cebaa0d17",
        build_file = filename_from_label("//thirdparty/ncurses:BUILD.ncurses"),
        strip_prefix = "ncurses-6.1",
    )

    http_archive(
        name = "net_zlib",
        urls = [urls["net_zlib"]],
        sha256 = "c3e5e9fdd5004dcb542feda5ee4f0ff0744628baf8ed2dd5d66f8ca1197cb1a1",
        strip_prefix = "zlib-1.2.11",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/zlib:BUILD.zlib"),
    )

    http_archive(
        name = "org_bzip_bzip2",
        urls = [urls["org_bzip_bzip2"]],
        sha256 = "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269",
        strip_prefix = "bzip2-1.0.8",
        build_file = filename_from_label("//thirdparty/bzip2:BUILD.bzip2"),
    )

    http_archive(
        name = "org_tukaani",
        urls = [urls["org_tukaani"]],
        strip_prefix = "xz-5.2.4",
        sha256 = "b512f3b726d3b37b6dc4c8570e137b9311e7552e8ccbab4d39d47ce5f4177145",
        build_file = filename_from_label("//thirdparty/xz:BUILD.xz"),
    )

    http_archive(
        name = "org_openssl",
        urls = [urls["org_openssl"]],
        sha256 = "186c6bfe6ecfba7a5b48c47f8a1673d0f3b0e5ba2e25602dd23b629975da3f35",
        strip_prefix = "openssl-1.1.1f",
        build_file = filename_from_label("//thirdparty/openssl:BUILD.openssl"),
    )

    http_archive(
        name = "org_sqlite",
        urls = [urls["org_sqlite"]],
        sha256 = "f3c79bc9f4162d0b06fa9fe09ee6ccd23bb99ce310b792c5145f87fbcc30efca",
        strip_prefix = "sqlite-amalgamation-3310100",
        build_file = filename_from_label("//thirdparty/sqlite:BUILD.sqlite"),
    )

def pypi_core_deps(urls = DEFAULT_EXTERNAL_URLS):
    """Deps needed by python build rules in //build_tools/py."""
    http_file(
        name = "io_pypa_pip_whl",
        urls = [urls["io_pypa_pip_whl"]],
        downloaded_file_path = "pip-9.0.1-py2.py3-none-any.whl",
        sha256 = "690b762c0a8460c303c089d5d0be034fb15a5ea2b75bdf565f40421f542fefb0",
    )

    http_file(
        name = "io_pypa_setuptools_whl",
        urls = [urls["io_pypa_setuptools_whl"]],
        downloaded_file_path = "setuptools-41.0.1-py2.py3-none-any.whl",
        sha256 = "c7769ce668c7a333d84e17fe8b524b1c45e7ee9f7908ad0a73e1eda7e6a5aebf",
    )

    http_file(
        name = "io_pypa_wheel_whl",
        urls = [urls["io_pypa_wheel_whl"]],
        downloaded_file_path = "wheel-0.33.4-py2.py3-none-any.whl",
        sha256 = "5e79117472686ac0c4aef5bad5172ea73a1c2d1646b808c35926bd26bdfb0c08",
    )
