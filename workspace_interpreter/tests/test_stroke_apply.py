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
import sys

_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "jas"))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

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


# ---------------------------------------------------------------------------
# The bridge: the same law, exercised through the store + document wiring
# ---------------------------------------------------------------------------

class _FakeModel:
    """The slice of the app model the stroke bridge touches."""

    def __init__(self, document, default_stroke=None):
        self.document = document
        self.default_stroke = default_stroke
        self.default_fill = None
        self.edits = 0

    def edit_document(self, doc):
        self.document = doc
        self.edits += 1

    def set_document_unbracketed(self, doc):
        self.document = doc


class _FakeController:
    def __init__(self, model):
        self.model = model
        self.width_profiles = []

    def set_selection_width_profile(self, wp):
        self.width_profiles.append(wp)

    def set_selection_stroke(self, stroke):
        from geometry.element import with_stroke
        doc = self.model.document
        for es in doc.selection:
            doc = doc.replace_element(
                es.path, with_stroke(doc.get_element(es.path), stroke))
        self.model.edit_document(doc)

    def set_selection_fill(self, fill):
        from geometry.element import with_fill
        doc = self.model.document
        for es in doc.selection:
            doc = doc.replace_element(
                es.path, with_fill(doc.get_element(es.path), fill))
        self.model.edit_document(doc)


def _colour_obj(spec):
    """A corpus colour — 6-char hex, or the ``{space, components, a}``
    object form — as a geometry Color."""
    from geometry.element import Color
    if isinstance(spec, str):
        return Color.from_hex(spec) or Color.BLACK
    space = spec["space"]
    a = spec.get("a", 1.0)
    if space == "cmyk":
        return Color.cmyk(spec["c"], spec["m"], spec["y"], spec["k"], a)
    if space == "hsb":
        return Color.hsb(spec["h"], spec["s"], spec["b"], a)
    return Color.rgb(spec["r"], spec["g"], spec["b"], a)


def _stroke_obj(attrs: dict):
    """A corpus attribute map as a geometry Stroke, colour included."""
    from workspace_interpreter.effects import _stroke_from_attrs
    from workspace_interpreter.stroke_law import normalize_stroke
    return _stroke_from_attrs(normalize_stroke(attrs),
                              color=_colour_obj(attrs["color"]))


def _rich_stroke_obj():
    """``rich_stroke`` from the corpus as a geometry Stroke."""
    return _stroke_obj(_CORPUS["rich_stroke"])


def _doc_with_stroked_line(stroke):
    """A one-layer document holding a single selected stroked Path."""
    from document.document import Document, ElementSelection
    from geometry.element import Layer, LineTo, MoveTo, Path
    path = Path(d=(MoveTo(x=0.0, y=0.0), LineTo(x=100.0, y=0.0)),
                stroke=stroke, fill=None)
    layer = Layer(children=(path,))
    return Document(layers=(layer,),
                    selection=frozenset({ElementSelection.all((0, 0))}))


def _seed_panel(store, **overrides):
    """The Stroke panel sitting at its corpus defaults, plus overrides.

    ``init_panel`` creates the scope; ``set_panel`` is a no-op on a scope
    that does not exist yet.
    """
    defaults = {k: v for k, v in _CORPUS["panel_defaults"].items()
                if not k.startswith("_")}
    store.init_panel("stroke_panel_content", {**defaults, **overrides})


class TestBridgeAppliesTheFieldScopedLaw:
    """``apply_stroke_panel_to_selection`` — the wiring, not just the pure
    law. This is the function that actually held the old law."""

    def _run(self, edited, **panel):
        from workspace_interpreter.effects import apply_stroke_panel_to_selection
        from workspace_interpreter.state_store import StateStore
        stroke = _rich_stroke_obj()
        model = _FakeModel(_doc_with_stroked_line(stroke))
        ctrl = _FakeController(model)
        store = StateStore()
        _seed_panel(store, **panel)
        apply_stroke_panel_to_selection(store, ctrl, edited)
        return model, ctrl, model.document.get_element((0, 0)).stroke

    def test_jyh_repro_arrowhead_edit_keeps_the_5pt_width(self):
        """The repro: rich 5pt stroke, panel at 1pt defaults, user picks an
        end arrowhead. Everything but the head survives."""
        _, _, got = self._run("stroke_end_arrowhead",
                              end_arrowhead="closed_arrow")
        from geometry.element import Arrowhead
        assert got.end_arrow == Arrowhead.CLOSED_ARROW
        assert got.width == 5.0
        rich = _rich_stroke_obj()
        assert got.linecap == rich.linecap
        assert got.linejoin == rich.linejoin
        assert got.dash_pattern == rich.dash_pattern
        assert got.start_arrow == rich.start_arrow
        assert got.align == rich.align
        assert got.miter_limit == rich.miter_limit
        assert got.opacity == rich.opacity
        assert got.start_arrow_scale == rich.start_arrow_scale
        assert got.end_arrow_scale == rich.end_arrow_scale

    def test_weight_edit_writes_the_committed_width(self):
        _, _, got = self._run("stroke_width", weight=8.0)
        assert got.width == 8.0
        assert got.dash_pattern == _rich_stroke_obj().dash_pattern

    def test_cap_edit_writes_only_the_cap(self):
        from geometry.element import LineCap
        _, _, got = self._run("stroke_cap", cap="square")
        assert got.linecap == LineCap.SQUARE
        assert got.width == 5.0

    def test_unlinked_start_scale_leaves_the_end_scale(self):
        _, _, got = self._run("stroke_start_arrowhead_scale",
                              start_arrowhead_scale=200.0)
        assert got.start_arrow_scale == 200.0
        assert got.end_arrow_scale == 75.0

    def test_link_toggle_writes_nothing_at_all(self):
        """A UI-only flag must not reach the document — no edit, so no undo
        step that changes nothing."""
        model, _, got = self._run("stroke_link_arrowhead_scale")
        assert model.edits == 0
        assert got == _rich_stroke_obj()

    def test_profile_edit_leaves_the_stroke_and_derives_width_points(self):
        model, ctrl, got = self._run("stroke_profile", profile="taper_both")
        assert got == _rich_stroke_obj()
        assert ctrl.width_profiles, "a profile edit must re-derive width points"

    def test_a_non_profile_edit_does_not_touch_width_points(self):
        _, ctrl, _ = self._run("stroke_cap", cap="round")
        assert ctrl.width_profiles == []

    def test_the_new_element_default_takes_the_same_scoped_edit(self):
        from workspace_interpreter.effects import apply_stroke_panel_to_selection
        from workspace_interpreter.state_store import StateStore
        from geometry.element import Color, LineCap, Stroke
        model = _FakeModel(_doc_with_stroked_line(_rich_stroke_obj()),
                           default_stroke=Stroke(color=Color.BLACK, width=2.0))
        store = StateStore()
        _seed_panel(store, cap="round")
        apply_stroke_panel_to_selection(store, _FakeController(model), "stroke_cap")
        # The default takes the cap, and keeps its OWN 2pt width — the
        # selected element's 5pt must not leak into the next element.
        assert model.default_stroke.linecap == LineCap.ROUND
        assert model.default_stroke.width == 2.0


class TestBridgePreservesTheColourObject:
    """STROKEWIDTH reverify F1: the bridge must carry the element's colour
    OBJECT through the apply, not a hex round trip.

    ``_stroke_to_attrs`` / ``_stroke_from_attrs`` used to serialize the
    colour to 6-char hex and parse it back on every apply, which is lossy
    three ways at once: the colour SPACE was demoted to RGB, the ALPHA was
    dropped, and the components were quantised to 8 bits. A ``stroke_cap``
    edit on a half-transparent CMYK stroke handed back an opaque RGB one —
    the law's own "every other attribute is preserved" clause violated in
    the reference, which is the contract the ports mirror. Both ports were
    already correct (they map the Stroke in place and never touch
    ``color``), so this was a reference-only divergence.

    Driven off the corpus's non-RGB / alpha-bearing vectors so the fixture
    and the bridge cannot drift apart.
    """

    COLOUR_VECTORS = [
        "cap_edit_preserves_a_cmyk_stroke_colour",
        "weight_edit_preserves_colour_alpha_and_precision",
    ]

    @pytest.mark.parametrize("name", COLOUR_VECTORS)
    def test_the_colour_object_survives_the_apply(self, name):
        from workspace_interpreter.effects import apply_stroke_panel_to_selection
        from workspace_interpreter.state_store import StateStore
        vec = _vec(name)
        stroke = _stroke_obj(_resolve_base(vec))
        model = _FakeModel(_doc_with_stroked_line(stroke), default_stroke=stroke)
        store = StateStore()
        _seed_panel(store, **vec["panel"])
        apply_stroke_panel_to_selection(store, _FakeController(model),
                                        vec["edited"])
        got = model.document.get_element((0, 0)).stroke
        assert type(got.color) is type(stroke.color), (
            f"{name}: the colour SPACE must survive the apply"
        )
        assert got.color == stroke.color, (
            f"{name}: the colour must come back bit-for-bit"
        )
        # The new-element default takes the same edit and must not lose its
        # own colour either.
        assert model.default_stroke.color == stroke.color, (
            f"{name}: the default stroke's colour must survive too"
        )

    def test_the_corpus_actually_carries_a_non_rgb_and_an_alpha_colour(self):
        """The vectors above only close the blind spot if the fixture really
        holds a non-RGB space and a non-opaque alpha."""
        spaces, alphas = set(), set()
        for name in self.COLOUR_VECTORS:
            spec = _resolve_base(_vec(name))["color"]
            assert isinstance(spec, dict), f"{name}: hex cannot express this"
            spaces.add(spec["space"])
            alphas.add(spec["a"])
        assert spaces - {"rgb"}, "no non-RGB colour space in the corpus"
        assert alphas - {1.0}, "no alpha-bearing colour in the corpus"


class TestBridgeColourRouteIsColourOnly:
    def test_stroke_colour_pick_preserves_every_other_attribute(self):
        from workspace_interpreter.effects import subscribe_active_color
        from workspace_interpreter.state_store import StateStore
        from geometry.element import Color
        rich = _rich_stroke_obj()
        model = _FakeModel(_doc_with_stroked_line(rich), default_stroke=rich)
        ctrl = _FakeController(model)
        store = StateStore()
        subscribe_active_color(store, lambda: ctrl)
        store.set("stroke_color", "#ff0000")
        got = model.document.get_element((0, 0)).stroke
        assert got.color == Color.from_hex("#ff0000")
        assert got.width == 5.0
        assert got.dash_pattern == rich.dash_pattern
        assert got.start_arrow == rich.start_arrow
        assert got.end_arrow == rich.end_arrow
        assert got.linecap == rich.linecap
        assert got.opacity == rich.opacity
