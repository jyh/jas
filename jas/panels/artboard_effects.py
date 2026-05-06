"""Shared platform-effect handlers for artboard doc.* effects.

Used by:
- panels/panel_menu.py — _dispatch_yaml_layers_action (tree_view /
  menu / keyboard paths).
- workspace/dock_panel.py — _dispatch_yaml_action (panel buttons and
  YAML-driven menus).

Each handler closes over the jas Model so it can replace
``model.document`` via ``dataclasses.replace`` (immutable frozen
dataclass). Semantics match the Rust / Swift / OCaml artboard doc
helpers and the ARTBOARDS.md spec.
"""

from __future__ import annotations

import dataclasses

from workspace_interpreter.expr import evaluate

from document.artboard import (
    Artboard, generate_artboard_id, next_artboard_name,
)


def _apply_artboard_override(ab: Artboard, field: str, value) -> Artboard:
    """Return a new Artboard with one field replaced. Matches
    apply_artboard_override() across Rust / Swift / OCaml — unknown
    fields silently no-op."""
    if field == "name" and isinstance(value, str):
        return dataclasses.replace(ab, name=value)
    if field == "x" and isinstance(value, (int, float)):
        return dataclasses.replace(ab, x=float(value))
    if field == "y" and isinstance(value, (int, float)):
        return dataclasses.replace(ab, y=float(value))
    if field == "width" and isinstance(value, (int, float)):
        return dataclasses.replace(ab, width=float(value))
    if field == "height" and isinstance(value, (int, float)):
        return dataclasses.replace(ab, height=float(value))
    if field == "fill" and isinstance(value, str):
        return dataclasses.replace(ab, fill=value)
    if field == "show_center_mark" and isinstance(value, bool):
        return dataclasses.replace(ab, show_center_mark=value)
    if field == "show_cross_hairs" and isinstance(value, bool):
        return dataclasses.replace(ab, show_cross_hairs=value)
    if field == "show_video_safe_areas" and isinstance(value, bool):
        return dataclasses.replace(ab, show_video_safe_areas=value)
    if field == "video_ruler_pixel_aspect_ratio" and isinstance(value, (int, float)):
        return dataclasses.replace(
            ab, video_ruler_pixel_aspect_ratio=float(value)
        )
    return ab


def _mint_artboard_id(existing_ids: set) -> str:
    """Generate a fresh artboard id with collision retry (100 attempts).
    Returns empty string on exhaustion (caller no-ops)."""
    for _ in range(100):
        c = generate_artboard_id()
        if c not in existing_ids:
            return c
    return ""


def _move_up(artboards: tuple, selected_ids: list) -> tuple[tuple, bool]:
    """Swap-with-neighbor-skipping-selected for Move Up.
    Returns (new_tuple, changed)."""
    selected = set(selected_ids)
    out = list(artboards)
    changed = False
    for i in range(len(out)):
        if out[i].id not in selected:
            continue
        if i == 0:
            continue
        if out[i - 1].id in selected:
            continue
        out[i - 1], out[i] = out[i], out[i - 1]
        changed = True
    return tuple(out), changed


def _move_down(artboards: tuple, selected_ids: list) -> tuple[tuple, bool]:
    """Symmetric — iterate bottom-up."""
    selected = set(selected_ids)
    out = list(artboards)
    changed = False
    n = len(out)
    for i in range(n - 1, -1, -1):
        if out[i].id not in selected:
            continue
        if i + 1 >= n:
            continue
        if out[i + 1].id in selected:
            continue
        out[i], out[i + 1] = out[i + 1], out[i]
        changed = True
    return tuple(out), changed


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
        overrides: dict = {}
        if isinstance(spec, dict):
            for k, v in spec.items():
                if isinstance(v, str):
                    r = evaluate(v, call_ctx)
                    overrides[k] = r.value
                else:
                    overrides[k] = v
        existing = {a.id for a in model.document.artboards}
        new_id = _mint_artboard_id(existing)
        if not new_id:
            return None
        default_name = next_artboard_name(model.document.artboards)
        ab = Artboard.default_with_id(new_id)
        ab = dataclasses.replace(ab, name=default_name)
        for field, value in overrides.items():
            ab = _apply_artboard_override(ab, field, value)
        new_artboards = model.document.artboards + (ab,)
        model.document = dataclasses.replace(
            model.document, artboards=new_artboards
        )
        return new_id

    def doc_delete_artboard_by_id(value, call_ctx, _store):
        id_expr = value if isinstance(value, str) else ""
        r = evaluate(id_expr, call_ctx)
        if r.type.name != "STRING":
            return None
        target = r.value
        new_artboards = tuple(
            a for a in model.document.artboards if a.id != target
        )
        if len(new_artboards) != len(model.document.artboards):
            model.document = dataclasses.replace(
                model.document, artboards=new_artboards
            )
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
        source = next(
            (a for a in model.document.artboards if a.id == target), None
        )
        if source is None:
            return None
        existing = {a.id for a in model.document.artboards}
        new_id = _mint_artboard_id(existing)
        if not new_id:
            return None
        dup_name = next_artboard_name(model.document.artboards)
        dup = dataclasses.replace(
            source,
            id=new_id,
            name=dup_name,
            x=source.x + ox,
            y=source.y + oy,
        )
        new_artboards = model.document.artboards + (dup,)
        model.document = dataclasses.replace(
            model.document, artboards=new_artboards
        )
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
        target = id_val.value
        new_artboards = tuple(
            _apply_artboard_override(a, field, value) if a.id == target else a
            for a in model.document.artboards
        )
        model.document = dataclasses.replace(
            model.document, artboards=new_artboards
        )
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
        opts = model.document.artboard_options
        if field == "fade_region_outside_artboard":
            new_opts = dataclasses.replace(
                opts, fade_region_outside_artboard=value
            )
        elif field == "update_while_dragging":
            new_opts = dataclasses.replace(opts, update_while_dragging=value)
        else:
            return None
        model.document = dataclasses.replace(
            model.document, artboard_options=new_opts
        )
        return None

    def doc_move_artboards_up(value, call_ctx, _store):
        ids_expr = value if isinstance(value, str) else ""
        r = evaluate(ids_expr, call_ctx)
        ids = _extract_id_list(r)
        new_artboards, changed = _move_up(model.document.artboards, ids)
        if changed:
            model.document = dataclasses.replace(
                model.document, artboards=new_artboards
            )
        return None

    def doc_move_artboards_down(value, call_ctx, _store):
        ids_expr = value if isinstance(value, str) else ""
        r = evaluate(ids_expr, call_ctx)
        ids = _extract_id_list(r)
        new_artboards, changed = _move_down(model.document.artboards, ids)
        if changed:
            model.document = dataclasses.replace(
                model.document, artboards=new_artboards
            )
        return None

    # PRINT.md §1A
    def doc_set_document_setup_field(spec, call_ctx, _store):
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
        s = model.document.document_setup
        bleed_fields = {
            "bleed_top", "bleed_right", "bleed_bottom", "bleed_left",
        }
        bool_fields = {
            "bleed_uniform", "show_images_outline", "highlight_substituted_glyphs",
        }
        if field in bleed_fields:
            if not isinstance(value, (int, float)):
                return None
            new_s = dataclasses.replace(s, **{field: float(value)})
        elif field in bool_fields:
            if not isinstance(value, bool):
                return None
            new_s = dataclasses.replace(s, **{field: value})
        else:
            return None
        model.document = dataclasses.replace(model.document, document_setup=new_s)
        return None

    # PRINT.md §1B
    def doc_set_print_preferences_field(spec, call_ctx, _store):
        from document.print_preferences import (
            ArtboardRangeMode, MediaSize, Orientation, PrintLayers, ScalingMode,
            _enum_from_string,
        )
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
        p = model.document.print_preferences
        # Field → (expected python type or enum class, optional cast).
        if field in {"copies"}:
            if not isinstance(value, (int, float)):
                return None
            new_p = dataclasses.replace(p, **{field: max(0, int(value))})
        elif field in {"media_width", "media_height", "placement_x", "placement_y",
                       "custom_scale", "tile_overlap_h", "tile_overlap_v"}:
            if not isinstance(value, (int, float)):
                return None
            new_p = dataclasses.replace(p, **{field: float(value)})
        elif field in {"collate", "reverse_order", "ignore_artboards",
                       "skip_blank_artboards", "auto_rotate", "transverse"}:
            if not isinstance(value, bool):
                return None
            new_p = dataclasses.replace(p, **{field: value})
        elif field in {"preset_name", "artboard_range", "tile_range"}:
            if not isinstance(value, str):
                return None
            new_p = dataclasses.replace(p, **{field: value})
        elif field == "printer_name":
            if value is None:
                new_p = dataclasses.replace(p, printer_name=None)
            elif isinstance(value, str):
                new_p = dataclasses.replace(
                    p, printer_name=value if value else None)
            else:
                return None
        elif field == "artboard_range_mode":
            if not isinstance(value, str):
                return None
            new_p = dataclasses.replace(p, artboard_range_mode=_enum_from_string(
                ArtboardRangeMode, value, p.artboard_range_mode))
        elif field == "media_size":
            if not isinstance(value, str):
                return None
            new_p = dataclasses.replace(p, media_size=_enum_from_string(
                MediaSize, value, p.media_size))
        elif field == "orientation":
            if not isinstance(value, str):
                return None
            new_p = dataclasses.replace(p, orientation=_enum_from_string(
                Orientation, value, p.orientation))
        elif field == "print_layers":
            if not isinstance(value, str):
                return None
            new_p = dataclasses.replace(p, print_layers=_enum_from_string(
                PrintLayers, value, p.print_layers))
        elif field == "scaling_mode":
            if not isinstance(value, str):
                return None
            new_p = dataclasses.replace(p, scaling_mode=_enum_from_string(
                ScalingMode, value, p.scaling_mode))
        else:
            return None
        model.document = dataclasses.replace(
            model.document, print_preferences=new_p)
        return None

    # PRINT.md §Phase 2
    def doc_set_marks_and_bleed_field(spec, call_ctx, _store):
        from document.print_preferences import (
            PrinterMarkType, _enum_from_string,
        )
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
        p = model.document.print_preferences
        m = p.marks_and_bleed
        if field in {"all_printer_marks", "trim_marks", "registration_marks",
                     "color_bars", "page_information", "use_document_bleed"}:
            if not isinstance(value, bool):
                return None
            new_m = dataclasses.replace(m, **{field: value})
        elif field in {"trim_mark_weight", "mark_offset",
                       "bleed_top", "bleed_right", "bleed_bottom", "bleed_left"}:
            if not isinstance(value, (int, float)):
                return None
            new_m = dataclasses.replace(m, **{field: float(value)})
        elif field == "printer_mark_type":
            if not isinstance(value, str):
                return None
            new_m = dataclasses.replace(m, printer_mark_type=_enum_from_string(
                PrinterMarkType, value, m.printer_mark_type))
        else:
            return None
        new_p = dataclasses.replace(p, marks_and_bleed=new_m)
        model.document = dataclasses.replace(
            model.document, print_preferences=new_p)
        return None

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
        "doc.move_artboards_up": doc_move_artboards_up,
        "doc.move_artboards_down": doc_move_artboards_down,
        "geometry.export_pdf": geometry_export_pdf,
    }
