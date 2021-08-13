load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")

# Retrieve a filename from given label. This is useful when the target is used in other repos, in
# which case the relative path for filename cannot be found but the label conversion works.
def filename_from_label(label):
    return str(Label(label))

DEFAULT_EXTERNAL_URLS = {
    "abseil_py": ["https://github.com/abseil/abseil-py/archive/pypi-v0.7.1.tar.gz"],
    "bazel_skylib": ["https://github.com/bazelbuild/bazel-skylib/releases/download/1.0.2/bazel-skylib-1.0.2.tar.gz"],
    "com_github_plougher_squashfs_tools": ["https://github.com/plougher/squashfs-tools/archive/4.4.tar.gz"],
    "cpython_27": ["https://www.python.org/ftp/python/2.7.17/Python-2.7.17.tar.xz"],
    "cpython_38": ["https://www.python.org/ftp/python/3.8.1/Python-3.8.1.tar.xz"],
    "go_1_16_7_linux_amd64_tar_gz": ["https://dl.google.com/go/go1.16.7.linux-amd64.tar.gz"],
    "io_pypa_pip_whl": ["https://files.pythonhosted.org/packages/54/0c/d01aa759fdc501a58f431eb594a17495f15b88da142ce14b5845662c13f3/pip-20.0.2-py2.py3-none-any.whl"],
    "io_pypa_setuptools_whl": ["https://files.pythonhosted.org/packages/f9/d3/955738b20d3832dfa3cd3d9b07e29a8162edb480bf988332f5e6e48ca444/setuptools-44.0.0-py2.py3-none-any.whl"],
    "io_pypa_wheel_whl": ["https://files.pythonhosted.org/packages/8c/23/848298cccf8e40f5bbb59009b32848a4c38f4e7f3364297ab3c3e2e2cd14/wheel-0.34.2-py2.py3-none-any.whl"],
    "lz4": ["https://github.com/lz4/lz4/archive/v1.9.3.tar.gz"],
    "net_zlib": ["http://zlib.net/zlib-1.2.11.tar.gz"],
    "org_bzip_bzip2": ["https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz"],
    "org_gnu_ncurses": ["https://invisible-mirror.net/archives/ncurses/ncurses-6.2.tar.gz"],
    "org_gnu_readline": ["https://ftp.gnu.org/gnu/readline/readline-8.1.tar.gz"],
    "org_openssl": ["https://www.openssl.org/source/openssl-1.1.1k.tar.gz"],
    "org_sourceware_libffi": ["https://github.com/libffi/libffi/releases/download/v3.3/libffi-3.3.tar.gz"],
    "org_sqlite": ["https://sqlite.org/2021/sqlite-amalgamation-3360000.zip"],
    "org_tukaani": ["https://downloads.sourceforge.net/project/lzmautils/xz-5.2.5.tar.xz"],
    "rules_pkg": ["https://github.com/bazelbuild/rules_pkg/releases/download/0.2.6-1/rules_pkg-0.2.6.tar.gz"],
    "six_archive": ["https://pypi.python.org/packages/b3/b2/238e2590826bfdd113244a40d9d3eb26918bd798fc187e2360a8367068db/six-1.10.0.tar.gz"],
    "ducible": ["https://github.com/jasonwhite/ducible/releases/download/v1.2.2/ducible-windows-Win32-Release.zip"],
    "zstd": ["https://github.com/facebook/zstd/releases/download/v1.4.9/zstd-1.4.9.tar.gz"],
}

def drte_deps(urls = DEFAULT_EXTERNAL_URLS):
    http_archive(
        name = "go_1_16_7_linux_amd64_tar_gz",
        urls = urls["go_1_16_7_linux_amd64_tar_gz"],
        sha256 = "7fe7a73f55ba3e2285da36f8b085e5c0159e9564ef5f63ee0ed6b818ade8ef04",
        build_file = filename_from_label("//build_tools/go:BUILD.go-dist"),
    )

    http_archive(
        name = "org_sourceware_libffi",
        urls = urls["org_sourceware_libffi"],
        sha256 = "72fba7922703ddfa7a028d513ac15a85c8d54c8d67f55fa5a4802885dc652056",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/libffi:BUILD.libffi"),
        strip_prefix = "libffi-3.3",
    )

    http_archive(
        name = "org_python_cpython_27",
        urls = urls["cpython_27"],
        sha256 = "4d43f033cdbd0aa7b7023c81b0e986fd11e653b5248dac9144d508f11812ba41",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/cpython:BUILD.python27"),
        strip_prefix = "Python-2.7.17",
    )

    http_archive(
        name = "org_python_cpython_38",
        urls = urls["cpython_38"],
        sha256 = "75894117f6db7051c1b34f37410168844bbb357c139a8a10a352e9bf8be594e8",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/cpython:BUILD.python38"),
        strip_prefix = "Python-3.8.1",
    )

    http_archive(
        name = "com_github_plougher_squashfs_tools",
        urls = urls["com_github_plougher_squashfs_tools"],
        sha256 = "a7fa4845e9908523c38d4acf92f8a41fdfcd19def41bd5090d7ad767a6dc75c3",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/squashfs-tools:BUILD.squashfs-tools"),
        strip_prefix = "squashfs-tools-4.4",
    )

    http_archive(
        name = "bazel_skylib",
        urls = urls["bazel_skylib"],
        sha256 = "97e70364e9249702246c0e9444bccdc4b847bed1eb03c5a3ece4f83dfe6abc44",
    )

    pypi_core_deps(urls)

    cpython_deps(urls)

def cpython_deps(urls = DEFAULT_EXTERNAL_URLS):
    http_archive(
        name = "rules_pkg",
        urls = urls["rules_pkg"],
        sha256 = "aeca78988341a2ee1ba097641056d168320ecc51372ef7ff8e64b139516a4937",
    )

    http_archive(
        name = "abseil_py",
        urls = urls["abseil_py"],
        strip_prefix = "abseil-py-pypi-v0.7.1",
        sha256 = "3d0f39e0920379ff1393de04b573bca3484d82a5f8b939e9e83b20b6106c9bbe",
    )

    http_archive(
        name = "org_gnu_readline",
        urls = urls["org_gnu_readline"],
        sha256 = "f8ceb4ee131e3232226a17f51b164afc46cd0b9e6cef344be87c65962cb82b02",
        build_file = filename_from_label("//thirdparty/readline:BUILD.readline"),
        strip_prefix = "readline-8.1",
    )

    http_archive(
        name = "six_archive",
        build_file = filename_from_label("@abseil_py//third_party:six.BUILD"),
        sha256 = "105f8d68616f8248e24bf0e9372ef04d3cc10104f1980f54d57b2ce73a5ad56a",
        strip_prefix = "six-1.10.0",
        urls = urls["six_archive"],
    )

    http_archive(
        name = "org_gnu_ncurses",
        urls = urls["org_gnu_ncurses"],
        sha256 = "30306e0c76e0f9f1f0de987cf1c82a5c21e1ce6568b9227f7da5b71cbea86c9d",
        build_file = filename_from_label("//thirdparty/ncurses:BUILD.ncurses"),
        strip_prefix = "ncurses-6.2",
    )

    http_archive(
        name = "net_zlib",
        urls = urls["net_zlib"],
        sha256 = "c3e5e9fdd5004dcb542feda5ee4f0ff0744628baf8ed2dd5d66f8ca1197cb1a1",
        strip_prefix = "zlib-1.2.11",
        build_file = filename_from_label("@dbx_build_tools//thirdparty/zlib:BUILD.zlib"),
    )

    http_archive(
        name = "org_bzip_bzip2",
        urls = urls["org_bzip_bzip2"],
        sha256 = "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269",
        strip_prefix = "bzip2-1.0.8",
        build_file = filename_from_label("//thirdparty/bzip2:BUILD.bzip2"),
    )

    http_archive(
        name = "org_tukaani",
        urls = urls["org_tukaani"],
        strip_prefix = "xz-5.2.5",
        sha256 = "3e1e518ffc912f86608a8cb35e4bd41ad1aec210df2a47aaa1f95e7f5576ef56",
        build_file = filename_from_label("//thirdparty/xz:BUILD.xz"),
    )

    http_archive(
        name = "org_openssl",
        urls = urls["org_openssl"],
        sha256 = "892a0875b9872acd04a9fde79b1f943075d5ea162415de3047c327df33fbaee5",
        strip_prefix = "openssl-1.1.1k",
        build_file = filename_from_label("//thirdparty/openssl:BUILD.openssl"),
    )

    http_archive(
        name = "org_sqlite",
        urls = urls["org_sqlite"],
        sha256 = "999826fe4c871f18919fdb8ed7ec9dd8217180854dd1fe21eea96aed36186729",
        strip_prefix = "sqlite-amalgamation-3360000",
        build_file = filename_from_label("//thirdparty/sqlite:BUILD.sqlite"),
    )

    http_archive(
        name = "lz4",
        urls = urls["lz4"],
        sha256 = "030644df4611007ff7dc962d981f390361e6c97a34e5cbc393ddfbe019ffe2c1",
        strip_prefix = "lz4-1.9.3",
        build_file = filename_from_label("//thirdparty/lz4:BUILD.lz4"),
    )

    http_archive(
        name = "zstd",
        urls = urls["zstd"],
        sha256 = "29ac74e19ea28659017361976240c4b5c5c24db3b89338731a6feb97c038d293",
        strip_prefix = "zstd-1.4.9",
        build_file = filename_from_label("//thirdparty/zstd:BUILD.zstd"),
    )

def pypi_core_deps(urls = DEFAULT_EXTERNAL_URLS):
    """Deps needed by python build rules in //build_tools/py."""
    http_file(
        name = "io_pypa_pip_whl",
        urls = urls["io_pypa_pip_whl"],
        downloaded_file_path = "pip-20.0.2-py2.py3-none-any.whl",
        sha256 = "4ae14a42d8adba3205ebeb38aa68cfc0b6c346e1ae2e699a0b3bad4da19cef5c",
    )

    http_file(
        name = "io_pypa_setuptools_whl",
        urls = urls["io_pypa_setuptools_whl"],
        downloaded_file_path = "setuptools-44.0.0-py2.py3-none-any.whl",
        sha256 = "180081a244d0888b0065e18206950d603f6550721bd6f8c0a10221ed467dd78e",
    )

    http_file(
        name = "io_pypa_wheel_whl",
        urls = urls["io_pypa_wheel_whl"],
        downloaded_file_path = "wheel-0.34.2-py2.py3-none-any.whl",
        sha256 = "df277cb51e61359aba502208d680f90c0493adec6f0e848af94948778aed386e",
    )

    # Windows client only package that is required because of rule-sharing.
    http_archive(
        name = "ducible",
        urls = urls["ducible"],
        sha256 = "b90d636b6ee08768cd198e00f007a25b91bc1be279d417bdd3d476296060b7da",
        build_file_content = """exports_files(["ducible.exe"])""",
    )
