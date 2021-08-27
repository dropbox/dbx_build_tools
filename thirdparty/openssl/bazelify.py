#!/usr/bin/env python3

from shutil import copyfile
from os.path import join as path_join
from collections import defaultdict
import json
import string
from tempfile import TemporaryDirectory
import tarfile
import subprocess
from textwrap import dedent, indent
from urllib.request import urlretrieve
from config import *


_punc_tbl = str.maketrans(string.punctuation, '_' * len(string.punctuation))

def slug(raw: str, trans=_punc_tbl) -> str:
    return raw.translate(trans)

def reindent(amt: int, text: str) -> str:
    text = dedent(text)
    return indent(text, amt * ' ', lambda x: True)

def bzl_list_fmt(indent_amt: int, items, delim=",\n", wrap=r'"%s"'):
    if wrap is None:
        wrap = r'%s'

    if delim is None:
        delim = '\n'

    pad = ' ' * indent_amt
    lines = '\n' + delim.join(pad + wrap % tok.strip() for tok in items)
    lines = indent(lines, pad, lambda line: True)
    return lines.lstrip()

def download(work_dir: str, version: str) -> str:
    url = f'https://www.openssl.org/source/openssl-{version}.tar.gz'
    file_name = path_join(work_dir, url.split('/')[-1])

    def report(block, size, total, barLength=20):
        percent = min(100.0, 100.0 * block * size / total)
        arrow = '-' * int(percent/100*barLength - 1) + '>'
        spaces = ' ' * (barLength - len(arrow))
        print(f'DL Progress: [{arrow}{spaces} {percent}%', end='\r')

    urlretrieve(url, file_name, report)
    print('\r\nDownloaded openssl')
    return file_name

def extract_archive(work_dir: str, archive: str) -> str:
    print('Extracting openssl')
    with tarfile.open(archive, 'r:*') as tarball:
        tarball.extractall(path=work_dir)

    return path_join(work_dir, archive.replace('.tar.gz', ''))

class Planner:
    def __init__(self, workdir: str, includes=INCLUDES, platforms=PLATFORMS):
        self.workdir = workdir
        self.platforms = platforms
        self.includes = includes
        self.build_details = {}
        self.prepare_build()

    def prepare_build(self):
        """Sets up the openssl build configuration for generating build configs"""
        copyfile('./extract_srcs.pl', path_join(self.workdir, 'extract_srcs.pl'))

        with open(path_join(self.workdir, 'tm.conf'), 'w') as conf:
            conf.write('(')
            for platform in self.platforms:
                # type: ignore
                conf.write(
                    reindent(
                        2, f'''
                    'tm-{platform}' => {{
                      inherit_from => ['{platform.openssl_moniker}'],
                      dso_scheme   => undef,
                    }},
                '''))
            conf.write(')')

    def _cmd(self, *cmd: str, check=True, capture_output=False) -> str:
        try:
            run = subprocess.run(
                cmd,
                shell=True,
                text=True,
                capture_output=capture_output,
                check=check,
                cwd=self.workdir,
                timeout=60,
            )
            return run.stdout
        except subprocess.CalledProcessError as failed_cmd:
            print(failed_cmd.output)
            raise

    def _read(self, file: str) -> str:
        with open(path_join(self.workdir, file), 'r') as data:
            return data.read()

    def gather_build_details(self):
        for platform in self.platforms:
            # no-afalgeng because we don't need afalgeng.
            # no-dynamic-engine to prevent loading shared libraries at runtime.
            self._cmd(
                f'./Configure "--config=tm.conf" "tm-{platform}" no-afalgeng no-dynamic-engine')

            for include in self.includes:
                if include == 'apps/progs.h':
                    # Hack - This file is special :(
                    self._cmd(f'perl apps/progs.pl apps/openssl > apps/progs.h')
                    continue

                cmd = f'perl -I. -Mconfigdata util/dofile.pl -oMakefile '\
                      f'{include}.in > {include}'
                self._cmd(cmd)

            includes = {inc: self._read(inc) for inc in self.includes}
            build_config = self._cmd('perl -I. -l -Mconfigdata ./extract_srcs.pl', capture_output=True)
            build_config = json.loads(build_config)
            build_config['includes'] = includes
            self.build_details[platform] = build_config


class Renderer:
    def __init__(self, build_details):
        self.build_details = build_details

    def _platform_config(self, platform: Platform) -> str:
        return f'''
            config_setting(
                name = "{platform}",
                constraint_values = [
                    "@platforms//cpu:{platform.bzl_cpu}",
                    "@platforms//os:{platform.bzl_os}",
                ]
            )'''

    def _platforms(self):
        return self.build_details.keys()

    def header(self, openssl_version=VERSION) -> str:
        configs = (self._platform_config(plat) for plat in self._platforms())
        configs = "\n".join(configs)

        return dedent(f'''\
            # GENERATED CODE! (see bazelify.py)
            load("@bazel_skylib//rules:write_file.bzl", "write_file")
            {configs}

            OPENSSL_VERSION = "{openssl_version}"
        ''')

    def _includes(self, plat: Platform, includes) -> str:
        for path, inc in includes.items():
            yield '\n'.join(("\n", f'{plat}_{slug(path)} = ["""', inc.strip(), '"""]\n'))

    def _srcs(self, plat: Platform, config) -> str:
        for lib in ('libcrypto', 'libssl', 'libapp', 'openssl_app'):
            srcs = config[f'{lib}_srcs']
            # Filter out asm sources
            srcs = sorted(src for src in srcs if src.endswith((".c", ".h")))
            yield dedent(f'''
                {plat}_{lib} = [
                    {bzl_list_fmt(10, srcs)}
                ]
            ''')

    def _asm_gen(self, plat, asm) -> str:
        gen = asm['generator']
        cmd = asm['cmdline']
        out = asm['output']

        return f"CC=$(CC) perl $(location {gen}) {cmd} $(location {plat}_{out})"

    def _perl_asms(self, plat: Platform, asms) -> str:
        asm_outs = sorted(set((f"{plat}_{asm['output']}" for asm in asms)))
        asm_cmd = sorted(set((self._asm_gen(plat, asm) for asm in asms)))
        asm_scripts = sorted(set((asm['generator'] for asm in asms)))

        return dedent(f'''
            genrule(
                name = "{plat}_asm",
                srcs = ["crypto/ec/ecp_nistz256_table.c"],
                outs = [
                    {bzl_list_fmt(10, asm_outs)}
                ],
                cmd = """
                    {bzl_list_fmt(10, asm_cmd, wrap=None, delim=None)}
                """,
                toolchains = ["@bazel_tools//tools/cpp:current_cc_toolchain"],
                tools = glob(["crypto/perlasm/*.pl"]) + [
                    {bzl_list_fmt(10, asm_scripts)}
                ]
            )
        ''')

    def _defines(self, plat: Platform, defines) -> str:
        defines = (f'{plat.compile_def_flag}{define}' for define in defines)
        return dedent(f'''
            {plat}_openssl_defines = [
                {bzl_list_fmt(8, defines)}
            ]
        ''')

    def rules(self) -> str:
        for platform, config in self.build_details.items():
            for inc in self._includes(platform, config['includes']):
                yield inc

            for src in self._srcs(platform, config):
                yield src

            yield self._perl_asms(platform, config['asm_srcs'])
            yield self._defines(platform, config['openssl_defines'])

    def _asm_target(self) -> str:
        asm_tgts = (f'":{plat}": [":{plat}_asm"]' for plat in self._platforms())

        def copts(plat) -> str:
            asm_copts = '\n'.join(plat.asm_copts)
            return reindent(12, f'''
                ":{plat}": [
                    {bzl_list_fmt(10, plat.asm_copts, wrap=None, delim=None)}
                ],
            ''')

        asm_copts = [copts(plat) for plat in self._platforms()]

        return dedent(f'''
            cc_library(
                name = "asm",
                linkstatic = True,
                alwayslink = True,
                copts = select(
                    {{
                        {bzl_list_fmt(12, asm_copts, wrap=None, delim=None)}
                    }},
                    no_match_error = "Please add a new target, see the openssl/README.MD",
                ),
                srcs = select(
                    {{
                        {bzl_list_fmt(12, asm_tgts, wrap=None)}
                    }},
                    no_match_error = "Please add a new target, see the openssl/README.MD",
                ),
            )
        ''')

    def _write_header_targets(self) -> str:
        includes = defaultdict(list)
        for plat, details in self.build_details.items():
            for inc in details['includes'].keys():
                includes[inc].append(plat)

        for inc_file, platforms in includes.items():
            actuals = (f'":{plat}": {plat}_{slug(inc_file)}' for plat in platforms)
            yield dedent(f'''
                write_file(
                    name = "{slug(inc_file)}",
                    out = "{inc_file}",
                    content = select(
                        {{
                            {bzl_list_fmt(14, actuals, wrap=None)}
                        }},
                        no_match_error = "Please add a new target, see the openssl/README.MD",
                    )
                )
            ''')

    def _buildinf_target(self) -> str:
        def buildinf(plat: Platform) -> str:
            null_list = r"'\0'"
            return reindent(12, f'''\
                ":{plat}": [
                    "static const char compiler_flags[] = {{{null_list}}};",
                    '#define PLATFORM "platform: {plat.openssl_moniker}"',
                    '#define DATE "__REDACTED__"',
                ]
            ''')

        buildinfs = (buildinf(plat) for plat in self._platforms())

        return dedent(f'''
            write_file(
                name = "crypto_buildinf_h",
                out = "crypto/buildinf.h",
                content = select(
                    {{
                        {bzl_list_fmt(12, buildinfs, wrap=None)}
                    }},
                    no_match_error = "Please add a new target, see the openssl/README.MD",
                )
            )
        ''')

    def _copts(self) -> str:
        for plat, details in self.build_details.items():
            yield dedent(f'''
                {plat}_copts = [
                {reindent(2, bzl_list_fmt(8, plat.copts, wrap=None))}
                ]
            ''')

            # There are two opts and defs to blend in, those that are specific
            # to bazel (as found in config.py), and those found in the build
            # from openssl
            yield dedent(f'''
                {plat}_defines = [
                {reindent(2, bzl_list_fmt(8, plat.defines, wrap=None))}
                ] + {plat}_openssl_defines
            ''')

        def plat_bind(suffix: str):
            return (f'":{plat}": {plat}_{suffix}' for plat in self._platforms())

        yield dedent(f'''
            copts = select(
                {{
                    {bzl_list_fmt(10, plat_bind('copts'), wrap=None)}
                }},
                no_match_error = "Please add a new target, see the openssl/README.MD",
            )

            defines = select(
                {{
                    {bzl_list_fmt(10, plat_bind('defines'), wrap=None)}
                }},
                no_match_error = "Please add a new target, see the openssl/README.MD",
            )

            libssl_srcs = select(
                {{
                    {bzl_list_fmt(10, plat_bind('libssl'), wrap=None)}
                }},
                no_match_error = "Please add a new target, see the openssl/README.MD",
            )

            libcrypto_srcs = select(
                {{
                    {bzl_list_fmt(10, plat_bind('libcrypto'), wrap=None)}
                }},
                no_match_error = "Please add a new target, see the openssl/README.MD",
            )

            libapp_srcs = select(
                {{
                    {bzl_list_fmt(10, plat_bind('libapp'), wrap=None)}
                }},
                no_match_error = "Please add a new target, see the openssl/README.MD",
            )

            openssl_app_srcs = select(
                {{
                    {bzl_list_fmt(10, plat_bind('openssl_app'), wrap=None)}
                }},
                no_match_error = "Please add a new target, see the openssl/README.MD",
            )
        ''')

    def _public_targets(self) -> str:
        return dedent(f'''
            cc_library(
                name = "crypto-textual-hdrs",
                textual_hdrs = [
                    "crypto/des/ncbc_enc.c",
                    "crypto/LPdir_unix.c",
                ],
            )

            cc_library(
                name = "crypto",
                srcs = libcrypto_srcs + glob([
                    "crypto/**/*.h",
                    "include/internal/*.h",
                ]) + [
                    "crypto/buildinf.h",
                    "include/crypto/dso_conf.h",
                    "e_os.h",
                ],
                hdrs = glob([
                    "include/openssl/*.h",
                    "include/crypto/*.h",
                ]) + [
                    "include/openssl/opensslconf.h",
                    "include/crypto/bn_conf.h",
                    "include/crypto/dso_conf.h",
                ],
                copts = copts + defines,
                linkopts = [
                    "-pthread",
                ],
                strip_include_prefix = "include",
                visibility = ["//visibility:public"],
                deps = [
                    ":crypto-textual-hdrs",
                    ":asm"
                ],
            )

            cc_library(
                name = "ssl",
                srcs = libssl_srcs + glob(["ssl/**/*.h"]) + [
                    "e_os.h",
                ],
                copts = copts + defines,
                visibility = ["//visibility:public"],
                deps = [
                    ":crypto",
                ],
            )

            alias(
                name = "crypto_ssl",
                actual = ":ssl",
                visibility = ["//visibility:public"],
            )

            cc_binary(
                name = "openssl",
                srcs = openssl_app_srcs + libapp_srcs + [
                    "apps/apps.h",
                    "apps/progs.h",
                    "apps/s_apps.h",
                    "apps/testdsa.h",
                    "apps/testrsa.h",
                    "apps/timeouts.h",
                ] + glob(["include/internal/*.h"]),
                copts = [
                    "-iquote",
                    "$(GENDIR)/external/org_openssl/apps",
                    "-I",
                    "external/org_openssl/include",
                ],
                visibility = ["//visibility:public"],
                deps = [":ssl"],
            )
        ''')

    def trailer(self) -> str:
        yield self._asm_target()

        for header in self._write_header_targets():
            yield header

        yield self._buildinf_target()

        for opts in self._copts():
            yield opts

        yield self._public_targets()

    def render(self, output):
        with output as out:
            out.write(self.header())

            for rule in self.rules():
                out.write(rule)

            for rule in self.trailer():
                out.write(rule)


def main(output_file: str):
    with open(output_file, 'w') as out, TemporaryDirectory() as work_path:
        print(f"Downloading, Extracting and handling OpenSSL in {work_path}")
        openssl_archive = download(work_path, VERSION)
        openssl_dir = extract_archive(work_path, openssl_archive)

        print("Deducing build configs for openssl")
        plan = Planner(openssl_dir)
        plan.gather_build_details()

        print("Rendering build file")
        render = Renderer(plan.build_details)
        render.render(out)


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} OUTPUT")
        sys.exit(1)

    main(sys.argv[1])
