"""Concepts-panel native action arms (CONCEPTS.md §6).

The Concepts panel's mutating ops are ``log`` stubs in the shared
``actions.yaml`` (like the Symbols panel's); the real work lives here and is
intercepted natively by the dock panel, exactly as ``symbols_apply`` does:

- ``place_concept_instance`` mints a fresh element id (value-in-op) and appends
  a default-param ``GeneratedElem`` of the panel-selected concept.
- ``set_concept_param`` writes one parameter on the single selected generated
  instance so it re-generates live (the §6.4 "tune the same parameters" promise).

Each op goes through a :class:`Controller` mutator that self-brackets one undo
step via ``edit_document``. Id minting is a UI-layer concern (``generate_element_id``
with a collision-retry loop), never minted inside the Controller, so every app
applies identical values. Mirrors the Rust ``place_concept_instance`` /
``set_concept_param`` dispatch arms and the Swift ``ConceptsPanel``.
"""

from __future__ import annotations


def _gather_existing_ids(doc) -> set[str]:
    """Every element id currently in the document (layers + master store), so a
    freshly minted id avoids collisions. Mirrors ``symbols_apply``."""
    existing: set[str] = set()

    def _walk(elem) -> None:
        eid = getattr(elem, "id", None)
        if eid is not None:
            existing.add(eid)
        children = getattr(elem, "children", None)
        if children is not None:
            for c in children:
                _walk(c)

    for layer in doc.layers:
        _walk(layer)
    for master in doc.symbols:
        _walk(master)
    return existing


def _mint(existing: set[str]) -> str | None:
    """Mint one collision-free element id (UI-layer minter)."""
    from document.artboard import generate_element_id
    for _ in range(100):
        candidate = generate_element_id()
        if candidate not in existing:
            return candidate
    return None


def default_params(concept_id: str) -> dict:
    """The concept's declared default parameters as a params dict, read from the
    compiled concept registry. Mirrors the Rust / Swift default-params helpers."""
    from panels.yaml_menu import get_workspace_data
    ws = get_workspace_data()
    concept = (ws or {}).get("concepts", {}).get(concept_id)
    if not isinstance(concept, dict):
        return {}
    out: dict = {}
    for p in concept.get("params", []) or []:
        if isinstance(p, dict) and "name" in p and "default" in p:
            out[p["name"]] = p["default"]
    return out


def _route(model, txn_name: str, op: dict) -> None:
    """OP_LOG.md §9 — route a Concepts-panel gesture through the SHARED
    ``op_apply`` dispatcher so it JOURNALS a real op in ONE named undo step. The
    dispatcher calls the SAME ``Controller`` mutator the handler called directly
    before, so the document is byte-identical; the journal now gains the
    replayable entry. Owns its own transaction (no surrounding snapshot effect),
    but only if none is already open, so a reentrant caller's bracket is
    preserved. Mirrors the Rust ``with_txn`` + ``op_apply`` bracket and Python's
    ``menu._route_delete_selection``."""
    from document.op_apply import op_apply
    owns = not model.in_txn
    if owns:
        model.begin_txn()
        model.name_txn(txn_name)
    op_apply(model, op)
    if owns:
        model.commit_txn()


def apply_place_concept_instance(model, concept_id: str | None) -> None:
    """Place Instance: append a new default-param generated instance of
    ``concept_id`` to the active layer and select it (CONCEPTS.md §6). Mints
    ``elem_id`` and resolves the registry defaults HERE (value-in-op, UI-layer
    concerns), then routes a ``place_concept_instance`` op through ``op_apply``
    (one undo step) so the placement JOURNALS. No-op when no concept is
    panel-selected. Mirrors the Rust ``place_concept_instance`` dispatch arm."""
    if model is None or not concept_id:
        return
    existing = _gather_existing_ids(model.document)
    elem_id = _mint(existing)
    if elem_id is None:
        return
    # VALUE-IN-OP: bake the concept id, the resolved default params, and the
    # minted id into the op; replay re-derives NONE of them.
    _route(model, "place_concept_instance", {
        "op": "place_concept_instance",
        "concept_id": concept_id,
        "params": default_params(concept_id),
        "elem_id": elem_id,
    })


def apply_set_concept_param(model, name: str, value: float) -> None:
    """Set one parameter on the single selected generated instance to ``value``
    so it re-generates live (CONCEPTS.md §6.4). Resolves the selected path HERE
    (the live selection is a UI-layer concern), then routes a
    ``set_concept_param`` op through ``op_apply`` (one undo step) so the edit
    JOURNALS. No-op unless exactly one ``GeneratedElem`` is selected. Mirrors the
    Rust ``set_concept_param`` dispatch arm."""
    if model is None or not name:
        return
    from geometry.element import GeneratedElem
    doc = model.document
    if len(doc.selection) != 1:
        return
    es = next(iter(doc.selection))
    try:
        elem = doc.get_element(es.path)
    except (ValueError, IndexError, KeyError):
        return
    if not isinstance(elem, GeneratedElem):
        return
    # VALUE-IN-OP: bake the resolved path, param name, and committed value into
    # the op; replay re-consults NEITHER the live selection NOR the element.
    _route(model, "set_concept_param", {
        "op": "set_concept_param",
        "path": list(es.path),
        "name": name,
        "value": value,
    })


def apply_concept_operation(model, op_id: str | None) -> None:
    """Apply a named concept operation (CONCEPTS.md §9) to the single selected
    generated instance. The operation's effect is RESOLVED here, at production
    time: look the operation up in the registry by ``op_id``, evaluate its
    ``set:`` expressions with the instance's CURRENT params bound under
    ``param``, and bake the resulting ``changes`` map into the op (value-in-op).
    Routed through ``op_apply`` inside the one-undo bracket so it JOURNALS;
    replay merges ``changes`` and never re-evaluates an expression nor consults
    the registry. No-op unless exactly one ``GeneratedElem`` is selected, the
    operation is unknown, or the resolved ``changes`` are empty. Mirrors the Rust
    ``apply_concept_operation`` dispatch arm."""
    if model is None or not op_id:
        return
    from geometry.element import GeneratedElem
    doc = model.document
    if len(doc.selection) != 1:
        return
    es = next(iter(doc.selection))
    try:
        elem = doc.get_element(es.path)
    except (ValueError, IndexError, KeyError):
        return
    if not isinstance(elem, GeneratedElem):
        return
    # Resolve the operation's ``set:`` expressions over the instance's current
    # params -> the concrete ``changes`` map.
    from panels.yaml_menu import get_workspace_data
    ws = get_workspace_data()
    concept = (ws or {}).get("concepts", {}).get(elem.concept_id)
    if not isinstance(concept, dict):
        return
    operation = None
    for o in concept.get("operations", []) or []:
        if isinstance(o, dict) and o.get("id") == op_id:
            operation = o
            break
    if operation is None:
        return
    set_map = operation.get("set")
    if not isinstance(set_map, dict):
        return
    from workspace_interpreter.expr import evaluate
    from workspace_interpreter.expr_types import ValueType
    ctx = {"param": elem.params}
    changes: dict = {}
    for pname, expr_src in set_map.items():
        if not isinstance(expr_src, str):
            continue
        result = evaluate(expr_src, ctx)
        if result.type == ValueType.NUMBER:
            # Store resolved param values as floats so serialization matches
            # across apps (sides=7.0), exactly as the determinism rule requires.
            changes[pname] = float(result.value)
    if not changes:
        return
    # VALUE-IN-OP: ``op_id`` rides as journal metadata; the RESOLVED ``changes``
    # map is the authoritative operand replay merges. Replay re-evaluates NOTHING
    # and re-consults the registry NEVER.
    _route(model, "apply_concept_operation", {
        "op": "apply_concept_operation",
        "path": list(es.path),
        "op_id": op_id,
        "changes": changes,
    })


def apply_promote_to_concept(model) -> None:
    """Promote the single selected raw shape to a live ``Generated`` concept
    instance (CONCEPTS.md §10 — the fitter / promote, the inverse of expand).
    Detection is RESOLVED here, at production time: extract the selected
    Polygon/Polyline's WORLD-space vertices (the element transform baked into the
    points), try EVERY registered concept's ``fitter`` expression over them (bound
    under ``shape.points``, in sorted-id order for a deterministic first match),
    and on the first match split its flat result ``[params..., cx, cy, rotation]``
    into the concept params (first K by declared order) + a placement transform
    (``translate(cx,cy) · rotate(rotation)``). Everything is baked into the op
    value-in-op and routed through ``op_apply`` (one undo step) so it JOURNALS;
    replay rebuilds the Generated and never re-runs the fitter. No-op unless
    exactly one Polygon/Polyline is selected and some concept matches. Mirrors the
    Rust ``promote_to_concept`` dispatch arm."""
    if model is None:
        return
    from geometry.element import Polygon, Polyline, Transform
    doc = model.document
    if len(doc.selection) != 1:
        return
    es = next(iter(doc.selection))
    try:
        elem = doc.get_element(es.path)
    except (ValueError, IndexError, KeyError):
        return
    # Only a Polygon / Polyline carries promotable vertices in v1.
    if not isinstance(elem, (Polygon, Polyline)):
        return
    raw_points = [(float(p[0]), float(p[1])) for p in elem.points]
    if not raw_points:
        return
    # Bake any element transform into the points so the fitter sees WORLD space
    # (the promoted instance re-places via its own transform).
    t_elem = getattr(elem, "transform", None)
    if t_elem is not None:
        pts = [t_elem.apply_point(x, y) for (x, y) in raw_points]
    else:
        pts = raw_points
    ctx = {"shape": {"points": [[x, y] for (x, y) in pts]}}

    from panels.yaml_menu import get_workspace_data
    ws = get_workspace_data()
    registry = (ws or {}).get("concepts", {})
    if not isinstance(registry, dict) or not registry:
        return

    from workspace_interpreter.expr import evaluate
    from workspace_interpreter.expr_types import ValueType

    def _num(v) -> float:
        # A LIST value's items are themselves Values; unwrap then coerce.
        raw = v.value if hasattr(v, "value") else v
        try:
            return float(raw)
        except (TypeError, ValueError):
            return 0.0

    chosen = None  # (concept_id, params_dict, cx, cy, rotation)
    for cid in sorted(registry.keys()):
        concept = registry[cid]
        if not isinstance(concept, dict):
            continue
        fitter = concept.get("fitter")
        if not isinstance(fitter, str):
            continue
        result = evaluate(fitter, ctx)
        if result.type != ValueType.LIST:
            continue  # null / non-list => no match for this concept
        items = result.value
        param_names = [
            p["name"] for p in (concept.get("params", []) or [])
            if isinstance(p, dict) and "name" in p
        ]
        k = len(param_names)
        if len(items) < k + 3:
            continue  # malformed fitter output (need params + cx,cy,rot)
        nums = [_num(v) for v in items]
        # Store recovered param values as floats so serialization matches across
        # apps (sides=6.0), exactly as the determinism rule requires.
        params = {name: nums[i] for i, name in enumerate(param_names)}
        chosen = (cid, params, nums[k], nums[k + 1], nums[k + 2])
        break

    if chosen is None:
        return  # nothing matched: no-op
    concept_id, params, cx, cy, rot = chosen
    # Placement: translate(cx,cy) * rotate(rot) — rotate then translate.
    t = Transform.translate(cx, cy).multiply(Transform.rotate(rot))
    # VALUE-IN-OP: the concept id, recovered params, and placement transform are
    # all baked in; replay rebuilds the Generated and re-runs the fitter NEVER.
    _route(model, "promote_to_concept", {
        "op": "promote_to_concept",
        "path": list(es.path),
        "concept_id": concept_id,
        "params": params,
        "transform": [t.a, t.b, t.c, t.d, t.e, t.f],
    })
