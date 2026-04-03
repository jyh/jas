load("@rules_python//python:defs.bzl", "py_library", "py_test", "py_binary")

py_library(
    name = "jas_lib",
    srcs = ["jas_app.py", "canvas.py", "toolbar.py", "menu.py", "element.py", "document.py", "measure.py", "controller.py", "model.py"],
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
    name = "canvas_test",
    srcs = ["canvas_test.py"],
    deps = [
        ":jas_lib",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "element_test",
    srcs = ["element_test.py"],
    deps = [
        ":jas_lib",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "menu_test",
    srcs = ["menu_test.py"],
    deps = [
        ":jas_lib",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "document_test",
    srcs = ["document_test.py"],
    deps = [
        ":jas_lib",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "measure_test",
    srcs = ["measure_test.py"],
    deps = [
        ":jas_lib",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "model_test",
    srcs = ["model_test.py"],
    deps = [
        ":jas_lib",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "controller_test",
    srcs = ["controller_test.py"],
    deps = [
        ":jas_lib",
        "@pip_deps//absl_py",
    ],
)
