"""Shared platform-effect handlers for artboard doc.* effects.

Used by:
- panels/panel_menu.py — _dispatch_yaml_layers_action (tree_view /
  menu / keyboard paths).
- workspace/dock_panel.py — _dispatch_yaml_action (panel buttons and
  YAML-driven menus).

Each handler closes over the jas Model. OP_LOG.md §9: every handler resolves its
YAML exprs to RESOLVED literals (replay has no eval context), builds the per-verb
op JSON, and routes through the SHARED ``op_apply`` dispatcher — the SAME
Artboard-helper / print-config mutation body, now JOURNALING a real op so each
gesture replays byte-identically (checkpoint_equivalence). VALUE-IN-OP:
create/duplicate mint the id ONCE here (production entropy) and journal it as a
LITERAL, so replay reads it VERBATIM and never re-mints. Semantics match the Rust
/ Swift / OCaml artboard doc helpers and the ARTBOARDS.md / PRINT.md specs.
"""

from __future__ import annotations

from workspace_interpreter.expr import evaluate

from document.artboard import generate_artboard_id, next_artboard_name
from document.op_apply import op_apply


def _mint_artboard_id(existing_ids: set) -> str:
    """Generate a fresh artboard id with collision retry (100 attempts).
    Returns empty string on exhaustion (caller no-ops)."""
    for _ in range(100):
        c = generate_artboard_id()
        if c not in existing_ids:
            return c
    return ""


def _extract_id_list(val) -> list:
    """Unwrap a LIST Value into a python list of string ids, or []."""
    if val.type.name != "LIST":
        return []
    return [item for item in val.value if isinstance(item, str)]


def build_artboard_handlers(model) -> dict:
    """Return a dict mapping effect names to handlers that mutate
    ``model.document`` via dataclasses.replace. The handlers match the
    Rust / Swift / OCaml semantics."""

    def doc_create_artboard(spec, call_ctx, _store):
        # OP_LOG.md §9 VALUE-IN-OP — mint the id ONCE here (production entropy)
        # and journal it as a LITERAL so replay reads it VERBATIM and never
        # re-mints. The default name (derived from the live doc) plus each
        # RESOLVED override are journaled as a flat `fields` literal object;
        # routed through the SHARED op_apply dispatcher (apply_create_artboard).
        existing = {a.id for a in model.document.artboards}
        new_id = _mint_artboard_id(existing)
        if not new_id:
            return None
        fields: dict = {"name": next_artboard_name(model.document.artboards)}
        if isinstance(spec, dict):
            for k, v in spec.items():
                if isinstance(v, str):
                    r = evaluate(v, call_ctx)
                    fields[k] = r.value
                else:
                    fields[k] = v
        op_apply(model, {"op": "create_artboard", "id": new_id, "fields": fields})
        return new_id

    def doc_delete_artboard_by_id(value, call_ctx, _store):
        # OP_LOG.md §9 — resolve the id literal, route through the SHARED op_apply
        # dispatcher (apply_delete_artboard_by_id). A missing id is a no-op that
        # journals nothing.
        id_expr = value if isinstance(value, str) else ""
        r = evaluate(id_expr, call_ctx)
        if r.type.name != "STRING":
            return None
        op_apply(model, {"op": "delete_artboard_by_id", "id": r.value})
        return None

    def doc_duplicate_artboard(spec, call_ctx, _store):
        if isinstance(spec, str):
            id_expr = spec
            ox_expr = None
            oy_expr = None
        elif isinstance(spec, dict):
            id_expr = str(spec.get("id", ""))
            ox_expr = spec.get("offset_x")
            oy_expr = spec.get("offset_y")
        else:
            return None
        id_val = evaluate(id_expr, call_ctx)
        if id_val.type.name != "STRING":
            return None
        target = id_val.value
        ox = 20.0
        oy = 20.0
        if isinstance(ox_expr, str):
            r = evaluate(ox_expr, call_ctx)
            if r.type.name == "NUMBER":
                ox = float(r.value)
        if isinstance(oy_expr, str):
            r = evaluate(oy_expr, call_ctx)
            if r.type.name == "NUMBER":
                oy = float(r.value)
        # Resolve the source up front: a missing source short-circuits BEFORE we
        # mint, so a no-op duplicate journals nothing (matching the op_apply arm).
        # OP_LOG.md §9 VALUE-IN-OP: mint new_id + derive name HERE (the ONLY mint
        # / derive) and journal both as literals; route through the SHARED
        # op_apply dispatcher (apply_duplicate_artboard).
        if not any(a.id == target for a in model.document.artboards):
            return None
        existing = {a.id for a in model.document.artboards}
        new_id = _mint_artboard_id(existing)
        if not new_id:
            return None
        dup_name = next_artboard_name(model.document.artboards)
        op_apply(model, {
            "op": "duplicate_artboard", "id": target, "new_id": new_id,
            "name": dup_name, "offset_x": ox, "offset_y": oy,
        })
        return new_id

    def doc_set_artboard_field(spec, call_ctx, _store):
        if not isinstance(spec, dict):
            return None
        id_expr = str(spec.get("id", ""))
        field = spec.get("field")
        if not isinstance(field, str):
            return None
        value_expr = spec.get("value")
        id_val = evaluate(id_expr, call_ctx)
        if id_val.type.name != "STRING":
            return None
        if isinstance(value_expr, str):
            vr = evaluate(value_expr, call_ctx)
            value = vr.value
        else:
            value = value_expr
        # OP_LOG.md §9 — RESOLVED literal value routed through the SHARED op_apply
        # dispatcher (apply_set_artboard_field). A missing artboard / type
        # mismatch is a no-op inside the arm (journals nothing).
        op_apply(model, {"op": "set_artboard_field",
                         "id": id_val.value, "field": field, "value": value})
        return None

    def doc_set_artboard_options_field(spec, call_ctx, _store):
        if not isinstance(spec, dict):
            return None
        field = spec.get("field")
        if not isinstance(field, str):
            return None
        value_expr = spec.get("value")
        if isinstance(value_expr, str):
            vr = evaluate(value_expr, call_ctx)
            value = vr.value
        else:
            value = value_expr
        if not isinstance(value, bool):
            return None
        # OP_LOG.md §9 — route through the SHARED op_apply dispatcher
        # (apply_set_artboard_options_field). A non-bool / unknown field is a
        # no-op inside the arm.
        op_apply(model, {"op": "set_artboard_options_field",
                         "field": field, "value": value})
        return None

    def doc_move_artboards_up(value, call_ctx, _store):
        # OP_LOG.md §9 — resolve the ids list literal, route through the SHARED
        # op_apply dispatcher (apply_move_artboards up). A boundary no-op
        # (top/bottom artboard) journals nothing.
        ids_expr = value if isinstance(value, str) else ""
        r = evaluate(ids_expr, call_ctx)
        ids = _extract_id_list(r)
        op_apply(model, {"op": "move_artboards_up", "ids": ids})
        return None

    def doc_move_artboards_down(value, call_ctx, _store):
        ids_expr = value if isinstance(value, str) else ""
        r = evaluate(ids_expr, call_ctx)
        ids = _extract_id_list(r)
        op_apply(model, {"op": "move_artboards_down", "ids": ids})
        return None

    # PRINT.md §1A-§6 — the eight print-config field setters (OP_LOG.md §9
    # Phase P1). Each evaluates its YAML `value` expr to a RESOLVED literal,
    # builds a {op, field, value[, index]} op, and routes through the SHARED
    # op_apply dispatcher (apply_print_config_field — the SAME field-match +
    # type-coerce + replace body the per-field switches drove before P1). Routing
    # through op_apply JOURNALS the edit as a real op so it replays
    # byte-identically (checkpoint_equivalence). set_output_ink_field also carries
    # an `index`; a missing index on the ink verb skips. A type mismatch / unknown
    # field is a no-op inside op_apply that journals nothing. Factory: one closure
    # per print-config verb, all sharing this body. Mirrors the Rust / Swift ports.
    def _make_print_config_handler(verb):
        def handler(spec, call_ctx, _store):
            if not isinstance(spec, dict):
                return None
            field = spec.get("field")
            if not isinstance(field, str):
                return None
            value_expr = spec.get("value")
            if isinstance(value_expr, str):
                vr = evaluate(value_expr, call_ctx)
                value = vr.value
            else:
                value = value_expr
            op = {"op": verb, "field": field, "value": value}
            if verb == "set_output_ink_field":
                index = spec.get("index")
                if not isinstance(index, int):
                    return None
                op["index"] = index
            op_apply(model, op)
            return None
        return handler

    doc_set_document_setup_field = _make_print_config_handler(
        "set_document_setup_field")
    doc_set_print_preferences_field = _make_print_config_handler(
        "set_print_preferences_field")
    doc_set_marks_and_bleed_field = _make_print_config_handler(
        "set_marks_and_bleed_field")
    doc_set_output_field = _make_print_config_handler("set_output_field")
    doc_set_output_ink_field = _make_print_config_handler("set_output_ink_field")
    doc_set_graphics_field = _make_print_config_handler("set_graphics_field")
    doc_set_color_management_field = _make_print_config_handler(
        "set_color_management_field")
    doc_set_advanced_field = _make_print_config_handler("set_advanced_field")

    # PRINT.md §1B
    def geometry_export_pdf(_spec, _call_ctx, _store):
        from geometry.pdf import document_to_pdf
        from PySide6.QtWidgets import QFileDialog
        bytes_ = document_to_pdf(model.document)
        # Suggested name: strip known extension on model.filename, append .pdf.
        # When no model attr exists, default to "Untitled.pdf".
        suggested = "Untitled.pdf"
        fname = getattr(model, "filename", "") or ""
        if fname and not fname.startswith("Untitled-"):
            stem = fname.rsplit(".", 1)[0] if "." in fname else fname
            suggested = f"{stem}.pdf"
        path, _ = QFileDialog.getSaveFileName(
            None, "Export to PDF", suggested, "PDF Files (*.pdf)")
        if path:
            with open(path, "wb") as f:
                f.write(bytes_)
        return None

    return {
        "doc.create_artboard": doc_create_artboard,
        "doc.delete_artboard_by_id": doc_delete_artboard_by_id,
        "doc.duplicate_artboard": doc_duplicate_artboard,
        "doc.set_artboard_field": doc_set_artboard_field,
        "doc.set_artboard_options_field": doc_set_artboard_options_field,
        "doc.set_document_setup_field": doc_set_document_setup_field,
        "doc.set_print_preferences_field": doc_set_print_preferences_field,
        "doc.set_marks_and_bleed_field": doc_set_marks_and_bleed_field,
        "doc.set_output_field": doc_set_output_field,
        "doc.set_output_ink_field": doc_set_output_ink_field,
        "doc.set_graphics_field": doc_set_graphics_field,
        "doc.set_color_management_field": doc_set_color_management_field,
        "doc.set_advanced_field": doc_set_advanced_field,
        "doc.move_artboards_up": doc_move_artboards_up,
        "doc.move_artboards_down": doc_move_artboards_down,
        "geometry.export_pdf": geometry_export_pdf,
    }
