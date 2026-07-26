"""CHARPANEL: the field-scoped Character-panel apply law (reference arm).

Runs the shared cross-language corpus
``test_fixtures/character_apply/panel_edit.json`` against
``workspace_interpreter.character_law`` — the reference statement of the law.
The Rust (``cross_language_test.rs``) and Swift
(``CharacterApplyCorpusTests``) arms read the SAME fixture, so all three live
implementations are pinned to one contract.
"""

from __future__ import annotations

import json
import os
import sys

# The reference's element / document model lives beside the frozen Python
# app (``geometry.element``, ``document.document``) — the same import the
# Stroke arm and `effects.py` itself use for the bridge-level tests.
_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "jas"))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

import pytest

from workspace_interpreter.character_law import (
    BASELINE_SHIFT,
    CASE,
    CHARACTER_EDIT_GROUPS,
    CHARACTER_GROUP_ATTRS,
    CHARACTER_PANEL_FIELDS,
    DECORATION,
    MULTI_FIELD_GROUPS,
    character_edit_group,
    character_with_field,
    fmt_num,
    kerning_attr,
    normalize_character,
    parse_style_name,
    text_decoration_from_flags,
)

FIXTURE = os.path.join(
    os.path.dirname(__file__), "..", "..", "test_fixtures", "character_apply",
    "panel_edit.json",
)

WORKSPACE_JSON = os.path.join(
    os.path.dirname(__file__), "..", "..", "workspace", "workspace.json")


def _load() -> dict:
    with open(FIXTURE) as f:
        return json.load(f)


_CORPUS = _load()


def _strip(d: dict) -> dict:
    return {k: v for k, v in d.items() if not k.startswith("_")}


def _base(vec: dict) -> dict:
    """A vector's ``base``: a literal attribute delta, or the name of a
    shared one. Either way it is a delta over ``element_defaults``."""
    base = vec["base"]
    if isinstance(base, str):
        base = _CORPUS[base]
    return {**_strip(_CORPUS["element_defaults"]), **_strip(base)}


def _panel(vec: dict) -> dict:
    return {**_strip(_CORPUS["panel_defaults"]), **_strip(vec["panel"])}


def _expected(vec: dict) -> dict:
    """The vector's ``expected`` DELTA merged over its base."""
    return normalize_character({**_base(vec), **vec["expected"]})


def _names() -> list[str]:
    return [v["name"] for v in _CORPUS["vectors"]]


def _vec(name: str) -> dict:
    return next(v for v in _CORPUS["vectors"] if v["name"] == name)


class TestPanelEditCorpus:
    """The group law: an edit names its field, and only that field's group
    is written."""

    @pytest.mark.parametrize("name", _names())
    def test_vector(self, name):
        vec = _vec(name)
        assert vec["op"] == "panel_edit", f"{name}: unknown op"
        group = character_edit_group(vec["edited"])
        if vec["expected"] is None:
            # No group -> the edit reaches the document not at all.
            assert group is None, (
                f"{name}: {vec['edited']} must own no attribute group"
            )
            return
        assert group is not None, f"{name}: {vec['edited']} must own a group"
        got = character_with_field(_base(vec), _panel(vec), vec["edited"])
        assert got == _expected(vec), name

    @pytest.mark.parametrize("name", _names())
    def test_a_multi_field_vector_names_only_its_own_field(self, name):
        """The anti-vacuity gate for the sibling rule. A vector of a
        multi-field group may NOT seed its siblings in ``panel``: if it did,
        it would pass just as happily under a law that reads siblings from
        panel state, which is exactly how the first cut of this corpus went
        green while the Rust port destroyed the element's line-through."""
        vec = _vec(name)
        group = character_edit_group(vec["edited"])
        if group not in MULTI_FIELD_GROUPS:
            return
        siblings = {f for f, g in CHARACTER_EDIT_GROUPS.items()
                    if g == group and f != vec["edited"]}
        named = set(_strip(vec["panel"]))
        assert not (named & siblings), (
            f"{name}: seeds the sibling field(s) {sorted(named & siblings)}; "
            f"a multi-field vector must name only '{vec['edited']}' so the "
            f"siblings have to come from the element"
        )

    def test_the_corpus_is_not_vacuous(self):
        """Every group in the table must be exercised by a vector that
        expects a write."""
        groups = {
            character_edit_group(v["edited"])
            for v in _CORPUS["vectors"]
            if v["expected"] is not None
        }
        assert groups == set(CHARACTER_EDIT_GROUPS.values()), (
            "the corpus must pin every attribute group"
        )

    def test_every_group_writes_only_its_own_attributes(self):
        """The group table and the law agree: running a group over the rich
        run may change only the attributes ``CHARACTER_GROUP_ATTRS`` claims
        for it. This is the law's invariant stated independently of any
        vector's expected values."""
        base = _base({"base": "rich_run"})
        panel = _strip(_CORPUS["panel_defaults"])
        for field, group in CHARACTER_EDIT_GROUPS.items():
            got = character_with_field(base, panel, field)
            changed = {k for k in got if got[k] != normalize_character(base)[k]}
            assert changed <= CHARACTER_GROUP_ATTRS[group], (
                f"{field} ({group}) wrote outside its group: "
                f"{changed - CHARACTER_GROUP_ATTRS[group]}"
            )

    def test_only_three_groups_are_fed_by_more_than_one_field(self):
        """``MULTI_FIELD_GROUPS`` is the set the sibling rule applies to, and
        it must be derivable from the field table rather than asserted."""
        counts: dict[str, int] = {}
        for group in CHARACTER_EDIT_GROUPS.values():
            counts[group] = counts.get(group, 0) + 1
        assert {g for g, n in counts.items() if n > 1} == set(MULTI_FIELD_GROUPS)
        assert set(MULTI_FIELD_GROUPS) == {CASE, DECORATION, BASELINE_SHIFT}

    def test_a_ui_only_field_owns_no_group(self):
        for field in ("snap_baseline", "snap_x_height", "snap_glyph_bounds",
                      "snap_proximity_guides", "snap_angular_guides",
                      "snap_anchor_point", "snap_to_glyph_visible",
                      "touch_type_enabled", "in_menu_font_previews"):
            assert character_edit_group(field) is None, field


class TestTheScalesAreSeparateGroups:
    """Called out because it is the ruling the Stroke law already paid for:
    two independent inputs must not share a group, or an edit of one stamps
    the panel's value for the other onto the element."""

    def test_the_two_scales_are_different_groups(self):
        assert character_edit_group("horizontal_scale") != character_edit_group(
            "vertical_scale")

    def test_a_horizontal_edit_leaves_the_vertical(self):
        base = _base({"base": "rich_run"})
        panel = {**_strip(_CORPUS["panel_defaults"]), "horizontal_scale": 150.0}
        got = character_with_field(base, panel, "horizontal_scale")
        assert got["horizontal_scale"] == "150"
        # The panel's vertical scale is the 100 identity; the element's is 90.
        assert got["vertical_scale"] == "90"


class TestFontSizeDoesNotOwnTheLeading:
    """The other ruling: Auto leading is an ABSENT line-height, so
    ``font_size`` owning only ``font_size`` keeps Auto alive without the
    post-write hook the whole-rebuild law needed."""

    def test_auto_survives_a_size_edit(self):
        got = character_with_field(
            {"font_size": 30.0, "line_height": ""},
            {**_strip(_CORPUS["panel_defaults"]), "font_size": 18.0,
             "leading": 36.0},
            "font_size")
        assert got["font_size"] == 18.0
        assert got["line_height"] == ""

    def test_an_explicit_leading_survives_a_size_edit(self):
        got = character_with_field(
            {"font_size": 30.0, "line_height": "40pt"},
            {**_strip(_CORPUS["panel_defaults"]), "font_size": 18.0},
            "font_size")
        assert got["line_height"] == "40pt"

    def test_the_auto_test_reads_the_elements_font_size(self):
        """A leading edit compares against the ELEMENT's font size, not a
        panel field the user did not touch. The element is 30pt, so 36
        is its Auto value even though the panel's size field says 12."""
        got = character_with_field(
            {"font_size": 30.0, "line_height": "40pt"},
            {**_strip(_CORPUS["panel_defaults"]), "leading": 36.0},
            "leading")
        assert got["line_height"] == ""


class TestTheFallbacksAreTheWorkspaceDefaults:
    """When a field is absent from panel state, the value the law reads is
    the panel default the workspace declares — not a hand-written constant.
    Machine-checked against the generated bundle so a workspace edit cannot
    silently drift from the law, and so the corpus's ``panel_defaults`` block
    has to agree with it too."""

    @classmethod
    def _declared(cls) -> dict:
        with open(WORKSPACE_JSON) as f:
            state = json.load(f)["panels"]["character_panel_content"]["state"]
        return {k: (v.get("default") if isinstance(v, dict) else v)
                for k, v in state.items()}

    def test_the_fallback_table_matches_the_workspace(self):
        declared = self._declared()
        for field, fallback in CHARACTER_PANEL_FIELDS.items():
            assert field in declared, f"{field} is not a declared panel field"
            if field == "leading":
                # The one sentinel: None means "no committed leading", which
                # sends the LEADING group to the element's own Auto value.
                assert fallback is None
                continue
            assert fallback == declared[field], (
                f"{field}: fallback {fallback!r} != workspace default "
                f"{declared[field]!r}"
            )

    def test_the_corpus_panel_defaults_match_the_workspace(self):
        declared = self._declared()
        for field, value in _strip(_CORPUS["panel_defaults"]).items():
            assert value == declared[field], (
                f"{field}: corpus default {value!r} != workspace default "
                f"{declared[field]!r}"
            )

    def test_every_edit_group_field_is_a_declared_panel_field(self):
        declared = self._declared()
        for field in CHARACTER_EDIT_GROUPS:
            assert field in declared, f"{field} is not a declared panel field"


def _whole_panel_attrs(panel: dict) -> dict:
    """Every character attribute derived from panel state alone — a FROZEN
    copy of the retired derivation, written out rather than composed from
    :func:`character_with_field` so the two retired laws below cannot drift
    into agreement with the live one.
    """
    leading = panel.get("leading")
    tracking = float(panel.get("tracking") or 0.0)
    v = float(panel.get("vertical_scale") or 0.0)
    h = float(panel.get("horizontal_scale") or 0.0)
    bs = float(panel.get("baseline_shift") or 0.0)
    rot = float(panel.get("character_rotation") or 0.0)
    aa = str(panel.get("anti_aliasing") or "")
    fw, fst = parse_style_name(str(panel.get("style_name") or "")) or (
        "normal", "normal")
    size = float(panel.get("font_size") or 0.0)
    return {
        "font_family": str(panel.get("font_family") or ""),
        "font_size": size,
        "font_weight": fw,
        "font_style": fst,
        "text_decoration": text_decoration_from_flags(
            bool(panel.get("underline")), bool(panel.get("strikethrough"))),
        "text_transform": "uppercase" if panel.get("all_caps") else "",
        "font_variant": ("small-caps" if (panel.get("small_caps")
                                          and not panel.get("all_caps")) else ""),
        "baseline_shift": ("super" if panel.get("superscript")
                           else "sub" if panel.get("subscript")
                           else "" if bs == 0.0 else f"{fmt_num(bs)}pt"),
        # The retired law's Auto test read the PANEL's font size.
        "line_height": ("" if leading is None or abs(float(leading) - size * 1.2) < 1e-6
                        else f"{fmt_num(float(leading))}pt"),
        "letter_spacing": "" if tracking == 0.0 else f"{fmt_num(tracking / 1000.0)}em",
        "xml_lang": str(panel.get("language") or ""),
        "aa_mode": "" if aa in ("Sharp", "") else aa,
        "rotate": "" if rot == 0.0 else fmt_num(rot),
        "horizontal_scale": "" if h == 100.0 else fmt_num(h),
        "vertical_scale": "" if v == 100.0 else fmt_num(v),
        "kerning": kerning_attr(str(panel.get("kerning") or "")),
    }


def _stale_sibling_law(base: dict, panel: dict, field: str) -> dict:
    """The FIRST cut of the field-scoped law (pre-H1): field-scoped, but a
    multi-field group took its SIBLING values from panel state too. That is
    the law the ports shipped before CHARPANEL's repair — and the reason the
    Rust port destroyed an element's line-through on an Underline click while
    the corpus stayed green, because the corpus had handed it a mirrored
    sibling. Frozen here so the discriminating vectors can be proved red
    against it."""
    group = character_edit_group(field)
    if group not in MULTI_FIELD_GROUPS:
        return character_with_field(base, panel, field)
    c = normalize_character(base)
    whole = _whole_panel_attrs(panel)
    for attr in CHARACTER_GROUP_ATTRS[group]:
        c[attr] = whole[attr]
    return c


class TestTheOldLawFails:
    """The corpus must REJECT the whole-rebuild law it replaced — otherwise
    it would gate nothing. Rebuilds the pre-CHARPANEL behaviour (the whole
    attribute set from panel state on every edit) and asserts JYH's repro
    fails against it."""

    @staticmethod
    def _whole_rebuild(panel: dict) -> dict:
        """The old law: every attribute from panel state, the element's
        existing character state ignored entirely."""
        return normalize_character(_whole_panel_attrs(panel))

    def test_jyh_repro_fails_under_the_old_law(self):
        vec = _vec("tracking_edit_preserves_the_rich_run")
        old = self._whole_rebuild(_panel(vec))
        want = _expected(vec)
        # The element is a 30pt Georgia run; the old law hands back the
        # panel's 12pt sans-serif.
        assert want["font_family"] == "Georgia"
        assert old["font_family"] == "sans-serif"
        assert want["font_size"] == 30.0
        assert old["font_size"] == 12.0
        assert old != want, (
            "the repro vector must FAIL against the whole-rebuild law"
        )

    def test_every_rich_vector_fails_under_the_old_law(self):
        """Not just the repro: every vector built on the rich run
        discriminates the two laws."""
        for vec in _CORPUS["vectors"]:
            if vec["base"] != "rich_run" or vec["expected"] is None:
                continue
            old = self._whole_rebuild(_panel(vec))
            assert old != _expected(vec), (
                f"{vec['name']}: does not discriminate the old law"
            )

    def test_the_ui_only_vectors_discriminate_too(self):
        """A UI-only toggle wrote the whole panel over the element under the
        old law; under the new one it writes nothing. The discriminator is
        that the old law's output differs from the untouched element."""
        for vec in _CORPUS["vectors"]:
            if vec["expected"] is not None:
                continue
            old = self._whole_rebuild(_panel(vec))
            assert old != normalize_character(_base(vec)), (
                f"{vec['name']}: a no-group edit must be observably different "
                f"from the whole-rebuild law"
            )


class TestTheStaleSiblingLawFails:
    """The corpus must also REJECT the law CHARPANEL's first cut shipped:
    field-scoped, but reading a multi-field group's SIBLINGS from panel state.
    That is the defect this repair exists for — under it, an Underline click
    on an element carrying ``text-decoration: line-through`` wrote a bare
    ``underline`` and destroyed the strikethrough. Every vector marked
    STALE-SIBLING DISCRIMINATOR must come out RED against it.
    """

    DISCRIMINATORS = (
        "underline_edit_rewrites_the_whole_decoration_list",
        "underline_off_keeps_the_strikethrough",
        "strikethrough_edit_writes_the_decoration",
        "strikethrough_off_keeps_the_underline",
        "all_caps_off_keeps_a_small_caps_variant",
        "small_caps_off_keeps_the_all_caps",
        "superscript_off_keeps_the_elements_numeric_shift",
        "superscript_off_keeps_the_elements_subscript",
        "a_zero_number_defers_to_the_elements_superscript",
    )

    @pytest.mark.parametrize("name", DISCRIMINATORS)
    def test_the_discriminator_is_red_against_the_stale_sibling_law(self, name):
        vec = _vec(name)
        stale = _stale_sibling_law(_base(vec), _panel(vec), vec["edited"])
        assert stale != _expected(vec), (
            f"{name} passes under the stale-sibling law, so it gates nothing"
        )

    def test_the_named_discriminators_are_the_marked_ones(self):
        """The list above must be exactly the vectors whose ``_comment`` says
        so, or a future vector could be marked and then never checked."""
        marked = {v["name"] for v in _CORPUS["vectors"]
                  if "STALE-SIBLING DISCRIMINATOR" in v.get("_comment", "")}
        assert marked == set(self.DISCRIMINATORS)

    def test_jyhs_line_through_case_loses_data_under_the_stale_sibling_law(self):
        """Spelled out because it is the reported defect, not an abstraction:
        the element is struck through, the user clicks Underline, and the
        retired law hands back a decoration with the line-through GONE."""
        vec = _vec("underline_edit_rewrites_the_whole_decoration_list")
        stale = _stale_sibling_law(_base(vec), _panel(vec), "underline")
        assert stale["text_decoration"] == "underline", "the data loss"
        assert _expected(vec)["text_decoration"] == "line-through underline"

    def test_the_bridge_is_red_against_the_stale_sibling_law_too(self):
        """The bridge (below) is the level the Stroke law's one reference-only
        divergence hid at, so the rejection has to be proved THERE, not only
        against the pure law."""
        vec = _vec("underline_edit_rewrites_the_whole_decoration_list")
        got = _run_bridge("underline", base=_base(vec), **_strip(vec["panel"]))
        assert got.text_decoration == "line-through underline"
        stale = _stale_sibling_law(_base(vec), _panel(vec), "underline")
        assert stale["text_decoration"] != got.text_decoration

    def test_every_group_still_reads_its_own_committed_field_from_the_panel(self):
        """The sibling rule must not have made the law ignore panel state:
        for every field, committing a NON-default value has to change the
        element. Guards the opposite over-correction (reading everything from
        the element, which would make the panel inert)."""
        base = _base({"base": "rich_run"})
        committed = {
            "font_family": "Helvetica", "style_name": "Italic",
            "font_size": 18.0, "leading": 22.0, "kerning": "Metrics",
            "tracking": 120.0, "vertical_scale": 55.0,
            "horizontal_scale": 65.0, "baseline_shift": -7.0,
            "superscript": True, "subscript": True,
            "character_rotation": 42.0, "all_caps": False, "small_caps": True,
            "underline": False, "strikethrough": True,
            "language": "ja", "anti_aliasing": "Smooth",
        }
        for field, value in committed.items():
            panel = {**_strip(_CORPUS["panel_defaults"]), field: value}
            got = character_with_field(base, panel, field)
            assert got != normalize_character(base), (
                f"committing {field}={value!r} changed nothing"
            )


# ---------------------------------------------------------------------------
# The bridge: the same law, exercised through the store + document wiring
# ---------------------------------------------------------------------------
#
# CHARPANEL's first cut had no reference bridge at all — the law sat alone and
# `effects.py` carried no Character apply. That is exactly the level the
# STROKE campaign's one reference-only divergence hid at (a lossy colour round
# trip in a correct law's wiring), so the Character apply gets a reference
# gate here too. Mirrors TestBridgeAppliesTheFieldScopedLaw in
# test_stroke_apply.py.

class _FakeModel:
    """The slice of the app model the character bridge touches."""

    def __init__(self, document):
        self.document = document
        self.edits = 0

    def edit_document(self, doc):
        self.document = doc
        self.edits += 1


class _FakeController:
    def __init__(self, model):
        self.model = model


def _text_from_attrs(attrs: dict):
    """A reference ``Text`` carrying the corpus's sixteen attributes."""
    from geometry.element import Text
    return Text(x=0.0, y=0.0, content="hello", **attrs)


def _doc_with_text(elem):
    from document.document import Document, ElementSelection
    from geometry.element import Layer
    return Document(layers=(Layer(children=(elem,)),),
                    selection=frozenset({ElementSelection.all((0, 0))}))


def _run_bridge(edited: str, base: dict | None = None, **panel):
    """Run the reference bridge over a selected Text built from ``base``
    (default: the rich run) with the panel at its corpus defaults plus
    ``panel``. Returns the resulting element."""
    from workspace_interpreter.effects import apply_character_panel_to_selection
    from workspace_interpreter.state_store import StateStore
    attrs = normalize_character(base if base is not None
                                else _base({"base": "rich_run"}))
    model = _FakeModel(_doc_with_text(_text_from_attrs(attrs)))
    store = StateStore()
    store.init_panel("character_panel_content",
                     {**_strip(_CORPUS["panel_defaults"]), **panel})
    apply_character_panel_to_selection(store, _FakeController(model), edited)
    _run_bridge.last_model = model
    return model.document.get_element((0, 0))


class TestBridgeAppliesTheFieldScopedLaw:
    """``apply_character_panel_to_selection`` — the wiring, not just the pure
    law."""

    def test_jyh_repro_a_tracking_edit_keeps_the_rich_run(self):
        got = _run_bridge("tracking", tracking=50.0)
        rich = normalize_character(_base({"base": "rich_run"}))
        assert got.letter_spacing == "0.05em", "the edited field lands"
        for attr, want in rich.items():
            if attr == "letter_spacing":
                continue
            assert getattr(got, attr) == want, f"{attr} preserved"

    def test_a_ui_only_toggle_writes_nothing_at_all(self):
        got = _run_bridge("snap_baseline")
        assert _run_bridge.last_model.edits == 0, "no undo step"
        rich = normalize_character(_base({"base": "rich_run"}))
        for attr, want in rich.items():
            assert getattr(got, attr) == want

    def test_a_non_text_selection_writes_nothing(self):
        from document.document import Document, ElementSelection
        from geometry.element import Layer, Rect
        from workspace_interpreter.effects import (
            apply_character_panel_to_selection,
        )
        from workspace_interpreter.state_store import StateStore
        rect = Rect(x=0.0, y=0.0, width=10.0, height=10.0)
        model = _FakeModel(Document(
            layers=(Layer(children=(rect,)),),
            selection=frozenset({ElementSelection.all((0, 0))})))
        store = StateStore()
        store.init_panel("character_panel_content",
                         {**_strip(_CORPUS["panel_defaults"]),
                          "font_family": "Arial"})
        apply_character_panel_to_selection(
            store, _FakeController(model), "font_family")
        assert model.edits == 0, "a non-text selection pushes no undo step"

    def test_the_bridge_reads_siblings_from_each_element(self):
        """PER ELEMENT, and per element's OWN siblings: two selected text
        elements with different decorations, one Underline click."""
        from document.document import Document, ElementSelection
        from geometry.element import Layer
        from workspace_interpreter.effects import (
            apply_character_panel_to_selection,
        )
        from workspace_interpreter.state_store import StateStore
        struck = _text_from_attrs(normalize_character(
            {"text_decoration": "line-through"}))
        plain = _text_from_attrs(normalize_character({"text_decoration": ""}))
        model = _FakeModel(Document(
            layers=(Layer(children=(struck, plain)),),
            selection=frozenset({ElementSelection.all((0, 0)),
                                 ElementSelection.all((0, 1))})))
        store = StateStore()
        store.init_panel("character_panel_content",
                         {**_strip(_CORPUS["panel_defaults"]),
                          "underline": True})
        apply_character_panel_to_selection(
            store, _FakeController(model), "underline")
        assert model.document.get_element((0, 0)).text_decoration == (
            "line-through underline")
        assert model.document.get_element((0, 1)).text_decoration == "underline"
        assert model.edits == 1, "a multi-element edit is ONE undo step"

    def test_the_bridge_writes_a_textpath_too(self):
        from document.document import Document, ElementSelection
        from geometry.element import Layer, TextPath
        from workspace_interpreter.effects import (
            apply_character_panel_to_selection,
        )
        from workspace_interpreter.state_store import StateStore
        tp = TextPath(d=(), content="hi", font_family="Georgia",
                      text_decoration="line-through")
        model = _FakeModel(Document(
            layers=(Layer(children=(tp,)),),
            selection=frozenset({ElementSelection.all((0, 0))})))
        store = StateStore()
        store.init_panel("character_panel_content",
                         {**_strip(_CORPUS["panel_defaults"]),
                          "underline": True})
        apply_character_panel_to_selection(
            store, _FakeController(model), "underline")
        got = model.document.get_element((0, 0))
        assert got.text_decoration == "line-through underline"
        assert got.font_family == "Georgia", "the family is preserved"

    @pytest.mark.parametrize("name", _names())
    def test_the_bridge_agrees_with_the_pure_law_on_every_vector(self, name):
        """No second derivation: the wiring's answer must be the law's answer
        for every vector in the corpus."""
        vec = _vec(name)
        base = _base(vec)
        got = _run_bridge(vec["edited"], base=base, **_strip(vec["panel"]))
        if vec["expected"] is None:
            assert _run_bridge.last_model.edits == 0
            want = normalize_character(base)
        else:
            want = _expected(vec)
        for attr, value in want.items():
            assert getattr(got, attr) == value, f"{name}: {attr}"


class TestTheReferencePanelReaderIsPanelScopedOnly:
    """Unlike Stroke there is no flat-global spelling: a global
    ``character_font_family`` must NOT be picked up, and an absent field must
    stay absent so the law's own declared default (and ``leading``'s "no
    committed leading" sentinel) still applies."""

    def test_a_global_is_not_a_fallback(self):
        from workspace_interpreter.effects import character_panel_state
        from workspace_interpreter.state_store import StateStore
        store = StateStore()
        store.init_panel("character_panel_content", {})
        store.set("character_font_family", "Wingdings")
        assert "font_family" not in character_panel_state(store)

    def test_an_absent_leading_stays_absent(self):
        from workspace_interpreter.effects import character_panel_state
        from workspace_interpreter.state_store import StateStore
        store = StateStore()
        store.init_panel("character_panel_content", {"tracking": 25.0})
        panel = character_panel_state(store)
        assert "leading" not in panel
        # ... and the law then takes the ELEMENT's Auto value.
        got = character_with_field({"font_size": 30.0, "line_height": "40pt"},
                                   panel, "leading")
        assert got["line_height"] == ""
