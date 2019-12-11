# mypy: allow-untyped-defs, no-check-untyped-defs

# Some seriously rinky-dink bullshit for parsing a Bazel build
# file. At least it is not regex.

import glob
import os.path

from typing import Any

MYPY = False
if MYPY:
    from typing import List, Dict, Text


def _exec_wrapper(code, namespace):
    exec(code, namespace)


def _glob_pattern(dirname, pattern, exclude_directories):
    chunks = pattern.split("**")
    # Only deal with simple patterns
    assert (
        len(chunks) < 3
    ), "pattern too complex for patrick's crappy implementation: %s %s" % (
        dirname,
        pattern,
    )

    if len(chunks) == 1:  # non-recursive
        return glob.glob(os.path.join(dirname, pattern)), []

    prefix, suffix = chunks

    assert prefix == "" or prefix.endswith("/"), "Invalid bazel glob pattern: %s %s" % (
        dirname,
        pattern,
    )
    if prefix.endswith("/"):
        prefix = prefix[:-1]

    assert suffix == "" or suffix.startswith(
        "/"
    ), "Invalid bazel glob pattern: %s %s" % (dirname, pattern)

    results = set()
    sub_pkgs = set()
    dirs = glob.glob(os.path.join(dirname, prefix))
    for d in dirs:
        if not os.path.isdir(d):
            continue

        if not exclude_directories and suffix == "":
            results.update(d)

        for root, _, files in os.walk(d):
            if suffix == "":  # <blah>/**
                results.update(os.path.join(root, f) for f in files)
            else:
                results.update(glob.glob(os.path.join(root, suffix[1:])))

            if "BUILD" in files and root != dirname:
                sub_pkgs.add(root)

    return results, sub_pkgs


# A super hacky implementation of bazel's glob.
def bazel_glob(dirname, include, exclude=None, exclude_directories=True):
    results = set()
    sub_pkgs = set()

    for pattern in include:
        files, pkgs = _glob_pattern(dirname, pattern, exclude_directories)
        results.update(files)
        sub_pkgs.update(pkgs)

    for pattern in exclude or []:
        files, pkgs = _glob_pattern(dirname, pattern, exclude_directories)
        results.difference_update(files)
        sub_pkgs.update(pkgs)

    trim = len(dirname)
    if not dirname.endswith("/"):
        trim += 1

    results = [src[trim:] for src in sorted(results)]
    sub_pkgs = [sub_pkg[trim:] + "/" for sub_pkg in sub_pkgs]

    final = []
    for src in results:
        for sub_pkg in sub_pkgs:
            if src.startswith(sub_pkg):
                break
        else:
            final.append(src)

    return final


class Rule(object):
    def __init__(self, rule_type, attr_map):
        self.rule_type = rule_type
        self.attr_map = attr_map


class BuildParser(object):
    def __init__(self):
        self.clauses = []
        self.constants = {}

    def parse(self, data, fname=None):
        class MacroDict(dict):
            def __missing__(d_self, name):
                def f(*args, **kargs):
                    self.clauses.append((name, args, kargs))
                    # The bazel select function needs to return a value for callers
                    # to exec properly. Here we'll return the concatenation of all options
                    # which matches output of bazel query, e.g. bzl query 'labels(label, //target)'.
                    if name == "select":
                        condition_dict = args[0]
                        return [
                            condition_val
                            for condition_values in condition_dict.values()
                            for condition_val in condition_values
                        ]

                return f

        pkg_name = ""
        glob_func = lambda *args, **kwargs: []
        if fname and os.path.isfile(fname):
            dirname = os.path.dirname(fname)

            glob_func = lambda *args, **kwargs: bazel_glob(dirname, *args, **kwargs)

            # This is not totally correct.  This should be full path relative
            # to workspace
            pkg_name = os.path.basename(dirname)

        build_globals = MacroDict()
        build_globals["package_name"] = lambda: pkg_name
        build_globals["glob"] = glob_func
        build_globals["True"] = True
        build_globals["False"] = False
        build_globals["str"] = str
        try:
            _exec_wrapper(data, build_globals)
        except Exception as e:
            # Add a small mount of file context to the error
            e.args += (fname,)
            raise e

        for key, value in build_globals.items():
            if key.isupper():
                # This only happens if the parser is reused for mutliple files
                assert key not in self.constants, "Constant name conflicit: " + key
                self.constants[key] = value

        return self.clauses

    def parse_file(self, build_file):
        with open(build_file, "rb") as f:
            return self.parse(f.read(), build_file)

    # Return a rule by name.
    def get_rule(self, name):
        for rule_type, args, kargs in self.clauses:
            if kargs.get("name") == name:
                return Rule(rule_type, kargs)
        raise KeyError("no rule with name", name)

    def get_rules_by_types(self, type_names):
        # type: (List[str]) -> List[Rule]
        rules = []
        for rule_type, args, kargs in self.clauses:
            if rule_type in type_names:
                rules.append(Rule(rule_type, kargs))
        return rules

    def get_all_rules(self):
        # type: () -> List[Rule]
        rules = []
        for rule_type, args, kargs in self.clauses:
            rules.append(Rule(rule_type, kargs))
        return rules

    def get_constant_value(self, name, default=None):
        return self.constants.get(name, default)

    def get_normalized_visibility_by_name(self):
        # type: () -> Dict[Text, List[Text]]
        rules = self.get_all_rules()
        default_visibility = []  # type: List[Text]
        for rule in rules:
            if rule.attr_map.get("default_visibility"):
                default_visibility = rule.attr_map["default_visibility"]
                break

        visibility_by_name = {}  # type: Dict[Text, List[Text]]
        for rule in rules:
            if not rule.attr_map.get("name"):
                # without names, we can't reference in. This should only be load and default visibility statements, not actual rules
                continue
            visibility_by_name[rule.attr_map["name"]] = rule.attr_map.get(
                "visibility", default_visibility
            )
        return visibility_by_name


def parse_file(fname):
    with open(fname, "rb") as f:
        return parse(f.read(), fname=fname)


def parse(src, fname="<BUILD>"):
    # type: (Any, str) -> BuildParser
    bp = BuildParser()
    try:
        bp.parse(src, fname)
    except SyntaxError as e:
        e.filename = fname
        raise e
    return bp
