"""Paragraph panel selection-driven state — Phase 3a.

Computes ``panel.text_selected`` and ``panel.area_text_selected``
from the current document selection so PARAGRAPH.md §Text-kind
gating ``bind.disabled`` expressions resolve to the live values
rather than the YAML defaults of true.

Mirrors the paragraph-panel block in the Rust dock_panel.rs
``build_live_panel_overrides``, the Swift
``paragraphPanelLiveOverrides``, and the OCaml
``Effects.sync_paragraph_panel_from_selection``.

Like the OCaml port, this function is currently unwired in the
Python app (no selection-change observer pumps it) — Phase 4
hooks it in alongside the panel→selection write pipeline.
"""

from __future__ import annotations

from geometry.element import Text, TextPath


def sync_paragraph_panel_from_selection(store, model) -> None:
    """Push ``text_selected`` and ``area_text_selected`` to the
    ``paragraph_panel_content`` panel scope.

    - ``text_selected`` — true when any selected element is a Text
      or TextPath.
    - ``area_text_selected`` — true when at least one text element
      is selected and every selected text element is area Text
      (Text with width > 0 and height > 0). Text-on-path counts as
      non-area; any non-area text in the selection makes this false.

    No-op when the model is None or when the panel scope has not
    been initialised — matches the OCaml ``set_panel`` semantics.
    """
    if model is None:
        return
    doc = getattr(model, "document", None)
    if doc is None:
        return

    any_text = False
    all_area = True
    wrappers = []
    for es in doc.selection:
        path = getattr(es, "path", None)
        if path is None:
            continue
        elem = doc.get_element(path)
        if isinstance(elem, Text):
            any_text = True
            if not (elem.width > 0 and elem.height > 0):
                all_area = False
            for t in elem.tspans:
                if t.jas_role == "paragraph":
                    wrappers.append(t)
        elif isinstance(elem, TextPath):
            any_text = True
            all_area = False

    text_selected = any_text
    area_text_selected = any_text and all_area
    store.set_panel("paragraph_panel_content", "text_selected", text_selected)
    store.set_panel("paragraph_panel_content", "area_text_selected", area_text_selected)

    # Phase 3c mixed-state aggregation. For each panel-surface
    # paragraph attribute we collect every wrapper's effective value
    # (the field value if set, else the type's default). If all
    # wrappers agree the agreed value flows to the matching panel
    # key; if they disagree the override is omitted so the panel
    # keeps its prior / YAML-default value.
    if not wrappers:
        return

    def _agree(values):
        """Return the single shared value when all entries are equal,
        else None. Empty list also returns None."""
        if not values:
            return None
        first = values[0]
        return first if all(v == first for v in values) else None

    li = _agree([w.jas_left_indent if w.jas_left_indent is not None else 0
                 for w in wrappers])
    if li is not None:
        store.set_panel("paragraph_panel_content", "left_indent", li)
    ri = _agree([w.jas_right_indent if w.jas_right_indent is not None else 0
                 for w in wrappers])
    if ri is not None:
        store.set_panel("paragraph_panel_content", "right_indent", ri)
    # Phase 1b1 attrs: first-line indent (signed), space-before / -after.
    fli = _agree([w.text_indent if w.text_indent is not None else 0
                  for w in wrappers])
    if fli is not None:
        store.set_panel("paragraph_panel_content", "first_line_indent", fli)
    sb = _agree([w.jas_space_before if w.jas_space_before is not None else 0
                 for w in wrappers])
    if sb is not None:
        store.set_panel("paragraph_panel_content", "space_before", sb)
    sa = _agree([w.jas_space_after if w.jas_space_after is not None else 0
                 for w in wrappers])
    if sa is not None:
        store.set_panel("paragraph_panel_content", "space_after", sa)
    hyph = _agree([w.jas_hyphenate if w.jas_hyphenate is not None else False
                   for w in wrappers])
    if hyph is not None:
        store.set_panel("paragraph_panel_content", "hyphenate", hyph)
    hp = _agree([w.jas_hanging_punctuation if w.jas_hanging_punctuation is not None else False
                 for w in wrappers])
    if hp is not None:
        store.set_panel("paragraph_panel_content", "hanging_punctuation", hp)
    # Single backing attr split into two panel dropdowns. Aggregate
    # first, then route by prefix.
    ls = _agree([w.jas_list_style if w.jas_list_style is not None else ""
                 for w in wrappers])
    if ls is not None:
        if ls.startswith("bullet-"):
            store.set_panel("paragraph_panel_content", "bullets", ls)
            store.set_panel("paragraph_panel_content", "numbered_list", "")
        elif ls.startswith("num-"):
            store.set_panel("paragraph_panel_content", "numbered_list", ls)
            store.set_panel("paragraph_panel_content", "bullets", "")
        else:
            # Empty agreement (no marker) clears both dropdowns.
            store.set_panel("paragraph_panel_content", "bullets", "")
            store.set_panel("paragraph_panel_content", "numbered_list", "")
    # Phase 4: alignment radio aggregation. text_align +
    # text_align_last together drive which of the seven radio bools
    # is set per the §Alignment sub-mapping; agreement on both fields
    # is required.
    tas = _agree([w.text_align if w.text_align is not None else "left"
                  for w in wrappers])
    tals = _agree([w.text_align_last if w.text_align_last is not None else ""
                   for w in wrappers])
    if tas is not None and tals is not None:
        for k in ("align_left", "align_center", "align_right",
                  "justify_left", "justify_center",
                  "justify_right", "justify_all"):
            store.set_panel("paragraph_panel_content", k, False)
        if tas == "center":
            key = "align_center"
        elif tas == "right":
            key = "align_right"
        elif tas == "justify" and tals == "left":
            key = "justify_left"
        elif tas == "justify" and tals == "center":
            key = "justify_center"
        elif tas == "justify" and tals == "right":
            key = "justify_right"
        elif tas == "justify" and tals == "justify":
            key = "justify_all"
        else:
            key = "align_left"
        store.set_panel("paragraph_panel_content", key, True)


# ── Phase 4: paragraph panel→selection writes ─────────────

_ALIGN_KEYS = ("align_left", "align_center", "align_right",
               "justify_left", "justify_center",
               "justify_right", "justify_all")


def ensure_paragraph_wrapper(tspans: list) -> list[int]:
    """Normalize the paragraph-wrapper layout for a text element's
    tspans, returning the wrapper indices (always >= 1 after this
    call). Wrapper tspans must be **empty**-content markers — the
    paragraph's body lives in subsequent body tspans until the next
    wrapper or end-of-tspans. Two corruption modes are repaired
    here:

    1. No wrapper at all -> prepend a fresh empty wrapper at index 0.
    2. A wrapper carries non-empty content (legacy "promote first
       tspan" path) -> demote it to a body tspan (clear ``jas_role``,
       keep its content) and prepend a fresh empty wrapper that
       inherits the legacy wrapper's paragraph attributes.

    ``build_segments_from_text`` doesn't count wrapper-tspan content
    toward the segment's char range, so leaving body chars on a
    wrapper makes the layout's effective slice shorter than the
    rendered string — the user sees the paragraph collapse to a
    single line the moment any Paragraph-panel control is clicked.

    Used by every paragraph-panel apply path:
    ``apply_paragraph_panel_to_selection``,
    ``apply_justification_dialog_to_selection``, and
    ``apply_hyphenation_dialog_to_selection``.

    Mutates ``tspans`` in place. Mirrors
    ``jas_dioxus/src/workspace/app_state.rs::ensure_paragraph_wrapper``
    and ``JasSwift/.../ensureParagraphWrapper``.
    """
    from dataclasses import replace
    from geometry.tspan import Tspan
    # Repair: if any wrapper has non-empty content, demote it to a
    # body tspan and prepend a fresh empty wrapper that inherits
    # the paragraph attributes.
    bad = [i for i, t in enumerate(tspans)
           if t.jas_role == "paragraph" and t.content != ""]
    for i in reversed(bad):
        src = tspans[i]
        # Build a new wrapper inheriting paragraph-attr fields off
        # the corrupted tspan; the corrupted tspan keeps its content
        # + character overrides but loses its wrapper role and
        # paragraph attrs.
        new_wrapper = Tspan(
            jas_role="paragraph",
            text_align=src.text_align,
            text_align_last=src.text_align_last,
            text_indent=src.text_indent,
            jas_left_indent=src.jas_left_indent,
            jas_right_indent=src.jas_right_indent,
            jas_space_before=src.jas_space_before,
            jas_space_after=src.jas_space_after,
            jas_hyphenate=src.jas_hyphenate,
            jas_hanging_punctuation=src.jas_hanging_punctuation,
            jas_list_style=src.jas_list_style,
            jas_word_spacing_min=src.jas_word_spacing_min,
            jas_word_spacing_desired=src.jas_word_spacing_desired,
            jas_word_spacing_max=src.jas_word_spacing_max,
            jas_letter_spacing_min=src.jas_letter_spacing_min,
            jas_letter_spacing_desired=src.jas_letter_spacing_desired,
            jas_letter_spacing_max=src.jas_letter_spacing_max,
            jas_glyph_scaling_min=src.jas_glyph_scaling_min,
            jas_glyph_scaling_desired=src.jas_glyph_scaling_desired,
            jas_glyph_scaling_max=src.jas_glyph_scaling_max,
            jas_auto_leading=src.jas_auto_leading,
            jas_single_word_justify=src.jas_single_word_justify,
            jas_hyphenate_min_word=src.jas_hyphenate_min_word,
            jas_hyphenate_min_before=src.jas_hyphenate_min_before,
            jas_hyphenate_min_after=src.jas_hyphenate_min_after,
            jas_hyphenate_limit=src.jas_hyphenate_limit,
            jas_hyphenate_zone=src.jas_hyphenate_zone,
            jas_hyphenate_bias=src.jas_hyphenate_bias,
            jas_hyphenate_capitalized=src.jas_hyphenate_capitalized,
        )
        # Demote the corrupted tspan: keep id + content + per-character
        # overrides (font/style/etc.), drop paragraph role + attrs.
        tspans[i] = replace(src,
            jas_role=None,
            text_align=None,
            text_align_last=None,
            text_indent=None,
            jas_left_indent=None,
            jas_right_indent=None,
            jas_space_before=None,
            jas_space_after=None,
            jas_hyphenate=None,
            jas_hanging_punctuation=None,
            jas_list_style=None,
            jas_word_spacing_min=None,
            jas_word_spacing_desired=None,
            jas_word_spacing_max=None,
            jas_letter_spacing_min=None,
            jas_letter_spacing_desired=None,
            jas_letter_spacing_max=None,
            jas_glyph_scaling_min=None,
            jas_glyph_scaling_desired=None,
            jas_glyph_scaling_max=None,
            jas_auto_leading=None,
            jas_single_word_justify=None,
            jas_hyphenate_min_word=None,
            jas_hyphenate_min_before=None,
            jas_hyphenate_min_after=None,
            jas_hyphenate_limit=None,
            jas_hyphenate_zone=None,
            jas_hyphenate_bias=None,
            jas_hyphenate_capitalized=None,
        )
        tspans.insert(i, new_wrapper)
    # Now collect indices of (post-repair) wrappers.
    existing = [i for i, t in enumerate(tspans) if t.jas_role == "paragraph"]
    if existing:
        return existing
    # No wrapper anywhere: prepend an empty one.
    tspans.insert(0, Tspan(jas_role="paragraph"))
    return [0]


def _paragraph_align_attrs(panel: dict):
    """Map the seven alignment radio bools to a (text_align,
    text_align_last) pair per PARAGRAPH.md §Alignment sub-mapping.
    Default ALIGN_LEFT_BUTTON returns (None, None) so it is omitted
    per the identity-value rule."""
    if panel.get("align_center"):
        return ("center", None)
    if panel.get("align_right"):
        return ("right", None)
    if panel.get("justify_left"):
        return ("justify", "left")
    if panel.get("justify_center"):
        return ("justify", "center")
    if panel.get("justify_right"):
        return ("justify", "right")
    if panel.get("justify_all"):
        return ("justify", "justify")
    return (None, None)


def apply_paragraph_panel_to_selection(store, model) -> None:
    """Push the YAML-stored paragraph panel state onto every
    paragraph wrapper tspan inside the selection. Per the
    identity-value rule, attrs equal to their default are omitted
    (set to None) rather than written. The seven alignment radio
    bools collapse to a (text_align, text_align_last) pair per the
    §Alignment sub-mapping; bullets and numbered_list both write the
    single jas_list_style attribute. Calls ``ensure_paragraph_wrapper``
    which inserts a fresh empty wrapper if none exists (rather than
    promoting the first tspan, which would shrink the segment's char
    range and collapse the paragraph). No-op when the model is None
    or the selection contains no text. Phase 4."""
    if model is None:
        return
    doc = getattr(model, "document", None)
    if doc is None or not doc.selection:
        return
    panel = store.get_panel_state("paragraph_panel_content") or {}

    text_align, text_align_last = _paragraph_align_attrs(panel)

    def _opt_f(v):
        try:
            f = float(v) if v is not None else 0.0
        except (TypeError, ValueError):
            f = 0.0
        return None if f == 0.0 else f

    def _opt_b(v):
        return True if bool(v) else None

    li = _opt_f(panel.get("left_indent", 0))
    ri = _opt_f(panel.get("right_indent", 0))
    # first_line_indent is signed — non-zero (incl. negative) writes.
    fli_raw = panel.get("first_line_indent", 0)
    try:
        fli = float(fli_raw) if fli_raw is not None else 0.0
    except (TypeError, ValueError):
        fli = 0.0
    fli_opt = None if fli == 0.0 else fli
    sb = _opt_f(panel.get("space_before", 0))
    sa = _opt_f(panel.get("space_after", 0))
    hyph = _opt_b(panel.get("hyphenate", False))
    hang = _opt_b(panel.get("hanging_punctuation", False))
    bullets = panel.get("bullets") or ""
    numbered = panel.get("numbered_list") or ""
    list_style = bullets if bullets else (numbered if numbered else None)

    from dataclasses import replace
    new_doc = doc
    any_change = False
    for es in doc.selection:
        path = getattr(es, "path", None)
        if path is None:
            continue
        elem = new_doc.get_element(path)
        if not isinstance(elem, (Text, TextPath)):
            continue
        tspans = list(elem.tspans)
        wrapper_idx = ensure_paragraph_wrapper(tspans)
        for i in wrapper_idx:
            tspans[i] = replace(tspans[i],
                text_align=text_align,
                text_align_last=text_align_last,
                text_indent=fli_opt,
                jas_left_indent=li,
                jas_right_indent=ri,
                jas_space_before=sb,
                jas_space_after=sa,
                jas_hyphenate=hyph,
                jas_hanging_punctuation=hang,
                jas_list_style=list_style)
        new_elem = replace(elem, tspans=tuple(tspans))
        new_doc = new_doc.replace_element(path, new_elem)
        any_change = True

    if any_change:
        # Undoable edit (one self-bracketed undo step) via the chokepoint.
        if hasattr(model, "edit_document"):
            model.edit_document(new_doc)
        else:
            model.document = new_doc


def apply_paragraph_panel_mutual_exclusion(store, key, value) -> None:
    """Apply mutual exclusion side effects for a paragraph panel
    write. Setting one of the seven alignment radio bools to True
    clears the other six; setting bullets / numbered_list to a
    non-empty string clears the sibling. Phase 4."""
    pid = "paragraph_panel_content"
    if key in _ALIGN_KEYS:
        if bool(value):
            for k in _ALIGN_KEYS:
                if k != key:
                    store.set_panel(pid, k, False)
    elif key == "bullets":
        if isinstance(value, str) and value:
            store.set_panel(pid, "numbered_list", "")
    elif key == "numbered_list":
        if isinstance(value, str) and value:
            store.set_panel(pid, "bullets", "")


def reset_paragraph_panel(store, model) -> None:
    """Reset every Paragraph panel control to its default per
    PARAGRAPH.md §Reset Panel and remove the corresponding
    jas:* / text-* attributes from every wrapper tspan in the
    selection (defaults appear as absence, identity rule). Phase 4."""
    pid = "paragraph_panel_content"
    store.set_panel(pid, "align_left", True)
    for k in _ALIGN_KEYS[1:]:
        store.set_panel(pid, k, False)
    store.set_panel(pid, "bullets", "")
    store.set_panel(pid, "numbered_list", "")
    for k in ("left_indent", "right_indent", "first_line_indent",
              "space_before", "space_after"):
        store.set_panel(pid, k, 0)
    store.set_panel(pid, "hyphenate", False)
    store.set_panel(pid, "hanging_punctuation", False)
    apply_paragraph_panel_to_selection(store, model)


def set_paragraph_panel_field(store, model, key, value) -> None:
    """Sync from selection → mutual exclusion → set field → apply.
    The full pipeline a widget write should call so untouched fields
    keep the selection's current values, the radio / list-style
    invariants hold, and the wrappers receive the full updated state
    in one snapshot. Phase 4."""
    sync_paragraph_panel_from_selection(store, model)
    apply_paragraph_panel_mutual_exclusion(store, key, value)
    store.set_panel("paragraph_panel_content", key, value)
    apply_paragraph_panel_to_selection(store, model)


# ── Phase 8: Justification dialog OK commit ────────────────


from dataclasses import dataclass


@dataclass
class JustificationDialogValues:
    """11 Justification-dialog field values, packed for one commit
    pass. ``None`` means the field was blank (mixed selection) and
    should not write — the existing wrapper attribute stays."""
    word_spacing_min: float | None = None
    word_spacing_desired: float | None = None
    word_spacing_max: float | None = None
    letter_spacing_min: float | None = None
    letter_spacing_desired: float | None = None
    letter_spacing_max: float | None = None
    glyph_scaling_min: float | None = None
    glyph_scaling_desired: float | None = None
    glyph_scaling_max: float | None = None
    auto_leading: float | None = None
    single_word_justify: str | None = None


def apply_justification_dialog_to_selection(model, v: JustificationDialogValues) -> None:
    """Commit the 11 Justification-dialog fields onto every paragraph
    wrapper tspan in the selection. Per the identity-value rule,
    each value at its spec default (word-spacing 80/100/133,
    letter-spacing 0/0/0, glyph-scaling 100/100/100, auto-leading
    120, single-word-justify 'justify') writes None so the wrapper
    attribute stays absent. Phase 8."""
    if model is None:
        return
    doc = getattr(model, "document", None)
    if doc is None or not doc.selection:
        return

    def _opt_n(value, default):
        if value is None:
            return None
        try:
            f = float(value)
        except (TypeError, ValueError):
            return None
        return None if abs(f - default) < 1e-6 else f

    ws_min = _opt_n(v.word_spacing_min, 80.0)
    ws_des = _opt_n(v.word_spacing_desired, 100.0)
    ws_max = _opt_n(v.word_spacing_max, 133.0)
    ls_min = _opt_n(v.letter_spacing_min, 0.0)
    ls_des = _opt_n(v.letter_spacing_desired, 0.0)
    ls_max = _opt_n(v.letter_spacing_max, 0.0)
    gs_min = _opt_n(v.glyph_scaling_min, 100.0)
    gs_des = _opt_n(v.glyph_scaling_desired, 100.0)
    gs_max = _opt_n(v.glyph_scaling_max, 100.0)
    auto = _opt_n(v.auto_leading, 120.0)
    swj = (v.single_word_justify
           if v.single_word_justify and v.single_word_justify != "justify"
           else None)

    from dataclasses import replace
    new_doc = doc
    any_change = False
    for es in doc.selection:
        path = getattr(es, "path", None)
        if path is None:
            continue
        elem = new_doc.get_element(path)
        if not isinstance(elem, (Text, TextPath)):
            continue
        tspans = list(elem.tspans)
        wrapper_idx = ensure_paragraph_wrapper(tspans)
        for i in wrapper_idx:
            tspans[i] = replace(tspans[i],
                jas_word_spacing_min=ws_min,
                jas_word_spacing_desired=ws_des,
                jas_word_spacing_max=ws_max,
                jas_letter_spacing_min=ls_min,
                jas_letter_spacing_desired=ls_des,
                jas_letter_spacing_max=ls_max,
                jas_glyph_scaling_min=gs_min,
                jas_glyph_scaling_desired=gs_des,
                jas_glyph_scaling_max=gs_max,
                jas_auto_leading=auto,
                jas_single_word_justify=swj)
        new_elem = replace(elem, tspans=tuple(tspans))
        new_doc = new_doc.replace_element(path, new_elem)
        any_change = True
    if any_change:
        # Undoable edit (one self-bracketed undo step) via the chokepoint.
        if hasattr(model, "edit_document"):
            model.edit_document(new_doc)
        else:
            model.document = new_doc


# ── Phase 9: Hyphenation dialog OK commit ──────────────────


@dataclass
class HyphenationDialogValues:
    """8 Hyphenation-dialog field values (master + 7 sub-controls).
    ``None`` means the field was blank (mixed selection) and should
    not write — the existing wrapper attribute stays. Phase 9."""
    hyphenate: bool | None = None
    min_word: float | None = None
    min_before: float | None = None
    min_after: float | None = None
    limit: float | None = None
    zone: float | None = None
    bias: float | None = None
    capitalized: bool | None = None


def apply_hyphenation_dialog_to_selection(model, store, v: HyphenationDialogValues) -> None:
    """Commit the master toggle + 7 Hyphenation-dialog fields onto
    every paragraph wrapper tspan in the selection. Per the
    identity-value rule, each value at its spec default (master off,
    3/1/1, 0, 0, 0, off) writes None so the wrapper attribute stays
    absent. Master toggle also mirrors to panel.hyphenate via
    ``store.set_panel`` so the main panel checkbox reflects the
    dialog commit. Phase 9."""
    def _opt_n(value, default):
        if value is None:
            return None
        try:
            f = float(value)
        except (TypeError, ValueError):
            return None
        return None if abs(f - default) < 1e-6 else f

    def _opt_b(value):
        if value is None:
            return None
        return True if value else None

    hyph = _opt_b(v.hyphenate)
    min_word = _opt_n(v.min_word, 3.0)
    min_before = _opt_n(v.min_before, 1.0)
    min_after = _opt_n(v.min_after, 1.0)
    limit = _opt_n(v.limit, 0.0)
    zone = _opt_n(v.zone, 0.0)
    bias = _opt_n(v.bias, 0.0)
    cap = _opt_b(v.capitalized)

    if model is not None:
        doc = getattr(model, "document", None)
        if doc is not None and doc.selection:
            from dataclasses import replace
            new_doc = doc
            any_change = False
            for es in doc.selection:
                path = getattr(es, "path", None)
                if path is None:
                    continue
                elem = new_doc.get_element(path)
                if not isinstance(elem, (Text, TextPath)):
                    continue
                tspans = list(elem.tspans)
                wrapper_idx = ensure_paragraph_wrapper(tspans)
                for i in wrapper_idx:
                    tspans[i] = replace(tspans[i],
                        jas_hyphenate=hyph,
                        jas_hyphenate_min_word=min_word,
                        jas_hyphenate_min_before=min_before,
                        jas_hyphenate_min_after=min_after,
                        jas_hyphenate_limit=limit,
                        jas_hyphenate_zone=zone,
                        jas_hyphenate_bias=bias,
                        jas_hyphenate_capitalized=cap)
                new_elem = replace(elem, tspans=tuple(tspans))
                new_doc = new_doc.replace_element(path, new_elem)
                any_change = True
            if any_change:
                # Undoable edit (one self-bracketed undo step) via the chokepoint.
                if hasattr(model, "edit_document"):
                    model.edit_document(new_doc)
                else:
                    model.document = new_doc

    # Master mirror to panel state for HYPHENATE_CHECKBOX.
    if v.hyphenate is not None and store is not None:
        store.set_panel("paragraph_panel_content", "hyphenate", bool(v.hyphenate))


def subscribe(store, model_getter) -> None:
    """Wire ``apply_paragraph_panel_to_selection`` to fire after any
    write into the ``paragraph_panel_content`` scope of ``store``.
    Mirrors ``character_panel_state.subscribe``.

    ``model_getter`` is a zero-arg callable returning the live
    ``Model`` (the app rotates models across tabs, so we can't
    capture a fixed reference)."""
    def _on_change(_key, _value):
        apply_paragraph_panel_to_selection(store, model_getter())

    store.subscribe_panel("paragraph_panel_content", _on_change)
