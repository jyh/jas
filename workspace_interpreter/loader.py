"""YAML workspace loader and element tree utilities.

Loads a workspace from a YAML file or directory, resolves include
directives, merges subdirectories (panels, dialogs, appearances,
swatches), and provides element tree query functions.
"""

import copy
import json
import os
import yaml


REQUIRED_KEYS = {"version", "app", "theme", "state", "actions", "shortcuts", "menubar", "layout"}


def load_workspace(path: str) -> dict:
    """Load a workspace from a YAML file or a directory of YAML files.

    If path is a directory, each *.yaml file is loaded and its top-level
    keys are merged into a single dict.  Recognized subdirectories are
    merged into their corresponding top-level key:

    - ``dialogs/`` -- each file's top-level keys merge into ``data["dialogs"]``
    - ``panels/`` -- each file is a single element spec, keyed by its ``id`` field

    Appearance overrides are loaded from ``appearances/*.json`` and swatch
    libraries from ``swatches/*.json``.

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
        for subdir in ("dialogs", "panels", "templates"):
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
                    panel_id = part.get("id", os.path.splitext(fname)[0])
                    merged[panel_id] = part
                else:
                    merged.update(part)
            if merged:
                data[subdir] = merged
        # Load appearance overrides from appearances/ directory
        appearances_dir = os.path.join(path, "appearances")
        if os.path.isdir(appearances_dir):
            theme = data.get("theme", {})
            appearances = theme.get("appearances", {})
            for fname in sorted(os.listdir(appearances_dir)):
                if not fname.endswith(".json"):
                    continue
                appearance_name = os.path.splitext(fname)[0]
                fpath = os.path.join(appearances_dir, fname)
                with open(fpath, "r") as f:
                    appearance_data = json.load(f)
                if isinstance(appearance_data, dict):
                    appearances[appearance_name] = appearance_data
            theme["appearances"] = appearances
            data["theme"] = theme
        # Load swatch libraries from swatches/ directory
        swatches_dir = os.path.join(path, "swatches")
        if os.path.isdir(swatches_dir):
            swatch_libraries = data.get("swatch_libraries", {})
            for fname in sorted(os.listdir(swatches_dir)):
                if not fname.endswith(".json"):
                    continue
                lib_name = os.path.splitext(fname)[0]
                fpath = os.path.join(swatches_dir, fname)
                with open(fpath, "r") as f:
                    lib_data = json.load(f)
                if isinstance(lib_data, dict):
                    swatch_libraries[lib_name] = lib_data
            data["swatch_libraries"] = swatch_libraries
    else:
        with open(path, "r") as f:
            data = yaml.safe_load(f)
    missing = REQUIRED_KEYS - set(data.keys())
    if missing:
        raise ValueError(f"Missing required top-level keys: {missing}")
    # Resolve include directives in the layout tree
    workspace_dir = path if os.path.isdir(path) else os.path.dirname(path)
    if "layout" in data:
        resolve_includes(data["layout"], workspace_dir)
    # Resolve templates in layout, dialogs, and panels
    templates = data.get("templates", {})
    if templates:
        if "layout" in data:
            resolve_templates(data["layout"], templates)
        for section in ("dialogs", "panels"):
            section_data = data.get(section, {})
            if isinstance(section_data, dict):
                for key, item in section_data.items():
                    if isinstance(item, dict):
                        content = item.get("content")
                        if isinstance(content, dict):
                            resolve_templates(content, templates)
    return data


def resolve_includes(element: dict, workspace_dir: str) -> None:
    """Walk the element tree and expand ``include:`` directives in-place.

    An include node like ``{include: "panels/layers.yaml", bind: {...}}``
    is replaced by the contents of the referenced file, with any sibling
    keys (e.g. ``bind``) merged on top.
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
                    for k, v in child.items():
                        included[k] = v
                    children[i] = included
                    resolve_includes(included, workspace_dir)
            else:
                resolve_includes(child, workspace_dir)
    content = element.get("content")
    if isinstance(content, dict):
        resolve_includes(content, workspace_dir)


def substitute_params(value, params: dict):
    """Substitute ``${name}`` tokens in a value tree.

    Two modes:
    - Whole-value: if value is exactly ``"${name}"``, replaced with typed param.
    - String interpolation: ``${name}`` inside a larger string is interpolated.

    Recursively processes dicts and lists. Unknown ``${name}`` are left unchanged.
    """
    if isinstance(value, str):
        import re
        # Whole-value substitution: string is exactly "${name}"
        m = re.fullmatch(r'\$\{(\w+)\}', value)
        if m:
            name = m.group(1)
            if name in params:
                return params[name]
            return value
        # String interpolation: replace all ${name} occurrences
        def _repl(m):
            name = m.group(1)
            if name in params:
                return str(params[name])
            return m.group(0)
        return re.sub(r'\$\{(\w+)\}', _repl, value)
    if isinstance(value, dict):
        return {k: substitute_params(v, params) for k, v in value.items()}
    if isinstance(value, list):
        return [substitute_params(item, params) for item in value]
    return value


def resolve_templates(element: dict, templates: dict, _depth: int = 0) -> None:
    """Walk an element tree and expand ``template:`` directives in-place.

    A template node like ``{template: "slider_row", params: {label: "H"}}``
    is replaced by the template's content with ``${name}`` tokens substituted.
    Sibling keys (e.g. ``id``, ``style``) merge onto the expanded element.

    Recursion depth is limited to prevent infinite loops from circular templates.
    """
    if _depth > 20:
        return
    children = element.get("children")
    if isinstance(children, list):
        for i, child in enumerate(children):
            if not isinstance(child, dict):
                continue
            if "template" in child and "repeat" not in child:
                template_name = child.pop("template")
                provided_params = child.pop("params", {})
                template_def = templates.get(template_name)
                if template_def is None:
                    continue
                # Resolve params: apply defaults from template definition
                param_defs = template_def.get("params", {})
                resolved = {}
                for pname, pdef in param_defs.items():
                    if pname in provided_params:
                        resolved[pname] = provided_params[pname]
                    elif isinstance(pdef, dict) and "default" in pdef:
                        resolved[pname] = pdef["default"]
                # Also pass through any extra params not in the definition
                for pname, pval in provided_params.items():
                    if pname not in resolved:
                        resolved[pname] = pval
                # Deep-clone and substitute
                import copy
                content = copy.deepcopy(template_def.get("content", {}))
                content = substitute_params(content, resolved)
                # Merge sibling keys from invocation onto expanded content
                # For dict values (like style), deep-merge instead of replacing
                for k, v in child.items():
                    if k in content and isinstance(content[k], dict) and isinstance(v, dict):
                        merged = dict(content[k])
                        merged.update(v)
                        content[k] = merged
                    else:
                        content[k] = v
                children[i] = content
                # Recurse into expanded element (handles nested templates)
                resolve_templates(content, templates, _depth + 1)
            else:
                resolve_templates(child, templates, _depth)
    content = element.get("content")
    if isinstance(content, dict):
        resolve_templates(content, templates, _depth)


def resolve_appearance(theme_config: dict, name: str | None = None) -> dict:
    """Resolve a named appearance by deep-merging base with overrides.

    Returns a flat dict with ``colors``, ``fonts``, ``sizes`` keys.
    """
    if name is None:
        name = theme_config.get("active", "dark_gray")
    appearances = theme_config.get("appearances", {})
    if name not in appearances:
        raise ValueError(f"Unknown appearance: {name!r}")
    overrides = appearances[name]
    result = copy.deepcopy(theme_config.get("base", {}))
    for section in ("colors", "sizes"):
        if section in overrides:
            result.setdefault(section, {}).update(overrides[section])
    if "fonts" in overrides:
        base_fonts = result.setdefault("fonts", {})
        for font_name, font_overrides in overrides["fonts"].items():
            if font_name in base_fonts and isinstance(base_fonts[font_name], dict):
                base_fonts[font_name] = dict(base_fonts[font_name], **font_overrides)
            else:
                base_fonts[font_name] = font_overrides
    return result


def list_appearances(theme_config: dict) -> list[dict]:
    """Return available appearances as ``[{"name": ..., "label": ...}, ...]``."""
    return [
        {"name": k, "label": v.get("label", k)}
        for k, v in theme_config.get("appearances", {}).items()
    ]


def find_element_by_id(element: dict, target_id: str) -> dict | None:
    """DFS walk to find an element by its id."""
    if not isinstance(element, dict):
        return None
    if element.get("id") == target_id:
        return element
    for child in element.get("children", []):
        result = find_element_by_id(child, target_id)
        if result:
            return result
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


def state_defaults(state_defs: dict) -> dict:
    """Extract default values from the state definitions section.

    Each entry is like ``{type: "color", default: "#ffffff", nullable: true}``.
    Returns a flat dict of ``{name: default_value}``.
    """
    defaults = {}
    for name, defn in (state_defs or {}).items():
        if isinstance(defn, dict):
            defaults[name] = defn.get("default")
        else:
            defaults[name] = defn
    return defaults


def panel_state_defaults(panel_spec: dict) -> dict:
    """Extract default values from a panel's state section.

    Returns a flat dict of ``{field_name: default_value}``.
    """
    return state_defaults(panel_spec.get("state", {}))
