load("@rules_python//python:defs.bzl", "py_library", "py_test", "py_binary")

py_library(
    name = "jas_lib",
    srcs = ["jas_app.py", "canvas.py", "toolbar.py"],
    imports = ["."],
    deps = [
        "@pip_deps//pyside6",
    ],
)

py_binary(
    name = "jas_app",
    srcs = ["jas_app.py"],
    deps = [":jas_lib"],
    main = "jas_app.py",
)

py_test(
    name = "jas_test",
    srcs = ["jas_test.py"],
    deps = [
        ":jas_lib",
        "@pip_deps//absl_py",
    ],
)
