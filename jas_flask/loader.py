"""YAML workspace loader — thin wrapper over workspace_interpreter.loader.

Flask-specific functions (resolve_interpolation) remain here as they
depend on the renderer module. All structural loading functions are
delegated to the shared library.
"""

import os
import re
import sys

# Add project root to path so workspace_interpreter is importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from workspace_interpreter.loader import (  # noqa: E402, F401
    REQUIRED_KEYS,
    load_workspace,
    resolve_includes,
    resolve_appearance,
    list_appearances,
    find_element_by_id,
    collect_element_ids,
    state_defaults,
    panel_state_defaults,
)

# Matches {{theme.colors.bg}}, {{state.active_tool}}, {{param.filename}}, etc.
_INTERP_RE = re.compile(r"\{\{(.+?)\}\}")


def resolve_interpolation(text: str, theme: dict, state: dict, params: dict | None = None) -> str:
    """Replace {{theme.*}}, {{state.*}}, {{param.*}} references with values.

    Returns the resolved string. Missing references resolve to empty string.

    NOTE: This is a legacy function used by Flask's server-side renderer.
    New code should use workspace_interpreter.expr.evaluate_text() instead.
    """
    if not isinstance(text, str) or "{{" not in text:
        return str(text) if text is not None else ""

    def _lookup(match):
        path = match.group(1).strip()
        parts = path.split(".")
        if len(parts) < 2:
            return ""
        root = parts[0]
        if root == "theme":
            obj = theme
            for key in parts[1:]:
                if isinstance(obj, dict) and key in obj:
                    obj = obj[key]
                else:
                    return ""
            return str(obj)
        elif root == "state":
            key = parts[1]
            if key in state:
                return str(state[key])
            return ""
        elif root == "param":
            if params and parts[1] in params:
                return str(params[parts[1]])
            return ""
        elif root == "data":
            from renderer import resolve_data_path
            result = resolve_data_path(".".join(parts[1:]))
            return str(result) if result is not None else ""
        return ""

    return _INTERP_RE.sub(_lookup, text)
