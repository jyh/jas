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

import pytest

from workspace_interpreter.character_law import (
    CHARACTER_EDIT_GROUPS,
    CHARACTER_GROUP_ATTRS,
    CHARACTER_PANEL_FIELDS,
    character_edit_group,
    character_with_group,
    normalize_character,
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
        got = character_with_group(_base(vec), _panel(vec), group)
        assert got == _expected(vec), name

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
            got = character_with_group(base, panel, group)
            changed = {k for k in got if got[k] != normalize_character(base)[k]}
            assert changed <= CHARACTER_GROUP_ATTRS[group], (
                f"{field} ({group}) wrote outside its group: "
                f"{changed - CHARACTER_GROUP_ATTRS[group]}"
            )

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
        got = character_with_group(
            base, panel, character_edit_group("horizontal_scale"))
        assert got["horizontal_scale"] == "150"
        # The panel's vertical scale is the 100 identity; the element's is 90.
        assert got["vertical_scale"] == "90"


class TestFontSizeDoesNotOwnTheLeading:
    """The other ruling: Auto leading is an ABSENT line-height, so
    ``font_size`` owning only ``font_size`` keeps Auto alive without the
    post-write hook the whole-rebuild law needed."""

    def test_auto_survives_a_size_edit(self):
        got = character_with_group(
            {"font_size": 30.0, "line_height": ""},
            {**_strip(_CORPUS["panel_defaults"]), "font_size": 18.0,
             "leading": 36.0},
            character_edit_group("font_size"))
        assert got["font_size"] == 18.0
        assert got["line_height"] == ""

    def test_an_explicit_leading_survives_a_size_edit(self):
        got = character_with_group(
            {"font_size": 30.0, "line_height": "40pt"},
            {**_strip(_CORPUS["panel_defaults"]), "font_size": 18.0},
            character_edit_group("font_size"))
        assert got["line_height"] == "40pt"

    def test_the_auto_test_reads_the_elements_font_size(self):
        """A leading edit compares against the ELEMENT's font size, not a
        panel field the user did not touch. The element is 30pt, so 36
        is its Auto value even though the panel's size field says 12."""
        got = character_with_group(
            {"font_size": 30.0, "line_height": "40pt"},
            {**_strip(_CORPUS["panel_defaults"]), "leading": 36.0},
            character_edit_group("leading"))
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


class TestTheOldLawFails:
    """The corpus must REJECT the whole-rebuild law it replaced — otherwise
    it would gate nothing. Rebuilds the pre-CHARPANEL behaviour (the whole
    attribute set from panel state on every edit) and asserts JYH's repro
    fails against it."""

    @staticmethod
    def _whole_rebuild(panel: dict) -> dict:
        """The old law: every attribute from panel state, the element's
        existing character state ignored entirely."""
        c = normalize_character(None)
        for group in CHARACTER_GROUP_ATTRS:
            c = character_with_group(c, panel, group)
        return c

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
