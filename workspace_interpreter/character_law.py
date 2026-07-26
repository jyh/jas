"""The field-scoped Character-panel apply law — the spec's executable meaning.

A Character-panel edit NAMES the field the user just committed. Only the
attribute group that field owns is taken from panel state; every other
character attribute is preserved from the element being edited, PER
ELEMENT. And where a group is fed by more than one panel field, the fields
the user did NOT commit are read from THE ELEMENT too — see
:data:`MULTI_FIELD_GROUPS`.

Before CHARPANEL (2026-07-25) every implementation rebuilt the WHOLE
character attribute set from panel state on any Character-panel write, so
nudging Tracking on a 30pt bold italic underlined Georgia run reset it to
the panel's 12pt sans-serif defaults — sixteen attributes clobbered by one
edit. This is the same defect class STROKEWIDTH fixed in the Stroke panel,
over more fields; the Swift port had a partial mitigation (the panel view
pushed its live selection mirror into panel state before the edit landed)
which the Rust port lacked entirely, so the two ports also disagreed. JYH's
repro is pinned as the first vector of
``test_fixtures/character_apply/panel_edit.json``, which gates this module
alongside the Rust ``character_with_group`` (jas_dioxus
``workspace/app_state.rs``) and the Swift ``characterWithGroup``
(``Interpreter/CharacterPanelSync.swift``). The English law lives in
``transcripts/CHARACTER.md``.

The ports spell this module's :func:`character_with_field` as
``character_with_group(base, panel, group)``, because their group enum
carries the committed field for the three multi-field groups; Python has no
such tagged group, so the field key IS the parameter. The two spellings are
the same function.

This module is deliberately PURE and dict-shaped. A character state is a
flat attribute map (:data:`CHARACTER_ATTRS`) using the language-neutral
names the conformance fixture uses — the SVG/CSS attribute names the Text /
TextPath element stores — so the law can be stated and gated without the
reference depending on any port's element type.

Unlike the Stroke panel there is NO flat-global spelling to normalize: every
Character control binds ``panel.<field>`` only (``workspace/panels/
character.yaml``), so a field key needs no ``stroke_``-style prefix strip.

The platform BRIDGE beside this law is
:func:`workspace_interpreter.effects.apply_character_panel_to_selection`,
mirroring the Stroke law's — the bridge is where the Stroke law's one
reference-only divergence (a lossy colour round trip) hid, so Character gets
a reference gate at that level too. Anything that applies a Character edit
must route through :func:`character_with_field` rather than re-deriving the
mapping.
"""

from __future__ import annotations

from typing import Any

# ---------------------------------------------------------------------------
# The character attribute map
# ---------------------------------------------------------------------------

#: Every character attribute a Character-panel edit can reach, with the
#: value a plain 12pt element carries. Also the canonical key ORDER and the
#: default source for :func:`normalize_character`.
#:
#: These are ELEMENT attributes (SVG / CSS names, per CHARACTER.md's
#: attribute-mapping table), not panel fields: the panel's ``leading`` field
#: writes ``line_height``, its ``tracking`` field writes ``letter_spacing``,
#: and its ``style_name`` dropdown writes the ``font_weight`` /
#: ``font_style`` pair. Empty string is the identity value for every string
#: attribute (CHARACTER.md's identity-omission rule: a default is stored as
#: absence).
CHARACTER_DEFAULTS: dict[str, Any] = {
    "font_family": "sans-serif",
    "font_size": 12.0,
    "font_weight": "normal",
    "font_style": "normal",
    "text_decoration": "",
    "text_transform": "",
    "font_variant": "",
    "baseline_shift": "",
    "line_height": "",
    "letter_spacing": "",
    "xml_lang": "",
    "aa_mode": "",
    "rotate": "",
    "horizontal_scale": "",
    "vertical_scale": "",
    "kerning": "",
}

CHARACTER_ATTRS: tuple[str, ...] = tuple(CHARACTER_DEFAULTS)


def normalize_character(attrs: dict[str, Any] | None) -> dict[str, Any]:
    """A full attribute map: ``attrs``'s keys over the plain-12pt defaults.

    ``None`` becomes the plain element. ``font_size`` is coerced to float so
    equality does not depend on int-vs-float.
    """
    out = dict(CHARACTER_DEFAULTS)
    if attrs:
        for k, v in attrs.items():
            if k in CHARACTER_DEFAULTS:
                out[k] = v
    out["font_size"] = float(out["font_size"])
    for k, v in out.items():
        if k != "font_size":
            out[k] = "" if v is None else str(v)
    return out


# ---------------------------------------------------------------------------
# The groups
# ---------------------------------------------------------------------------

# Group names. One per set of attributes that must move together.
FONT_FAMILY = "font_family"
STYLE = "style"
FONT_SIZE = "font_size"
LEADING = "leading"
KERNING = "kerning"
TRACKING = "tracking"
VERTICAL_SCALE = "vertical_scale"
HORIZONTAL_SCALE = "horizontal_scale"
BASELINE_SHIFT = "baseline_shift"
ROTATION = "rotation"
CASE = "case"
DECORATION = "decoration"
LANGUAGE = "language"
AA_MODE = "aa_mode"

#: Group -> the element attributes it writes. A group is a single attribute
#: except where one panel control genuinely cannot write one attribute at a
#: time; those three cases are spelled out in
#: :data:`CHARACTER_EDIT_GROUPS`'s docstring.
CHARACTER_GROUP_ATTRS: dict[str, frozenset[str]] = {
    FONT_FAMILY: frozenset({"font_family"}),
    STYLE: frozenset({"font_weight", "font_style"}),
    FONT_SIZE: frozenset({"font_size"}),
    LEADING: frozenset({"line_height"}),
    KERNING: frozenset({"kerning"}),
    TRACKING: frozenset({"letter_spacing"}),
    VERTICAL_SCALE: frozenset({"vertical_scale"}),
    HORIZONTAL_SCALE: frozenset({"horizontal_scale"}),
    BASELINE_SHIFT: frozenset({"baseline_shift"}),
    ROTATION: frozenset({"rotate"}),
    CASE: frozenset({"text_transform", "font_variant"}),
    DECORATION: frozenset({"text_decoration"}),
    LANGUAGE: frozenset({"xml_lang"}),
    AA_MODE: frozenset({"aa_mode"}),
}

#: Character-panel field key -> the attribute group it owns. A field absent
#: from this table owns no element attribute, so editing it writes NOTHING
#: to the document — not even an undo step.
#:
#: The grouping is stated HERE, explicitly, because the reference is the
#: contract: the ports mirror this table rather than the reverse. Three
#: groups are wider than a single attribute, and all three are forced by the
#: panel's own control shape:
#:
#: * ``style_name`` is ONE dropdown whose four entries (Regular / Italic /
#:   Bold / Bold Italic) name a ``font_weight`` + ``font_style`` PAIR. There
#:   is no control that moves the weight without the style, so the pair is
#:   one group. An unrecognised style name writes NEITHER (see
#:   :func:`parse_style_name`).
#: * ``all_caps`` and ``small_caps`` are two toggles whose mutual exclusion
#:   (CHARACTER.md: All Caps wins) can only be expressed by writing
#:   ``text_transform`` and ``font_variant`` together — turning All Caps ON
#:   must clear a small-caps ``font_variant``, which a one-attribute write
#:   cannot do. So both toggles own the same two-attribute CASE group.
#: * ``underline`` and ``strikethrough`` are two toggles feeding ONE CSS
#:   ``text-decoration`` token list. A token list cannot be written a token
#:   at a time, so any decoration edit re-derives the whole list from both
#:   flags — exactly as the dash family re-derives the whole dash pattern in
#:   the Stroke law.
#:
#: Three FIELDS also share the single-attribute BASELINE_SHIFT group:
#: ``superscript``, ``subscript`` and the numeric ``baseline_shift`` all
#: write the one ``baseline-shift`` attribute, with the toggles taking
#: precedence over the number (CHARACTER.md mutual exclusion). Many fields
#: to one group is not a wide group: the group is still one attribute.
#:
#: Notably NOT wide:
#:
#: * ``vertical_scale`` and ``horizontal_scale`` are SEPARATE groups. They
#:   are two independent inputs, so grouping them would let an edit of one
#:   stamp the panel's value for the other onto the element — the mistake
#:   the Stroke law's two arrowhead scales already paid for.
#: * ``font_size`` owns ONLY ``font_size``, never ``line_height``. Leading's
#:   Auto state is stored as an ABSENT ``line-height``, so preserving the
#:   attribute bit-for-bit keeps Auto alive and lets it re-derive against
#:   the new size. The whole-rebuild law needed a post-write hook to bump
#:   the panel's leading in step; the field-scoped law does not.
#:
#: The seven ``snap_*`` flags, ``touch_type_enabled``,
#: ``show_font_height_options`` and ``in_menu_font_previews`` are
#: deliberately absent: they are UI-only state (CHARACTER.md "Panel state"),
#: and toggling one must not push an undo step that changes nothing.
CHARACTER_EDIT_GROUPS: dict[str, str] = {
    "font_family": FONT_FAMILY,
    "style_name": STYLE,
    "font_size": FONT_SIZE,
    "leading": LEADING,
    "kerning": KERNING,
    "tracking": TRACKING,
    "vertical_scale": VERTICAL_SCALE,
    "horizontal_scale": HORIZONTAL_SCALE,
    "baseline_shift": BASELINE_SHIFT,
    "superscript": BASELINE_SHIFT,
    "subscript": BASELINE_SHIFT,
    "character_rotation": ROTATION,
    "all_caps": CASE,
    "small_caps": CASE,
    "underline": DECORATION,
    "strikethrough": DECORATION,
    "language": LANGUAGE,
    "anti_aliasing": AA_MODE,
}


def character_edit_group(key: str) -> str | None:
    """The attribute group Character-panel field ``key`` owns, or ``None``
    when it owns none (so the edit writes nothing to the document)."""
    return CHARACTER_EDIT_GROUPS.get(key)


#: The groups fed by MORE THAN ONE panel field — derived from the table
#: above, never hand-listed. These are the only groups where "the edit names
#: its field" leaves anything open: the group's OTHER fields still have a say
#: in the attribute being written, and the law reads those from THE ELEMENT.
#:
#: THE SIBLING RULE. The committed field comes from panel state; every
#: sibling field of its group comes from the element being edited. Panel
#: state is NOT a picture of the selection — most Character controls display
#: panel-local state, and nothing in this law obliges the panel to have
#: mirrored the element before an edit lands. Reading a sibling from the
#: panel therefore destroys the element's attribute: with
#: ``text-decoration: line-through`` on the element and the panel's
#: strikethrough flag sitting at its ``False`` default, an Underline click
#: wrote a bare ``underline`` and the strikethrough was gone. (Only the Swift
#: port's panel VIEW pushed a mirror, which is why the two ports also
#: disagreed about what the same click meant — CHARPANEL repair, 2026-07-25.)
#:
#: Where the committed field and an element-read sibling CONFLICT, the
#: committed field wins: it is the one the user just chose. The single
#: exception is a numeric field at its identity — committing ``0`` into
#: Baseline Shift carries no intent, because ``0`` is exactly what that input
#: displays while super / sub is set, so the element's super / sub stands.
MULTI_FIELD_GROUPS: frozenset[str] = frozenset(
    g for g in CHARACTER_GROUP_ATTRS
    if sum(1 for v in CHARACTER_EDIT_GROUPS.values() if v == g) > 1
)


# ---------------------------------------------------------------------------
# The panel-field fallbacks
# ---------------------------------------------------------------------------

#: Character-panel field -> the value the law reads when the field is absent
#: from panel state. These are the panel defaults the workspace declares
#: (``workspace/panels/character.yaml`` ``state:``); the reference test
#: machine-checks this table against the generated bundle so a workspace
#: edit cannot silently drift from the law.
CHARACTER_PANEL_FIELDS: dict[str, Any] = {
    "font_family": "sans-serif",
    "style_name": "Regular",
    "font_size": 12.0,
    # `leading` is the one sentinel: None means "no committed leading",
    # which sends the LEADING group to the element's own Auto value.
    "leading": None,
    "kerning": "Auto",
    "tracking": 0.0,
    "vertical_scale": 100.0,
    "horizontal_scale": 100.0,
    "baseline_shift": 0.0,
    "character_rotation": 0.0,
    "all_caps": False,
    "small_caps": False,
    "superscript": False,
    "subscript": False,
    "underline": False,
    "strikethrough": False,
    "language": "en",
    "anti_aliasing": "Sharp",
}


def _field(panel: dict[str, Any], key: str) -> Any:
    val = panel.get(key)
    return CHARACTER_PANEL_FIELDS.get(key) if val is None else val


def _num(panel: dict[str, Any], key: str) -> float:
    return float(_field(panel, key) or 0.0)


def _flag(panel: dict[str, Any], key: str) -> bool:
    return bool(_field(panel, key))


# ---------------------------------------------------------------------------
# The panel -> attribute conversions
# ---------------------------------------------------------------------------

def fmt_num(n: float) -> str:
    """A number formatted for a CSS length / value: integers carry no
    decimal point, fractions drop trailing zeros. Mirrors the Rust
    ``fmt_num`` and the Swift ``_fmtNum``."""
    if n == int(n):
        return str(int(n))
    s = f"{n:.4f}".rstrip("0").rstrip(".")
    return s


def parse_style_name(name: str) -> tuple[str, str] | None:
    """``(font_weight, font_style)`` for a Style dropdown entry, or ``None``
    for an unrecognised name — which leaves BOTH attributes alone rather
    than guessing one."""
    return {
        "Regular": ("normal", "normal"),
        "Italic": ("normal", "italic"),
        "Bold": ("bold", "normal"),
        "Bold Italic": ("bold", "italic"),
        "Italic Bold": ("bold", "italic"),
    }.get(name.strip())


def text_decoration_from_flags(underline: bool, strikethrough: bool) -> str:
    """The CSS ``text-decoration`` token list for the two toggles, in
    alphabetical order so equality never depends on which toggle the user
    hit first."""
    parts = []
    if strikethrough:
        parts.append("line-through")
    if underline:
        parts.append("underline")
    return " ".join(parts)


# ---------------------------------------------------------------------------
# The attribute -> flag inverses (the element side of the sibling rule)
# ---------------------------------------------------------------------------
#
# One per multi-field group. These are what make "the sibling comes from the
# element" executable: they read the element's attribute back into the panel
# flags that feed it. The ports mirror them (Rust `text_decoration_flags` /
# `case_flags` / `baseline_shift_state`, Swift the same names), and the panel
# DISPLAY mirror uses the same derivation — that is the point, there is one
# rule and it lives in the law.

def decoration_flags(text_decoration: str) -> tuple[bool, bool]:
    """``(underline, strikethrough)`` implied by a CSS ``text-decoration``
    token list. Order-insensitive; ``none`` and ``""`` both mean neither."""
    toks = str(text_decoration or "").split()
    return ("underline" in toks, "line-through" in toks)


def case_flags(text_transform: str, font_variant: str) -> tuple[bool, bool]:
    """``(all_caps, small_caps)`` implied by ``text-transform`` /
    ``font-variant``."""
    return (str(text_transform or "") == "uppercase",
            str(font_variant or "") == "small-caps")


def baseline_shift_state(baseline_shift: str) -> tuple[bool, bool, float]:
    """``(superscript, subscript, numeric_pt)`` implied by ``baseline-shift``.

    The three are mutually exclusive on the element: a ``super`` / ``sub``
    keyword carries no number, and a number carries neither keyword.
    """
    val = str(baseline_shift or "").strip()
    if val == "super":
        return (True, False, 0.0)
    if val == "sub":
        return (False, True, 0.0)
    return (False, False, parse_pt(val))


def parse_pt(s: str) -> float:
    """``"4pt"`` / ``"4"`` -> 4.0; anything unparseable -> 0.0."""
    val = str(s or "").strip()
    if val.endswith("pt"):
        val = val[:-2]
    try:
        return float(val)
    except ValueError:
        return 0.0


def kerning_attr(raw: str) -> str:
    """The element's ``kerning`` attribute for a Kerning combo entry.

    Named modes pass through verbatim; a numeric entry is 1/1000 em and
    serialises to ``"{N}em"``. Empty / ``"0"`` / ``"Auto"`` all round-trip
    to an empty attribute, since Auto is the element default.
    """
    val = raw.strip()
    if val in ("", "0", "Auto"):
        return ""
    if val in ("Optical", "Metrics"):
        return val
    try:
        n = float(val)
    except ValueError:
        return ""
    return "" if n == 0.0 else f"{fmt_num(n / 1000.0)}em"


# ---------------------------------------------------------------------------
# The law
# ---------------------------------------------------------------------------

def character_with_field(
    base: dict[str, Any] | None, panel: dict[str, Any], field: str,
) -> dict[str, Any]:
    """``base`` with the group ``field`` owns overwritten, and every other
    attribute left exactly as it was.

    ``field`` is the panel field the user COMMITTED. It must own a group:
    callers check :func:`character_edit_group` first, because a field owning
    no group writes nothing at all — not even an undo step — and that is a
    decision about whether to touch the document, not about values. An
    unknown field here yields ``base`` unchanged.

    Only the committed field is read from ``panel``. Everything else comes
    from ``base``:

    * every attribute outside the group, trivially — that is field scoping;
    * the SIBLING fields of a multi-field group (:data:`MULTI_FIELD_GROUPS`),
      read back out of ``base``'s own attributes by the inverses above;
    * and the values a derivation needs from the element — notably the
      LEADING group's Auto test, which compares the panel's leading against
      the ELEMENT's ``font_size × 1.2`` rather than the panel's font size.
      The whole-rebuild law used the panel's, which was harmless only because
      it rewrote the size in the same breath; under the field-scoped law a
      leading edit must not consult a font-size field the user did not touch.
    """
    group = CHARACTER_EDIT_GROUPS.get(field)
    c = normalize_character(base)
    if group is None:
        return c
    if group == FONT_FAMILY:
        c["font_family"] = str(_field(panel, "font_family"))
    elif group == STYLE:
        parsed = parse_style_name(str(_field(panel, "style_name")))
        if parsed is not None:
            c["font_weight"], c["font_style"] = parsed
    elif group == FONT_SIZE:
        c["font_size"] = _num(panel, "font_size")
    elif group == LEADING:
        # Auto (an ABSENT line-height) is 120% of the element's font size.
        auto = c["font_size"] * 1.2
        leading = panel.get("leading")
        if leading is None or abs(float(leading) - auto) < 1e-6:
            c["line_height"] = ""
        else:
            c["line_height"] = f"{fmt_num(float(leading))}pt"
    elif group == KERNING:
        c["kerning"] = kerning_attr(str(_field(panel, "kerning")))
    elif group == TRACKING:
        tracking = _num(panel, "tracking")
        c["letter_spacing"] = (
            "" if tracking == 0.0 else f"{fmt_num(tracking / 1000.0)}em")
    elif group == VERTICAL_SCALE:
        v = _num(panel, "vertical_scale")
        c["vertical_scale"] = "" if v == 100.0 else fmt_num(v)
    elif group == HORIZONTAL_SCALE:
        h = _num(panel, "horizontal_scale")
        c["horizontal_scale"] = "" if h == 100.0 else fmt_num(h)
    elif group == BASELINE_SHIFT:
        # THREE fields, one attribute: the two the user did not commit come
        # from the element. A toggle turned OFF therefore falls back to the
        # element's other keyword or its own numeric shift instead of wiping
        # the attribute with the panel's 0.
        sup, sub, num = baseline_shift_state(c["baseline_shift"])
        if field == "superscript":
            sup = _flag(panel, "superscript")
            sub = False if sup else sub
        elif field == "subscript":
            sub = _flag(panel, "subscript")
            sup = False if sub else sup
        else:
            num = _num(panel, "baseline_shift")
            # An explicit shift replaces super / sub; a committed 0 does not,
            # because 0 is what the input displays while super / sub is set.
            if num != 0.0:
                sup = sub = False
        if sup:
            c["baseline_shift"] = "super"
        elif sub:
            c["baseline_shift"] = "sub"
        else:
            c["baseline_shift"] = "" if num == 0.0 else f"{fmt_num(num)}pt"
    elif group == ROTATION:
        rot = _num(panel, "character_rotation")
        c["rotate"] = "" if rot == 0.0 else fmt_num(rot)
    elif group == CASE:
        # The sibling toggle comes from the element, so turning one off
        # cannot clear the other's attribute; the committed toggle turned ON
        # still wins the exclusion.
        all_caps, small_caps = case_flags(c["text_transform"], c["font_variant"])
        if field == "all_caps":
            all_caps = _flag(panel, "all_caps")
        else:
            small_caps = _flag(panel, "small_caps")
            all_caps = False if small_caps else all_caps
        c["text_transform"] = "uppercase" if all_caps else ""
        c["font_variant"] = "small-caps" if (small_caps and not all_caps) else ""
    elif group == DECORATION:
        # One token list, two fields: the token the user did not commit is
        # read off the element, so underlining never un-strikes.
        underline, strikethrough = decoration_flags(c["text_decoration"])
        if field == "underline":
            underline = _flag(panel, "underline")
        else:
            strikethrough = _flag(panel, "strikethrough")
        c["text_decoration"] = text_decoration_from_flags(
            underline, strikethrough)
    elif group == LANGUAGE:
        c["xml_lang"] = str(_field(panel, "language"))
    elif group == AA_MODE:
        aa = str(_field(panel, "anti_aliasing"))
        c["aa_mode"] = "" if aa in ("Sharp", "") else aa
    return c
