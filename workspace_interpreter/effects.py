"""Effects interpreter for the workspace YAML schema.

Executes effect lists from actions and behaviors. Each effect is a
dict with a single key identifying the effect type. Pure Python,
no Qt dependency.
"""

from __future__ import annotations

from workspace_interpreter.expr import evaluate
from workspace_interpreter.state_store import StateStore


def run_effects(effects: list, ctx: dict, store: StateStore,
                actions: dict | None = None,
                platform_effects: dict | None = None,
                dialogs: dict | None = None,
                schema=None,
                diagnostics: list | None = None):
    """Execute a list of effects.

    Args:
        effects: List of effect dicts.
        ctx: Additional evaluation context (params, event, etc.).
        store: The state store to read from and mutate.
        actions: The actions catalog for dispatch effects.
        platform_effects: Registry of platform-specific effect handlers
            keyed by effect name. Each handler receives (effect_data, ctx, store).
        dialogs: Dialog definitions dict for open_dialog effects.
        schema: Optional SchemaTable for schema-driven set: coercion.
            When None, set: uses the legacy untyped path.
        diagnostics: Mutable list to which diagnostic dicts are appended.
            Each dict has {level, key, reason}. Ignored when schema is None.
    """
    if not effects:
        return
    # Thread ctx through the list: each `let:` produces a new ctx visible
    # to subsequent effects in this list only. Inner lists (then/else/do)
    # get their own threading in recursive calls.
    for effect in effects:
        # Bare-string effects (e.g. `- snapshot` in YAML) normalize to
        # a single-key mapping with null value.
        if isinstance(effect, str):
            effect = {effect: None}
        if isinstance(effect, dict):
            # Extract optional `as: <name>` return-binding (PHASE3 §5.5)
            as_name = effect.get("as") if isinstance(effect.get("as"), str) else None
            result = _run_one(effect, ctx, store, actions, platform_effects, dialogs,
                              schema, diagnostics)
            # _run_one may return a new_ctx (from let:) OR a (new_ctx, return_value)
            # tuple. Normalize.
            new_ctx = None
            return_value = None
            if isinstance(result, tuple):
                new_ctx, return_value = result
            else:
                new_ctx = result
            if new_ctx is not None:
                ctx = new_ctx
            if as_name is not None and return_value is not None:
                ctx = {**ctx, as_name: return_value}


def _eval(expr, store: StateStore, ctx: dict):
    """Evaluate an expression against the store's current state + ctx."""
    eval_ctx = store.eval_context(ctx)
    result = evaluate(str(expr) if expr is not None else "", eval_ctx)
    return result.value


def apply_set_schemadriven(
    set_map: dict,
    store: StateStore,
    schema,
    diagnostics: list,
    active_panel: str | None = None,
) -> None:
    """Apply a schema-driven set: effect from already-evaluated values.

    set_map values are Python native types (the result of expression evaluation,
    or raw YAML values from test fixtures).  Coercion and scope resolution happen
    here; expression evaluation is the caller's responsibility.
    """
    from workspace_interpreter.schema import coerce_value

    pending: list[tuple[str, str, object]] = []

    for key, value in set_map.items():
        resolved = schema.resolve(key, active_panel)

        if resolved is None:
            diagnostics.append({"level": "warning", "key": key, "reason": "unknown_key"})
            continue
        if resolved == "ambiguous":
            diagnostics.append({"level": "error", "key": key, "reason": "ambiguous_key"})
            continue

        scope, field_name, entry = resolved

        if not entry.writable:
            diagnostics.append({"level": "warning", "key": key, "reason": "field_not_writable"})
            continue

        coerced, error = coerce_value(value, entry)
        if error:
            diagnostics.append({"level": "error", "key": key, "reason": error})
            continue

        pending.append((scope, field_name, coerced))

    # Apply all successful writes as a batch
    for scope, field_name, value in pending:
        if scope == "state":
            store.set(field_name, value)
        else:
            panel_id = scope[len("panel:"):]
            store.set_panel(panel_id, field_name, value)


def _run_one(effect: dict, ctx: dict, store: StateStore,
             actions: dict | None, platform_effects: dict | None,
             dialogs: dict | None, schema=None, diagnostics: list | None = None):
    """Execute one effect. Returns a new ctx if the effect introduces a
    binding (let:), else None. Callers in run_effects use the returned
    ctx for subsequent effects in the same list."""

    # Platform-specific handlers take priority over built-ins so apps
    # can override snapshot/doc.set with Model-based versions. The
    # handler's return value is propagated as the effect's return value
    # (bound via `as:` when present).
    if platform_effects:
        for key in effect:
            if key == "as":
                continue
            handler = platform_effects.get(key)
            if handler:
                result = handler(effect[key], ctx, store)
                return None, result

    # let: { name: expr, ... } — PHASE3 §5.1
    # Evaluates each expression against current ctx (earlier names visible
    # to later ones in the same block), returns an extended ctx.
    if "let" in effect:
        from workspace_interpreter.expr_types import ValueType
        bindings = effect["let"]
        new_ctx = dict(ctx)
        for name, expr in bindings.items():
            eval_ctx = store.eval_context(new_ctx)
            result = evaluate(str(expr) if expr is not None else "", eval_ctx)
            # Preserve Value wrapper for types that can't round-trip
            # through their .value (CLOSURE, PATH). Other types unwrap.
            if result.type in (ValueType.CLOSURE, ValueType.PATH):
                new_ctx[name] = result
            else:
                new_ctx[name] = result.value
        return new_ctx

    # snapshot — PHASE3 §5.2 — push undo checkpoint on active document
    if "snapshot" in effect:
        store.snapshot()
        return None

    # doc.create_layer: { name } — PHASE3 sub-tollgate 2
    # Factory returning a Layer element dict with sane defaults. Bind
    # via `as:` and then insert with doc.insert_at / doc.insert_after.
    if "doc.create_layer" in effect:
        from workspace_interpreter.expr_types import ValueType
        spec = effect["doc.create_layer"]
        if not isinstance(spec, dict):
            return None, None
        name_expr = spec.get("name", "'Layer'")
        eval_ctx = store.eval_context(ctx)
        name_val = evaluate(str(name_expr), eval_ctx)
        name = name_val.value if name_val.type == ValueType.STRING else "Layer"
        layer = {
            "kind": "Layer",
            "name": name,
            "children": [],
            "common": {
                "visibility": "preview",
                "locked": False,
                "opacity": 1.0,
            },
        }
        return None, layer

    # doc.delete_at: path_expr — PHASE3 §5.5
    # Deletes the element at the given path. Returns the deleted
    # element (native form) for binding via `as:`.
    if "doc.delete_at" in effect:
        from workspace_interpreter.expr_types import ValueType
        path_expr = effect["doc.delete_at"]
        eval_ctx = store.eval_context(ctx)
        path_val = evaluate(str(path_expr) if path_expr is not None else "", eval_ctx)
        if path_val.type != ValueType.PATH:
            return None, None
        deleted = store.delete_element_at(path_val.value)
        return None, deleted

    # doc.clone_at: path_expr — PHASE3 §5.5
    # Deep-copies the element at path. Returns the clone for `as:`.
    if "doc.clone_at" in effect:
        from workspace_interpreter.expr_types import ValueType
        path_expr = effect["doc.clone_at"]
        eval_ctx = store.eval_context(ctx)
        path_val = evaluate(str(path_expr) if path_expr is not None else "", eval_ctx)
        if path_val.type != ValueType.PATH:
            return None, None
        clone = store.clone_element_at(path_val.value)
        return None, clone

    # doc.insert_after: { path, element } — PHASE3 §5.5
    # Inserts element immediately after the element at path.
    if "doc.insert_after" in effect:
        from workspace_interpreter.expr_types import ValueType
        spec = effect["doc.insert_after"]
        if not isinstance(spec, dict):
            return None
        path_expr = spec.get("path", "")
        elem_expr = spec.get("element")
        eval_ctx = store.eval_context(ctx)
        path_val = evaluate(str(path_expr), eval_ctx)
        if path_val.type != ValueType.PATH:
            return None
        # Element: if a string, treat as expression; else raw dict
        if isinstance(elem_expr, str):
            elem_val = evaluate(elem_expr, eval_ctx)
            element = elem_val.value if elem_val.type != ValueType.CLOSURE else None
        else:
            element = elem_expr
        if element is None:
            return None
        store.insert_after(path_val.value, element)
        return None

    # doc.wrap_in_group: { paths } — PHASE3 sub-tollgate 3
    # Wraps a set of elements in a new Group at the position of the
    # topmost source path. Children are ordered by their document
    # position (not selection order). All paths must share the same
    # parent — this check is the caller's responsibility (via
    # enabled_when on the YAML action).
    if "doc.wrap_in_group" in effect:
        from workspace_interpreter.expr_types import ValueType
        spec = effect["doc.wrap_in_group"]
        if not isinstance(spec, dict):
            return None
        eval_ctx = store.eval_context(ctx)
        paths_expr = spec.get("paths", "[]")
        if isinstance(paths_expr, list):
            # Raw list of path-ish items (from YAML literal)
            raw_paths = paths_expr
        else:
            val = evaluate(str(paths_expr), eval_ctx)
            if val.type != ValueType.LIST:
                return None
            raw_paths = val.value
        # Normalize paths: accept tuples, Value.PATH wrappers, or
        # __path__-marker dicts.
        normalized: list[tuple[int, ...]] = []
        for p in raw_paths:
            if hasattr(p, "type") and p.type == ValueType.PATH:
                normalized.append(tuple(p.value))
            elif isinstance(p, dict) and "__path__" in p:
                normalized.append(tuple(p["__path__"]))
            elif isinstance(p, (list, tuple)):
                normalized.append(tuple(p))
        if not normalized:
            return None
        # Sort by document order (ascending) for children; track
        # topmost for insertion.
        sorted_paths = sorted(normalized)
        insert_path_parent = sorted_paths[0][:-1]
        insert_index = sorted_paths[0][-1] if sorted_paths[0] else 0
        # Collect element clones in document order
        children = []
        import copy
        for p in sorted_paths:
            elem = store.get_element(p)
            if elem is not None:
                children.append(copy.deepcopy(elem))
        if not children:
            return None
        # Delete in reverse order so indices stay valid
        for p in reversed(sorted_paths):
            store.delete_element_at(p)
        # Construct the group element
        group = {
            "kind": "Group",
            "children": children,
            "common": {
                "visibility": "preview",
                "locked": False,
                "opacity": 1.0,
            },
        }
        # Insert at the topmost-source position under the shared parent
        store.insert_at(insert_path_parent, insert_index, group)
        return None

    # doc.unpack_group_at: path_expr — PHASE3 sub-tollgate 3
    # Replace a Group at the given path with its children in place.
    # Non-Group targets are no-ops. Used by flatten_artwork.
    if "doc.unpack_group_at" in effect:
        from workspace_interpreter.expr_types import ValueType
        path_expr = effect["doc.unpack_group_at"]
        eval_ctx = store.eval_context(ctx)
        path_val = evaluate(str(path_expr) if path_expr is not None else "", eval_ctx)
        if path_val.type != ValueType.PATH:
            return None
        path = path_val.value
        if len(path) == 0:
            return None
        # Fetch the element to check it's a Group
        elem = store.get_element(path)
        if not isinstance(elem, dict) or elem.get("kind") != "Group":
            return None
        children = elem.get("children", [])
        # Remove the group at path
        store.delete_element_at(path)
        # Insert children at the vacated position (in order). Each
        # insert shifts subsequent siblings; insert_at with increasing
        # index places them consecutively.
        parent_path = path[:-1]
        base_index = path[-1]
        for i, child in enumerate(children):
            store.insert_at(parent_path, base_index + i, child)
        return None

    # doc.wrap_in_layer: { paths, name } — PHASE3 sub-tollgate 3
    # Same as wrap_in_group but always produces a top-level Layer
    # with the given name. Selected elements are removed and become
    # the new layer's children (in document order).
    if "doc.wrap_in_layer" in effect:
        from workspace_interpreter.expr_types import ValueType
        spec = effect["doc.wrap_in_layer"]
        if not isinstance(spec, dict):
            return None
        eval_ctx = store.eval_context(ctx)
        paths_expr = spec.get("paths", "[]")
        if isinstance(paths_expr, list):
            raw_paths = paths_expr
        else:
            val = evaluate(str(paths_expr), eval_ctx)
            if val.type != ValueType.LIST:
                return None
            raw_paths = val.value
        # Normalize paths
        normalized: list[tuple[int, ...]] = []
        for p in raw_paths:
            if hasattr(p, "type") and p.type == ValueType.PATH:
                normalized.append(tuple(p.value))
            elif isinstance(p, dict) and "__path__" in p:
                normalized.append(tuple(p["__path__"]))
            elif isinstance(p, (list, tuple)):
                normalized.append(tuple(p))
        if not normalized:
            return None
        sorted_paths = sorted(normalized)
        # Layer name
        name_expr = spec.get("name", "'Layer'")
        name_val = evaluate(str(name_expr), eval_ctx)
        name = name_val.value if name_val.type == ValueType.STRING else "Layer"
        # Collect deep clones
        import copy
        children = []
        for p in sorted_paths:
            elem = store.get_element(p)
            if elem is not None:
                children.append(copy.deepcopy(elem))
        if not children:
            return None
        # Delete in reverse (keeps indices valid during deletion)
        for p in reversed(sorted_paths):
            store.delete_element_at(p)
        new_layer = {
            "kind": "Layer",
            "name": name,
            "children": children,
            "common": {
                "visibility": "preview",
                "locked": False,
                "opacity": 1.0,
            },
        }
        # Append at end — collect_in_new_layer semantics: "above all
        # existing layers" = highest index (visually topmost).
        if store.document() is not None:
            layers = store.document().setdefault("layers", [])
            if isinstance(layers, list):
                layers.append(new_layer)
        return None

    # doc.insert_at: { parent_path, index, element } — PHASE3 §5.5
    if "doc.insert_at" in effect:
        from workspace_interpreter.expr_types import ValueType
        spec = effect["doc.insert_at"]
        if not isinstance(spec, dict):
            return None
        parent_expr = spec.get("parent_path", "path()")
        idx_expr = spec.get("index", 0)
        elem_expr = spec.get("element")
        eval_ctx = store.eval_context(ctx)
        parent_val = evaluate(str(parent_expr), eval_ctx)
        idx_val = evaluate(str(idx_expr), eval_ctx) if isinstance(idx_expr, str) else None
        idx = int(idx_val.value) if idx_val and idx_val.type == ValueType.NUMBER else (
            int(idx_expr) if isinstance(idx_expr, (int, float)) else 0)
        if parent_val.type != ValueType.PATH:
            return None
        if isinstance(elem_expr, str):
            elem_val = evaluate(elem_expr, eval_ctx)
            element = elem_val.value if elem_val.type != ValueType.CLOSURE else None
        else:
            element = elem_expr
        if element is None:
            return None
        store.insert_at(parent_val.value, idx, element)
        return None

    # doc.set: { path, fields } — PHASE3 §5.4
    # Schema-driven write on the element at `path`. Each field is a
    # dotted path relative to the element root. Expressions in fields
    # are evaluated in the current ctx before being written.
    if "doc.set" in effect:
        from workspace_interpreter.expr_types import ValueType
        spec = effect["doc.set"]
        path_expr = spec.get("path", "")
        fields = spec.get("fields", {}) or {}
        # Evaluate path expression; must resolve to a PATH value
        eval_ctx = store.eval_context(ctx)
        path_val = evaluate(str(path_expr) if path_expr is not None else "", eval_ctx)
        if path_val.type != ValueType.PATH:
            return None
        # Evaluate each field's value expression and write
        for dotted_field, expr in fields.items():
            val_result = evaluate(str(expr) if expr is not None else "", eval_ctx)
            value = val_result.value if val_result.type != ValueType.CLOSURE else val_result
            store.set_element_field(path_val.value, dotted_field, value)
        return None

    # foreach: { source, as } do: [...] — PHASE3 §5.3
    # Evaluates source once; each iteration runs do: in a fresh scope
    # with `as:` bound to the item. Bindings inside do: do not leak
    # across iterations or past the loop.
    if "foreach" in effect and "do" in effect:
        spec = effect["foreach"]
        source_expr = spec.get("source", "")
        var_name = spec.get("as", "item")
        body = effect["do"]
        items = _eval(source_expr, store, ctx)
        if not isinstance(items, list):
            return None
        for i, item in enumerate(items):
            iter_ctx = dict(ctx)
            iter_ctx[var_name] = item
            iter_ctx["_index"] = i
            run_effects(body, iter_ctx, store, actions, platform_effects, dialogs,
                        schema, diagnostics)
        return None

    # set: { key: expr, ... }
    if "set" in effect:
        if schema is not None:
            evaluated = {k: _eval(v, store, ctx) for k, v in effect["set"].items()}
            apply_set_schemadriven(
                evaluated, store, schema,
                diagnostics if diagnostics is not None else [],
                active_panel=store.get_active_panel_id(),
            )
        else:
            for key, expr in effect["set"].items():
                value = _eval(expr, store, ctx)
                store.set(key, value)
        return

    # toggle: state_key_name
    if "toggle" in effect:
        key = effect["toggle"]
        # Support text-context interpolation for constructed keys
        if "{{" in str(key):
            from workspace_interpreter.expr import evaluate_text
            key = evaluate_text(str(key), store.eval_context(ctx))
        store.set(key, not store.get(key))
        return

    # swap: [key_a, key_b]
    if "swap" in effect:
        keys = effect["swap"]
        if len(keys) == 2:
            a_val = store.get(keys[0])
            b_val = store.get(keys[1])
            store.set(keys[0], b_val)
            store.set(keys[1], a_val)
        return

    # increment: { key, by }
    if "increment" in effect:
        key = effect["increment"]["key"]
        by = effect["increment"].get("by", 1)
        store.set(key, (store.get(key) or 0) + by)
        return

    # decrement: { key, by }
    if "decrement" in effect:
        key = effect["decrement"]["key"]
        by = effect["decrement"].get("by", 1)
        store.set(key, (store.get(key) or 0) - by)
        return

    # reset: [keys]
    if "reset" in effect:
        # Would need access to original defaults — skip for now
        return

    # if: { condition, then, else }
    if "if" in effect:
        cond = effect["if"]
        cond_expr = cond.get("condition", "false")
        eval_ctx = store.eval_context(ctx)
        result = evaluate(str(cond_expr), eval_ctx)
        if result.to_bool():
            run_effects(cond.get("then", []), ctx, store, actions, platform_effects, dialogs,
                        schema, diagnostics)
        elif "else" in cond:
            run_effects(cond["else"], ctx, store, actions, platform_effects, dialogs,
                        schema, diagnostics)
        return

    # set_panel_state: { key, value, panel? }
    if "set_panel_state" in effect:
        sps = effect["set_panel_state"]
        key = sps.get("key", "")
        value = _eval(sps.get("value", "null"), store, ctx)
        panel_id = sps.get("panel") or store.get_active_panel_id()
        if panel_id:
            store.set_panel(panel_id, key, value)
        return

    # pop: panel.field_name  or  pop: global_field_name
    if "pop" in effect:
        target = effect["pop"]
        parts = str(target).split(".", 1)
        if len(parts) == 2 and parts[0] == "panel":
            panel_id = store.get_active_panel_id()
            if panel_id:
                lst = store.get_panel(panel_id, parts[1])
                if isinstance(lst, list) and lst:
                    store.set_panel(panel_id, parts[1], lst[:-1])
        else:
            lst = store.get(target)
            if isinstance(lst, list) and lst:
                store.set(target, lst[:-1])
        return

    # list_push: { target, value, unique, max_length }
    if "list_push" in effect:
        lp = effect["list_push"]
        target = lp.get("target", "")
        parts = target.split(".", 1)
        # Evaluate value, preserving Path as __path__ marker so it
        # round-trips through the panel state list (matches the shape
        # of layers_panel_selection entries).
        from workspace_interpreter.expr_types import Value as _V, ValueType
        eval_ctx = store.eval_context(ctx)
        result = evaluate(str(lp.get("value", "null")) if lp.get("value") is not None else "",
                          eval_ctx)
        if result.type == ValueType.PATH:
            value = {"__path__": list(result.value)}
        elif result.type == ValueType.CLOSURE:
            value = result
        else:
            value = result.value
        unique = lp.get("unique", False)
        max_length = lp.get("max_length")
        if len(parts) == 2 and parts[0] == "panel":
            panel_id = store.get_active_panel_id()
            if panel_id:
                store.list_push(panel_id, parts[1], value,
                               unique=unique, max_length=max_length)
        return

    # dispatch: action_name or { action, params }
    if "dispatch" in effect:
        d = effect["dispatch"]
        if isinstance(d, str):
            action_name = d
            params = {}
        else:
            action_name = d.get("action", "")
            params = d.get("params", {})
        if actions and action_name in actions:
            action_def = actions[action_name]
            action_effects = action_def.get("effects", [])
            dispatch_ctx = dict(ctx)
            if params:
                resolved_params = {}
                for k, v in params.items():
                    resolved_params[k] = _eval(v, store, ctx)
                dispatch_ctx["param"] = resolved_params
            run_effects(action_effects, dispatch_ctx, store, actions, platform_effects, dialogs,
                        schema, diagnostics)
        return

    # open_dialog: { id, params }
    if "open_dialog" in effect:
        od = effect["open_dialog"]
        dlg_id = od.get("id", "") if isinstance(od, dict) else str(od)
        if not dialogs or dlg_id not in dialogs:
            return
        dlg_def = dialogs[dlg_id]
        # Extract state defaults and property definitions (get/set)
        defaults = {}
        props = {}
        state_defs = dlg_def.get("state", {})
        if isinstance(state_defs, dict):
            for key, defn in state_defs.items():
                if isinstance(defn, dict):
                    # Extract get/set property definitions
                    has_get = "get" in defn
                    has_set = "set" in defn
                    if has_get or has_set:
                        prop = {}
                        if has_get:
                            prop["get"] = defn["get"]
                        if has_set:
                            prop["set"] = defn["set"]
                        props[key] = prop
                    # Only store default for plain variables (no get)
                    if not has_get:
                        defaults[key] = defn.get("default")
                else:
                    defaults[key] = defn
        # Resolve params
        resolved_params = {}
        raw_params = od.get("params", {}) if isinstance(od, dict) else {}
        for k, v in raw_params.items():
            resolved_params[k] = _eval(v, store, ctx)
        # Init dialog state with defaults, params, and property definitions
        store.init_dialog(dlg_id, defaults,
                         params=resolved_params or None,
                         props=props or None)
        # Evaluate init expressions (order matters — later inits may reference earlier ones).
        # The dialog's own params must win over the outer action's: dialog
        # init expressions reference param.* expecting the dialog's params.
        # Drop the outer "param" key from the eval-ctx extras so
        # store.eval_context's own dialog-scoped param binding is preserved.
        init_ctx = {k: v for k, v in ctx.items() if k != "param"} if ctx else {}
        init_map = dlg_def.get("init", {})
        if isinstance(init_map, dict):
            for key, expr in init_map.items():
                value = _eval(expr, store, init_ctx)
                store.set_dialog(key, value)
        # Capture preview snapshot if the dialog declares preview_targets.
        # Restored on close_dialog unless first cleared by an OK action via
        # clear_dialog_snapshot.
        targets = dlg_def.get("preview_targets")
        if isinstance(targets, dict):
            store.capture_dialog_snapshot({
                k: v for k, v in targets.items() if isinstance(v, str)
            })
        return

    # close_dialog: null or dialog_id
    if "close_dialog" in effect:
        # Preview restore: if a snapshot survived (i.e., no OK action
        # cleared it), revert each target to its captured original
        # value. Phase 0 handles only top-level state keys.
        snapshot = store.get_dialog_snapshot()
        if snapshot is not None:
            for key, value in snapshot.items():
                if "." not in key:
                    store.set(key, value)
            store.clear_dialog_snapshot()
        store.close_dialog()
        return

    # clear_dialog_snapshot: drop the preview snapshot so close_dialog
    # does not restore. OK actions emit this before close_dialog to commit.
    if "clear_dialog_snapshot" in effect:
        store.clear_dialog_snapshot()
        return

    # log: message (no-op in interpreter, just print for debug)
    if "log" in effect:
        return

    # Platform-specific effects — delegate to registered handlers
    # (kept for non-priority keys; priority keys handled at top of _run_one)
    if platform_effects:
        for key in effect:
            handler = platform_effects.get(key)
            if handler:
                handler(effect[key], ctx, store)
                return


def apply_stroke_panel_to_selection(store: StateStore, controller) -> None:
    """Read stroke state keys from the store and apply to selected elements.

    This is a platform-level helper that bridges the YAML panel state
    (stroke_width, stroke_color, etc.) to the document controller.
    """
    from geometry.element import (
        Stroke, Color, RgbColor, LineCap, LineJoin,
        StrokeAlign, Arrowhead, ArrowAlign,
        StrokeWidthPoint, profile_to_width_points,
    )

    # Read stroke properties from store
    width = store.get("stroke_width")
    if width is None:
        width = 1.0
    width = float(width)

    color_hex = store.get("stroke_color")
    if color_hex and isinstance(color_hex, str):
        c = Color.from_hex(color_hex)
        color = c if c is not None else Color.BLACK
    else:
        color = Color.BLACK

    opacity = store.get("stroke_opacity")
    opacity = float(opacity) if opacity is not None else 1.0

    cap_str = store.get("stroke_linecap") or "butt"
    cap_map = {"butt": LineCap.BUTT, "round": LineCap.ROUND, "square": LineCap.SQUARE}
    linecap = cap_map.get(cap_str, LineCap.BUTT)

    join_str = store.get("stroke_linejoin") or "miter"
    join_map = {"miter": LineJoin.MITER, "round": LineJoin.ROUND, "bevel": LineJoin.BEVEL}
    linejoin = join_map.get(join_str, LineJoin.MITER)

    miter_limit = store.get("stroke_miter_limit")
    miter_limit = float(miter_limit) if miter_limit is not None else 10.0

    align_str = store.get("stroke_align") or "center"
    align_map = {"center": StrokeAlign.CENTER, "inside": StrokeAlign.INSIDE,
                 "outside": StrokeAlign.OUTSIDE}
    align = align_map.get(align_str, StrokeAlign.CENTER)

    dash_str = store.get("stroke_dash_pattern") or ""
    dash_pattern: tuple[float, ...] = ()
    if dash_str and isinstance(dash_str, str):
        try:
            dash_pattern = tuple(float(x) for x in dash_str.split(",") if x.strip())
        except ValueError:
            pass
    elif isinstance(dash_str, (list, tuple)):
        dash_pattern = tuple(float(x) for x in dash_str)

    start_arrow_str = store.get("stroke_start_arrow") or "none"
    start_arrow = Arrowhead.from_string(start_arrow_str)
    end_arrow_str = store.get("stroke_end_arrow") or "none"
    end_arrow = Arrowhead.from_string(end_arrow_str)

    start_arrow_scale = store.get("stroke_start_arrow_scale")
    start_arrow_scale = float(start_arrow_scale) if start_arrow_scale is not None else 100.0
    end_arrow_scale = store.get("stroke_end_arrow_scale")
    end_arrow_scale = float(end_arrow_scale) if end_arrow_scale is not None else 100.0

    arrow_align_str = store.get("stroke_arrow_align") or "tip_at_end"
    arrow_align_map = {"tip_at_end": ArrowAlign.TIP_AT_END,
                       "center_at_end": ArrowAlign.CENTER_AT_END}
    arrow_align = arrow_align_map.get(arrow_align_str, ArrowAlign.TIP_AT_END)

    stroke = Stroke(
        color=color, width=width, linecap=linecap, linejoin=linejoin,
        opacity=opacity, miter_limit=miter_limit, align=align,
        dash_pattern=dash_pattern, start_arrow=start_arrow,
        end_arrow=end_arrow, start_arrow_scale=start_arrow_scale,
        end_arrow_scale=end_arrow_scale, arrow_align=arrow_align,
    )
    controller.set_selection_stroke(stroke)

    # Apply width profile if set
    profile = store.get("stroke_width_profile") or "uniform"
    flipped = bool(store.get("stroke_width_profile_flipped"))
    wp = profile_to_width_points(profile, width, flipped)
    controller.set_selection_width_profile(wp)
