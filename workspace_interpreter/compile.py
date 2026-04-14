"""Compile workspace YAML directory to a single JSON file.

Usage: python -m workspace_interpreter.compile <workspace_dir> [output.json]
"""

import json
import sys

from workspace_interpreter.loader import load_workspace


def main():
    if len(sys.argv) < 2:
        print("Usage: python -m workspace_interpreter.compile <workspace_dir> [output.json]", file=sys.stderr)
        sys.exit(1)

    workspace_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else None

    ws = load_workspace(workspace_path)

    if output_path:
        with open(output_path, "w") as f:
            json.dump(ws, f, indent=2)
    else:
        json.dump(ws, sys.stdout, indent=2)
        print()


if __name__ == "__main__":
    main()
