# mypy: allow-untyped-defs, no-check-untyped-defs

# Some seriously rinky-dink bullshit for parsing a Bazel build
# file. At least it is not regex.

import glob
import os.path

MYPY = False
if MYPY:
    from typing import Any, Dict, List, Optional, Sequence, Text


def normalize_path(p):
    # type: (Text) -> Text
    """Convenience function to convert all path separators to forward slashes."""
    return p.replace(os.path.sep, "/")


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
        return (
            {
                normalize_path(f)
                for f in glob.glob(os.path.join(dirname, pattern))
                if not exclude_directories or os.path.isfile(f)
            },
            set(),
        )

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

    results = {
        normalize_path(result)
        for result in results
        if not exclude_directories or os.path.isfile(result)
    }
    sub_pkgs = {normalize_path(pkg) for pkg in sub_pkgs}
    return results, sub_pkgs


# A super hacky implementation of bazel's glob.
def bazel_glob(dirname, include, exclude=None, exclude_directories=True):
    results = set()
    sub_pkgs = set()

    dirname = normalize_path(dirname)

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


def select_func(*args, **kwargs):
    # type: (*Any, **Any) -> List[Select]
    """Hacky way to handle `select()` calls in BUILD files.

    Note that this treats `select()`s like lists, so it'll
    fail to parse BUILD files that try to add `select()`s
    to non-list items."""
    return [Select(args[0])]


def maybe_expand_attribute(attr_val):
    # type: (Any) -> Any
    """Attempts to expand any `select()`s found in attr_val.

    Useful for normalizing values that might contain `select()`s.
    """
    # If an attribute value has a Select, it must be in a list.
    if not isinstance(attr_val, list):
        return attr_val

    expanded = []
    for val in attr_val:
        if isinstance(val, Select):
            expanded.extend(val.expand())
        else:
            expanded.append(val)

    return expanded


def get_select_aware_attribute_repr(attr_val):
    # type: (Any) -> Text
    """Returns a string representation of an attribute value
    that respects potential `select()`s."""
    # If an attribute value has a Select, it must be in a list.
    if not isinstance(attr_val, list):
        return repr(attr_val)

    selects = []
    non_selects = []
    for val in attr_val:
        if isinstance(val, Select):
            selects.append(val)
        else:
            non_selects.append(val)

    if not selects:
        return repr(non_selects)

    select_repr = " + ".join([repr(i) for i in selects])
    if not non_selects:
        return select_repr

    return repr(non_selects) + " + " + select_repr


class Rule(object):
    def __init__(self, rule_type, attr_map):
        # type: (Text, Dict[Text, Any]) -> None
        self.rule_type = rule_type
        self.attr_map = attr_map


class Select(object):
    """Represents a `select()` call in Starlark."""

    def __init__(self, select_map):
        # type: (Dict[Text, Any]) -> None
        self.select_map = select_map
        self.expanded = None  # type: Optional[List[Any]]

    def __repr__(self):
        # type: () -> str
        return "select({})".format(repr(self.select_map))

    def expand(self):
        # type: () -> List[Any]
        if self.expanded:
            return self.expanded

        # For the sake of simplicity, we assume we're either
        # dealing with lists or constants. This doesn't do
        # the right thing with dicts -- callers will have to
        # figure it out themselves.
        expanded = []  # type: List[Any]
        for values in self.select_map.values():
            if isinstance(values, list):
                expanded.extend(values)
            else:
                expanded.append(values)
        self.expanded = expanded
        return self.expanded


class BuildParser(object):
    def __init__(self):
        self.clauses = []
        self.constants = {}

    def parse(self, data, fname=None):
        class MissingItem(object):
            """An object that can pretend to be either a function or a struct.
            While most items in a BUILD file are rules, we can occasionally get
            structs (such as the `selects` struct in bazel-skylib).

            Be aware that this may be exposed directly in `clauses`, such as
            cases when a named constant variable is used.
            """

            def __init__(mi_self, name):
                # type: (Text) -> None
                mi_self.name = name

            def __call__(mi_self, *args, **kargs):
                # type: (*Any, **Any) -> None
                """Handles the case where the item is a function."""
                self.clauses.append(
                    (object.__getattribute__(mi_self, "name"), args, kargs)
                )

            def __getattribute__(mi_self, key):
                # type: (Text) -> MissingItem
                """Handles the case where the item is a struct."""
                return MissingItem(
                    "{}.{}".format(object.__getattribute__(mi_self, "name"), key)
                )

        class MacroDict(dict):
            def __missing__(d_self, name):
                return MissingItem(name)

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
        build_globals["select"] = select_func
        try:
            _exec_wrapper(data, build_globals)
        except Exception as e:
            # Add a small amount of file context to the error
            e.args += (fname,)
            raise e

        for key, value in build_globals.items():
            if key.isupper():
                # This only happens if the parser is reused for multiple files
                assert key not in self.constants, "Constant name conflicit: " + key
                self.constants[key] = value

        return self.clauses

    def parse_file(self, build_file):
        with open(build_file, "rb") as f:
            return self.parse(f.read(), build_file)

    # Return a rule by name.
    def get_rule(self, name):
        # type: (object) -> Rule
        for rule_type, args, kargs in self.clauses:
            if kargs.get("name") == name:
                return Rule(rule_type, kargs)
        raise KeyError("no rule with name", name)

    def get_rules_by_types(self, type_names):
        # type: (Sequence[str]) -> List[Rule]
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

    def default_visibility(self):
        # type: () -> List[Text]
        for rule in self.get_all_rules():
            if "default_visibility" in rule.attr_map:
                return rule.attr_map["default_visibility"]
        return []

    def get_normalized_visibility_by_name(self):
        # type: () -> Dict[Text, List[Text]]
        default_visibility = self.default_visibility()
        visibility_by_name = {}  # type: Dict[Text, List[Text]]
        for rule in self.get_all_rules():
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
