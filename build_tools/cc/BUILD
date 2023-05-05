package(default_visibility = ["//visibility:public"])

constraint_setting(name = "drte_version")

constraint_value(
    name = "drte-v3",
    constraint_setting = ":drte_version",
)

constraint_value(
    name = "drte-v5",
    constraint_setting = ":drte_version",
)

constraint_value(
    name = "drte-off",
    constraint_setting = ":drte_version",
)

platform(
    name = "linux-x64-drte-v3",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
        ":drte-v3",
    ],
)

platform(
    name = "linux-x64-drte-v5",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
        ":drte-v5",
    ],
)
platform(
    name = "linux-x64-drte-off",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
        ":drte-off",
    ],
)
