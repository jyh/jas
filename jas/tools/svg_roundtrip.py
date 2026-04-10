#!/usr/bin/env python3
"""CLI tool for cross-language commutativity testing.

Usage:
    python svg_roundtrip.py parse <file.svg>      -- parse SVG, output canonical JSON
    python svg_roundtrip.py roundtrip <file.svg>  -- parse SVG, re-serialize, output SVG
"""

import sys
import os

# Add project root to path so imports work.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from geometry.svg import svg_to_document, document_to_svg
from geometry.test_json import document_to_test_json


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} parse|roundtrip <file.svg>", file=sys.stderr)
        sys.exit(1)

    mode = sys.argv[1]
    filepath = sys.argv[2]

    with open(filepath) as f:
        svg = f.read()

    doc = svg_to_document(svg)

    if mode == "parse":
        print(document_to_test_json(doc), end="")
    elif mode == "roundtrip":
        print(document_to_svg(doc), end="")
    else:
        print(f"Unknown mode: {mode} (use 'parse' or 'roundtrip')", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
