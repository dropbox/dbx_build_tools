load("//build_tools/go:inna/dbx_go_repository.bzl", "dbx_go_dependency")
load("@io_bazel_rules_go//go/private:sdk.bzl", "go_download_sdk", "go_host_sdk")

# Metadata are copied from https://go.dev/dl/?mode=json&include=all
GO_SDK_METADATA = {
    "darwin_amd64": ("go1.16.5.darwin-amd64.tar.gz", "be761716d5bfc958a5367440f68ba6563509da2f539ad1e1864bd42fe553f277"),
    "darwin_arm64": ("go1.16.5.darwin-arm64.tar.gz", "7b1bed9b63d69f1caa14a8d6911fbd743e8c37e21ed4e5b5afdbbaa80d070059"),
    "freebsd_386": ("go1.16.5.freebsd-386.tar.gz", "d2c6a5d17200c70160d5a79b23320f7802fb5e2620fa58ab0b43c147fc018192"),
    "freebsd_amd64": ("go1.16.5.freebsd-amd64.tar.gz", "7110fe0c16e45641cf5a457b1bf1cba76275abca298a4dc93b60b4b33697310f"),
    "linux_386": ("go1.16.5.linux-386.tar.gz", "a37c6b71d0b673fe8dfeb2a8b3de78824f05d680ad32b7ac6b58c573fa6695de"),
    "linux_amd64": ("go1.16.5.linux-amd64.tar.gz", "b12c23023b68de22f74c0524f10b753e7b08b1504cb7e417eccebdd3fae49061"),
    "linux_arm64": ("go1.16.5.linux-arm64.tar.gz", "d5446b46ef6f36fdffa852f73dfbbe78c1ddf010b99fa4964944b9ae8b4d6799"),
    "linux_armv6l": ("go1.16.5.linux-armv6l.tar.gz", "93cacacfbe87e3106b5bf5821de106f0f0a43c8bd1029826d44445c15df795a5"),
    "linux_ppc64le": ("go1.16.5.linux-ppc64le.tar.gz", "fad2da6c86ede8448d2d0e66e1776e2f0ae9169714eade29b9ffbbdede7fc6cc"),
    "linux_s390x": ("go1.16.5.linux-s390x.tar.gz", "21085f6a3568fae639edf383cce78bcb00d8f415e5e3d7feb04b6124e8e9efc1"),
    "windows_386": ("go1.16.5.windows-386.zip", "bee3e7b3dda252725de4df63f5182b30e579bf9f613bda2efe0e0919fe34112d"),
    "windows_amd64": ("go1.16.5.windows-amd64.zip", "0a3fa279ae5b91bc8c88017198c8f1ba5d9925eb6e5d7571316e567c73add39d"),
}

def go_register_toolchains(version = None, nogo = None, go_version = None):
    """
        This function is our in house version of io_bazel_rules_go/go/private/sdk:go_register_toolchains()
        https://github.com/bazelbuild/rules_go/blob/v0.25.1/go/private/sdk.bzl#L400
        The purpose is to direct the download of gosdk to magic mirror.
    """
    if not version:
        version = go_version  # old name

    sdk_kinds = ("_go_download_sdk", "_go_host_sdk", "_go_local_sdk", "_go_wrap_sdk")
    existing_rules = native.existing_rules()
    sdk_rules = [r for r in existing_rules.values() if r["kind"] in sdk_kinds]
    if len(sdk_rules) == 0 and "go_sdk" in existing_rules:
        # may be local_repository in bazel_tests.
        sdk_rules.append(existing_rules["go_sdk"])

    if version and len(sdk_rules) > 0:
        fail("go_register_toolchains: version set after go sdk rule declared ({})".format(", ".join([r["name"] for r in sdk_rules])))
    if len(sdk_rules) == 0:
        if not version:
            fail('go_register_toolchains: version must be a string like "1.15.5" or "host"')
        elif version == "host":
            go_host_sdk(name = "go_sdk")
        else:
            go_download_sdk(
                name = "go_sdk",
                version = version,
                urls = ["https://forge-magic-mirror.awsvip.dbxnw.net/archives/golang/{}"],
                sdks = GO_SDK_METADATA,
            )

def define_go_deps():
    dbx_go_dependency(
        name = "com_github_schollz_progressbar",
        commit = "7486f6b9f2207d78ad4636ee635f5f2386a26451",
        url = "https://forge-magic-mirror.awsvip.dbxnw.net/git-archives/progressbar.git-7486f6b9f2207d78ad4636ee635f5f2386a26451.tgz",
        sha256 = "f9b133827c426d8c14e5bc903d0fb198539abd38ea6b62123736afca16c57915",
        importpath = "github.com/schollz/progressbar",
    )

    dbx_go_dependency(
        name = "com_github_mitchellh_colorstring",
        commit = "d06e56a500db4d08c33db0b79461e7c9beafca2d",
        url = "https://forge-magic-mirror.awsvip.dbxnw.net/git-archives/colorstring.git-d06e56a500db4d08c33db0b79461e7c9beafca2d.tgz",
        sha256 = "9794420aa88478b04b7dc29ebdb215af282255e75dc3b2122b07ab81d7f09c06",
        importpath = "github.com/mitchellh/colorstring",
    )

    dbx_go_dependency(
        name = "com_github_mattn_go_runewidth",
        commit = "dc8fe66265afbd17ea8515ea85adb7de6e685a78",
        url = "https://forge-magic-mirror.awsvip.dbxnw.net/git-archives/go-runewidth.git-dc8fe66265afbd17ea8515ea85adb7de6e685a78.tgz",
        sha256 = "91107be76965f05edb8d472e4b38bc52eeb19e6e42ba2e32b25688cfe3395d24",
        importpath = "github.com/mattn/go-runewidth",
    )

    dbx_go_dependency(
        name = "com_github_rivo_uniseg",
        commit = "57c86be7915a626793725fce30bb2f4da513c1a2",
        url = "https://forge-magic-mirror.awsvip.dbxnw.net/git-archives/uniseg.git-57c86be7915a626793725fce30bb2f4da513c1a2.tgz",
        sha256 = "81b97b64ba710dbf896b5d38321b70ee89cb48f1e386f9735b51bfffe6b625c5",
        importpath = "github.com/rivo/uniseg",
    )

    dbx_go_dependency(
        name = "org_golang_x_crypto",
        commit = "ae814b36b87190c757eede9bc2d32ed77df88551",
        url = "https://forge-magic-mirror.awsvip.dbxnw.net/git-archives/crypto.git-ae814b36b87190c757eede9bc2d32ed77df88551.tgz",
        sha256 = "e4e47a394ea57ae65e1e0edf38ce92bb832802d2fd0b99f3b97d9ac4720d7f23",
        importpath = "golang.org/x/crypto",
        submodules = [
            "ssh/terminal",
        ],
    )

    dbx_go_dependency(
        name = "org_golang_x_term",
        commit = "03fcf44c2211dcd5eb77510b5f7c1fb02d6ded50",
        url = "https://forge-magic-mirror.awsvip.dbxnw.net/git-archives/term.git-03fcf44c2211dcd5eb77510b5f7c1fb02d6ded50.tgz",
        sha256 = "6d644cd834f059b6a8b5a98c3d710a9f6d5ae52a0941229521c866e82548783d",
        importpath = "golang.org/x/term",
    )

    dbx_go_dependency(
        name = "org_golang_x_sys",
        commit = "dee7805ff2e13b1c4206de89b1c06e95ab66ae0d",
        url = "https://forge-magic-mirror.awsvip.dbxnw.net/git-archives/sys.git-dee7805ff2e13b1c4206de89b1c06e95ab66ae0d.tgz",
        sha256 = "4f9a23a8c262e05c23d8eeb8d765385c8f5518ba698f157ce40e34cd0ffc63a0",
        importpath = "golang.org/x/sys",
        submodules = [
            "unix",
            "internal/unsafeheader",
        ],
    )
