"""STROKEWIDTH: the field-scoped Stroke-panel apply law (reference arm).

Runs the shared cross-language corpus
``test_fixtures/stroke_apply/panel_edit.json`` against
``workspace_interpreter.stroke_law`` — the reference statement of the law.
The Rust (``cross_language_test.rs``) and Swift (``CrossLanguageTests``)
arms read the SAME fixture, so all three live implementations are pinned to
one contract.
"""

from __future__ import annotations

import json
import os

import pytest

from workspace_interpreter.stroke_law import (
    normalize_stroke,
    recolor_stroke,
    stroke_edit_group,
    stroke_with_group,
)

FIXTURE = os.path.join(
    os.path.dirname(__file__), "..", "..", "test_fixtures", "stroke_apply",
    "panel_edit.json",
)


def _load() -> dict:
    with open(FIXTURE) as f:
        return json.load(f)


_CORPUS = _load()


def _resolve_base(vec: dict) -> dict | None:
    """A vector's ``base``: a literal attribute map, the name of a shared
    map, or None for an element carrying no stroke."""
    base = vec.get("base")
    if isinstance(base, str):
        base = _CORPUS[base]
    return base


def _effective_base(vec: dict) -> dict | None:
    """What the law builds on: the element's stroke, or the vector's
    ``fallback`` when the element has none."""
    return _resolve_base(vec) or vec.get("fallback")


def _expected(vec: dict) -> dict:
    """The vector's ``expected`` DELTA merged over its effective base."""
    return normalize_stroke({**(_effective_base(vec) or {}), **vec["expected"]})


def _ids(op: str) -> list[str]:
    return [v["name"] for v in _CORPUS["vectors"] if v["op"] == op]


def _vec(name: str) -> dict:
    return next(v for v in _CORPUS["vectors"] if v["name"] == name)


class TestPanelEditCorpus:
    """The group law: an edit names its field, and only that field's group
    is written."""

    @pytest.mark.parametrize("name", _ids("panel_edit"))
    def test_vector(self, name):
        vec = _vec(name)
        panel = {**_CORPUS["panel_defaults"], **vec["panel"]}
        group = stroke_edit_group(vec["edited"])
        if vec["expected"] is None:
            # No group -> the edit reaches the document not at all.
            assert group is None, (
                f"{name}: {vec['edited']} must own no attribute group"
            )
            return
        assert group is not None, f"{name}: {vec['edited']} must own a group"
        got = stroke_with_group(
            _effective_base(vec), panel, group, vec["committed_width"],
        )
        assert got == _expected(vec), name

    def test_the_corpus_is_not_vacuous(self):
        """Every panel_edit vector that expects a write must be reachable,
        and the corpus must actually exercise every group."""
        groups = {
            stroke_edit_group(v["edited"])
            for v in _CORPUS["vectors"]
            if v["op"] == "panel_edit" and v["expected"] is not None
        }
        from workspace_interpreter.stroke_law import STROKE_EDIT_GROUPS
        assert groups == set(STROKE_EDIT_GROUPS.values()), (
            "the corpus must pin every attribute group"
        )


class TestColorPickCorpus:
    """The colour route: a colour pick changes the colour and nothing
    else."""

    @pytest.mark.parametrize("name", _ids("color_pick"))
    def test_vector(self, name):
        vec = _vec(name)
        got = recolor_stroke(_resolve_base(vec), vec["color"])
        assert got == _expected(vec), name


class TestTheOldLawFails:
    """The corpus must REJECT the whole-rebuild law it replaced — otherwise
    it would gate nothing. Rebuilds the pre-STROKEWIDTH behaviour (the whole
    Stroke from panel state on every edit) and asserts JYH's repro fails
    against it."""

    @staticmethod
    def _whole_rebuild(panel: dict, committed_width: float) -> dict:
        """The old law: every attribute from panel state, the element's
        existing stroke ignored entirely."""
        from workspace_interpreter.stroke_law import STROKE_EDIT_GROUPS
        s = normalize_stroke(None)
        for group in set(STROKE_EDIT_GROUPS.values()):
            s = stroke_with_group(s, panel, group, committed_width)
        return s

    def test_jyh_repro_fails_under_the_old_law(self):
        vec = _vec("arrowhead_edit_preserves_rich_width")
        panel = {**_CORPUS["panel_defaults"], **vec["panel"]}
        old = self._whole_rebuild(panel, vec["committed_width"])
        # The element is a 5pt stroke; the old law hands back the panel's 1pt.
        assert _expected(vec)["width"] == 5.0
        assert old["width"] == 1.0
        assert old != _expected(vec), (
            "the repro vector must FAIL against the whole-rebuild law"
        )

    def test_every_rich_vector_fails_under_the_old_law(self):
        """Not just the repro: every vector built on the rich stroke
        discriminates the two laws."""
        for vec in _CORPUS["vectors"]:
            if vec["op"] != "panel_edit" or vec["base"] != "rich_stroke":
                continue
            if vec["expected"] is None:
                continue
            panel = {**_CORPUS["panel_defaults"], **vec["panel"]}
            old = self._whole_rebuild(panel, vec["committed_width"])
            assert old != _expected(vec), (
                f"{vec['name']}: does not discriminate the old law"
            )

    def test_color_route_rebuild_fails(self):
        """The old colour route built a bare Stroke(color, width) and
        dropped every other attribute."""
        vec = _vec("color_pick_preserves_the_rich_stroke")
        base = _resolve_base(vec)
        old = normalize_stroke({"color": vec["color"], "width": base["width"]})
        assert old != _expected(vec)


class TestUnlinkedScaleIsItsOwnGroup:
    """STROKEWIDTH repair 4, called out because it CHANGED an encoded
    behaviour: the scales used to share one group, so an unlinked
    start-scale edit stamped the panel's end-scale onto the element."""

    def test_scales_are_separate_groups(self):
        assert stroke_edit_group("start_arrowhead_scale") != stroke_edit_group(
            "end_arrowhead_scale"
        )

    def test_start_scale_edit_leaves_the_end_scale_alone(self):
        base = _CORPUS["rich_stroke"]
        panel = {**_CORPUS["panel_defaults"], "start_arrowhead_scale": 200.0}
        got = stroke_with_group(
            base, panel, stroke_edit_group("start_arrowhead_scale"), 1.0,
        )
        assert got["start_arrow_scale"] == 200.0
        # The panel's end scale is the 100 default; the element's is 75.
        assert got["end_arrow_scale"] == 75.0


class TestLinkScalesToggleIsUiOnly:
    def test_toggle_owns_no_group(self):
        assert stroke_edit_group("link_arrowhead_scale") is None
        assert stroke_edit_group("stroke_link_arrowhead_scale") is None


class TestGlobalKeyNormalization:
    @pytest.mark.parametrize(
        "global_key,panel_key",
        [
            ("stroke_cap", "cap"),
            ("stroke_join", "join"),
            ("stroke_width", "weight"),
            ("stroke_align", "align_stroke"),
            ("stroke_dash_1", "dash_1"),
            ("stroke_start_arrowhead", "start_arrowhead"),
            ("stroke_end_arrowhead_scale", "end_arrowhead_scale"),
            ("stroke_profile_flipped", "profile_flipped"),
        ],
    )
    def test_global_and_panel_keys_agree(self, global_key, panel_key):
        assert stroke_edit_group(global_key) == stroke_edit_group(panel_key)
        assert stroke_edit_group(panel_key) is not None
