"""Character panel apply-to-selection pipeline (Layer B).

Mirrors the Rust ``apply_character_panel_to_selection`` and Swift
``applyCharacterPanelToSelection`` helpers. Reads the current panel
state under the ``character_panel`` scope in the shared StateStore
and pushes the resulting Text attributes onto every ``Text`` /
``TextPath`` element in the active document's selection.

Subscribed to panel-state changes from the app root (see
``jas_app.py``) so any widget write in the Character panel flows
through to the selected element automatically, the same way the
Rust / Flask Character panels behave.
"""

from __future__ import annotations

from dataclasses import replace
from typing import Any

from geometry.element import Element, Text, TextPath
from geometry.tspan import Tspan


def apply_character_panel_to_selection(store, model) -> None:
    """Push the Character-panel state to every selected Text / TextPath.

    No-op when the model is None, when the active document has no
    selection, or when no selected element is a Text / TextPath.

    Attribute rules mirror CHARACTER.md's SVG mapping:
    - underline + strikethrough combine into text_decoration
      (sorted alphabetically: "line-through underline").
    - all_caps -> text_transform: uppercase; small_caps (when All
      Caps is off) -> font_variant: small-caps.
    - superscript / subscript -> baseline_shift: super / sub; numeric
      pt value loses to the toggles.
    - style_name parses into font_weight + font_style (Regular /
      Italic / Bold / Bold Italic; unknown names leave the existing
      weight + style untouched).
    - leading -> line_height ("Npt"; empty at the 120% Auto default).
    - tracking (1/1000 em) -> letter_spacing ("Nem").
    - kerning (1/1000 em) -> "Nem" on the kerning field
      (named Auto / Optical / Metrics modes land once the panel
      exposes a combo_box widget).
    - character_rotation -> rotate (degrees string, empty at 0).
    - horizontal_scale / vertical_scale -> percent strings, empty at
      100% identity.
    - language -> xml_lang; anti_aliasing -> aa_mode (Sharp default
      empties).
    """
    if model is None:
        return
    doc = getattr(model, "document", None)
    if doc is None:
        return

    panel = store.get_panel_state("character_panel") or {}

    # Phase 3: route to next-typed-character state when there is an
    # active edit session with a bare caret (no range selection).
    # Replace semantics: clear pending, prime from the new template.
    session = getattr(model, "current_edit_session", None)
    if session is not None and not session.has_selection():
        try:
            elem = doc.get_element(session.path)
        except Exception:
            elem = None
        if isinstance(elem, (Text, TextPath)):
            template = build_panel_pending_template(panel, elem)
            session.clear_pending_override()
            if template is not None:
                session.set_pending_override(template)
            return

    # Per-range write: when the active session has a range selection,
    # apply the panel state to that range only via split_range +
    # merge_tspan_overrides + merge. The rest of the edited element
    # is left untouched (per TSPAN.md's "Character attribute writes
    # (from panels)" algorithm).
    if session is not None and session.has_selection():
        try:
            elem = doc.get_element(session.path)
        except Exception:
            elem = None
        if isinstance(elem, (Text, TextPath)):
            lo, hi = session.selection_range()
            overrides = build_panel_full_overrides(panel)
            new_tspans = tuple(apply_overrides_to_tspan_range(
                list(elem.tspans), lo, hi, overrides, elem=elem))
            new_elem = replace(elem, tspans=new_tspans)
            model.snapshot()
            model.document = doc.replace_element(session.path, new_elem)
            return

    selection = getattr(doc, "selection", None) or []
    if not selection:
        return

    attrs = _attrs_from_panel(panel)

    # Collect paths of text targets (without holding a borrow on the
    # document across replace_element calls).
    target_paths = []
    for es in selection:
        path = getattr(es, "path", None)
        if path is None:
            continue
        elem = doc.get_element(path)
        if isinstance(elem, (Text, TextPath)):
            target_paths.append(path)
    if not target_paths:
        return

    # Snapshot before the batch so undo reverts the whole apply.
    model.snapshot()
    for path in target_paths:
        elem = doc.get_element(path)
        if isinstance(elem, Text):
            new_elem = replace(elem, **_text_kwargs(elem, attrs))
        elif isinstance(elem, TextPath):
            new_elem = replace(elem, **_text_kwargs(elem, attrs))
        else:
            continue
        doc = doc.replace_element(path, new_elem)
    model.document = doc


def build_panel_full_overrides(panel: dict) -> Tspan:
    """Build a ``Tspan`` override template with every panel-scoped
    field forced to a concrete value (not diffed against the
    element). Used by the per-range Character-panel write path.

    Unlike :func:`build_panel_pending_template`, this emits
    ``"normal"`` etc. for Regular so the range's bold override gets
    cleared, not skipped.
    """
    fam = panel.get("font_family")
    ff = str(fam) if fam is not None else "sans-serif"
    fs_raw = panel.get("font_size")
    fs = float(fs_raw) if fs_raw is not None else 12.0
    style = panel.get("style_name") or ""
    style = style.strip() if isinstance(style, str) else ""
    style_map = {
        "Regular": ("normal", "normal"),
        "Italic": ("normal", "italic"),
        "Bold": ("bold", "normal"),
        "Bold Italic": ("bold", "italic"),
        "Italic Bold": ("bold", "italic"),
    }
    fw, fst = style_map.get(style, (None, None))
    underline = bool(panel.get("underline"))
    strikethrough = bool(panel.get("strikethrough"))
    td = tuple(sorted([
        t for t in ("line-through" if strikethrough else None,
                    "underline" if underline else None) if t
    ]))
    all_caps = bool(panel.get("all_caps"))
    tt = "uppercase" if all_caps else ""
    small_caps = bool(panel.get("small_caps"))
    fv = "small-caps" if (small_caps and not all_caps) else ""
    lang_raw = panel.get("language")
    lang = str(lang_raw) if lang_raw is not None else ""
    rot = float(panel.get("character_rotation") or 0.0)
    # Leading → line_height (pt). Always emitted.
    leading_raw = panel.get("leading")
    leading = float(leading_raw) if leading_raw is not None else (fs * 1.2)
    # Tracking → letter_spacing (em). Panel unit: 1/1000 em.
    tracking = float(panel.get("tracking") or 0.0)
    letter_spacing = tracking / 1000.0
    # Baseline shift numeric (pt), skipped when super / sub is on.
    super_on = bool(panel.get("superscript"))
    sub_on = bool(panel.get("subscript"))
    bs_num = float(panel.get("baseline_shift") or 0.0)
    baseline_shift = None if (super_on or sub_on) else bs_num
    # Anti-aliasing → jas_aa_mode.
    aa_raw = panel.get("anti_aliasing")
    aa_raw = str(aa_raw) if aa_raw is not None else "Sharp"
    aa_mode = "" if aa_raw in ("Sharp", "") else aa_raw
    return Tspan(
        font_family=ff,
        font_size=fs,
        font_weight=fw,
        font_style=fst,
        text_decoration=td,
        text_transform=tt,
        font_variant=fv,
        xml_lang=lang,
        rotate=rot,
        line_height=leading,
        letter_spacing=letter_spacing,
        baseline_shift=baseline_shift,
        jas_aa_mode=aa_mode,
    )


def identity_omit_tspan(t: Tspan, elem: Element) -> Tspan:
    """Drop any tspan override field that matches the parent
    element's effective value (TSPAN.md "Character attribute writes
    (from panels)" step 3). After this pass the tspan retains only
    overrides whose stored value differs from what the element
    renders on its own; ``merge`` can then collapse same-override
    neighbours freely. Non-Text / TextPath elements pass through.
    """
    from dataclasses import replace
    if not isinstance(elem, (Text, TextPath)):
        return t

    def str_eq_opt(a, b):
        return a is not None and a == b

    updates: dict[str, Any] = {}
    if str_eq_opt(t.font_family, elem.font_family):
        updates["font_family"] = None
    if t.font_size is not None and abs(t.font_size - elem.font_size) < 1e-6:
        updates["font_size"] = None
    if str_eq_opt(t.font_weight, elem.font_weight):
        updates["font_weight"] = None
    if str_eq_opt(t.font_style, elem.font_style):
        updates["font_style"] = None
    if t.text_decoration is not None:
        a = sorted(t.text_decoration)
        b = sorted(tok for tok in elem.text_decoration.split()
                    if tok and tok != "none")
        if a == b:
            updates["text_decoration"] = None
    if str_eq_opt(t.text_transform, elem.text_transform):
        updates["text_transform"] = None
    if str_eq_opt(t.font_variant, elem.font_variant):
        updates["font_variant"] = None
    if str_eq_opt(t.xml_lang, elem.xml_lang):
        updates["xml_lang"] = None
    if t.rotate is not None:
        try:
            elem_rot = float(elem.rotate) if elem.rotate else 0.0
        except ValueError:
            elem_rot = 0.0
        if abs(t.rotate - elem_rot) < 1e-6:
            updates["rotate"] = None
    if t.line_height is not None:
        elem_lh = _parse_pt(elem.line_height)
        if elem_lh is None:
            elem_lh = elem.font_size * 1.2
        if abs(t.line_height - elem_lh) < 1e-6:
            updates["line_height"] = None
    if t.letter_spacing is not None:
        elem_ls = _parse_em(elem.letter_spacing) or 0.0
        if abs(t.letter_spacing - elem_ls) < 1e-6:
            updates["letter_spacing"] = None
    if t.baseline_shift is not None:
        elem_bs = _parse_pt(elem.baseline_shift)
        if elem_bs is not None:
            if abs(t.baseline_shift - elem_bs) < 1e-6:
                updates["baseline_shift"] = None
        elif elem.baseline_shift == "" and t.baseline_shift == 0.0:
            updates["baseline_shift"] = None
    if t.jas_aa_mode is not None:
        elem_aa = "" if elem.aa_mode == "Sharp" else elem.aa_mode
        if t.jas_aa_mode == elem_aa:
            updates["jas_aa_mode"] = None
    return replace(t, **updates) if updates else t


def apply_overrides_to_tspan_range(
    tspans, char_start: int, char_end: int, overrides: Tspan,
    elem: Element | None = None,
):
    """Apply ``overrides`` to every tspan covered by
    ``[char_start, char_end)`` of ``tspans``. Returns a list produced
    by TSPAN.md's per-range pipeline: ``split_range`` +
    ``merge_tspan_overrides`` + ``merge``. When ``elem`` is supplied,
    runs identity-omission (TSPAN.md step 3) between the override-
    merge and final merge steps so redundant overrides get cleared.
    """
    if char_start >= char_end:
        return list(tspans)
    from geometry.tspan import split_range, merge, merge_tspan_overrides
    split, first, last = split_range(list(tspans), char_start, char_end)
    if first is None or last is None:
        return split
    out = list(split)
    for i in range(first, last + 1):
        merged = merge_tspan_overrides(out[i], overrides)
        if elem is not None:
            merged = identity_omit_tspan(merged, elem)
        out[i] = merged
    return merge(out)


def build_panel_pending_template(panel: dict, elem: Element) -> Tspan | None:
    """Build a ``Tspan`` override template from the Character panel
    state containing only the fields where the panel differs from the
    currently-edited ``elem``. Returns ``None`` when everything
    matches. Scope (Phase 3 MVP, mirrors Rust 390513e / Swift bea4d61 /
    OCaml 63b5def): font-family, font-size, font-weight, font-style,
    text-decoration, text-transform, font-variant, xml-lang, rotate.
    """
    if not isinstance(elem, (Text, TextPath)):
        return None
    kwargs: dict[str, Any] = {}
    if (v := panel.get("font_family")) is not None and str(v) != elem.font_family:
        kwargs["font_family"] = str(v)
    if (v := panel.get("font_size")) is not None and abs(float(v) - elem.font_size) > 1e-6:
        kwargs["font_size"] = float(v)
    # style_name → font_weight + font_style
    style = panel.get("style_name") or ""
    style = style.strip() if isinstance(style, str) else ""
    style_map = {
        "Regular": ("normal", "normal"),
        "Italic": ("normal", "italic"),
        "Bold": ("bold", "normal"),
        "Bold Italic": ("bold", "italic"),
        "Italic Bold": ("bold", "italic"),
    }
    fw_fst = style_map.get(style)
    if fw_fst is not None:
        fw, fst = fw_fst
        if fw != elem.font_weight:
            kwargs["font_weight"] = fw
        if fst != elem.font_style:
            kwargs["font_style"] = fst
    # text-decoration: parse both sides into sorted sets so "none"
    # and "" (no decoration) collapse.
    underline = bool(panel.get("underline"))
    strikethrough = bool(panel.get("strikethrough"))
    panel_td = tuple(sorted([
        t for t in ("line-through" if strikethrough else None,
                    "underline" if underline else None) if t
    ]))
    elem_td_parsed = tuple(sorted(
        t for t in elem.text_decoration.split() if t and t != "none"
    ))
    if panel_td != elem_td_parsed:
        kwargs["text_decoration"] = panel_td
    # text-transform: All Caps flag.
    all_caps = bool(panel.get("all_caps"))
    tt = "uppercase" if all_caps else ""
    if tt != elem.text_transform:
        kwargs["text_transform"] = tt
    # font-variant: Small Caps flag (when All Caps is off).
    small_caps = bool(panel.get("small_caps"))
    fv = "small-caps" if (small_caps and not all_caps) else ""
    if fv != elem.font_variant:
        kwargs["font_variant"] = fv
    # language → xml_lang.
    if (v := panel.get("language")) is not None and str(v) != elem.xml_lang:
        kwargs["xml_lang"] = str(v)
    # Character rotation: float on the panel, string on the element.
    rot = float(panel.get("character_rotation") or 0.0)
    rot_str = "" if rot == 0.0 else _fmt_num(rot)
    if rot_str != elem.rotate and rot != 0.0:
        kwargs["rotate"] = rot
    # Leading → line_height (pt). Element stores as CSS length
    # string; empty round-trips to auto (120% of font_size).
    leading_raw = panel.get("leading")
    if leading_raw is not None:
        leading = float(leading_raw)
        elem_lh = _parse_pt(elem.line_height)
        if elem_lh is None:
            elem_lh = elem.font_size * 1.2
        if abs(leading - elem_lh) > 1e-6:
            kwargs["line_height"] = leading
    # Tracking → letter_spacing (em). Panel unit: 1/1000 em.
    tracking = float(panel.get("tracking") or 0.0)
    elem_tracking = (_parse_em(elem.letter_spacing) or 0.0) * 1000.0
    if abs(tracking - elem_tracking) > 1e-6:
        kwargs["letter_spacing"] = tracking / 1000.0
    # Baseline shift numeric, skipped when super / sub is on.
    if not bool(panel.get("superscript")) and not bool(panel.get("subscript")):
        bs = float(panel.get("baseline_shift") or 0.0)
        elem_bs = _parse_pt(elem.baseline_shift) or 0.0
        if abs(bs - elem_bs) > 1e-6:
            kwargs["baseline_shift"] = bs
    # Anti-aliasing → jas_aa_mode.
    aa_raw = panel.get("anti_aliasing")
    aa_raw = str(aa_raw) if aa_raw is not None else "Sharp"
    aa_mode = "" if aa_raw in ("Sharp", "") else aa_raw
    if aa_mode != elem.aa_mode:
        kwargs["jas_aa_mode"] = aa_mode
    if not kwargs:
        return None
    return Tspan(**kwargs)


def _parse_pt(s: str) -> float | None:
    """Parse a CSS pt-length (``"5pt"`` or bare ``"5"``). Empty → None."""
    s = (s or "").strip()
    if not s:
        return None
    if s.endswith("pt"):
        s = s[:-2]
    try:
        return float(s)
    except ValueError:
        return None


def _parse_em(s: str) -> float | None:
    """Parse a CSS em-length (``"0.025em"``). Empty → None."""
    s = (s or "").strip()
    if not s:
        return None
    if s.endswith("em"):
        s = s[:-2]
    try:
        return float(s)
    except ValueError:
        return None


def _attrs_from_panel(panel: dict) -> dict[str, Any]:
    """Translate Character-panel state fields into the Text-element
    attribute surface. See ``apply_character_panel_to_selection`` for
    the mapping rules; kept as a pure function for testability."""
    attrs: dict[str, Any] = {}

    if (v := panel.get("font_family")) is not None:
        attrs["font_family"] = str(v)
    if (v := panel.get("font_size")) is not None:
        attrs["font_size"] = float(v)

    # style_name -> font_weight + font_style
    style = panel.get("style_name") or ""
    style = style.strip() if isinstance(style, str) else ""
    if style == "Regular":
        attrs["font_weight"] = "normal"; attrs["font_style"] = "normal"
    elif style == "Italic":
        attrs["font_weight"] = "normal"; attrs["font_style"] = "italic"
    elif style == "Bold":
        attrs["font_weight"] = "bold"; attrs["font_style"] = "normal"
    elif style in ("Bold Italic", "Italic Bold"):
        attrs["font_weight"] = "bold"; attrs["font_style"] = "italic"

    # underline + strikethrough -> text_decoration (alphabetical tokens).
    underline = bool(panel.get("underline"))
    strikethrough = bool(panel.get("strikethrough"))
    td_tokens = [
        "line-through" if strikethrough else None,
        "underline" if underline else None,
    ]
    attrs["text_decoration"] = " ".join(t for t in td_tokens if t)

    # all_caps / small_caps.
    all_caps = bool(panel.get("all_caps"))
    small_caps = bool(panel.get("small_caps"))
    attrs["text_transform"] = "uppercase" if all_caps else ""
    attrs["font_variant"] = "small-caps" if (small_caps and not all_caps) else ""

    # super / sub + numeric baseline_shift.
    if bool(panel.get("superscript")):
        attrs["baseline_shift"] = "super"
    elif bool(panel.get("subscript")):
        attrs["baseline_shift"] = "sub"
    else:
        bs_num = float(panel.get("baseline_shift") or 0.0)
        attrs["baseline_shift"] = _fmt_num(bs_num) + "pt" if bs_num != 0.0 else ""

    # leading -> line_height; empty at the 120% Auto default.
    fs_num = float(panel.get("font_size") or 12.0)
    leading = float(panel.get("leading") or (fs_num * 1.2))
    attrs["line_height"] = "" if abs(leading - fs_num * 1.2) < 1e-6 \
        else _fmt_num(leading) + "pt"

    # tracking (1/1000 em) -> letter_spacing.
    tracking = float(panel.get("tracking") or 0.0)
    attrs["letter_spacing"] = "" if tracking == 0.0 else _fmt_num(tracking / 1000.0) + "em"

    # kerning combo_box: named modes (Auto / Optical / Metrics) pass
    # through verbatim; numeric strings are 1/1000 em and convert to
    # "{N}em". Empty / "0" / "Auto" all omit (the element default).
    # Legacy numeric panel values also land here via the else branch.
    k_raw = panel.get("kerning")
    if isinstance(k_raw, str):
        k = k_raw.strip()
        if k in ("", "0", "Auto"):
            attrs["kerning"] = ""
        elif k in ("Optical", "Metrics"):
            attrs["kerning"] = k
        else:
            try:
                n = float(k)
                attrs["kerning"] = "" if n == 0.0 else _fmt_num(n / 1000.0) + "em"
            except ValueError:
                attrs["kerning"] = ""
    else:
        k = float(k_raw or 0.0)
        attrs["kerning"] = "" if k == 0.0 else _fmt_num(k / 1000.0) + "em"

    # character_rotation (degrees).
    rot = float(panel.get("character_rotation") or 0.0)
    attrs["rotate"] = "" if rot == 0.0 else _fmt_num(rot)

    # vertical / horizontal scale (percent).
    v_scale = float(panel.get("vertical_scale") or 100.0)
    h_scale = float(panel.get("horizontal_scale") or 100.0)
    attrs["vertical_scale"] = "" if v_scale == 100.0 else _fmt_num(v_scale)
    attrs["horizontal_scale"] = "" if h_scale == 100.0 else _fmt_num(h_scale)

    # language -> xml_lang; anti_aliasing -> aa_mode (Sharp default empties).
    if (v := panel.get("language")) is not None:
        attrs["xml_lang"] = str(v)
    if (v := panel.get("anti_aliasing")) is not None:
        v = str(v)
        attrs["aa_mode"] = "" if v in ("Sharp", "") else v

    return attrs


def _text_kwargs(elem: Element, attrs: dict[str, Any]) -> dict[str, Any]:
    """Keep only attrs that correspond to real fields on this element
    type. ``dataclasses.replace`` rejects unknown kwargs, so we filter
    defensively in case callers pass extras."""
    field_names = set(type(elem).__dataclass_fields__.keys())
    return {k: v for k, v in attrs.items() if k in field_names}


def _fmt_num(n: float) -> str:
    """Match Rust's ``fmt_num``: integers have no decimal, fractions
    drop trailing zeros. Used for the CSS length-like strings."""
    if n == int(n):
        return str(int(n))
    s = f"{n:.4f}".rstrip("0").rstrip(".")
    return s


def subscribe(store, model_getter) -> None:
    """Wire ``apply_character_panel_to_selection`` to fire after any
    write into the ``character_panel`` scope of ``store``.

    ``model_getter`` is a zero-arg callable returning the live
    ``Model`` (the app rotates models across tabs, so we can't
    capture a fixed reference).
    """
    def _on_change(_key, _value):
        apply_character_panel_to_selection(store, model_getter())

    store.subscribe_panel("character_panel", _on_change)
