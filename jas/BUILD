load("@rules_python//python:defs.bzl", "py_library", "py_test", "py_binary")

py_library(
    name = "geometry",
    srcs = [
        "geometry/__init__.py",
        "geometry/element.py",
        "geometry/measure.py",
        "geometry/svg.py",
    ],
    imports = ["."],
)

py_library(
    name = "algorithms",
    srcs = [
        "algorithms/__init__.py",
        "algorithms/boolean.py",
        "algorithms/boolean_normalize.py",
        "algorithms/fit_curve.py",
        "algorithms/hit_test.py",
        "algorithms/path_text_layout.py",
        "algorithms/text_layout.py",
    ],
    imports = ["."],
    deps = [":geometry"],
)

py_library(
    name = "document",
    srcs = [
        "document/__init__.py",
        "document/controller.py",
        "document/document.py",
        "document/model.py",
    ],
    imports = ["."],
    deps = [":algorithms", ":geometry"],
)

py_library(
    name = "tools",
    srcs = [
        "tools/__init__.py",
        "tools/partial_selection_tool.py",
        "tools/drawing_tool.py",
        "tools/interior_selection_tool.py",
        "tools/line_tool.py",
        "tools/pen_tool.py",
        "tools/pencil_tool.py",
        "tools/polygon_tool.py",
        "tools/rect_tool.py",
        "tools/rounded_rect_tool.py",
        "tools/selection_tool.py",
        "tools/star_tool.py",
        "tools/type_tool.py",
        "tools/type_on_path_tool.py",
        "tools/tool.py",
        "tools/toolbar.py",
    ],
    imports = ["."],
    deps = [
        ":algorithms",
        ":document",
        ":geometry",
        "@pip_deps//pyside6",
    ],
)

py_library(
    name = "canvas",
    srcs = [
        "canvas/__init__.py",
        "canvas/canvas.py",
    ],
    imports = ["."],
    deps = [
        ":algorithms",
        ":document",
        ":geometry",
        ":tools",
        "@pip_deps//pyside6",
    ],
)

py_library(
    name = "menu",
    srcs = [
        "menu/__init__.py",
        "menu/menu.py",
    ],
    imports = ["."],
    deps = [
        ":document",
        ":geometry",
        "@pip_deps//pyside6",
    ],
)

py_library(
    name = "jas_lib",
    srcs = ["jas_app.py"],
    imports = ["."],
    deps = [":algorithms", ":canvas", ":document", ":geometry", ":menu", ":tools"],
)

py_binary(
    name = "jas_app",
    srcs = ["jas_app.py"],
    deps = [":algorithms", ":canvas", ":document", ":geometry", ":menu", ":tools"],
    main = "jas_app.py",
)

py_test(
    name = "element_test",
    srcs = ["geometry/element_test.py"],
    deps = [
        ":geometry",
        ":tools",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "measure_test",
    srcs = ["geometry/measure_test.py"],
    deps = [
        ":geometry",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "svg_test",
    srcs = ["geometry/svg_test.py"],
    deps = [
        ":geometry",
        ":document",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "document_test",
    srcs = ["document/document_test.py"],
    deps = [
        ":document",
        ":geometry",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "model_test",
    srcs = ["document/model_test.py"],
    deps = [
        ":document",
        ":geometry",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "controller_test",
    srcs = ["document/controller_test.py"],
    deps = [
        ":document",
        ":geometry",
        "@pip_deps//absl_py",
    ],
)

py_test(
    name = "canvas_test",
    srcs = ["canvas/canvas_test.py"],
    deps = [
        ":canvas",
        ":document",
        ":geometry",
        ":tools",
        "@pip_deps//absl_py",
        "@pip_deps//pyside6",
    ],
)

py_test(
    name = "menu_test",
    srcs = ["menu/menu_test.py"],
    deps = [
        ":jas_lib",
        ":menu",
        ":document",
        ":geometry",
        "@pip_deps//absl_py",
        "@pip_deps//pyside6",
    ],
)

py_test(
    name = "toolbar_test",
    srcs = ["tools/toolbar_test.py"],
    deps = [
        ":tools",
        ":document",
        ":geometry",
        "@pip_deps//absl_py",
        "@pip_deps//pyside6",
    ],
)

py_test(
    name = "tool_interaction_test",
    srcs = ["tools/tool_interaction_test.py"],
    deps = [
        ":tools",
        ":document",
        ":geometry",
        "@pip_deps//absl_py",
        "@pip_deps//pyside6",
    ],
)
