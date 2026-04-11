"""YAML workspace loader, interpolation resolver, and element tree utilities."""

import re
import yaml


REQUIRED_KEYS = {"version", "app", "theme", "state", "actions", "shortcuts", "menubar", "layout"}

# Matches {{theme.colors.bg}}, {{state.active_tool}}, {{param.filename}}, etc.
_INTERP_RE = re.compile(r"\{\{(.+?)\}\}")


def load_workspace(path: str) -> dict:
    """Load a WORKSPACE.yaml file and validate required top-level keys."""
    with open(path, "r") as f:
        data = yaml.safe_load(f)
    missing = REQUIRED_KEYS - set(data.keys())
    if missing:
        raise ValueError(f"Missing required top-level keys: {missing}")
    return data


def resolve_interpolation(text: str, theme: dict, state: dict, params: dict | None = None) -> str:
    """Replace {{theme.*}}, {{state.*}}, {{param.*}} references with values.

    Returns the resolved string. Missing references resolve to empty string.
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
        return ""

    return _INTERP_RE.sub(_lookup, text)


def find_element_by_id(element: dict, target_id: str) -> dict | None:
    """DFS walk to find an element by its id."""
    if not isinstance(element, dict):
        return None
    if element.get("id") == target_id:
        return element
    # Search children
    for child in element.get("children", []):
        result = find_element_by_id(child, target_id)
        if result:
            return result
    # Search content (panes have content instead of children)
    content = element.get("content")
    if isinstance(content, dict):
        result = find_element_by_id(content, target_id)
        if result:
            return result
    return None


def collect_element_ids(element: dict) -> list[str]:
    """Collect all element ids from the layout tree."""
    ids = []
    if not isinstance(element, dict):
        return ids
    if "id" in element:
        ids.append(element["id"])
    for child in element.get("children", []):
        ids.extend(collect_element_ids(child))
    content = element.get("content")
    if isinstance(content, dict):
        ids.extend(collect_element_ids(content))
    return ids
