import os


class RunfilesError(Exception):
    pass


def _validate_repo_path(repo_path: str) -> None:
    if not repo_path.startswith(("//", "@")):
        raise RunfilesError("absolute Bazel path required", repo_path)
    if ":" in repo_path:
        raise RunfilesError("absolute Bazel target not allowed - use path", repo_path)
    for x in repo_path.split("/"):
        if x in (".", ".."):
            raise RunfilesError(
                "absolute Bazel path only - no relative paths", repo_path
            )


# Return a full path to a resource referenced by the Bazel target path.
def data_path(repo_path: str) -> str:
    _validate_repo_path(repo_path)

    runfiles_dir = os.getenv("RUNFILES")
    if not runfiles_dir:
        raise RunfilesError("RUNFILES environment variable not defined")

    if repo_path.startswith("@"):
        return os.path.normpath(os.path.join(runfiles_dir, "..", repo_path[1:]))
    return os.path.join(runfiles_dir, repo_path[2:])


# Return a full path to a resource referenced by the Bazel target path
# deployed by external config path.
def config_data_path(repo_path: str, external_config_path: str) -> str:
    _validate_repo_path(repo_path)

    runfiles_dir = external_config_path + ".runfiles"
    if not os.path.isdir(runfiles_dir):
        raise RunfilesError(
            "external config does not have runfiles", external_config_path
        )

    return os.path.join(runfiles_dir, "__main__", repo_path[2:])


def maybe_data_path(file_or_repo_path: str) -> str:
    """
    If given a Bazel target path, return a full file path to the referenced resource.
    Otherwise, return the input unchanged.
    """
    if file_or_repo_path.startswith(("//", "@")):
        return data_path(file_or_repo_path)
    else:
        return file_or_repo_path
