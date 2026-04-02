load("@rules_python//python:defs.bzl", "py_library", "py_test", "py_binary")

py_library(
    name = "mandelbrot_lib",
    srcs = ["mandelbrot_app.py"],
    deps = [
        "@pip_deps//numpy",
        "@pip_deps//numba",
        "@pip_deps//pyside6",
    ],
)

py_binary(
    name = "mandelbrot_app",
    srcs = ["mandelbrot_app.py"],
    deps = [":mandelbrot_lib"],
    main = "mandelbrot_app.py",
)

py_test(
    name = "mandelbrot_test",
    srcs = ["mandelbrot_test.py"],
    deps = [
        ":mandelbrot_lib",
        "@pip_deps//absl_py",
    ],
)
