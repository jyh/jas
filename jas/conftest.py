"""Pytest bootstrap — add the repo root to sys.path so tests can import
`workspace_interpreter` (which lives at the repo root, not inside jas/).

Individual modules (e.g. panels/yaml_menu.py) do the same sys.path insertion
at module load time, but that doesn't fire before pytest collection imports
test files that transitively depend on workspace_interpreter via jas_app.
"""

import os
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)
