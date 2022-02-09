from build_tools.npm_utils import target_to_npm_name


def test_target_to_npm_name() -> None:
    """ target_to_npm_name takes the target and computes the name of the npm package
        that the target should refer to.
    """

    # basic case
    assert target_to_npm_name("//npm/angular-cookies") == "angular-cookies"

    # make sure we don't blow up or misgenerate if a :part is present in the target
    assert (
        target_to_npm_name("//npm/angular-cookies:angular-cookies") == "angular-cookies"
    )

    # scoped packages
    assert target_to_npm_name("//npm/at_types/foo") == "@types/foo"

    # non-root npm folder
    assert target_to_npm_name("//fakecenter/static/nfs/npm/foo") == "foo"

    # some invalid names - should all return None
    assert target_to_npm_name("//npm/at_types/react/node_modules") is None
    assert target_to_npm_name("//npm/foo/bar") is None
    assert target_to_npm_name("//npm/at_foo") is None
    assert target_to_npm_name("//npm/at_types") is None

    # a non-npm test case - necessary because we use this function in some situations
    # where an npm input isn't guaranteed
    assert target_to_npm_name("//broken") is None
