"""Flask application for rendering WORKSPACE.yaml in normal and wireframe modes."""

import json
import os

from flask import Flask, render_template, request, jsonify

from loader import load_workspace, find_element_by_id, resolve_appearance, list_appearances
from renderer import render_element, render_menubar, render_dialogs, set_icons, set_initial_state, set_brand, set_panels


def _safe_join(root: str, rel: str) -> str | None:
    """Join [root]/[rel] and confirm the result stays within [root].

    Returns the absolute path on success, or None if [rel] escapes the
    root (e.g. via ``../`` segments or by being an absolute path).
    Defense-in-depth — workspace YAML is trusted in the normal case,
    but rejecting traversal keeps the surface clean if the YAML ever
    comes from a less-trusted source."""
    candidate = os.path.abspath(os.path.join(root, rel))
    root_abs = os.path.abspath(root)
    if candidate != root_abs and not candidate.startswith(root_abs + os.sep):
        return None
    return candidate


def _resolve_brand(ws: dict, workspace_path: str | None) -> None:
    """Read brand logo SVG files from disk and store inlined content in ws['app']['brand']."""
    brand = ws.get("app", {}).get("brand")
    if not brand or workspace_path is None:
        return
    project_root = os.path.dirname(workspace_path) if os.path.isdir(workspace_path) else os.path.dirname(os.path.dirname(workspace_path))
    for key in ("logo", "logo_small"):
        rel = brand.get(key)
        if rel:
            path = _safe_join(project_root, rel)
            if path is None:
                brand[key + "_svg"] = ""
                continue
            try:
                with open(path, encoding="utf-8") as f:
                    brand[key + "_svg"] = f.read()
            except OSError:
                brand[key + "_svg"] = ""


def create_app(workspace: dict | None = None, workspace_path: str | None = None) -> Flask:
    """Create and configure the Flask app.

    Args:
        workspace: Pre-loaded workspace dict (for testing).
        workspace_path: Path to WORKSPACE.yaml (used if workspace is None).
    """
    app = Flask(__name__)

    # When a static workspace dict is provided (e.g. testing), use it directly
    # with no file-watching.  Otherwise, reload from disk when the file changes.
    _static_ws = workspace

    if _static_ws is None and workspace_path is None:
        workspace_path = os.environ.get(
            "WORKSPACE_YAML",
            os.path.join(os.path.dirname(__file__), "..", "workspace"),
        )

    _cached_ws: dict | None = None
    _cached_mtime: float = 0.0

    def _get_ws() -> dict:
        """Return the workspace dict, reloading from disk if the file changed."""
        nonlocal _cached_ws, _cached_mtime

        if _static_ws is not None:
            return _static_ws

        try:
            if os.path.isdir(workspace_path):
                # Use max mtime of all yaml files in the directory and subdirectories
                mtimes = []
                for dirpath, _dirnames, filenames in os.walk(workspace_path):
                    for f in filenames:
                        if f.endswith((".yaml", ".yml", ".json")):
                            mtimes.append(os.path.getmtime(os.path.join(dirpath, f)))
                mtime = max(mtimes) if mtimes else 0.0
            else:
                mtime = os.path.getmtime(workspace_path)
        except (OSError, ValueError):
            if _cached_ws is not None:
                return _cached_ws
            raise

        if _cached_ws is None or mtime != _cached_mtime:
            _cached_ws = load_workspace(workspace_path)
            _cached_mtime = mtime
            set_icons(_cached_ws.get("icons", {}))
            set_initial_state(_cached_ws.get("state", {}))
            set_panels(_cached_ws.get("panels", {}))
            _resolve_brand(_cached_ws, workspace_path)
            set_brand(_cached_ws.get("app", {}).get("brand", {}))

        return _cached_ws

    # Ensure icons, initial state, panels, and brand are set on first load
    ws_init = _get_ws()
    set_icons(ws_init.get("icons", {}))
    set_initial_state(ws_init.get("state", {}))
    set_panels(ws_init.get("panels", {}))
    _resolve_brand(ws_init, workspace_path)
    set_brand(ws_init.get("app", {}).get("brand", {}))

    def _state_defaults(ws: dict) -> dict:
        """Extract default values from state definitions."""
        return {name: defn.get("default") for name, defn in ws.get("state", {}).items()}

    def _pane_configs(ws: dict) -> dict:
        """Extract layout config for each pane: default_position, fixed_width, flex, min_width, collapsed_width."""
        configs = {}
        layout = ws.get("layout", {})
        for child in layout.get("children", []):
            if child.get("type") == "pane" and "id" in child:
                configs[child["id"]] = {
                    "default_position": child.get("default_position", {}),
                    "fixed_width": child.get("fixed_width", False),
                    "flex": child.get("flex", False),
                    "min_width": child.get("min_width", 50),
                    "collapsed_width": child.get("collapsed_width"),
                    "layout_state": child.get("layout_state", []),
                }
        return configs

    @app.route("/")
    def index():
        ws = _get_ws()
        mode = request.args.get("mode", "normal")
        theme_config = ws.get("theme", {})
        resolved = resolve_appearance(theme_config)
        state = _state_defaults(ws)

        # Template sees resolved appearance (flat: colors/fonts/sizes)
        ws_for_template = dict(ws)
        ws_for_template["theme"] = resolved

        # Render menubar (swap mode toggle link based on current mode)
        brand = ws.get("app", {}).get("brand")
        menubar_html = render_menubar(ws.get("menubar", []), ws.get("actions", {}), resolved, brand)
        if mode == "wireframe":
            menubar_html = menubar_html.replace(
                'href="?mode=wireframe" id="mode-toggle">Wireframe',
                'href="/" id="mode-toggle">Normal',
            )

        # Both modes render the same layout in normal mode
        layout_html = render_element(ws.get("layout", {}), resolved, state, mode="normal")
        dialogs_html = render_dialogs(ws.get("dialogs", {}), resolved, state, brand)
        state_json = json.dumps(_state_defaults(ws))
        actions_json = json.dumps(ws.get("actions", {}))
        shortcuts_json = json.dumps(ws.get("shortcuts", []))
        positions_json = json.dumps(_pane_configs(ws))
        icons_json = json.dumps(ws.get("icons", {}))
        theme_json = json.dumps(resolved)
        default_layouts_json = json.dumps(ws.get("default_layouts", {}))
        runtime_contexts_json = json.dumps(ws.get("runtime_contexts", {}))
        appearances_json = json.dumps(list_appearances(theme_config))
        active_appearance_json = json.dumps(theme_config.get("active", "dark_gray"))
        all_appearances_json = json.dumps(theme_config.get("appearances", {}))
        base_theme_json = json.dumps(theme_config.get("base", {}))
        metrics_json = json.dumps(theme_config.get("metrics", {}))
        # Tool yamls — consumed by static/js/canvas_bootstrap.mjs to
        # seed engine/tools.mjs's registry, so engine/tools.mjs's
        # dispatchEvent can find on_<event> handlers when DOM events
        # land on the canvas.
        tools_json = json.dumps(ws.get("tools", {}))

        template = "wireframe.html" if mode == "wireframe" else "normal.html"
        return render_template(template, ws=ws_for_template,
                               menubar_html=menubar_html,
                               layout_html=layout_html, dialogs_html=dialogs_html,
                               state_json=state_json, actions_json=actions_json,
                               shortcuts_json=shortcuts_json,
                               positions_json=positions_json,
                               icons_json=icons_json,
                               theme_json=theme_json,
                               default_layouts_json=default_layouts_json,
                               runtime_contexts_json=runtime_contexts_json,
                               appearances_json=appearances_json,
                               active_appearance_json=active_appearance_json,
                               all_appearances_json=all_appearances_json,
                               base_theme_json=base_theme_json,
                               metrics_json=metrics_json,
                               tools_json=tools_json)

    @app.route("/canvas")
    def canvas_demo():
        """Minimal demo of the JS engine — loads workspace.json, mounts the
        selection tool, and shows a document with two rectangles. Uses the
        engine modules under /static/js/engine/. See FLASK_PARITY.md §7."""
        return render_template("canvas_demo.html")

    @app.route("/api/workspace")
    def workspace_json():
        """Serve the compiled workspace.json for the JS engine to load."""
        return jsonify(_get_ws())

    @app.route("/api/spec/<element_id>")
    def element_spec(element_id):
        """Return the full YAML spec for an element as JSON."""
        ws = _get_ws()
        layout = ws.get("layout", {})
        elem = find_element_by_id(layout, element_id)
        if elem is None:
            # Also search in dialogs
            for dialog in ws.get("dialogs", {}).values():
                content = dialog.get("content")
                if isinstance(content, dict):
                    elem = find_element_by_id(content, element_id)
                    if elem:
                        break
        if elem is None:
            return jsonify({"error": "not found"}), 404
        return jsonify(elem)

    return app


if __name__ == "__main__":
    import glob
    app = create_app()
    # Watch workspace YAML files, static JS/CSS, and templates for auto-reload
    extra = []
    extra += glob.glob(os.path.join(os.path.dirname(__file__), "..", "workspace", "**", "*.yaml"), recursive=True)
    extra += glob.glob(os.path.join(os.path.dirname(__file__), "..", "workspace", "**", "*.json"), recursive=True)
    extra += glob.glob(os.path.join(os.path.dirname(__file__), "static", "**", "*"), recursive=True)
    extra += glob.glob(os.path.join(os.path.dirname(__file__), "templates", "*.html"))
    app.run(debug=True, host='0.0.0.0', port=5051, extra_files=extra)
