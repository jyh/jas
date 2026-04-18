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
    if not kwargs:
        return None
    return Tspan(**kwargs)


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
