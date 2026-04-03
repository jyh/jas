# Jas OCaml Application
#
# The OCaml app is built and tested using Dune build system.
# Dune is the primary build system for OCaml targets.
#
# Dune Commands:
#   Build: dune build
#   Run: dune exec bin/main.exe
#   Test: dune runtest
#
# Bazel Integration:
# The OCaml project is fully integrated into Bazel for dependency tracking.
# Helper scripts are provided for easy invocation:
#   bazel run //jas_ocaml:build_with_dune
#   bazel run //jas_ocaml:test_with_dune
#   bazel run //jas_ocaml:run_app
#
# Dependencies:
# - OCaml compiler
# - Dune build system
# - lablgtk3 (OCaml GTK3 bindings)

package(default_visibility = ["//visibility:public"])

exports_files(glob(
    ["**/*"],
    exclude = [
        "_build/**",
        ".merlin",
        "*.lock",
    ],
))

# Helper: Build OCaml project with Dune
genrule(
    name = "build_with_dune",
    srcs = glob(
        ["**/*"],
        exclude = [
            "_build/**",
            ".merlin",
            "*.lock",
        ],
    ),
    outs = ["build.txt"],
    cmd = "cd jas_ocaml && dune build && echo 'Build complete' > $@",
    local = True,
)

# Helper: Run OCaml tests with Dune
genrule(
    name = "test_with_dune",
    srcs = glob(
        ["**/*"],
        exclude = [
            "_build/**",
            ".merlin",
            "*.lock",
        ],
    ),
    outs = ["test.txt"],
    cmd = "cd jas_ocaml && dune runtest && echo 'Tests passed' > $@",
    local = True,
)

# Helper: Run OCaml application
genrule(
    name = "run_app",
    srcs = glob(
        ["**/*"],
        exclude = [
            "_build/**",
            ".merlin",
            "*.lock",
        ],
    ),
    outs = ["run.txt"],
    cmd = "cd jas_ocaml && dune exec bin/main.exe && echo 'App executed' > $@",
    local = True,
)
