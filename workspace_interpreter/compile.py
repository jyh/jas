"""Compile workspace YAML directory to a single JSON file.

Usage: python -m workspace_interpreter.compile <workspace_dir> [output.json] [--no-validate]

Validation runs by default. Pass ``--no-validate`` to skip (e.g. for
partial workspaces during development). CI should always run with
validation; see ``FLASK_PARITY.md`` §12 and ``schema/README.md``.
"""

import json
import sys

from workspace_interpreter.loader import load_workspace
from workspace_interpreter.validator import validate_workspace, format_errors


def main():
    args = sys.argv[1:]
    validate = True
    if "--no-validate" in args:
        validate = False
        args = [a for a in args if a != "--no-validate"]

    if len(args) < 1:
        print(
            "Usage: python -m workspace_interpreter.compile "
            "<workspace_dir> [output.json] [--no-validate]",
            file=sys.stderr,
        )
        sys.exit(1)

    workspace_path = args[0]
    output_path = args[1] if len(args) > 1 else None

    ws = load_workspace(workspace_path)

    if validate:
        errors = validate_workspace(ws)
        if errors:
            print(format_errors(errors), file=sys.stderr)
            sys.exit(2)

    if output_path:
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(ws, f, indent=2)
    else:
        json.dump(ws, sys.stdout, indent=2)
        print()


if __name__ == "__main__":
    main()
