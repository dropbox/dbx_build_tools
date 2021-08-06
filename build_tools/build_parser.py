# mypy: allow-any-generics

# Some seriously rinky-dink bullshit for parsing a Bazel build
# file. At least it is not regex.

import glob
import os.path

from typing import (
    Any,
    Callable,
    cast,
    Dict,
    List,
    Optional,
    Sequence,
    Set,
    Text,
    Tuple,
    TypeVar,
    Union,
)

F = TypeVar("F", bound=Callable[..., Any])

# Used in place of functools.lru_cache as it is significantly faster in this case
def memoize(func):
    # type: (F) -> F
    """A simple memoization decorator.
    NOTICE: kwargs is ignored for key construction"""
    cache = {}  # type: Dict[Any, Any]

    def wrap(*args, **kwargs):
        # type: (Any, Any) -> Any
        key = tuple(args)
        value = cache.get(key)
        if value is None:
            value = func(*args, **kwargs)
            cache[key] = value
        return value

    return cast(F, wrap)


def normalize_path(p):
    # type: (Text) -> Text
    """Convenience function to convert all path separators to forward slashes."""
    return p.replace(os.path.sep, "/")


def _exec_wrapper(code, namespace):
    # type: (Text, Any) -> Any
    exec(code, namespace)


@memoize
def os_walk(d):
    # type: (Text) -> List[Tuple[Text, List[Text], List[Text]]]
    return list(os.walk(d))


@memoize
def get_glob(path):
    # type: (Text) -> List[Text]
    return glob.glob(path)


@memoize
def _glob_pattern(dirname, pattern, exclude_directories):
    # type: (Text, Text, bool) -> Tuple[Set[Text], Set[Text]]
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
                for f in get_glob(os.path.join(dirname, pattern))
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

    results = set()  # type: Set[Text]
    sub_pkgs = set()  # type: Set[Text]
    dirs = get_glob(os.path.join(dirname, prefix))
    for d in dirs:
        if not os.path.isdir(d):
            continue

        if not exclude_directories and suffix == "":
            results.update(d)

        for root, _, files in os_walk(d):
            if suffix == "":  # <blah>/**
                results.update(os.path.join(root, f) for f in files)
            else:
                results.update(get_glob(os.path.join(root, suffix[1:])))

            if "BUILD" in files and root != dirname:
                sub_pkgs.add(root)

    results = {
        normalize_path(result)
        for result in results
        if not exclude_directories or os.path.isfile(result)
    }
    sub_pkgs = {normalize_path(pkg) for pkg in sub_pkgs}
    return results, sub_pkgs


@memoize
def _bazel_glob(dirname, include, exclude=None, exclude_directories=True):
    # type: (Text, Tuple[Text, ...], Optional[Tuple[Text, ...]], bool) -> Tuple[Text, ...]
    """A super hacky implementation of bazel's glob."""

    results = set()  # type: Set[Text]
    sub_pkgs = set()  # type: Set[Text]

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

    results_list = [src[trim:] for src in sorted(results)]
    sub_pkgs_list = [sub_pkg[trim:] + "/" for sub_pkg in sub_pkgs]

    final = []  # type: List[Text]
    for src in results_list:
        for sub_pkg in sub_pkgs_list:
            if src.startswith(sub_pkg):
                break
        else:
            final.append(src)

    return tuple(final)


class BazelGlob(object):
    def __init__(self, dirname=None):
        # type: (Optional[Text]) -> None
        self.dirname = dirname

    def glob(self, include, exclude=None, exclude_directories=True):
        # type: (List[Text], Optional[List[Text]], bool) -> List[Text]
        if self.dirname is None:
            return []
        _exclude = tuple(exclude) if exclude is not None else exclude
        return list(
            _bazel_glob(self.dirname, tuple(include), _exclude, exclude_directories)
        )


def maybe_expand_attribute(attr_val):
    # type: (Any) -> Any
    """Attempts to expand any `select()`s found in attr_val.

    Useful for normalizing values that might contain `select()`s.
    """
    # If an attribute value has a Select, it must be in a list.
    if not isinstance(attr_val, list):
        return attr_val

    expanded = []  # type: List[Any]
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

    selects = []  # type: List[Select]
    non_selects = []  # type: List[Text]
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


class ConstDict(dict):
    def __setitem__(self, _key, _value):
        # type: (Any, Any) -> None
        raise TypeError("ConstDict object does not support item assignment")

    def update(self, *_args, **_kwargs):
        # type: (Any, Any) -> None
        raise TypeError("ConstDict object does not support item update")

    def __delitem__(self, _key):
        # type: (Any) -> None
        raise TypeError("ConstDict object does not support item deletion")

    def popitem(self):
        # type: () -> Any
        raise TypeError("ConstDict object does not support item removal")

    def pop(self, *_key):
        # type: (Any) -> Any
        raise TypeError("ConstDict object does not support item removal")


class MutableRule(object):
    def __init__(self, rule_type, attr_map, expanded_attr_map):
        # type: (Text, Dict[Text, Any], Dict[Text, Union[Text, List[Text]]]) -> None
        self.rule_type = rule_type
        self.attr_map = attr_map
        self.expanded_attr_map = expanded_attr_map

    def copy_attr_map(self):
        # type: () -> Dict[Text, Any]
        return self.attr_map.copy()


class Rule(object):
    def __init__(self, rule_type, attr_map):
        # type: (Text, Dict[Text, Any]) -> None
        self._rule_type = rule_type
        self._attr_map = ConstDict(attr_map)
        self._expanded_attr_map = ConstDict(
            {k: maybe_expand_attribute(v) for k, v in attr_map.items()}
        )

    def copy(self):
        # type: () ->  MutableRule
        return MutableRule(
            self._rule_type, self.copy_attr_map(), self.expanded_attr_map.copy()
        )

    def copy_attr_map(self):
        # type: () -> Dict[Text, Any]
        return self._attr_map.copy()

    @property
    def rule_type(self):
        # type: () -> Text
        return self._rule_type

    @rule_type.setter
    def rule_type(self, _value):
        # type: (Any) -> None
        raise TypeError("Rule object does not support item assignment")

    @property
    def attr_map(self):
        # type: () -> ConstDict
        return self._attr_map

    @attr_map.setter
    def attr_map(self, _value):
        # type: (Any) -> None
        raise TypeError("Rule object does not support item assignment")

    @property
    def expanded_attr_map(self):
        # type: () -> ConstDict
        return self._expanded_attr_map

    @expanded_attr_map.setter
    def expanded_attr_map(self, _value):
        # type: (Any) -> None
        raise TypeError("Rule object does not support item assignment")


class Select(object):
    """Represents a `select()` call in Starlark."""

    def __init__(self, select_map):
        # type: (Dict[Text, Any]) -> None
        self._select_map = select_map
        self._expanded = None  # type: Optional[Tuple[Any, ...]]

    def __repr__(self):
        # type: () -> str
        return "select({})".format(repr(self._select_map))

    @property
    def select_map(self):
        # type: () -> Dict[Text, Any]
        return self._select_map

    @select_map.setter
    def select_map(self, _value):
        # type: (Any) -> None
        raise TypeError("Setting const attribute Select.select_map")

    def expand(self):
        # type: () -> Tuple[Any, ...]
        if self._expanded:
            return self._expanded

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
        self._expanded = tuple(expanded)
        return self._expanded


def select_func(*args, **kwargs):
    # type: (Dict[Text, Any], Any) -> List[Select]
    """Hacky way to handle `select()` calls in BUILD files.

    Note that this treats `select()`s like lists, so it'll
    fail to parse BUILD files that try to add `select()`s
    to non-list items."""
    assert not kwargs
    return [Select(args[0])]


class _MissingItem(object):
    """An object that can pretend to be either a function or a struct.
    While most items in a BUILD file are rules, we can occasionally get
    structs (such as the `selects` struct in bazel-skylib).

    Be aware that this may be exposed directly in `clauses`, such as
    cases when a named constant variable is used.
    """

    def __init__(self, parser, name):
        # type: (BuildParser, Text) -> None
        self.name = name
        self.parser = parser

    def __call__(self, *args, **kargs):
        # type: (List[Any], Dict[Any, Any]) -> None
        """Handles the case where the item is a function."""
        parser = object.__getattribute__(self, "parser")
        parser._parsed_clauses.append(
            (object.__getattribute__(self, "name"), args, kargs)
        )

    def __getattribute__(self, key):
        # type: (Text) -> _MissingItem
        """Handles the case where the item is a struct."""
        return _MissingItem(
            object.__getattribute__(self, "parser"),
            "{}.{}".format(object.__getattribute__(self, "name"), key),
        )


class _MacroDict(dict):
    def __init__(self, parser):
        # type: (BuildParser) -> None
        self.parser = parser
        super(_MacroDict, self).__init__()

    def __missing__(self, name):
        # type: (Text) -> _MissingItem
        return _MissingItem(self.parser, name)


class BuildParser(object):
    def __init__(self):
        # type: () -> None

        self._parsed_clauses = []  # type: List[Any]
        self._parsed_constants = {}  # type: Dict[Text, Any]

    def parse(self, data, fname=None):
        # type: (Text, Optional[Text]) -> Tuple[Any, ...]
        """ 'parse' a BUILD file """

        pkg_name = ""  # type: Text
        dirname = None

        self.filename = fname

        if fname and os.path.isfile(fname):
            dirname = os.path.dirname(fname)

            # This is not totally correct.  This should be full path relative
            # to workspace
            pkg_name = os.path.basename(dirname)

        build_globals = _MacroDict(self)
        build_globals["package_name"] = lambda: pkg_name
        build_globals["glob"] = BazelGlob(dirname).glob
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
                assert (
                    key not in self._parsed_constants
                ), "Constant name conflicit: {}".format(key)
                self._parsed_constants[key] = value

        parsed_rules = {}  # type: Dict[Text, Rule]
        ordered_rules = []  # type: List[Rule]
        for rule_type, args, kargs in self._parsed_clauses:
            rule = Rule(rule_type, kargs)  # type: Rule
            parsed_rules[kargs.get("name")] = rule
            ordered_rules.append(rule)

        # Store the final parse data in immutable form
        self._rules = ConstDict(parsed_rules)
        self._ordered_rules = tuple(ordered_rules)
        self._clauses = tuple(self._parsed_clauses)
        self._constants = ConstDict(self._parsed_constants)
        # Clear mutable data to prevent access
        self._parsed_clauses = []
        self._parsed_constants = {}
        return self._clauses

    def parse_file(self, build_file):
        # type: (Text) -> Tuple[Any, ...]
        with open(build_file, "r") as f:
            return self.parse(f.read(), build_file)

    # Return a rule by name.
    def get_rule(self, name):
        # type: (Text) -> Rule
        rule = self._rules.get(name)
        if not rule:
            raise KeyError("no rule with name", name)
        return rule

    def get_rules_by_types(self, type_names):
        # type: (Sequence[str]) -> List[Rule]
        rules = []
        for rule in self._rules.values():
            if rule.rule_type in type_names:
                rules.append(rule)
        return rules

    def get_all_rules(self):
        # type: () -> Tuple[Rule, ...]
        # At least one generator is sensitive to the ordering of the rules, for example:
        #  bzl gen //configs/proto/dropbox/proto/envoy
        assert self._ordered_rules
        return self._ordered_rules

    def get_constant_value(self, name, default=None):
        # type: (Text, Any) -> Any
        return self._constants.get(name, default)

    def default_visibility(self):
        # type: () -> List[Text]
        for rule in self.get_all_rules():
            if "default_visibility" in rule.attr_map:
                return rule.attr_map["default_visibility"]
        return []

    def get_normalized_visibility_by_name(self):
        # type: () -> Dict[Text, List[Text]]
        default_visibility = self.default_visibility()
        visibility_by_name = {}
        for rule in self.get_all_rules():
            if not rule.attr_map.get("name"):
                # without names, we can't reference in. This should only be load and default visibility statements, not actual rules
                continue
            visibility_by_name[rule.attr_map["name"]] = rule.attr_map.get(
                "visibility", default_visibility
            )
        return visibility_by_name

    @property
    def clauses(self):
        # type: () -> Tuple[Any, ...]
        return self._clauses

    @clauses.setter
    def clauses(self, _value):
        # type: (Any) -> None
        raise TypeError("BuildParser does not support item assignment")

    @property
    def constants(self):
        # type: () -> ConstDict
        return self._constants

    @constants.setter
    def constants(self, _value):
        # type: (Any) -> None
        raise TypeError("BuildParser does not support item assignment")

    @property
    def rules(self):
        # type: () -> ConstDict
        return self._rules

    @rules.setter
    def rules(self, _value):
        # type: (Any) -> None
        raise TypeError("BuildParser does not support item assignment")


def parse_file(fname):
    # type: (Text) -> BuildParser
    with open(fname, "r") as f:
        return parse(f.read(), fname=fname)


def parse(src, fname="<BUILD>"):
    # type: (Text, Text) -> BuildParser
    bp = BuildParser()
    try:
        bp.parse(src, fname)
    except SyntaxError as e:
        e.filename = fname  # type: ignore
        raise e
    return bp
