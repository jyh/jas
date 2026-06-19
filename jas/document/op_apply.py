"""The single op dispatcher — ``op_apply`` (OP_LOG.md §4 / §9, Increment 3b-B).

STAGED-ASTERISK: this is the promoted, production-shared form of what was the
``cross_language_test._apply_op`` dispatcher. It is the §4 single-path end-state
built in the increment that needs it. In 3b-B it is adopted from production for
**exactly three replay-safe verbs** — ``select_rect``, ``copy_selection``, and
``move_selection`` — which are the ones ``capture_recipe`` consumes. Those three
populate ``targets:[common.id]`` (Fork 4); EVERY OTHER verb here keeps
``targets`` empty and is reachable only from the cross-language harness (which
shims through this module so harness + production share ONE dispatcher and ONE
``record_op`` site). The other ~30 ``doc.*`` production verbs, the AppState-level
duplicate handlers, the per-frame drag coalescing, and the full 33-verb
unification are explicitly deferred per OP_LOG.md §9.

Production input must never raise, so every param read is hardened: numbers
resolve via ``num_field`` (default 0.0); a missing REQUIRED field (a path, an id,
a transform) early-returns/skips rather than indexing. The harness fixtures
(which always carry well-formed params) replay byte-identically. Mirrors the
Rust ``jas_dioxus/src/document/op_apply.rs``.
"""

from __future__ import annotations

from typing import Any

from document.controller import Controller, selection_to_ids
from document.model import Model
from document.op_log import PrimitiveOp


def parse_path(v: Any) -> tuple[int, ...] | None:
    """Parse a JSON array of indices into an element path. Returns ``None`` if
    the field is absent or not an array of integers (a malformed production
    payload skips the op rather than raising)."""
    if not isinstance(v, list):
        return None
    out: list[int] = []
    for i in v:
        if isinstance(i, bool) or not isinstance(i, (int, float)):
            return None
        out.append(int(i))
    return tuple(out)


def str_field(op: dict, key: str) -> str | None:
    """Read a string field, or ``None`` if absent / not a string."""
    v = op.get(key)
    return v if isinstance(v, str) else None


def num_field(op: dict, key: str) -> float:
    """Read an f64 field, defaulting to 0.0 (the non-raising number form)."""
    v = op.get(key)
    if isinstance(v, bool):
        return float(v)
    if isinstance(v, (int, float)):
        return float(v)
    return 0.0


def bool_field(op: dict, key: str) -> bool:
    """Read a bool field, defaulting to False (the non-raising bool form)."""
    v = op.get(key)
    return v if isinstance(v, bool) else False


# ── Value coercion helpers (the non-raising "skip on type mismatch" reads) ──
#
# The P1-P7 verbs carry RESOLVED literals (replay has no eval context). A field
# whose value is the wrong JSON type SKIPS (the inline renderer blocks they
# replace also skipped), so each per-field arm reads through one of these and
# treats ``None`` as "field did not apply". JSON has no separate int/float, so a
# number arrives as int or float; ``_as_num`` accepts both but rejects bool
# (``isinstance(True, int)`` is True in Python, so the guard is explicit).

def _as_num(v: Any) -> float | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    return None


def _as_bool(v: Any) -> bool | None:
    return v if isinstance(v, bool) else None


def _as_str(v: Any) -> str | None:
    return v if isinstance(v, str) else None


def parse_path_list(v: Any) -> list[tuple[int, ...]] | None:
    """Parse a JSON array of index arrays (``[[..],..]``) into a list of paths.
    Returns ``None`` if the value is absent or not an array of arrays of
    non-negative integers (a malformed payload skips the op). An empty top-level
    array yields ``[]`` (the caller treats it as a journal-nothing no-op)."""
    if not isinstance(v, list):
        return None
    out: list[tuple[int, ...]] = []
    for item in v:
        inner = parse_path(item)
        if inner is None:
            return None
        out.append(inner)
    return out


def str_list_field(op: dict, key: str) -> list[str]:
    """Read a JSON array-of-strings field (the ``ids`` payload for the move
    verbs). Non-string entries are dropped; a missing/non-array field yields []."""
    v = op.get(key)
    if not isinstance(v, list):
        return []
    return [x for x in v if isinstance(x, str)]


# ── P1: print-config field setters (OP_LOG.md §9 Phase P1) ──────────────────
#
# The eight doc.* print-config verbs journal RESOLVED literals through ONE
# shared helper so production and replay mutate byte-identically. Each value is
# a literal (NOT a YAML expr); a type mismatch SKIPS the field (records nothing).
# Python's print structs are FROZEN dataclasses, so a write rebuilds the struct
# via ``dataclasses.replace`` rather than mutating in place — but the field-match
# + type-coerce set is arm-for-arm with the Rust ``apply_print_config_field``.
# Returns the new sub-record (or ``None`` to skip), so the dispatcher only
# records the op on a non-None result.

_PRINT_CONFIG_VERBS = frozenset({
    "set_color_management_field",
    "set_document_setup_field",
    "set_graphics_field",
    "set_marks_and_bleed_field",
    "set_output_field",
    "set_output_ink_field",
    "set_print_preferences_field",
    "set_advanced_field",
})


def apply_print_config_field(
    model: Model, verb: str, field: str, value: Any, index: int
) -> bool:
    """Apply one print-config field setter to ``model.document``. Returns
    ``True`` iff the field matched AND the value coerced (the caller records the
    op only on ``True``). Mirrors the Rust ``apply_print_config_field``."""
    import dataclasses
    from document import print_preferences as pp

    doc = model.document
    as_num = _as_num(value)
    as_bool = _as_bool(value)
    as_str = _as_str(value)

    def enum_or_none(enum_cls, s, default):
        # An enum field accepts only a string; the canonical-from helper maps an
        # unknown string to the default (matching the renderer's tolerance).
        return pp._enum_from_string(enum_cls, s, default) if s is not None else None

    if verb == "set_print_preferences_field":
        p = doc.print_preferences
        updates: dict | None = None
        if field == "preset_name":
            if as_str is not None: updates = {"preset_name": as_str}
        elif field == "printer_name":
            if as_str is not None:
                updates = {"printer_name": None if as_str == "" else as_str}
        elif field == "copies":
            if as_num is not None: updates = {"copies": max(0, int(as_num))}
        elif field == "collate":
            if as_bool is not None: updates = {"collate": as_bool}
        elif field == "reverse_order":
            if as_bool is not None: updates = {"reverse_order": as_bool}
        elif field == "artboard_range_mode":
            if as_str is not None:
                updates = {"artboard_range_mode": pp._enum_from_string(
                    pp.ArtboardRangeMode, as_str, p.artboard_range_mode)}
        elif field == "artboard_range":
            if as_str is not None: updates = {"artboard_range": as_str}
        elif field == "ignore_artboards":
            if as_bool is not None: updates = {"ignore_artboards": as_bool}
        elif field == "skip_blank_artboards":
            if as_bool is not None: updates = {"skip_blank_artboards": as_bool}
        elif field == "media_size":
            if as_str is not None:
                updates = {"media_size": pp._enum_from_string(
                    pp.MediaSize, as_str, p.media_size)}
        elif field == "media_width":
            if as_num is not None: updates = {"media_width": as_num}
        elif field == "media_height":
            if as_num is not None: updates = {"media_height": as_num}
        elif field == "orientation":
            if as_str is not None:
                updates = {"orientation": pp._enum_from_string(
                    pp.Orientation, as_str, p.orientation)}
        elif field == "auto_rotate":
            if as_bool is not None: updates = {"auto_rotate": as_bool}
        elif field == "transverse":
            if as_bool is not None: updates = {"transverse": as_bool}
        elif field == "print_layers":
            if as_str is not None:
                updates = {"print_layers": pp._enum_from_string(
                    pp.PrintLayers, as_str, p.print_layers)}
        elif field == "placement_x":
            if as_num is not None: updates = {"placement_x": as_num}
        elif field == "placement_y":
            if as_num is not None: updates = {"placement_y": as_num}
        elif field == "scaling_mode":
            if as_str is not None:
                updates = {"scaling_mode": pp._enum_from_string(
                    pp.ScalingMode, as_str, p.scaling_mode)}
        elif field == "custom_scale":
            if as_num is not None: updates = {"custom_scale": as_num}
        elif field == "tile_overlap_h":
            if as_num is not None: updates = {"tile_overlap_h": as_num}
        elif field == "tile_overlap_v":
            if as_num is not None: updates = {"tile_overlap_v": as_num}
        elif field == "tile_range":
            if as_str is not None: updates = {"tile_range": as_str}
        if updates is None:
            return False
        new_pp = dataclasses.replace(p, **updates)
        model.document = dataclasses.replace(doc, print_preferences=new_pp)
        return True

    if verb == "set_marks_and_bleed_field":
        m = doc.print_preferences.marks_and_bleed
        updates = None
        if field == "all_printer_marks":
            if as_bool is not None: updates = {"all_printer_marks": as_bool}
        elif field == "trim_marks":
            if as_bool is not None: updates = {"trim_marks": as_bool}
        elif field == "registration_marks":
            if as_bool is not None: updates = {"registration_marks": as_bool}
        elif field == "color_bars":
            if as_bool is not None: updates = {"color_bars": as_bool}
        elif field == "page_information":
            if as_bool is not None: updates = {"page_information": as_bool}
        elif field == "printer_mark_type":
            if as_str is not None:
                updates = {"printer_mark_type": pp._enum_from_string(
                    pp.PrinterMarkType, as_str, m.printer_mark_type)}
        elif field == "trim_mark_weight":
            if as_num is not None: updates = {"trim_mark_weight": as_num}
        elif field == "mark_offset":
            if as_num is not None: updates = {"mark_offset": as_num}
        elif field == "use_document_bleed":
            if as_bool is not None: updates = {"use_document_bleed": as_bool}
        elif field == "bleed_top":
            if as_num is not None: updates = {"bleed_top": as_num}
        elif field == "bleed_right":
            if as_num is not None: updates = {"bleed_right": as_num}
        elif field == "bleed_bottom":
            if as_num is not None: updates = {"bleed_bottom": as_num}
        elif field == "bleed_left":
            if as_num is not None: updates = {"bleed_left": as_num}
        if updates is None:
            return False
        new_m = dataclasses.replace(m, **updates)
        new_pp = dataclasses.replace(doc.print_preferences, marks_and_bleed=new_m)
        model.document = dataclasses.replace(doc, print_preferences=new_pp)
        return True

    if verb == "set_output_field":
        o = doc.print_preferences.output
        updates = None
        if field == "mode":
            if as_str is not None:
                updates = {"mode": pp._enum_from_string(pp.OutputMode, as_str, o.mode)}
        elif field == "emulsion":
            if as_str is not None:
                updates = {"emulsion": pp._enum_from_string(pp.Emulsion, as_str, o.emulsion)}
        elif field == "image_polarity":
            if as_str is not None:
                updates = {"image_polarity": pp._enum_from_string(
                    pp.ImagePolarity, as_str, o.image_polarity)}
        elif field == "printer_resolution":
            if as_str is not None: updates = {"printer_resolution": as_str}
        elif field == "convert_spot_to_process":
            if as_bool is not None: updates = {"convert_spot_to_process": as_bool}
        elif field == "overprint_black":
            if as_bool is not None: updates = {"overprint_black": as_bool}
        if updates is None:
            return False
        new_o = dataclasses.replace(o, **updates)
        new_pp = dataclasses.replace(doc.print_preferences, output=new_o)
        model.document = dataclasses.replace(doc, print_preferences=new_pp)
        return True

    if verb == "set_output_ink_field":
        o = doc.print_preferences.output
        if index < 0 or index >= len(o.inks):
            return False
        ink = o.inks[index]
        updates = None
        if field == "print":
            if as_bool is not None: updates = {"print": as_bool}
        elif field == "frequency":
            if as_num is not None: updates = {"frequency": as_num}
        elif field == "angle":
            if as_num is not None: updates = {"angle": as_num}
        elif field == "dot_shape":
            if as_str is not None:
                updates = {"dot_shape": pp._enum_from_string(
                    pp.DotShape, as_str, ink.dot_shape)}
        elif field == "name":
            if as_str is not None: updates = {"name": as_str}
        if updates is None:
            return False
        new_ink = dataclasses.replace(ink, **updates)
        new_inks = o.inks[:index] + (new_ink,) + o.inks[index + 1:]
        new_o = dataclasses.replace(o, inks=new_inks)
        new_pp = dataclasses.replace(doc.print_preferences, output=new_o)
        model.document = dataclasses.replace(doc, print_preferences=new_pp)
        return True

    if verb == "set_graphics_field":
        g = doc.print_preferences.graphics
        updates = None
        if field == "flatness":
            if as_num is not None: updates = {"flatness": as_num}
        elif field == "font_download":
            if as_str is not None:
                updates = {"font_download": pp._enum_from_string(
                    pp.FontDownload, as_str, g.font_download)}
        elif field == "postscript_level":
            if as_str is not None:
                updates = {"postscript_level": pp._enum_from_string(
                    pp.PostScriptLevel, as_str, g.postscript_level)}
        elif field == "data_format":
            if as_str is not None:
                updates = {"data_format": pp._enum_from_string(
                    pp.DataFormat, as_str, g.data_format)}
        elif field == "compatible_gradient_printing":
            if as_bool is not None: updates = {"compatible_gradient_printing": as_bool}
        elif field == "raster_effects_resolution":
            if as_num is not None: updates = {"raster_effects_resolution": as_num}
        if updates is None:
            return False
        new_g = dataclasses.replace(g, **updates)
        new_pp = dataclasses.replace(doc.print_preferences, graphics=new_g)
        model.document = dataclasses.replace(doc, print_preferences=new_pp)
        return True

    if verb == "set_color_management_field":
        c = doc.print_preferences.color_management
        updates = None
        if field == "document_profile":
            if as_str is not None: updates = {"document_profile": as_str}
        elif field == "color_handling":
            if as_str is not None:
                updates = {"color_handling": pp._enum_from_string(
                    pp.ColorHandling, as_str, c.color_handling)}
        elif field == "printer_profile":
            if as_str is not None: updates = {"printer_profile": as_str}
        elif field == "rendering_intent":
            if as_str is not None:
                updates = {"rendering_intent": pp._enum_from_string(
                    pp.RenderingIntent, as_str, c.rendering_intent)}
        elif field == "preserve_rgb_numbers":
            if as_bool is not None: updates = {"preserve_rgb_numbers": as_bool}
        if updates is None:
            return False
        new_c = dataclasses.replace(c, **updates)
        new_pp = dataclasses.replace(doc.print_preferences, color_management=new_c)
        model.document = dataclasses.replace(doc, print_preferences=new_pp)
        return True

    if verb == "set_advanced_field":
        a = doc.print_preferences.advanced
        updates = None
        if field == "print_as_bitmap":
            if as_bool is not None: updates = {"print_as_bitmap": as_bool}
        elif field == "overprint_flattener_preset":
            if as_str is not None:
                updates = {"overprint_flattener_preset": pp._enum_from_string(
                    pp.FlattenerPreset, as_str, a.overprint_flattener_preset)}
        if updates is None:
            return False
        new_a = dataclasses.replace(a, **updates)
        new_pp = dataclasses.replace(doc.print_preferences, advanced=new_a)
        model.document = dataclasses.replace(doc, print_preferences=new_pp)
        return True

    if verb == "set_document_setup_field":
        d = doc.document_setup
        updates = None
        if field == "bleed_top":
            if as_num is not None: updates = {"bleed_top": as_num}
        elif field == "bleed_right":
            if as_num is not None: updates = {"bleed_right": as_num}
        elif field == "bleed_bottom":
            if as_num is not None: updates = {"bleed_bottom": as_num}
        elif field == "bleed_left":
            if as_num is not None: updates = {"bleed_left": as_num}
        elif field == "bleed_uniform":
            if as_bool is not None: updates = {"bleed_uniform": as_bool}
        elif field == "show_images_outline":
            if as_bool is not None: updates = {"show_images_outline": as_bool}
        elif field == "highlight_substituted_glyphs":
            if as_bool is not None: updates = {"highlight_substituted_glyphs": as_bool}
        elif field == "simulate_colored_paper":
            if as_bool is not None: updates = {"simulate_colored_paper": as_bool}
        elif field == "discard_white_overprint":
            if as_bool is not None: updates = {"discard_white_overprint": as_bool}
        elif field == "grid_size":
            if as_num is not None: updates = {"grid_size": as_num}
        elif field == "grid_color":
            if as_str is not None: updates = {"grid_color": as_str}
        elif field == "paper_color":
            if as_str is not None: updates = {"paper_color": as_str}
        elif field == "transparency_flattener_preset":
            if as_str is not None:
                updates = {"transparency_flattener_preset": pp._enum_from_string(
                    pp.FlattenerPreset, as_str, d.transparency_flattener_preset)}
        if updates is None:
            return False
        new_d = dataclasses.replace(d, **updates)
        model.document = dataclasses.replace(doc, document_setup=new_d)
        return True

    return False


# ── P2/P3: artboard verbs (OP_LOG.md §9 Phases P2-P3) ───────────────────────
#
# Artboards live in ``document.artboards`` (String ids), NOT the element tree.
# Each carries RESOLVED literals; the id-minting verbs (create/duplicate) read
# the already-minted id VERBATIM and NEVER mint / tap entropy / collision-retry
# on replay (VALUE-IN-OP). A no-op edit (type mismatch / missing id / boundary
# swap / missing source) journals nothing. Mirrors the Rust artboard helpers.

_ARTBOARD_FIELD_TYPES = {
    "name": "str", "x": "num", "y": "num", "width": "num", "height": "num",
    "fill": "str", "show_center_mark": "bool", "show_cross_hairs": "bool",
    "show_video_safe_areas": "bool", "video_ruler_pixel_aspect_ratio": "num",
}


def _artboard_field_update(field: str, value: Any) -> dict | None:
    """Coerce one RESOLVED artboard field literal to a replace-kwargs dict, or
    ``None`` on a type mismatch / unknown field. The field set + types mirror the
    Rust ``apply_set_artboard_field`` / ``apply_artboard_field_in_place``."""
    kind = _ARTBOARD_FIELD_TYPES.get(field)
    if kind is None:
        return None
    if kind == "num":
        n = _as_num(value)
        return {field: n} if n is not None else None
    if kind == "bool":
        b = _as_bool(value)
        return {field: b} if b is not None else None
    # str (name / fill — fill stays a plain string in this app, matching
    # ArtboardFill = str).
    s = _as_str(value)
    return {field: s} if s is not None else None


def apply_set_artboard_field(model: Model, id: str, field: str, value: Any) -> bool:
    """Apply one field of one artboard (by id). Returns ``True`` iff the artboard
    exists AND the field matched AND the value coerced. Mirrors the Rust
    ``apply_set_artboard_field``."""
    import dataclasses
    doc = model.document
    idx = next((i for i, a in enumerate(doc.artboards) if a.id == id), None)
    if idx is None:
        return False
    updates = _artboard_field_update(field, value)
    if updates is None:
        return False
    new_ab = dataclasses.replace(doc.artboards[idx], **updates)
    new_abs = doc.artboards[:idx] + (new_ab,) + doc.artboards[idx + 1:]
    model.document = dataclasses.replace(doc, artboards=new_abs)
    return True


def apply_set_artboard_options_field(model: Model, field: str, value: Any) -> bool:
    """Apply one document-global artboard-options field (bool only). Returns
    ``True`` iff the field matched and the value coerced to a bool."""
    import dataclasses
    b = _as_bool(value)
    if b is None:
        return False
    if field not in ("fade_region_outside_artboard", "update_while_dragging"):
        return False
    new_opts = dataclasses.replace(model.document.artboard_options, **{field: b})
    model.document = dataclasses.replace(model.document, artboard_options=new_opts)
    return True


def apply_delete_artboard_by_id(model: Model, id: str) -> bool:
    """Delete the artboard whose id == ``id``. Returns ``True`` iff one was
    removed (a missing id is a journal-nothing no-op)."""
    import dataclasses
    doc = model.document
    new_abs = tuple(a for a in doc.artboards if a.id != id)
    if len(new_abs) == len(doc.artboards):
        return False
    model.document = dataclasses.replace(doc, artboards=new_abs)
    return True


def _move_artboards_in_place(artboards: list, selected_ids: list[str], down: bool) -> bool:
    """Swap-with-neighbor-skipping-selected for Move Up/Down (ARTBOARDS.md
    §Reordering), in place on the list. Returns ``True`` iff any swap occurred.
    Mirrors the Rust ``move_artboards_up_in_place`` / ``_down_in_place``."""
    selected = set(selected_ids)
    changed = False
    n = len(artboards)
    indices = range(n - 1, -1, -1) if down else range(n)
    for i in indices:
        if artboards[i].id not in selected:
            continue
        nbr = i + 1 if down else i - 1
        if nbr < 0 or nbr >= n:
            continue
        if artboards[nbr].id in selected:
            continue
        artboards[i], artboards[nbr] = artboards[nbr], artboards[i]
        changed = True
    return changed


def apply_move_artboards(model: Model, ids: list[str], down: bool) -> bool:
    """Apply Move Up/Down to ``model``'s artboards. Returns ``True`` iff any
    swap occurred."""
    import dataclasses
    abs_list = list(model.document.artboards)
    if not _move_artboards_in_place(abs_list, ids, down):
        return False
    model.document = dataclasses.replace(model.document, artboards=tuple(abs_list))
    return True


def apply_create_artboard(model: Model, id: str, fields: Any) -> None:
    """Append a new artboard with the GIVEN (already-minted) ``id``, applying the
    RESOLVED ``fields`` overrides. ``id`` is taken VERBATIM — no minting, no
    collision-retry, no entropy. A type mismatch on any field SKIPS that field.
    Always an effective change. Mirrors the Rust ``apply_create_artboard``."""
    import dataclasses
    from document.artboard import Artboard
    ab = Artboard.default_with_id(id)
    if isinstance(fields, dict):
        updates: dict = {}
        for field, value in fields.items():
            u = _artboard_field_update(field, value)
            if u is not None:
                updates.update(u)
        if updates:
            ab = dataclasses.replace(ab, **updates)
    model.document = dataclasses.replace(
        model.document, artboards=model.document.artboards + (ab,))


def apply_duplicate_artboard(
    model: Model, source_id: str, new_id: str, name: str, ox: float, oy: float
) -> bool:
    """Clone the artboard ``source_id``, assign the GIVEN ``new_id`` and ``name``
    VERBATIM, and offset by ``(ox, oy)``. Returns ``True`` iff the source existed
    (a missing source is a journal-nothing no-op). Mirrors the Rust
    ``apply_duplicate_artboard``."""
    import dataclasses
    doc = model.document
    source = next((a for a in doc.artboards if a.id == source_id), None)
    if source is None:
        return False
    dup = dataclasses.replace(
        source, id=new_id, name=name, x=source.x + ox, y=source.y + oy)
    model.document = dataclasses.replace(doc, artboards=doc.artboards + (dup,))
    return True


# ── P4/P5: structural + wrapping verbs (OP_LOG.md §9 Phases P4-P5) ──────────
#
# These mutate the ELEMENT TREE. The inserting verbs use VALUE-IN-OP at full
# strength: the op carries the WHOLE element as LITERAL serde JSON, deserialized
# on replay and inserted byte-identically (the clone keeps whatever id it had).
# Python has no derived Codable for the externally-tagged ``Element``, so
# ``parse_element`` converts the Rust serde shape (``{"Rect":{...}}``) to the
# canonical test_json flat dict the existing ``parse_element_json`` consumes,
# then delegates. The wrapping verbs are MULTI-STEP (collect, reverse-delete,
# build container, insert) replayed as ONE op. Mirrors the Rust P4/P5 helpers.


def _serde_color_to_test_json(v: Any) -> dict | None:
    """Rust serde Color (``{"Rgb":{r,g,b,a}}``) -> test_json flat (``{r,g,b,a,
    space}``)."""
    if not isinstance(v, dict) or len(v) != 1:
        return None
    tag, body = next(iter(v.items()))
    if not isinstance(body, dict):
        return None
    space = {"Rgb": "rgb", "Hsb": "hsb", "Cmyk": "cmyk"}.get(tag)
    if space is None:
        return None
    out = dict(body)
    out["space"] = space
    return out


def _serde_fill_to_test_json(v: Any) -> dict | None:
    if not isinstance(v, dict):
        return None
    out: dict = {}
    color = _serde_color_to_test_json(v.get("color"))
    if color is not None:
        out["color"] = color
    out["opacity"] = v.get("opacity")
    return out


def _serde_stroke_to_test_json(v: Any) -> dict | None:
    if not isinstance(v, dict):
        return None
    out: dict = {}
    color = _serde_color_to_test_json(v.get("color"))
    if color is not None:
        out["color"] = color
    out["width"] = v.get("width")
    if isinstance(v.get("linecap"), str):
        out["linecap"] = v["linecap"]
    if isinstance(v.get("linejoin"), str):
        out["linejoin"] = v["linejoin"]
    out["opacity"] = v.get("opacity")
    return out


def _serde_common_to_test_json(common: Any) -> dict:
    """Rust serde ``common`` block -> the test_json flat common fields the
    ``_parse_common`` reader consumes (locked / opacity / transform / visibility
    / name / id). serde Visibility is PascalCase; test_json wants lowercase."""
    d: dict = {}
    if not isinstance(common, dict):
        return d
    d["opacity"] = common.get("opacity")
    d["locked"] = common.get("locked")
    v = common.get("visibility")
    if isinstance(v, str):
        d["visibility"] = v.lower()
    d["transform"] = common.get("transform")  # null or {a..f} (same shape)
    if "name" in common:
        d["name"] = common.get("name")
    if "id" in common:
        d["id"] = common.get("id")
    return d


def _serde_element_to_test_json(el: Any) -> dict | None:
    """Rust serde externally-tagged element JSON (``{"Rect":{...}}``,
    ``{"Layer":{...}}``, ``{"Group":{...}}``) -> the canonical test_json flat
    dict. Returns ``None`` for an unrecognized variant tag (a malformed payload
    skips the op). Only the variants the shared structural fixtures carry are
    mapped (Rect, Layer, Group + nested children). Mirrors the Swift
    ``serdeElementToTestJson``."""
    if not isinstance(el, dict) or len(el) != 1:
        return None
    tag, fields = next(iter(el.items()))
    if not isinstance(fields, dict):
        return None
    if tag == "Rect":
        d = _serde_common_to_test_json(fields.get("common"))
        d["type"] = "rect"
        for k in ("x", "y", "width", "height", "rx", "ry"):
            d[k] = fields.get(k)
        fill = _serde_fill_to_test_json(fields.get("fill"))
        d["fill"] = fill  # None ⇒ null fill (parsed as None)
        d["stroke"] = _serde_stroke_to_test_json(fields.get("stroke"))
        return d
    if tag in ("Layer", "Group"):
        d = _serde_common_to_test_json(fields.get("common"))
        d["type"] = "layer" if tag == "Layer" else "group"
        d["children"] = _serde_children_to_test_json(fields.get("children"))
        return d
    return None


def _serde_children_to_test_json(v: Any) -> list:
    if not isinstance(v, list):
        return []
    out = []
    for c in v:
        conv = _serde_element_to_test_json(c)
        if conv is not None:
            out.append(conv)
    return out


def parse_element(op: dict):
    """Deserialize the ``element`` op param (Rust serde externally-tagged JSON)
    into an Element. Returns ``None`` if the field is absent or is not a
    recognized variant (a malformed payload skips the op). Mirrors the Rust
    ``parse_element`` (serde_json::from_value) via the Swift conversion strategy."""
    from geometry.test_json import parse_element_json
    el = op.get("element")
    conv = _serde_element_to_test_json(el)
    if conv is None:
        return None
    try:
        return parse_element_json(conv)
    except Exception:
        return None


def _element_id(el) -> str | None:
    return getattr(el, "id", None)


def insert_element_at(model: Model, parent_path: tuple[int, ...], index: int, element) -> list[str]:
    """Insert ``element`` at ``index`` under ``parent_path`` (an empty
    ``parent_path`` inserts into the top-level ``layers`` array). The element is
    taken VERBATIM (value-in-op). Returns the inserted element's id (if any) for
    targets. Mirrors the Rust ``apply_insert_element_at``."""
    import dataclasses
    targets = [eid] if (eid := _element_id(element)) is not None else []
    doc = model.document
    if not parent_path:
        idx = min(index, len(doc.layers))
        new_layers = doc.layers[:idx] + (element,) + doc.layers[idx:]
        model.document = dataclasses.replace(doc, layers=new_layers)
    else:
        # Build the full path to the insertion slot, then reuse the Document's
        # insert-at-path semantics (insert BEFORE the element currently there).
        insert_path = parent_path + (index,)
        model.document = _document_insert_element_at(doc, insert_path, element)
    return targets


def _document_insert_element_at(doc, path: tuple[int, ...], element):
    """Insert ``element`` BEFORE the position ``path`` (the slot the new element
    will occupy). Top-level inserts go into ``layers``; nested inserts recurse
    into the group at ``path[:-1]``. Mirrors the Rust ``Document::
    insert_element_at`` (the renderer's insert-at-path body)."""
    import dataclasses
    from geometry.element import Group
    if len(path) == 1:
        idx = min(path[0], len(doc.layers))
        new_layers = doc.layers[:idx] + (element,) + doc.layers[idx:]
        return dataclasses.replace(doc, layers=new_layers)

    def insert_in_group(node, rest):
        children = list(node.children)
        if len(rest) == 1:
            idx = min(rest[0], len(children))
            children.insert(idx, element)
        else:
            child = children[rest[0]]
            children[rest[0]] = insert_in_group(child, rest[1:])
        return dataclasses.replace(node, children=tuple(children))

    new_layers = list(doc.layers)
    new_layers[path[0]] = insert_in_group(doc.layers[path[0]], path[1:])
    return dataclasses.replace(doc, layers=tuple(new_layers))


def apply_delete_element_at(model: Model, path: tuple[int, ...]) -> tuple[bool, list[str]]:
    """Delete the element at ``path``. Returns ``(changed, targets)``: ``changed``
    is ``False`` (no-op, journals nothing) when ``path`` resolves to nothing.
    Mirrors the Rust ``apply_delete_element_at``."""
    doc = model.document
    try:
        existing = doc.get_element(path)
    except (ValueError, IndexError, KeyError):
        return (False, [])
    targets = [eid] if (eid := _element_id(existing)) is not None else []
    model.document = doc.delete_element(path)
    return (True, targets)


def apply_delete_selection(model: Model) -> tuple[bool, list[str]]:
    """Delete every selected element. Returns the pre-deletion selection ids and
    ``True`` iff the selection was non-empty. Mirrors the Rust
    ``apply_delete_selection``."""
    doc = model.document
    if not doc.selection:
        return (False, [])
    targets = selection_to_ids(doc)
    model.document = doc.delete_selection()
    return (True, targets)


def apply_insert_element_after(model: Model, path: tuple[int, ...], element) -> list[str]:
    """Insert ``element`` immediately after ``path`` (value-in-op). Returns the
    inserted element's id (if any). Mirrors the Rust
    ``apply_insert_element_after``."""
    targets = [eid] if (eid := _element_id(element)) is not None else []
    model.document = model.document.insert_element_after(path, element)
    return targets


def _collect_children_for_wrap(doc, paths: list[tuple[int, ...]]):
    """Collect (in sorted document order) clones of the elements at ``paths``,
    their ids, and the sorted paths. A path that resolves to nothing is dropped.
    Mirrors the Rust ``collect_children_for_wrap``."""
    sorted_paths = sorted(paths)
    children = []
    ids: list[str] = []
    for p in sorted_paths:
        try:
            elem = doc.get_element(p)
        except (ValueError, IndexError, KeyError):
            continue
        eid = _element_id(elem)
        if eid is not None:
            ids.append(eid)
        children.append(elem)
    return children, ids, sorted_paths


def apply_wrap_in_group(model: Model, paths: list[tuple[int, ...]], id: str | None) -> tuple[bool, list[str]]:
    """Wrap the elements at ``paths`` in a new Group, inserted at the TOPMOST
    source index. Returns ``(changed, targets)``. Mirrors the Rust
    ``apply_wrap_in_group``."""
    from geometry.element import Group
    doc = model.document
    children, child_ids, sorted_paths = _collect_children_for_wrap(doc, paths)
    if not children:
        return (False, [])
    first = sorted_paths[0]
    if not first:
        return (False, [])
    insert_parent = first[:-1]
    insert_index = first[-1]
    new_doc = doc
    for p in reversed(sorted_paths):
        new_doc = new_doc.delete_element(p)
    group = Group(children=tuple(children), id=id)
    targets = list(child_ids)
    if id is not None:
        targets.append(id)
    if not insert_parent:
        idx = min(insert_index, len(new_doc.layers))
        new_layers = new_doc.layers[:idx] + (group,) + new_doc.layers[idx:]
        import dataclasses
        new_doc = dataclasses.replace(new_doc, layers=new_layers)
    else:
        new_doc = _document_insert_element_at(
            new_doc, insert_parent + (insert_index,), group)
    model.document = new_doc
    return (True, targets)


def apply_wrap_in_layer(model: Model, paths: list[tuple[int, ...]], name: str, id: str | None) -> tuple[bool, list[str]]:
    """Wrap the elements at ``paths`` in a new top-level Layer with the RESOLVED
    ``name`` literal (always APPENDED). Returns ``(changed, targets)``. Mirrors
    the Rust ``apply_wrap_in_layer``."""
    import dataclasses
    from geometry.element import Layer
    doc = model.document
    children, child_ids, sorted_paths = _collect_children_for_wrap(doc, paths)
    if not children:
        return (False, [])
    new_doc = doc
    for p in reversed(sorted_paths):
        new_doc = new_doc.delete_element(p)
    new_layer = Layer(children=tuple(children), name=name, id=id)
    targets = list(child_ids)
    if id is not None:
        targets.append(id)
    new_doc = dataclasses.replace(new_doc, layers=new_doc.layers + (new_layer,))
    model.document = new_doc
    return (True, targets)


def apply_unpack_group_at(model: Model, path: tuple[int, ...]) -> tuple[bool, list[str]]:
    """Unpack the Group at ``path``: extract its children, delete the group, and
    re-insert the children at the vacated position (children keep their ids — NO
    minting). A non-Group target (or absent path) is a journal-nothing no-op.
    Returns ``(changed, targets)``. Mirrors the Rust ``apply_unpack_group_at``."""
    from geometry.element import Group, Layer
    doc = model.document
    try:
        target = doc.get_element(path)
    except (ValueError, IndexError, KeyError):
        return (False, [])
    # Must be a Group (NOT a Layer — Layer is a Group subclass in this app).
    if not isinstance(target, Group) or isinstance(target, Layer):
        return (False, [])
    children = list(target.children)
    targets = [eid for c in children if (eid := _element_id(c)) is not None]
    new_doc = doc.delete_element(path)
    insert_path = list(path)
    for child in children:
        new_doc = _document_insert_element_at(new_doc, tuple(insert_path), child)
        insert_path[-1] += 1
    model.document = new_doc
    return (True, targets)


# ── P6: set_attr_on_selection (OP_LOG.md §9 Phase P6) ───────────────────────
#
# A Model-runner verb applying one attribute to every selected element through a
# Controller mutator. Phase 1 supports the two brush attributes only. The op
# carries the RESOLVED value literal: an empty string clears (None); an unknown
# attr or an absent value key SKIPS. Because the canonical no-op rule
# (commit_txn) is BLIND to stroke_brush (document_to_test_json omits it), a
# stroke_brush-only edit detects an effective change here via layers equality so
# an ineffective set journals nothing. Mirrors the Rust
# ``apply_set_attr_on_selection``.


def apply_set_attr_on_selection(model: Model, attr: str, value: str | None) -> tuple[bool, list[str]]:
    if attr not in ("stroke_brush", "stroke_brush_overrides"):
        return (False, [])
    targets = selection_to_ids(model.document)
    before = model.document.layers
    ctrl = Controller(model=model)
    if attr == "stroke_brush":
        ctrl.set_selection_stroke_brush(value)
    else:
        ctrl.set_selection_stroke_brush_overrides(value)
    changed = model.document.layers != before
    return (changed, targets)


# ── P7: the transform trio (scale / rotate / shear) (OP_LOG.md §9 Phase P7) ──
#
# Each journals the CONFIRM apply by recording one transform op carrying the
# RESOLVED matrix params. The matrix-application CORE composes the SAME
# transform_apply matrix against the selected element paths via the shared
# ``_compose_matrix_over_paths`` (pre-multiply matrix * existing), mirroring the
# production ``_apply_matrix_to_selection`` body exactly. An IDENTITY transform
# is a journal-nothing no-op. ``copy=true`` is handled by the dispatcher
# (journals ``copy_selection`` first). Mirrors the Rust P7 helpers.


def _compose_matrix_over_paths(doc, paths, matrix, stroke_factor, corners):
    """Compose ``matrix`` against every element at ``paths`` (pre-multiply the
    element's existing transform). When ``stroke_factor`` is set, multiply stroke
    width; when ``corners`` is set, scale rounded-rect rx/ry. Pure (no Model).
    Mirrors the production ``_apply_matrix_to_selection`` + the Rust
    ``compose_matrix_over_paths``."""
    import dataclasses
    from geometry.element import Rect as RectElem, Transform
    new_doc = doc
    for path in paths:
        try:
            elem = new_doc.get_element(path)
        except (ValueError, IndexError, KeyError):
            continue
        current = getattr(elem, "transform", None) or Transform()
        elem = dataclasses.replace(elem, transform=matrix.multiply(current))
        if stroke_factor is not None:
            stroke = getattr(elem, "stroke", None)
            if stroke is not None:
                elem = dataclasses.replace(
                    elem, stroke=dataclasses.replace(
                        stroke, width=stroke.width * stroke_factor))
        if corners is not None and isinstance(elem, RectElem):
            sx_abs, sy_abs = corners
            elem = dataclasses.replace(
                elem, rx=elem.rx * sx_abs, ry=elem.ry * sy_abs)
        new_doc = new_doc.replace_element(path, elem)
    return new_doc


def _selection_paths(doc) -> list[tuple[int, ...]]:
    return [es.path for es in sorted(doc.selection, key=lambda e: e.path)]


def apply_scale(model: Model, sx: float, sy: float, rx: float, ry: float,
                scale_strokes: bool, scale_corners: bool) -> tuple[bool, list[str]]:
    from jas.algorithms.transform_apply import scale_matrix, stroke_width_factor
    if abs(sx - 1.0) < 1e-9 and abs(sy - 1.0) < 1e-9:
        return (False, [])
    targets = selection_to_ids(model.document)
    matrix = scale_matrix(sx, sy, rx, ry)
    stroke_factor = stroke_width_factor(sx, sy) if scale_strokes else None
    corners = (abs(sx), abs(sy)) if scale_corners else None
    model.document = _compose_matrix_over_paths(
        model.document, _selection_paths(model.document), matrix,
        stroke_factor, corners)
    return (True, targets)


def apply_rotate(model: Model, theta_deg: float, rx: float, ry: float) -> tuple[bool, list[str]]:
    from jas.algorithms.transform_apply import rotate_matrix
    if abs(theta_deg) < 1e-9:
        return (False, [])
    targets = selection_to_ids(model.document)
    matrix = rotate_matrix(theta_deg, rx, ry)
    model.document = _compose_matrix_over_paths(
        model.document, _selection_paths(model.document), matrix, None, None)
    return (True, targets)


def apply_shear(model: Model, angle_deg: float, axis: str, axis_angle_deg: float,
                rx: float, ry: float) -> tuple[bool, list[str]]:
    from jas.algorithms.transform_apply import shear_matrix
    if abs(angle_deg) < 1e-9:
        return (False, [])
    targets = selection_to_ids(model.document)
    matrix = shear_matrix(angle_deg, axis, axis_angle_deg, rx, ry)
    model.document = _compose_matrix_over_paths(
        model.document, _selection_paths(model.document), matrix, None, None)
    return (True, targets)


# ── OP_LOG.md §5 Fork 4 / RECORDED_ELEMENTS.md — the id-primary op family ─────
#
# The id-primary verbs ``select_by_ids`` / ``move_by_ids`` / ``copy_by_ids``
# promote the recorded-recipe vocabulary (input-addressed, side-effect-free) to a
# first-class op family ``op_apply`` can execute, so a captured recipe IS a
# replayable journal segment (RECORDED_ELEMENTS.md §7) and ``capture_recipe``
# collapses to a pass-through. They are ADDITIVE: the selection-relative verbs
# (``select_rect`` / ``move_selection`` / ``copy_selection``) keep their params
# VERBATIM (OP_LOG.md §7 — selection is serialized Document state, so the
# byte-gate reproduces it); this is a NEW family, not a params rewrite. The
# decisive property (OP_LOG.md §7 determinism rule): the operand ids come from the
# OP'S OWN PARAMS, never inferred from ``doc.selection``, so snapshot and replay
# apply identical operands and a recorded recipe survives source edits with NO
# selection dependency.
#
# THE BYTE-GATE RECONCILIATION (OP_LOG.md §6, the gate compares
# document_to_test_json INCLUDING selection): the family is committed as the
# canonical PAIR ``[select_by_ids, <op>_by_ids]``, AND each ``<op>_by_ids`` ALSO
# re-establishes the working selection from its OWN ids before mutating. So the
# replayed selection is byte-identical to ``[select_rect, move_selection]`` for the
# same elements: ``select_by_ids`` resolves ids to paths and writes
# ``ElementSelection.all(path)`` in DOCUMENT ORDER (the same order
# ``_select_flat`` / ``select_rect`` produces), then the mutator routes through the
# SAME shared ``Controller`` body (no divergent second mutation path). Hardened
# reads: an unknown id / a non-array params is SKIPPED, never a panic.


def _id_paths_in_document_order(doc) -> list[tuple[str, tuple[int, ...]]]:
    """Walk the element tree (Group/Layer ``children`` only — the SAME descent
    discipline as the id-index builder ``geometry.live._collect_ref_ids``)
    collecting ``(id, path)`` for every id-bearing element, in DOCUMENT ORDER. The
    id-primary selection builder uses this so a ``select_by_ids`` produces the SAME
    ordered selection a ``select_rect`` over the same elements would — the
    byte-gate reconciliation. Top-level layer ids are NOT resolution targets
    (mirroring the id index), so the walk starts at each layer's children, exactly
    like ``resolver_from_document``. Mirrors the Rust
    ``id_paths_in_document_order``.
    """
    out: list[tuple[str, tuple[int, ...]]] = []

    def walk(elem, path: tuple[int, ...]) -> None:
        eid = _element_id(elem)
        if eid is not None:
            out.append((eid, path))
        children = getattr(elem, "children", None)
        if children is not None:
            for i, child in enumerate(children):
                walk(child, path + (i,))

    for li, layer in enumerate(doc.layers):
        children = getattr(layer, "children", None)
        if children is not None:
            for ci, child in enumerate(children):
                walk(child, (li, ci))
    return out


def _selection_for_ids(doc, ids: list[str]):
    """Build the selection (in DOCUMENT ORDER) for the elements whose ``id`` is in
    ``ids``, as ``ElementSelection.all(path)`` entries. Document order — NOT the
    order of ``ids`` — so the result is byte-identical to what ``select_rect``
    would produce for the same set (the byte-gate reconciliation). An id that
    resolves to no element is silently dropped (hardened: a stale/unknown id is a
    skip). Mirrors the Rust ``selection_for_ids``.
    """
    from document.document import ElementSelection
    wanted = set(ids)
    return frozenset(
        ElementSelection.all(path)
        for (eid, path) in _id_paths_in_document_order(doc)
        if eid in wanted
    )


def apply_select_by_ids(model: Model, ctrl: Controller, ids: list[str]) -> list[str]:
    """Resolve ``ids`` to their selection and write it BY PATH (selection-only,
    non-undoable — like ``select_rect``, this goes through the unbracketed
    selection write ``Controller.set_selection``). The id-primary ``select_by_ids``
    body, SHARED by the standalone ``select_by_ids`` op and by ``move_by_ids`` /
    ``copy_by_ids`` (which re-establish the working selection from their own ids
    before the mutation). Returns the resolved selection ids (in document order)
    for ``targets``. Mirrors the Rust ``apply_select_by_ids``.
    """
    ctrl.set_selection(_selection_for_ids(model.document, ids))
    return selection_to_ids(model.document)


def op_apply(model: Model, op: dict) -> None:
    """The single op dispatcher (OP_LOG.md §4). Applies one primitive op to the
    model and records it into the open transaction (the ``checkpoint_equivalence``
    gate, §5-6). History-navigation ops (``snapshot``/``undo``/``redo``) manage
    the transaction boundary / journal cursor and are NOT primitive ops, so they
    early-return WITHOUT being journaled. ``record_op`` is a no-op when no
    transaction is open, so this is safe to call unconditionally.
    """
    if not isinstance(op, dict):
        return
    name = op.get("op")
    if not isinstance(name, str):
        # A primitive op with no verb is malformed; skip it (never raise).
        return

    # History-navigation ops (OP_LOG.md §5): they manage transaction boundaries
    # / the journal cursor and are NOT primitive ops, so they are never
    # journaled. ``snapshot`` commits the prior action's transaction (relocated
    # redo-clear) and opens a new one, so the mutator ops that follow JOIN one
    # checkpoint; undo/redo end the open context and move the cursor.
    if name == "snapshot":
        model.commit_txn()
        model.begin_txn()
        return
    if name == "undo":
        model.undo()
        return
    if name == "redo":
        model.redo()
        return

    # OP_LOG.md §9 (Increment 3b-B) — close the subsequent-drag-frame journaling
    # hole. Every verb below except ``select_rect`` is an UNDOABLE mutation; in
    # this app the Controller methods mutate via ``replace()`` with NO txn
    # bracket and never self-bracket. On a bare drag frame (selection.yaml emits
    # ``doc.snapshot`` only on the FIRST mousemove), there is no self-commit to
    # close the txn early as there is in the self-bracketing apps, so the op
    # would simply never be recorded (no open transaction). Opening the
    # transaction HERE — and leaving it OPEN — makes ``record_op`` land the op,
    # and the batch owner (run_effects) names + commits the single transaction.
    # ``begin_txn`` is a no-op while one is already open, so the harness (which
    # always brackets around ``op_apply``) and the snapshot-led first frame are
    # byte-unchanged. ``select_rect`` is EXCLUDED: it only changes selection
    # (non-undoable, serialized state), so a bare marquee must stay
    # journal-neutral — opening a txn for it would spuriously journal a
    # selection-only batch as an undoable step. ``select_by_ids`` is the id-primary
    # twin (selection-only, non-undoable), so it is excluded for the identical
    # reason.
    if name not in ("select_rect", "select_by_ids") and not model.in_txn:
        model.begin_txn()

    ctrl = Controller(model=model)

    # Fork-4 ``targets`` (OP_LOG.md §9). Populated for the THREE replay-safe
    # verbs ``capture_recipe`` consumes; every other verb keeps it empty.
    # ``move_selection``/``copy_selection`` resolve the source ids BEFORE the
    # mutation (a copy is born id-less; a move can change which ids are selected
    # — pre-mutation avoids the post-mutation-id hazard). ``select_rect``
    # resolves AFTER its Controller call (the selection it just established IS
    # the keystone targets).
    targets: list[str] = []
    if name in ("move_selection", "copy_selection"):
        targets = selection_to_ids(model.document)

    # ── id-primary op family (OP_LOG.md §5 Fork 4 / RECORDED_ELEMENTS.md) ──
    # Operand ids come from the OP'S OWN PARAMS (never doc.selection), so snapshot
    # and replay apply identical operands (the §7 determinism rule). Each
    # ``*_by_ids`` re-establishes the working selection from its own ids (via the
    # SHARED ``apply_select_by_ids`` body) BEFORE routing through the SAME
    # ``Controller`` mutator the selection-relative verb uses, so the replayed
    # document+selection is byte-identical to ``[select_rect, move_selection]``
    # (the byte-gate reconciliation, OP_LOG.md §6).
    if name == "select_by_ids":
        # Selection-only / non-undoable (like select_rect): write the resolved
        # selection BY PATH in document order; targets = the resolved ids (the
        # keystone the recipe seeds its working set from).
        targets = apply_select_by_ids(model, ctrl, str_list_field(op, "ids"))
    elif name == "move_by_ids":
        # Set the working selection from the OP's ids, then run the SAME mutator
        # ``move_selection`` uses. targets = the operand ids (from params, resolved
        # to the selection) — never inferred post-mutation.
        targets = apply_select_by_ids(model, ctrl, str_list_field(op, "ids"))
        ctrl.move_selection(num_field(op, "dx"), num_field(op, "dy"))
    elif name == "copy_by_ids":
        # Set the working selection from the OP's ``from`` ids, then run the SAME
        # mutator ``copy_selection`` uses. targets = the source ids (the produced
        # copies are born id-less, so the source is the operand).
        targets = apply_select_by_ids(model, ctrl, str_list_field(op, "from"))
        ctrl.copy_selection(num_field(op, "dx"), num_field(op, "dy"))
    elif name == "select_rect":
        ctrl.select_rect(
            num_field(op, "x"),
            num_field(op, "y"),
            num_field(op, "width"),
            num_field(op, "height"),
            extend=bool_field(op, "extend"),
        )
        # Keystone: the resolved selection is this op's targets, so
        # ``capture_recipe`` can seed its working set (empty targets => empty
        # recipe). Resolved AFTER the Controller call.
        targets = selection_to_ids(model.document)
    elif name == "move_selection":
        ctrl.move_selection(num_field(op, "dx"), num_field(op, "dy"))
    elif name == "copy_selection":
        ctrl.copy_selection(num_field(op, "dx"), num_field(op, "dy"))
    elif name == "assign_id":
        path = parse_path(op.get("path"))
        id_ = str_field(op, "id")
        if path is None or id_ is None:
            return
        ctrl.assign_id(path, id_)
    elif name == "create_reference":
        target_path = parse_path(op.get("target_path"))
        target_id = str_field(op, "target_id")
        ref_id = str_field(op, "ref_id")
        if target_path is None or target_id is None or ref_id is None:
            return
        ctrl.create_reference(target_path, target_id, ref_id)
    elif name == "make_symbol":
        path = parse_path(op.get("path"))
        master_id = str_field(op, "master_id")
        ref_id = str_field(op, "ref_id")
        if path is None or master_id is None or ref_id is None:
            return
        ctrl.make_symbol(path, master_id, ref_id)
    elif name == "place_instance":
        master_id = str_field(op, "master_id")
        ref_id = str_field(op, "ref_id")
        if master_id is None or ref_id is None:
            return
        ctrl.place_instance(master_id, ref_id)
    elif name == "detach":
        path = parse_path(op.get("path"))
        if path is None:
            return
        ctrl.detach(path)
    elif name == "redefine":
        master_id = str_field(op, "master_id")
        path = parse_path(op.get("path"))
        ref_id = str_field(op, "ref_id")
        if master_id is None or path is None or ref_id is None:
            return
        ctrl.redefine(master_id, path, ref_id)
    elif name == "delete_symbol":
        master_id = str_field(op, "master_id")
        if master_id is None:
            return
        ctrl.delete_symbol(master_id)
    elif name == "set_instance_transform":
        from geometry.element import Transform
        path = parse_path(op.get("path"))
        t = op.get("transform")
        if path is None or not isinstance(t, dict):
            return
        ctrl.set_instance_transform(
            path,
            Transform(
                a=num_field(t, "a"), b=num_field(t, "b"),
                c=num_field(t, "c"), d=num_field(t, "d"),
                e=num_field(t, "e"), f=num_field(t, "f"),
            ),
        )
    elif name == "delete_at":
        # P4 structural tree-mutation. A missing/malformed path or an absent
        # element early-returns BEFORE record_op (a no-op journals nothing).
        path = parse_path(op.get("path"))
        if path is None:
            return
        changed, t = apply_delete_element_at(model, path)
        if not changed:
            return
        targets = t
    elif name == "delete_selection":
        # P4: the document's serialized selection IS the operand. An empty
        # selection is a no-op that journals nothing.
        changed, t = apply_delete_selection(model)
        if not changed:
            return
        targets = t
    elif name == "insert_after":
        # P4 value-in-op: the op carries the WHOLE element as serde JSON.
        path = parse_path(op.get("path"))
        element = parse_element(op)
        if path is None or element is None:
            return
        targets = apply_insert_element_after(model, path, element)
    elif name == "insert_at":
        parent_path = parse_path(op.get("parent_path"))
        element = parse_element(op)
        if parent_path is None or element is None:
            return
        idx_v = op.get("index")
        index = int(idx_v) if isinstance(idx_v, (int, float)) and not isinstance(idx_v, bool) else 0
        targets = insert_element_at(model, parent_path, index, element)
    elif name == "wrap_in_group":
        # P5 multi-step replayed as one op; optional value-in-op id.
        paths = parse_path_list(op.get("paths"))
        if paths is None or not paths:
            return
        changed, t = apply_wrap_in_group(model, paths, str_field(op, "id"))
        if not changed:
            return
        targets = t
    elif name == "wrap_in_layer":
        # P5: the name is a RESOLVED literal (replay never re-derives it).
        paths = parse_path_list(op.get("paths"))
        if paths is None or not paths:
            return
        name_lit = str_field(op, "name") or ""
        changed, t = apply_wrap_in_layer(model, paths, name_lit, str_field(op, "id"))
        if not changed:
            return
        targets = t
    elif name == "unpack_group_at":
        path = parse_path(op.get("path"))
        if path is None:
            return
        changed, t = apply_unpack_group_at(model, path)
        if not changed:
            return
        targets = t
    elif name == "set_attr_on_selection":
        # P6: a missing value key is a hard skip (no silent clear). When
        # present, an empty string clears (None); a non-empty string sets.
        attr = str_field(op, "attr")
        if attr is None:
            return
        if "value" not in op:
            return
        value_field = op.get("value")
        value = value_field if isinstance(value_field, str) and value_field != "" else None
        changed, t = apply_set_attr_on_selection(model, attr, value)
        if not changed:
            return
        targets = t
    elif name == "scale_transform":
        # P7: RESOLVED matrix params; identity is a journal-nothing no-op.
        scale_strokes = op["scale_strokes"] if isinstance(op.get("scale_strokes"), bool) else True
        scale_corners = op["scale_corners"] if isinstance(op.get("scale_corners"), bool) else False
        changed, t = apply_scale(
            model, num_field(op, "sx"), num_field(op, "sy"),
            num_field(op, "rx"), num_field(op, "ry"),
            scale_strokes, scale_corners)
        if not changed:
            return
        targets = t
    elif name == "rotate_transform":
        changed, t = apply_rotate(
            model, num_field(op, "angle"), num_field(op, "rx"), num_field(op, "ry"))
        if not changed:
            return
        targets = t
    elif name == "shear_transform":
        axis = str_field(op, "axis") or "horizontal"
        changed, t = apply_shear(
            model, num_field(op, "angle"), axis, num_field(op, "axis_angle"),
            num_field(op, "rx"), num_field(op, "ry"))
        if not changed:
            return
        targets = t
    elif name in _PRINT_CONFIG_VERBS:
        # P1: print-config field setters. A type-mismatch/unknown-field skip
        # mutates nothing AND records nothing (early-return before record_op).
        field = str_field(op, "field")
        if field is None or "value" not in op:
            return
        idx_v = op.get("index")
        index = int(idx_v) if isinstance(idx_v, (int, float)) and not isinstance(idx_v, bool) else 0
        if not apply_print_config_field(model, name, field, op.get("value"), index):
            return
    elif name == "set_artboard_field":
        # P2: each carries RESOLVED literals; a skip journals nothing.
        ab_id = str_field(op, "id")
        field = str_field(op, "field")
        if ab_id is None or field is None or "value" not in op:
            return
        if not apply_set_artboard_field(model, ab_id, field, op.get("value")):
            return
        targets = [ab_id]
    elif name == "set_artboard_options_field":
        field = str_field(op, "field")
        if field is None or "value" not in op:
            return
        if not apply_set_artboard_options_field(model, field, op.get("value")):
            return
    elif name == "delete_artboard_by_id":
        ab_id = str_field(op, "id")
        if ab_id is None:
            return
        if not apply_delete_artboard_by_id(model, ab_id):
            return
        targets = [ab_id]
    elif name == "move_artboards_up":
        ids = str_list_field(op, "ids")
        if not apply_move_artboards(model, ids, down=False):
            return
        targets = ids
    elif name == "move_artboards_down":
        ids = str_list_field(op, "ids")
        if not apply_move_artboards(model, ids, down=True):
            return
        targets = ids
    elif name == "create_artboard":
        # P3 VALUE-IN-OP: read the already-minted id VERBATIM (never mint).
        ab_id = str_field(op, "id")
        if not ab_id:
            return
        apply_create_artboard(model, ab_id, op.get("fields"))
        targets = [ab_id]
    elif name == "duplicate_artboard":
        source_id = str_field(op, "id")
        new_id = str_field(op, "new_id")
        if not source_id or not new_id:
            return
        name_lit = str_field(op, "name") or ""
        if not apply_duplicate_artboard(
                model, source_id, new_id, name_lit,
                num_field(op, "offset_x"), num_field(op, "offset_y")):
            return
        targets = [new_id]
    elif name == "lock_selection":
        ctrl.lock_selection()
    elif name == "unlock_all":
        ctrl.unlock_all()
    elif name == "hide_selection":
        ctrl.hide_selection()
    elif name == "show_all":
        ctrl.show_all()
    elif name == "boolean_union":
        from panels.boolean_apply import apply_destructive_boolean
        apply_destructive_boolean(model, "union")
    elif name == "simplify":
        precision = op.get("precision")
        precision = float(precision) if isinstance(precision, (int, float)) else 0.5
        ctrl.simplify_selection(precision)
    else:
        # Unknown verb: a malformed/unsupported production payload is skipped
        # rather than raising. (The harness corpus only carries known verbs, so
        # this never fires under test — the byte-gate would catch a typo.)
        return

    # Capture the op into the open transaction so the journal replays to the same
    # document — the checkpoint_equivalence gate (OP_LOG.md §5-6). ``targets``
    # (Fork 4) is populated above for the three replay-safe verbs; empty for
    # every other verb. ``record_op`` is a no-op when no transaction is open.
    model.record_op(PrimitiveOp(op=name, params=dict(op), targets=targets))
