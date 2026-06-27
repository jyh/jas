"""Effects interpreter for the workspace YAML schema.

Executes effect lists from actions and behaviors. Each effect is a
dict with a single key identifying the effect type. Pure Python,
no Qt dependency.
"""

from __future__ import annotations

from workspace_interpreter.expr import evaluate
from workspace_interpreter.state_store import StateStore


def _set_by_scoped_target(store: StateStore, raw_target: str, value) -> None:
    """Route a scope-qualified ``set:`` target to the right section
    of the StateStore.

    Target shapes (leading ``$`` stripped):
        ``tool.<id>.<key>``   -> ``store.set_tool``
        ``panel.<key>``       -> active panel's scope
        ``state.<key>``       -> global state (explicit)
        anything else         -> global state (bare, legacy)

    Matches the Rust/Swift/OCaml set_by_scoped_target dispatchers.
    """
    target = raw_target[1:] if raw_target.startswith("$") else raw_target
    if "." not in target:
        store.set(target, value)
        return
    head, rest = target.split(".", 1)
    if head == "tool":
        if "." not in rest:
            # tool.<id> without field — malformed, drop silently.
            return
        tool_id, key = rest.split(".", 1)
        store.set_tool(tool_id, key, value)
    elif head == "panel":
        panel_id = store.get_active_panel_id()
        if panel_id is not None:
            store.set_panel(panel_id, rest, value)
    elif head == "state":
        store.set(rest, value)
    else:
        store.set(target, value)


def run_effects(effects: list, ctx: dict, store: StateStore,
                actions: dict | None = None,
                platform_effects: dict | None = None,
                dialogs: dict | None = None,
                schema=None,
                diagnostics: list | None = None,
                model=None,
                action_name: str | None = None):
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
        model: Optional document Model for transaction ownership (OP_LOG.md §9,
            Increment 3b-B). When supplied, this run_effects call OWNS the undo
            transaction iff none was open when it started — so a reentrant nested
            run_effects (dispatch / on_change / let-in / if-then) does NOT commit
            the outer's transaction. The owner commits once at the end, spanning
            every effect in this batch into a single undo step. ``model`` carries
            no platform-specific dependency here: the doc.* mutations reach the
            document through the ``platform_effects`` closures; this thread is
            ONLY for the begin/name/commit bracket the batch owner must run.
            Nested run_effects calls pass model=None (the inner batch is not the
            owner). When None (the Flask path and all non-doc callers), the
            bracket is skipped and behavior is byte-unchanged.
        action_name: Optional action/event verb naming the owning transaction
            (OP_LOG.md §9). Stamped via ``model.name_txn`` just before commit, so
            the journal's name-legibility hole is closed for the doc.* batch.
    """
    if not effects and model is None:
        return
    # OP_LOG.md §9, Increment 3b-B: this batch OWNS the transaction only if none
    # was open when it started. ``begin_txn`` (lazily opened by op_apply for the
    # mutating verbs) and ``commit_txn`` are no-ops when nothing opened one, so a
    # no-edit gesture stays anonymous and commits nothing.
    owns_txn = model is not None and not model.in_txn
    if not effects:
        # An empty batch with a model still respects ownership semantics (the
        # bracket below is a clean no-op), so fall through to the owner commit.
        effects = []
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

    # Dialog on_change post-batch hook. Fires the action declared on
    # the open dialog's on_change field whenever this batch mutated
    # dialog state. Per-batch debounced (one fire per UI tick batch).
    # Re-entrancy guarded so the action's effects do not re-fire.
    # See SCALE_TOOL.md §Preview.
    if not store.is_firing_on_change() and store.take_dialog_dirty():
        on_change_action = store.get_dialog_on_change()
        if on_change_action:
            store.set_firing_on_change(True)
            try:
                _run_one({"dispatch": on_change_action}, ctx, store, actions,
                         platform_effects, dialogs, schema, diagnostics)
            finally:
                store.set_firing_on_change(False)

    # OP_LOG.md §9, Increment 3b-B: commit the transaction this batch opened (if
    # any), making the whole action one undo step. Name it with the action/event
    # verb so the journal's name-legibility hole is closed. name_txn/commit_txn
    # are no-ops when nothing opened one or when this call is nested (owns_txn is
    # False). Set the name just before commit, once this batch's lazily-opened
    # transaction (if any) is live.
    if owns_txn and model is not None:
        if action_name is not None:
            model.name_txn(action_name)
        model.commit_txn()


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
    # Two shapes: sibling-threading (no `in:`) and scoped (`let: {...}
    # in: [...]` runs the nested list with bindings, then drops them).
    # Tool YAMLs (e.g. selection) use the scoped form.
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
        if "in" in effect and isinstance(effect["in"], list):
            run_effects(
                effect["in"], new_ctx, store,
                actions, platform_effects, dialogs,
                schema, diagnostics,
            )
            return None
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

    # doc.create_artboard: { [field]: expr, ... } — ARTBOARDS.md §Menu — New Artboard
    # Factory-and-insert: mints a fresh 8-char base36 id, picks the
    # next unused "Artboard N" name unless overridden, appends to
    # document.artboards, and returns the new artboard for `as:`.
    if "doc.create_artboard" in effect:
        from workspace_interpreter.expr_types import ValueType
        spec = effect["doc.create_artboard"]
        overrides: dict = {}
        if isinstance(spec, dict):
            eval_ctx = store.eval_context(ctx)
            for k, v in spec.items():
                if isinstance(v, str):
                    val = evaluate(v, eval_ctx)
                    overrides[k] = val.value if val.type != ValueType.CLOSURE else None
                else:
                    overrides[k] = v
        artboard = store.create_artboard(overrides)
        return None, artboard

    # doc.delete_artboard_by_id: id_expr — ARTBOARDS.md §Menu — Delete Artboards
    # Removes the artboard with the given id from document.artboards.
    # Returns the deleted artboard for `as:` binding, or None.
    if "doc.delete_artboard_by_id" in effect:
        from workspace_interpreter.expr_types import ValueType
        id_expr = effect["doc.delete_artboard_by_id"]
        eval_ctx = store.eval_context(ctx)
        val = evaluate(str(id_expr) if id_expr is not None else "", eval_ctx)
        if val.type != ValueType.STRING:
            return None, None
        deleted = store.delete_artboard_by_id(val.value)
        return None, deleted

    # doc.duplicate_artboard: { id, offset_x?, offset_y? }
    # — ARTBOARDS.md §Menu — Duplicate Artboards
    # Deep-copies the artboard with the given id and appends it with
    # a fresh id, next-unused name, offset position. Returns the new
    # artboard.
    if "doc.duplicate_artboard" in effect:
        from workspace_interpreter.expr_types import ValueType
        spec = effect["doc.duplicate_artboard"]
        if isinstance(spec, str):
            spec = {"id": spec}
        if not isinstance(spec, dict):
            return None, None
        eval_ctx = store.eval_context(ctx)
        id_val = evaluate(str(spec.get("id", "")), eval_ctx)
        if id_val.type != ValueType.STRING:
            return None, None
        ox = 20
        oy = 20
        if "offset_x" in spec:
            v = evaluate(str(spec["offset_x"]), eval_ctx)
            if v.type == ValueType.NUMBER:
                ox = v.value
        if "offset_y" in spec:
            v = evaluate(str(spec["offset_y"]), eval_ctx)
            if v.type == ValueType.NUMBER:
                oy = v.value
        dup = store.duplicate_artboard(id_val.value, ox, oy)
        return None, dup

    # doc.move_artboards_up: ids_expr — ARTBOARDS.md §Reordering
    # Applies the swap-with-neighbor-skipping-selected rule to the
    # given list of artboard ids.
    if "doc.move_artboards_up" in effect:
        from workspace_interpreter.expr_types import ValueType
        ids_expr = effect["doc.move_artboards_up"]
        eval_ctx = store.eval_context(ctx)
        val = evaluate(str(ids_expr) if ids_expr is not None else "", eval_ctx)
        if val.type != ValueType.LIST:
            return None
        store.move_artboards_up(val.value)
        return None

    # doc.move_artboards_down: ids_expr — ARTBOARDS.md §Reordering
    if "doc.move_artboards_down" in effect:
        from workspace_interpreter.expr_types import ValueType
        ids_expr = effect["doc.move_artboards_down"]
        eval_ctx = store.eval_context(ctx)
        val = evaluate(str(ids_expr) if ids_expr is not None else "", eval_ctx)
        if val.type != ValueType.LIST:
            return None
        store.move_artboards_down(val.value)
        return None

    # doc.set_artboard_options_field: { field, value }
    # — ARTBOARDS.md §Artboard Options Dialogue — Global section
    # Writes a document-wide artboard option
    # (fade_region_outside_artboard / update_while_dragging).
    if "doc.set_artboard_options_field" in effect:
        from workspace_interpreter.expr_types import ValueType
        spec = effect["doc.set_artboard_options_field"]
        if not isinstance(spec, dict):
            return None
        field = spec.get("field")
        if not isinstance(field, str):
            return None
        value_expr = spec.get("value")
        eval_ctx = store.eval_context(ctx)
        if isinstance(value_expr, str):
            value_result = evaluate(value_expr, eval_ctx)
            value = value_result.value if value_result.type != ValueType.CLOSURE else None
        else:
            value = value_expr
        store.set_artboard_options_field(field, value)
        return None

    # doc.set_artboard_field: { id, field, value }
    # — ARTBOARDS.md §Rename, §Artboard Options Dialogue
    # Writes value to the named field on the artboard with the given id.
    if "doc.set_artboard_field" in effect:
        from workspace_interpreter.expr_types import ValueType
        spec = effect["doc.set_artboard_field"]
        if not isinstance(spec, dict):
            return None
        eval_ctx = store.eval_context(ctx)
        id_val = evaluate(str(spec.get("id", "")), eval_ctx)
        if id_val.type != ValueType.STRING:
            return None
        field = spec.get("field")
        if not isinstance(field, str):
            return None
        value_expr = spec.get("value")
        if isinstance(value_expr, str):
            value_result = evaluate(value_expr, eval_ctx)
            value = value_result.value if value_result.type != ValueType.CLOSURE else None
        else:
            value = value_expr
        store.set_artboard_field(id_val.value, field, value)
        return None

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
            # YAML authors target state scopes via dotted paths with
            # optional $ prefix: $tool.selection.mode, $state.fill_color,
            # $panel.mode. The non-schema branch dispatches through
            # _set_by_scoped_target. Unscoped keys continue to write
            # to the global state map (legacy behavior).
            for key, expr in effect["set"].items():
                value = _eval(expr, store, ctx)
                _set_by_scoped_target(store, key, value)
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

    # if: two supported shapes
    #   Flat (tool-YAML authoring):  if: "<expr>"  then: [...]  else: [...]
    #   Nested (legacy actions):      if: { condition: <expr>, then: [...], else: [...] }
    if "if" in effect:
        cond_val = effect["if"]
        if isinstance(cond_val, str):
            cond_expr = cond_val
            then_list = effect.get("then", [])
            else_list = effect.get("else", [])
        elif isinstance(cond_val, dict):
            cond_expr = cond_val.get("condition", "false")
            then_list = cond_val.get("then", [])
            else_list = cond_val.get("else", [])
        else:
            return
        eval_ctx = store.eval_context(ctx)
        result = evaluate(str(cond_expr), eval_ctx)
        if result.to_bool():
            if isinstance(then_list, list) and then_list:
                run_effects(then_list, ctx, store, actions, platform_effects,
                            dialogs, schema, diagnostics)
        else:
            if isinstance(else_list, list) and else_list:
                run_effects(else_list, ctx, store, actions, platform_effects,
                            dialogs, schema, diagnostics)
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

    # select: { target, list, scope, scope_value, mode } — generic
    # tile-selection effect. Plain click replaces panel.{list} with
    # [target] and resets panel.{scope} to scope_value. Mode "auto"
    # reads event.shift / event.ctrl / event.meta from ctx for
    # shift-extend / ctrl-toggle behaviors. Mirrors the Rust
    # apply_select_effect.
    if "select" in effect:
        spec = effect["select"]
        panel_id = store.get_active_panel_id()
        list_field = spec.get("list", "")
        if panel_id and list_field:
            scope_field = spec.get("scope", "")
            mode = spec.get("mode", "auto")
            target = _eval(spec.get("target", ""), store, ctx)
            scope_value = _eval(spec.get("scope_value", ""), store, ctx)
            event = ctx.get("event") if isinstance(ctx, dict) else None
            shift = bool((event or {}).get("shift", False))
            ctrl_or_meta = bool((event or {}).get("ctrl", False)) \
                or bool((event or {}).get("meta", False))
            effective_mode = mode
            if mode == "auto":
                effective_mode = "extend" if shift \
                    else "toggle" if ctrl_or_meta \
                    else "single"
            scope_changed = False
            if scope_field:
                cur_scope = store.get_panel(panel_id, scope_field)
                if cur_scope != scope_value:
                    store.set_panel(panel_id, scope_field, scope_value)
                    store.set_panel(panel_id, list_field, [target])
                    scope_changed = True
            if not scope_changed:
                cur_list = store.get_panel(panel_id, list_field) or []
                if not isinstance(cur_list, list):
                    cur_list = []
                if effective_mode == "toggle":
                    if target in cur_list:
                        new_list = [v for v in cur_list if v != target]
                    else:
                        new_list = list(cur_list) + [target]
                elif effective_mode == "extend":
                    if cur_list and isinstance(cur_list[0], int) and isinstance(target, int):
                        anchor = cur_list[0]
                        lo, hi = sorted([anchor, target])
                        new_list = list(range(lo, hi + 1))
                    else:
                        new_list = [target]
                else:
                    new_list = [target]
                store.set_panel(panel_id, list_field, new_list)
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
        # Document-level preview snapshot for transform-tool dialogs
        # (Scale Options / Rotate Options / Shear Options). Fired
        # through the doc.preview.capture platform effect — see
        # SCALE_TOOL.md §Preview.
        if dlg_def.get("doc_preview") is True and platform_effects:
            handler = platform_effects.get("doc.preview.capture")
            if handler:
                handler(None, ctx, store)
        # Wire the dialog's on_change action — fired by the post-run
        # hook in run_effects after any batch that mutated dialog
        # state.
        on_change = dlg_def.get("on_change")
        store.set_dialog_on_change(on_change if isinstance(on_change, str) else None)
        # Clear any leftover dirty flag from prior dialog sessions so
        # the very-first init does not immediately fire on_change.
        store.take_dialog_dirty()
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
        # Document-level preview restore (Cancel path).
        if platform_effects:
            for name in ("doc.preview.restore", "doc.preview.clear"):
                handler = platform_effects.get(name)
                if handler:
                    handler(None, ctx, store)
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

    dash_align_anchors = bool(store.get("stroke_dash_align_anchors"))

    stroke = Stroke(
        color=color, width=width, linecap=linecap, linejoin=linejoin,
        opacity=opacity, miter_limit=miter_limit, align=align,
        dash_pattern=dash_pattern,
        dash_align_anchors=dash_align_anchors,
        start_arrow=start_arrow,
        end_arrow=end_arrow, start_arrow_scale=start_arrow_scale,
        end_arrow_scale=end_arrow_scale, arrow_align=arrow_align,
    )
    controller.set_selection_stroke(stroke)

    # Apply width profile if set
    profile = store.get("stroke_width_profile") or "uniform"
    flipped = bool(store.get("stroke_width_profile_flipped"))
    wp = profile_to_width_points(profile, width, flipped)
    controller.set_selection_width_profile(wp)


# Rendering-affecting stroke state keys. Mirrors OCaml's
# stroke_render_keys list — when any of these change in the global
# store, subscribe_stroke_panel fires apply_stroke_panel_to_selection.
STROKE_RENDER_KEYS: list[str] = [
    "stroke_cap", "stroke_join", "stroke_width", "stroke_miter_limit",
    "stroke_dashed", "stroke_dash_1", "stroke_gap_1",
    "stroke_dash_2", "stroke_gap_2", "stroke_dash_3", "stroke_gap_3",
    "stroke_dash_align_anchors",
    "stroke_align", "stroke_start_arrowhead", "stroke_end_arrowhead",
    "stroke_start_arrowhead_scale", "stroke_end_arrowhead_scale",
    "stroke_arrow_align", "stroke_profile", "stroke_profile_flipped",
]


def subscribe_stroke_panel(store: StateStore, controller_getter) -> None:
    """Wire ``apply_stroke_panel_to_selection`` to fire after any
    write into the global state for one of ``STROKE_RENDER_KEYS``.

    ``controller_getter`` is a zero-arg callable returning the live
    Controller (the app rotates models across tabs, so we can't
    capture a fixed reference). Mirrors OCaml's
    ``Effects.subscribe_stroke_panel``.
    """
    keys_set = set(STROKE_RENDER_KEYS)

    def _on_change(key, _value):
        if key in keys_set:
            apply_stroke_panel_to_selection(store, controller_getter())

    store.subscribe(STROKE_RENDER_KEYS, _on_change)


def sync_stroke_panel_from_selection(store: StateStore, model) -> None:
    """Mirror the SELECTED element's stroke WEIGHT into the Stroke panel's
    ``weight`` field so it shows the selection's effective (baked) stroke width
    — not the YAML default. Reads the FIRST selected element's stroke; falls
    back to ``model.default_stroke`` when nothing is selected or the element has
    no stroke.

    Sets the PANEL state (``stroke_panel_content.weight``, the value the weight
    widget binds), NOT the global ``stroke_width`` — so this DISPLAY sync does
    NOT trigger the panel->selection apply (``subscribe_stroke_panel`` listens
    on the global key), avoiding a clobber of the selection's other stroke
    props. The panel->selection EDIT path stays the widget's on_change ->
    global ``stroke_width``. No-op until the Stroke panel state exists. The
    caller wires it on every document/selection change.
    """
    if model is None:
        return
    doc = model.document
    stroke = None
    if doc.selection:
        first = next(iter(doc.selection))
        try:
            elem = doc.get_element(first.path)
        except Exception:
            elem = None
        if elem is not None:
            stroke = getattr(elem, "stroke", None)
    if stroke is None:
        stroke = getattr(model, "default_stroke", None)
    width = stroke.width if stroke is not None else 1.0
    store.set_panel("stroke_panel_content", "weight", float(width))


def _element_evaluated_bbox(doc, path):
    """Axis-aligned bounding box ``(x, y, w, h)`` of the element at ``path``
    in DOCUMENT space: the element's geometric bbox corners mapped through
    its own transform and every ancestor (group / layer) transform, then
    axis-aligned. Mirrors the selection-highlight transform chain
    (``canvas.selection_handle_rects``) so the Properties panel numbers match
    the visible selection box. Returns ``None`` when ``path`` does not
    resolve. Duck-typed (no geometry imports): a container exposes
    ``children``; every element exposes ``geometric_bounds`` and an optional
    ``transform`` with ``apply_point``."""
    if not path:
        return None
    layers = getattr(doc, "layers", None)
    if layers is None:
        return None
    try:
        node = layers[path[0]]
    except (IndexError, TypeError):
        return None
    ancestors = []  # outermost (layer) first
    if len(path) > 1:
        ancestors.append(getattr(node, "transform", None))
        for idx in path[1:-1]:
            children = getattr(node, "children", None)
            if children is None:
                return None
            try:
                node = children[idx]
            except (IndexError, TypeError):
                return None
            ancestors.append(getattr(node, "transform", None))
        children = getattr(node, "children", None)
        if children is None:
            return None
        try:
            node = children[path[-1]]
        except (IndexError, TypeError):
            return None
    bounds_fn = getattr(node, "geometric_bounds", None)
    if bounds_fn is None:
        return None
    bx, by, bw, bh = bounds_fn()
    # Apply innermost-first: the element's own transform, then each ancestor
    # outward (layer last) — matching the painter's combined CTM.
    chain = [getattr(node, "transform", None)] + list(reversed(ancestors))
    xs, ys = [], []
    for (px, py) in ((bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh)):
        for t in chain:
            if t is not None:
                px, py = t.apply_point(px, py)
        xs.append(px)
        ys.append(py)
    return (min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys))


def selection_evaluated_bounds(doc):
    """Union ``(x, y, w, h)`` of every selected element's evaluated geometric
    bbox (see :func:`_element_evaluated_bbox`) in DOCUMENT space — the
    post-transform values the Properties panel shows. ``(0, 0, 0, 0)`` when
    the selection is empty or nothing resolves."""
    boxes = []
    for es in getattr(doc, "selection", None) or []:
        bbox = _element_evaluated_bbox(doc, es.path)
        if bbox is not None:
            boxes.append(bbox)
    if not boxes:
        return (0.0, 0.0, 0.0, 0.0)
    min_x = min(b[0] for b in boxes)
    min_y = min(b[1] for b in boxes)
    max_x = max(b[0] + b[2] for b in boxes)
    max_y = max(b[1] + b[3] for b in boxes)
    return (min_x, min_y, max_x - min_x, max_y - min_y)


def sync_properties_panel_from_selection(store: StateStore, model) -> None:
    """Mirror the selection's evaluated bounding box into the Properties
    panel's ``x`` / ``y`` / ``w`` / ``h`` fields (decision-5 Part B) — the
    values the X/Y/W/H widgets bind. Display-only (panel keys, never the
    selection). ``(0, 0, 0, 0)`` when nothing is selected. No-op until the
    Properties panel state exists. The caller wires it on every
    document/selection change."""
    if model is None:
        return
    import math
    doc = model.document
    x, y, w, h = selection_evaluated_bounds(doc)
    pid = "properties_panel_content"
    # Keys are prop_-prefixed to avoid colliding with another panel's short
    # leaf keys in renderers that feed live values through one shared override
    # map (the Color panel uses y / h). See properties.yaml.
    store.set_panel(pid, "prop_x", round(float(x), 2))
    store.set_panel(pid, "prop_y", round(float(y), 2))
    store.set_panel(pid, "prop_w", round(float(w), 2))
    store.set_panel(pid, "prop_h", round(float(h), 2))
    # Per-element attrs (rotation / opacity / blend) reflect the FIRST
    # selected element, like the Stroke panel weight (Part B.3). Defaults
    # when nothing is selected: 0 degrees, 100%, normal.
    rotation, opacity, blend = 0.0, 100.0, "normal"
    if doc.selection:
        first = next(iter(doc.selection))
        try:
            elem = doc.get_element(first.path)
        except Exception:
            elem = None
        if elem is not None:
            t = getattr(elem, "transform", None)
            if t is not None:
                rotation = math.degrees(math.atan2(t.b, t.a))
            opacity = float(getattr(elem, "opacity", 1.0)) * 100.0
            bm = getattr(elem, "blend_mode", None)
            if bm is not None:
                blend = getattr(bm, "value", "normal")
    # Guard the panel writes so subscribe_properties_panel does NOT treat
    # these sync pushes as user edits (Part B.2). Only genuine widget edits
    # (made while _PROPS_SYNCING is False) apply back to the selection.
    global _PROPS_SYNCING
    _PROPS_SYNCING = True
    try:
        store.set_panel(pid, "prop_rotation", round(float(rotation), 2))
        store.set_panel(pid, "prop_opacity", round(float(opacity), 2))
        store.set_panel(pid, "prop_blend", blend)
    finally:
        _PROPS_SYNCING = False


# ── Part B.2: Properties panel field EDITING (apply to selection) ──────────
# Guards: _PROPS_SYNCING is True while the display sync pushes panel keys
# (so those writes are not mistaken for user edits); _PROPS_APPLYING is True
# while an apply runs (so the post-apply document-change re-sync cannot loop).
_PROPS_SYNCING = False
_PROPS_APPLYING = False

_PROP_IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def _mat_mul(a, b):
    """2x3 affine compose: result applies ``b`` first, then ``a``
    (``result.apply(p) == a.apply(b.apply(p))``). Tuples are
    ``(a, b, c, d, e, f)`` for the matrix ``[a c e; b d f]``."""
    a1, b1, c1, d1, e1, f1 = a
    a2, b2, c2, d2, e2, f2 = b
    return (a1 * a2 + c1 * b2,
            b1 * a2 + d1 * b2,
            a1 * c2 + c1 * d2,
            b1 * c2 + d1 * d2,
            a1 * e2 + c1 * f2 + e1,
            b1 * e2 + d1 * f2 + f1)


def _aabb_through(local_bbox, mat):
    """Axis-aligned bbox ``(x, y, w, h)`` of ``local_bbox``'s four corners
    mapped through the 2x3 matrix tuple ``mat``."""
    bx, by, bw, bh = local_bbox
    a, b, c, d, e, f = mat
    pts = [(a * px + c * py + e, b * px + d * py + f)
           for (px, py) in ((bx, by), (bx + bw, by),
                            (bx + bw, by + bh), (bx, by + bh))]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys))


def _scaled_transform_tuple(mat, local_bbox, rx, ry):
    """New transform that scales the element's LOCAL axes by ``(rx, ry)``
    (post-multiply, preserving rotation — never shears) while keeping the
    evaluated bbox top-left fixed."""
    scaled = _mat_mul(mat, (rx, 0.0, 0.0, ry, 0.0, 0.0))
    old = _aabb_through(local_bbox, mat)
    new = _aabb_through(local_bbox, scaled)
    a, b, c, d, e, f = scaled
    return (a, b, c, d, e + (old[0] - new[0]), f + (old[1] - new[1]))


def _rotated_transform_tuple(mat, local_bbox, deg):
    """New transform with the element's rotation set to ``deg`` (keeping the
    decomposed scale; shear-free assumption), rotated about the evaluated
    bbox center so the object stays in place."""
    import math
    a, b, c, d, e, f = mat
    sx = math.hypot(a, b)
    sy = math.hypot(c, d)
    rad = math.radians(deg)
    cos_a, sin_a = math.cos(rad), math.sin(rad)
    rotated = (sx * cos_a, sx * sin_a, -sy * sin_a, sy * cos_a, e, f)
    old = _aabb_through(local_bbox, mat)
    new = _aabb_through(local_bbox, rotated)
    ocx, ocy = old[0] + old[2] / 2.0, old[1] + old[3] / 2.0
    ncx, ncy = new[0] + new[2] / 2.0, new[1] + new[3] / 2.0
    ra, rb, rc, rd, _, _ = rotated
    return (ra, rb, rc, rd, e + (ocx - ncx), f + (ocy - ncy))


def apply_properties_field(controller, field, value) -> None:
    """Apply a Properties-panel field edit to the selection (Part B.2).

    ``field`` in {x, y, w, h, rotation, opacity, blend}:
      - x / y: move the selection so its bbox edge reaches the value
        (translation bakes into geometry, decision-3); any selection.
      - opacity / blend: set the attribute on every selected element.
      - w / h: scale the LOCAL axes by value/current-bbox (decision: scale
        local axes by ratio); SINGLE selection only.
      - rotation: set the absolute rotation about the bbox center; SINGLE
        selection only.
    """
    import dataclasses
    from geometry.element import Transform, BlendMode
    model = controller.model
    doc = model.document
    if not doc.selection:
        return
    bbox = selection_evaluated_bounds(doc)
    if field == "x":
        controller.move_selection(float(value) - bbox[0], 0.0)
        return
    if field == "y":
        controller.move_selection(0.0, float(value) - bbox[1])
        return
    if field == "opacity":
        op = max(0.0, min(100.0, float(value))) / 100.0
        new_doc = doc
        for es in doc.selection:
            elem = doc.get_element(es.path)
            new_doc = new_doc.replace_element(
                es.path, dataclasses.replace(elem, opacity=op))
        model.edit_document(new_doc)
        return
    if field == "blend":
        try:
            bm = BlendMode(str(value))
        except ValueError:
            return
        new_doc = doc
        for es in doc.selection:
            elem = doc.get_element(es.path)
            new_doc = new_doc.replace_element(
                es.path, dataclasses.replace(elem, blend_mode=bm))
        model.edit_document(new_doc)
        return
    # w / h / rotation — single selection only (local-axes semantics is
    # well-defined for one element; the widgets are disabled for multi-select).
    if len(doc.selection) != 1:
        return
    es = next(iter(doc.selection))
    elem = doc.get_element(es.path)
    local = elem.geometric_bounds()
    t = getattr(elem, "transform", None)
    mat = (t.a, t.b, t.c, t.d, t.e, t.f) if t is not None else _PROP_IDENTITY
    if field == "w":
        if bbox[2] <= 0:
            return
        mp = _scaled_transform_tuple(mat, local, float(value) / bbox[2], 1.0)
    elif field == "h":
        if bbox[3] <= 0:
            return
        mp = _scaled_transform_tuple(mat, local, 1.0, float(value) / bbox[3])
    elif field == "rotation":
        mp = _rotated_transform_tuple(mat, local, float(value))
    else:
        return
    new_t = Transform(a=mp[0], b=mp[1], c=mp[2], d=mp[3], e=mp[4], f=mp[5])
    new_doc = doc.replace_element(
        es.path, dataclasses.replace(elem, transform=new_t))
    model.edit_document(new_doc)


def subscribe_properties_panel(store: StateStore, model_getter) -> None:
    """Wire :func:`apply_properties_field` to fire after a genuine USER edit
    of a ``prop_*`` field (Part B.2). Skips the display sync's own pushes
    (``_PROPS_SYNCING``) and guards against the apply -> document-change ->
    re-sync loop (``_PROPS_APPLYING``)."""
    fields = {"x", "y", "w", "h", "rotation", "opacity", "blend"}

    def _on_change(key, value):
        global _PROPS_APPLYING
        if _PROPS_SYNCING or _PROPS_APPLYING:
            return
        field = key[len("prop_"):] if key.startswith("prop_") else key
        if field not in fields:
            return
        model = model_getter()
        if model is None:
            return
        from document.controller import Controller
        _PROPS_APPLYING = True
        try:
            apply_properties_field(Controller(model), field, value)
        finally:
            _PROPS_APPLYING = False

    store.subscribe_panel("properties_panel_content", _on_change)


def subscribe_active_color(store: StateStore, controller_getter) -> None:
    """Wire a write-back to the canvas selection on every global
    write to ``fill_color`` or ``stroke_color``. The Color Panel
    updates the selection directly; the YAML route through
    ``set: { fill_color: ... }`` (used by the Swatches Panel's
    set_active_color action) needs this subscription so the
    selection follows the active-color change. Mirrors OCaml's
    ``Effects.subscribe_active_color``.
    """
    from geometry.element import Color, Fill, Stroke

    def _on_change(key, _value):
        if key not in ("fill_color", "stroke_color"):
            return
        ctrl = controller_getter()
        model = ctrl.model
        # Apply by KEY only, not gated on fill_on_top — explicit
        # writes to fill_color / stroke_color (Color panel toolbar
        # swap, reset_fill_stroke action, picker OK with target=
        # fill) should always land on the matching side regardless
        # of which swatch is currently "active" in the panel. Was
        # previously gated, which made reset_fill_stroke (sets
        # both keys in one effect) apply only one side per click.
        if key == "fill_color":
            raw = store.get("fill_color")
            if isinstance(raw, str):
                color = Color.from_hex(raw)
                if color is None:
                    return
                fill = Fill(color=color)
            elif raw is None:
                fill = None
            else:
                return
            model.default_fill = fill
            if model.document.selection:
                # The Controller mutator self-brackets via edit_document.
                ctrl.set_selection_fill(fill)
        elif key == "stroke_color":
            raw = store.get("stroke_color")
            existing_width = model.default_stroke.width if model.default_stroke else 1.0
            if isinstance(raw, str):
                color = Color.from_hex(raw)
                if color is None:
                    return
                stroke = Stroke(color=color, width=existing_width)
            elif raw is None:
                stroke = None
            else:
                return
            model.default_stroke = stroke
            if model.document.selection:
                # The Controller mutator self-brackets via edit_document.
                ctrl.set_selection_stroke(stroke)

    store.subscribe(["fill_color", "stroke_color"], _on_change)
