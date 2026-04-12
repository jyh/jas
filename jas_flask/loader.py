"""YAML workspace loader, interpolation resolver, and element tree utilities."""

import os
import re
import yaml


REQUIRED_KEYS = {"version", "app", "theme", "state", "actions", "shortcuts", "menubar", "layout"}

# Matches {{theme.colors.bg}}, {{state.active_tool}}, {{param.filename}}, etc.
_INTERP_RE = re.compile(r"\{\{(.+?)\}\}")


def load_workspace(path: str) -> dict:
    """Load a workspace from a YAML file or a directory of YAML files.

    If path is a directory, each *.yaml file is loaded and its top-level
    keys are merged into a single dict.  Recognized subdirectories are
    merged into their corresponding top-level key:

    - ``dialogs/`` — each file's top-level keys merge into ``data["dialogs"]``
    - ``panels/`` — each file's top-level keys merge into ``data["panels"]``

    After loading, ``include:`` directives in the layout tree are resolved
    (see :func:`resolve_includes`).

    If path is a file, it is loaded as a single YAML document.
    """
    if os.path.isdir(path):
        data: dict = {}
        # Load top-level YAML files
        for fname in sorted(os.listdir(path)):
            if fname.endswith(".yaml") or fname.endswith(".yml"):
                fpath = os.path.join(path, fname)
                with open(fpath, "r") as f:
                    part = yaml.safe_load(f)
                if isinstance(part, dict):
                    data.update(part)
        # Load recognized subdirectories
        # dialogs: each file contains one or more named dialog entries (keyed dicts)
        # panels: each file is a single element spec, keyed by its "id" field
        for subdir in ("dialogs", "panels"):
            subdir_path = os.path.join(path, subdir)
            if not os.path.isdir(subdir_path):
                continue
            merged = data.get(subdir, {}) or {}
            for fname in sorted(os.listdir(subdir_path)):
                if not (fname.endswith(".yaml") or fname.endswith(".yml")):
                    continue
                fpath = os.path.join(subdir_path, fname)
                with open(fpath, "r") as f:
                    part = yaml.safe_load(f)
                if not isinstance(part, dict):
                    continue
                if subdir == "panels":
                    # Panel files are single elements — key by id
                    panel_id = part.get("id", os.path.splitext(fname)[0])
                    merged[panel_id] = part
                else:
                    # Dialog files contain named entries
                    merged.update(part)
            if merged:
                data[subdir] = merged
    else:
        with open(path, "r") as f:
            data = yaml.safe_load(f)
    missing = REQUIRED_KEYS - set(data.keys())
    if missing:
        raise ValueError(f"Missing required top-level keys: {missing}")
    # Resolve include directives in the layout tree
    if "layout" in data:
        resolve_includes(data["layout"], path if os.path.isdir(path) else os.path.dirname(path))
    return data


def resolve_includes(element: dict, workspace_dir: str) -> None:
    """Walk the element tree and expand ``include:`` directives in-place.

    An include node like ``{include: "panels/layers.yaml", bind: {...}}``
    is replaced by the contents of the referenced file, with any sibling
    keys (e.g. ``bind``) merged on top.  The file path is resolved relative
    to *workspace_dir*.
    """
    children = element.get("children")
    if isinstance(children, list):
        for i, child in enumerate(children):
            if not isinstance(child, dict):
                continue
            if "include" in child:
                rel_path = child.pop("include")
                fpath = os.path.join(workspace_dir, rel_path)
                with open(fpath, "r") as f:
                    included = yaml.safe_load(f)
                if isinstance(included, dict):
                    # Merge sibling keys (e.g. bind) onto the included element
                    for k, v in child.items():
                        included[k] = v
                    children[i] = included
                    # Recurse into the newly included element
                    resolve_includes(included, workspace_dir)
            else:
                resolve_includes(child, workspace_dir)
    content = element.get("content")
    if isinstance(content, dict):
        resolve_includes(content, workspace_dir)


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
