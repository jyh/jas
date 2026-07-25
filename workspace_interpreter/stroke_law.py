"""The field-scoped Stroke-panel apply law — the spec's executable meaning.

A Stroke-panel edit NAMES the field the user just committed. Only the
attribute group that field owns is taken from panel state; every other
stroke attribute is preserved from the element being edited, PER ELEMENT.
The colour route is likewise colour-only.

Before STROKEWIDTH (2026-07-24) every implementation rebuilt the WHOLE
Stroke from panel state on any write to a render-affecting key, so
touching one control reset a selected 5pt dashed arrowheaded line to the
panel's 1pt defaults. JYH's repro is pinned as the first vector of
``test_fixtures/stroke_apply/panel_edit.json``, which gates this module
alongside the Rust ``stroke_with_group`` (jas_dioxus
``workspace/app_state.rs``) and the Swift ``strokeWithGroup``
(``Interpreter/StrokePanelSync.swift``). The English law lives in
``transcripts/STROKE.md``.

This module is deliberately PURE and dict-shaped. A stroke is a flat
attribute map (``STROKE_ATTRS``) using the language-neutral names the
conformance fixture uses, so the law can be stated and gated without the
reference depending on any port's Stroke type. The platform bridge in
``effects.py`` converts its Stroke objects to and from this map.
"""

from __future__ import annotations

from typing import Any

# ---------------------------------------------------------------------------
# The stroke attribute map
# ---------------------------------------------------------------------------

#: Every attribute of a stroke, with the value it takes on a plain 1pt
#: black stroke. Also the canonical key ORDER and the default source for
#: :func:`normalize_stroke`.
STROKE_DEFAULTS: dict[str, Any] = {
    "color": "#000000",
    "width": 1.0,
    "linecap": "butt",
    "linejoin": "miter",
    "miter_limit": 10.0,
    "align": "center",
    "dash": (),
    "dash_align_anchors": False,
    "start_arrow": "none",
    "end_arrow": "none",
    "start_arrow_scale": 100.0,
    "end_arrow_scale": 100.0,
    "arrow_align": "tip_at_end",
    "opacity": 1.0,
}

STROKE_ATTRS: tuple[str, ...] = tuple(STROKE_DEFAULTS)


def normalize_stroke(stroke: dict[str, Any] | None) -> dict[str, Any]:
    """A full attribute map: ``stroke``'s keys over the 1pt defaults.

    ``None`` becomes the plain 1pt black stroke. ``dash`` is normalized to
    a tuple of floats so equality does not depend on list-vs-tuple.
    """
    out = dict(STROKE_DEFAULTS)
    if stroke:
        for k, v in stroke.items():
            if k in STROKE_DEFAULTS:
                out[k] = v
    out["dash"] = tuple(float(x) for x in (out["dash"] or ()))
    for k in ("width", "miter_limit", "start_arrow_scale", "end_arrow_scale",
              "opacity"):
        out[k] = float(out[k])
    out["dash_align_anchors"] = bool(out["dash_align_anchors"])
    return out


# ---------------------------------------------------------------------------
# The groups
# ---------------------------------------------------------------------------

# Group names. One per set of attributes that must move together.
WIDTH = "width"
CAP = "cap"
JOIN = "join"
MITER_LIMIT = "miter_limit"
ALIGN = "align"
DASH = "dash"
START_ARROW = "start_arrow"
END_ARROW = "end_arrow"
START_ARROW_SCALE = "start_arrow_scale"
END_ARROW_SCALE = "end_arrow_scale"
ARROW_ALIGN = "arrow_align"
#: The width profile lives in the element's WIDTH POINTS, not the Stroke —
#: a profile edit leaves the Stroke byte-identical.
PROFILE = "profile"

#: Stroke-panel field key -> the attribute group it owns. A field absent
#: from this table owns no element attribute, so editing it writes NOTHING
#: to the document.
#:
#: The grouping is stated HERE, explicitly, because the reference is the
#: contract: the ports mirror this table rather than the reverse. Only two
#: groups are wider than a single attribute, and both are forced:
#:
#: * the dash inputs and the ``dashed`` toggle are ONE pattern — a dash
#:   array cannot be written a slot at a time, so any dash-family edit
#:   rewrites the whole pattern (and the anchor-alignment flag with it);
#: * ``align_stroke`` is spelled ``align`` in the flat global scope, so
#:   both spellings map to the align group.
#:
#: Notably NOT wide: the two arrowhead scales are separate groups. The
#: link-scales chain mirrors one onto the other by COMMITTING the sibling
#: field, which applies through that field's own group, so the wide group
#: bought nothing and cost an unlinked scale edit stamping the panel's
#: sibling scale onto the element.
#:
#: ``link_arrowhead_scale`` is deliberately absent: it is a UI-only flag,
#: and toggling it must not push an undo step that changes nothing.
STROKE_EDIT_GROUPS: dict[str, str] = {
    "weight": WIDTH,
    "cap": CAP,
    "join": JOIN,
    "miter_limit": MITER_LIMIT,
    "align_stroke": ALIGN,
    "align": ALIGN,
    "dashed": DASH,
    "dash_1": DASH,
    "gap_1": DASH,
    "dash_2": DASH,
    "gap_2": DASH,
    "dash_3": DASH,
    "gap_3": DASH,
    "dash_align_anchors": DASH,
    "start_arrowhead": START_ARROW,
    "end_arrowhead": END_ARROW,
    "start_arrowhead_scale": START_ARROW_SCALE,
    "end_arrowhead_scale": END_ARROW_SCALE,
    "arrow_align": ARROW_ALIGN,
    "profile": PROFILE,
    "profile_flipped": PROFILE,
}


def stroke_field_name(key: str) -> str:
    """A panel-field key normalized to its panel-scope name.

    The flat GLOBAL keys a YAML ``set:`` effect writes carry a ``stroke_``
    prefix (``stroke_cap``); the panel scope does not (``cap``). The weight
    input is the one asymmetric pair: its global is ``stroke_width`` while
    its panel field is ``weight``.
    """
    name = key[len("stroke_"):] if key.startswith("stroke_") else key
    return "weight" if name == "width" else name


def stroke_edit_group(key: str) -> str | None:
    """The attribute group panel field ``key`` owns, or ``None`` when it
    owns none (so the edit writes nothing to the document). Accepts either
    the panel key (``"cap"``) or the flat global key (``"stroke_cap"``)."""
    return STROKE_EDIT_GROUPS.get(stroke_field_name(key))


# ---------------------------------------------------------------------------
# The law
# ---------------------------------------------------------------------------

#: The dash / gap length used when the input holds nothing at all — the
#: panel default the workspace declares (``workspace/panels/stroke.yaml``
#: ``dash_1`` / ``gap_1``, ``workspace/state.yaml`` ``stroke_dash_1`` /
#: ``stroke_gap_1``). Both ports already used 12.0 while this module used
#: 0.0; the workspace settles it.
DASH_DEFAULT: float = 12.0


def _panel_dash(panel: dict[str, Any]) -> tuple[float, ...]:
    """The dash array the panel's dash family describes. Empty when the
    ``dashed`` toggle is off. A second / third pair joins the pattern only
    when BOTH its dash and gap are set.

    An ABSENT first pair takes :data:`DASH_DEFAULT`; a dash length the user
    really set to 0 stays 0. This read used to be ``panel.get("dash_1") or
    0.0``, which cannot tell 0 from absent — harmless while the fallback was
    itself 0, a silent value change the moment it is not.
    """
    if not panel.get("dashed"):
        return ()

    def _pair(key: str) -> float:
        val = panel.get(key)
        return DASH_DEFAULT if val is None else float(val)

    out = [_pair("dash_1"), _pair("gap_1")]
    for d_key, g_key in (("dash_2", "gap_2"), ("dash_3", "gap_3")):
        d, g = panel.get(d_key), panel.get(g_key)
        if d is None or g is None:
            break
        out += [float(d), float(g)]
    return tuple(out)


def stroke_with_group(
    base: dict[str, Any] | None, panel: dict[str, Any], group: str,
    committed_width: float,
) -> dict[str, Any]:
    """``base`` with ``group``'s attributes overwritten from ``panel`` and
    every other attribute left exactly as it was.

    ``committed_width`` is the weight input's committed value and is read
    ONLY by the width group — nothing else may read a panel-committed
    width, which is precisely what stops an unrelated edit from resetting
    the element's weight.
    """
    s = normalize_stroke(base)
    if group == WIDTH:
        s["width"] = float(committed_width)
    elif group == CAP:
        cap = panel.get("cap")
        s["linecap"] = cap if cap in ("round", "square") else "butt"
    elif group == JOIN:
        join = panel.get("join")
        s["linejoin"] = join if join in ("round", "bevel") else "miter"
    elif group == MITER_LIMIT:
        ml = panel.get("miter_limit")
        s["miter_limit"] = float(ml) if ml is not None else 10.0
    elif group == ALIGN:
        al = panel.get("align_stroke", panel.get("align"))
        s["align"] = al if al in ("inside", "outside") else "center"
    elif group == DASH:
        s["dash"] = _panel_dash(panel)
        s["dash_align_anchors"] = bool(panel.get("dash_align_anchors"))
    elif group == START_ARROW:
        s["start_arrow"] = panel.get("start_arrowhead") or "none"
    elif group == END_ARROW:
        s["end_arrow"] = panel.get("end_arrowhead") or "none"
    elif group == START_ARROW_SCALE:
        v = panel.get("start_arrowhead_scale")
        s["start_arrow_scale"] = float(v) if v is not None else 100.0
    elif group == END_ARROW_SCALE:
        v = panel.get("end_arrowhead_scale")
        s["end_arrow_scale"] = float(v) if v is not None else 100.0
    elif group == ARROW_ALIGN:
        s["arrow_align"] = ("center_at_end"
                            if panel.get("arrow_align") == "center_at_end"
                            else "tip_at_end")
    elif group == PROFILE:
        # The profile lives in the element's width points, not the Stroke.
        pass
    return s


def recolor_stroke(base: dict[str, Any] | None, color: str) -> dict[str, Any]:
    """``base`` with its colour replaced and every other attribute
    preserved. ``None`` (nothing to recolour) becomes a plain 1pt stroke in
    that colour. Mirrors the Rust ``recolor_stroke`` / Swift
    ``recolorStroke``."""
    s = normalize_stroke(base)
    s["color"] = color
    return s


def recolor_fill(base: dict[str, Any] | None, color: str) -> dict[str, Any]:
    """``base`` with its colour replaced and its opacity preserved."""
    out = {"color": color, "opacity": 1.0}
    if base:
        out["opacity"] = float(base.get("opacity", 1.0))
    return out


#: Panel fields whose write must re-derive the element's width points: the
#: profile shape / flip, and the weight the profile scales with.
PROFILE_REDERIVING_GROUPS: frozenset[str] = frozenset({WIDTH, PROFILE})
