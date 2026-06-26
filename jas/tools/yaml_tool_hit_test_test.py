"""Hit-test gesture-seam tests for the Magic Wand and Eyedropper YAML tools.

Ports the magic_wand_parity_* (5) and eyedropper_parity_* (3) seam tests
from the Rust reference (jas_dioxus/src/tools/yaml_tool.rs) 1:1. Both tools
resolve a clicked element with ``hit_test(event.x, event.y)`` — which
already runs headlessly in the seam (the same primitive the selection
tools rely on, registered per-dispatch by ``YamlTool._dispatch`` via
``doc_primitives.register_document``) — so no new hit-test fixture is
needed; the cases reuse the loader + ctx machinery from
``yaml_tool_selection_variants_test.py``.

Two tools, eight cases:

  * magic_wand — click a red rect selects BOTH reds (not blue); click
    blue selects only blue; shift-click unions, alt-click subtracts;
    click empty clears; and a non-default-config gate that seeds
    ``magic_wand_fill_color=false`` through the PRODUCTION app-state
    bridge (``seed_globals_from`` / the ``BRIDGED_STATE_KEYS`` allowlist,
    the same path the live Magic Wand Panel drives) so the blue — sharing
    the reds' 1pt black stroke and opacity — also matches and a click on
    a red selects all three rects.
  * eyedropper — click a green source with an empty target selected
    copies the EXACT source green (0,0.6,0.2) into the target; a
    plain-click loads the cache then an alt-click applies it; a click on
    empty space is a byte-identical no-op.

The asserted selection paths, sampled rgb, and config numbers/tolerances
mirror the Rust reference exactly.
"""

from __future__ import annotations

import json
import os
import sys

_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)
_JAS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _JAS_DIR not in sys.path:
    sys.path.insert(0, _JAS_DIR)

import pytest

from document.controller import Controller
from document.document import Document, ElementSelection
from document.model import Model
from geometry.element import Color, Fill, Layer, Rect as RectElem, Stroke
from tools.yaml_tool import BRIDGED_STATE_KEYS
from workspace_interpreter.state_store import StateStore


# ── Shared machinery (mirrors yaml_tool_selection_variants_test.py) ──


def _load_ws_tool(tool_id: str) -> "YamlTool | None":
    from tools.yaml_tool import YamlTool

    ws_path = os.path.abspath(os.path.join(
        _REPO_ROOT, "workspace", "workspace.json",
    ))
    if not os.path.exists(ws_path):
        return None
    with open(ws_path, "r") as f:
        data = json.load(f)
    tools = data.get("tools")
    if not isinstance(tools, dict):
        return None
    spec = tools.get(tool_id)
    return YamlTool.from_workspace_tool(spec) if spec else None


def _ctx(model: Model, app_state: StateStore | None = None):
    """Build the ad-hoc ToolContext the YAML tools dispatch against. When
    ``app_state`` is given it is exposed as ``ctx.app_state`` so the
    PRODUCTION per-dispatch bridge (``_store.seed_globals_from`` over
    ``BRIDGED_STATE_KEYS``) copies the seeded ``state.*`` keys into the
    tool store before each handler runs — the same path the live canvas
    uses to feed Magic Wand Panel values to the wand."""
    ctrl = Controller(model)
    ctx_obj = type("Ctx", (), {})()
    ctx_obj.model = model
    ctx_obj.controller = ctrl
    ctx_obj.document = model.document
    ctx_obj.request_update = lambda: None
    ctx_obj.app_state = app_state
    return ctx_obj, ctrl


def _selection_paths(model: Model) -> set[tuple[int, ...]]:
    """Selected element paths as a set, for order-independent assertions
    (mirrors Rust's selection_paths)."""
    return {es.path for es in model.document.selection}


# ── Magic Wand fixtures (mirror magic_wand_seam_model) ──────────────


def _magic_wand_seam_model() -> Model:
    """Three rects in one layer — red @[0,0], red @[0,1], blue @[0,2] —
    each 10x10 with an identical 1pt black stroke, laid out at x = 0,
    20, 40 so screen (5,5) hits the first red, (45,5) hits the blue.
    Mirrors the Rust magic_wand_seam_model fixture (same geometry the
    effect tests assert against)."""
    red = Fill(color=Color.rgb(1.0, 0.0, 0.0))
    blue = Fill(color=Color.rgb(0.0, 0.0, 1.0))
    stroke = Stroke(color=Color.rgb(0.0, 0.0, 0.0), width=1.0)

    def make(fill: Fill, x: float) -> RectElem:
        return RectElem(x=x, y=0.0, width=10.0, height=10.0,
                        fill=fill, stroke=stroke)

    layer = Layer(name="L", children=(
        make(red, 0.0),
        make(red, 20.0),
        make(blue, 40.0),
    ))
    return Model(document=Document(layers=(layer,)))


def _magic_wand_app_state(fill_color: bool = True) -> StateStore:
    """The full Magic Wand config, written to an app-state store so the
    PRODUCTION bridge carries it into the tool store exactly as the live
    canvas would. ``fill_color`` toggles the one criterion the
    non-default-config gate flips. Mirrors Rust's seed_magic_wand_defaults
    / the sync_global_state map."""
    s = StateStore()
    s.set("magic_wand_fill_color", fill_color)
    s.set("magic_wand_fill_tolerance", 32)
    s.set("magic_wand_stroke_color", True)
    s.set("magic_wand_stroke_tolerance", 32)
    s.set("magic_wand_stroke_weight", True)
    s.set("magic_wand_stroke_weight_tolerance", 5.0)
    s.set("magic_wand_opacity", True)
    s.set("magic_wand_opacity_tolerance", 5)
    s.set("magic_wand_blending_mode", False)
    return s


# ── Magic Wand seam tests ───────────────────────────────────────────


class TestMagicWandHitTest:
    def test_click_red_selects_both_reds_not_blue(self):
        tool = _load_ws_tool("magic_wand")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _magic_wand_seam_model()
        ctx, _ = _ctx(model, _magic_wand_app_state())

        # Plain click on the first red rect at screen (5,5) -> replace.
        tool.on_press(ctx, 5.0, 5.0)
        tool.on_release(ctx, 5.0, 5.0)

        paths = _selection_paths(model)
        assert (0, 0) in paths, f"seed red [0,0] selected, got {paths}"
        assert (0, 1) in paths, f"matching red [0,1] selected, got {paths}"
        assert (0, 2) not in paths, f"blue [0,2] must NOT be selected, got {paths}"
        assert paths == {(0, 0), (0, 1)}, f"exactly the two reds, got {paths}"

    def test_click_blue_selects_only_blue(self):
        tool = _load_ws_tool("magic_wand")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _magic_wand_seam_model()
        ctx, _ = _ctx(model, _magic_wand_app_state())

        # Plain click on the blue rect at screen (45,5) -> replace.
        tool.on_press(ctx, 45.0, 5.0)
        tool.on_release(ctx, 45.0, 5.0)

        assert _selection_paths(model) == {(0, 2)}, (
            "clicking blue selects ONLY blue [0,2] (no red matches), "
            f"got {_selection_paths(model)}"
        )

    def test_shift_click_unions_alt_click_subtracts(self):
        tool = _load_ws_tool("magic_wand")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _magic_wand_seam_model()
        ctx, ctrl = _ctx(model, _magic_wand_app_state())

        # Pre-select the blue rect [0,2].
        ctrl.set_selection(frozenset({ElementSelection.all((0, 2))}))

        # Shift+click red [0,0] -> ADD: {2} u {0,1} = {0,1,2}.
        tool.on_press(ctx, 5.0, 5.0, shift=True)
        tool.on_release(ctx, 5.0, 5.0, shift=True)
        assert _selection_paths(model) == {(0, 0), (0, 1), (0, 2)}, (
            "Shift+click unions the wand result onto the existing selection"
        )

        # Alt+click red [0,0] -> SUBTRACT the wand result {0,1}: leaves {2}.
        tool.on_press(ctx, 5.0, 5.0, alt=True)
        tool.on_release(ctx, 5.0, 5.0, alt=True)
        assert _selection_paths(model) == {(0, 2)}, (
            "Alt+click subtracts the wand result {0,1}, leaving blue {2}"
        )

    def test_click_empty_clears_selection(self):
        tool = _load_ws_tool("magic_wand")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _magic_wand_seam_model()
        ctx, ctrl = _ctx(model, _magic_wand_app_state())

        # Start with a non-empty selection.
        ctrl.set_selection(frozenset({ElementSelection.all((0, 1))}))
        assert len(model.document.selection) != 0

        # Plain click on empty canvas (100,100) -> selection cleared.
        tool.on_press(ctx, 100.0, 100.0)
        tool.on_release(ctx, 100.0, 100.0)
        assert len(model.document.selection) == 0, (
            "plain click on empty canvas clears the selection, "
            f"got {_selection_paths(model)}"
        )

    def test_respects_bridged_nondefault_config(self):
        # REGRESSION GATE for the live state-bridge fix. With Fill Color
        # turned OFF and only stroke/weight/opacity matching the seed, the
        # blue rect — which has the SAME 1pt black stroke and opacity as
        # the reds — also matches, so a click on a red selects all THREE
        # rects. This non-default config only reaches the tool via the
        # bridge, and only because magic_wand_* is now in
        # BRIDGED_STATE_KEYS. Drop the keys from the allowlist and the
        # config falls back to MagicWandConfig() (Fill ON) -> the blue
        # stops matching -> this assertion fails. That is the bridge proof.
        tool = _load_ws_tool("magic_wand")
        if tool is None:
            pytest.skip("workspace.json not available")
        # Sanity: the keys this gate depends on are actually bridged.
        assert "magic_wand_fill_color" in BRIDGED_STATE_KEYS
        model = _magic_wand_seam_model()
        ctx, _ = _ctx(model, _magic_wand_app_state(fill_color=False))

        # Click red [0,0]. Fill is ignored, stroke+weight+opacity are
        # identical across all three rects -> all three match.
        tool.on_press(ctx, 5.0, 5.0)
        tool.on_release(ctx, 5.0, 5.0)

        assert _selection_paths(model) == {(0, 0), (0, 1), (0, 2)}, (
            "with Fill Color OFF (bridged), the wand matches on shared "
            "stroke/weight/opacity -> all three rects; got "
            f"{_selection_paths(model)}"
        )


# ── Eyedropper fixtures (mirror eyedropper_seam_model) ──────────────


def _eyedropper_source_color() -> Color:
    """The exact green the eyedropper fixture source carries — a
    distinctive non-primary colour so the apply assertion can't
    accidentally pass against a stray black/red default. (0,0.6,0.2)
    round-trips through the appearance cache exactly: 0.6*255 = 153,
    0.2*255 = 51, both integral."""
    return Color.rgb(0.0, 0.6, 0.2)


def _eyedropper_seam_model() -> Model:
    """Two rects in one layer: source [0,0] green-filled, target [0,1]
    fill-less, both 10x10 side by side at x = 0 and 20 so screen (5,5)
    hits the source and (25,5) hits the target. Mirrors the Rust
    eyedropper_seam_model fixture."""
    green = Fill(color=_eyedropper_source_color())
    stroke = Stroke(color=Color.rgb(0.0, 0.0, 0.0), width=1.0)

    def make(fill: Fill | None, x: float) -> RectElem:
        return RectElem(x=x, y=0.0, width=10.0, height=10.0,
                        fill=fill, stroke=stroke)

    layer = Layer(name="L", children=(
        make(green, 0.0),
        make(None, 20.0),
    ))
    return Model(document=Document(layers=(layer,)))


# ── Eyedropper seam tests ───────────────────────────────────────────
#
# The Eyedropper is a single-click tool: on_mousedown hit-tests and (on a
# hit) fires doc.eyedropper.sample (plain) or doc.eyedropper.apply_loaded
# (Alt). sample snapshots the source appearance into state.eyedropper_cache
# AND — when the selection is non-empty — writes that appearance to every
# eligible selected target. A click on empty space is a no-op. The
# eyedropper toggles all default true and EyedropperConfig() agrees, so the
# fill-copy path needs no bridge seeding (the cache write goes straight to
# the tool store and the config falls back to all-on).


class TestEyedropperHitTest:
    def test_click_source_with_selection_copies_fill_to_target(self):
        tool = _load_ws_tool("eyedropper")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _eyedropper_seam_model()
        ctx, ctrl = _ctx(model)

        # Pre-select the empty target [0,1]; the source [0,0] is clicked.
        ctrl.set_selection(frozenset({ElementSelection.all((0, 1))}))
        assert model.document.get_element((0, 1)).fill is None, (
            "precondition: target starts with no fill"
        )

        # Plain click on the green source at screen (5,5) -> sample, which
        # (selection non-empty) also writes the appearance to [0,1].
        tool.on_press(ctx, 5.0, 5.0)
        tool.on_release(ctx, 5.0, 5.0)

        fill = model.document.get_element((0, 1)).fill
        assert fill is not None, "target now carries the sampled fill"
        assert fill.color == _eyedropper_source_color(), (
            "eyedropper sample must copy the EXACT source green (0,0.6,0.2) "
            f"into the selected target, got {fill.color}"
        )

    def test_alt_click_applies_cached_color_to_target(self):
        tool = _load_ws_tool("eyedropper")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _eyedropper_seam_model()
        ctx, _ = _ctx(model)

        # First, plain-click the source with NO selection -> loads the
        # cache (and mutates nothing, since the selection is empty).
        tool.on_press(ctx, 5.0, 5.0)
        tool.on_release(ctx, 5.0, 5.0)
        assert model.document.get_element((0, 1)).fill is None, (
            "a sample with no selection must not mutate other elements"
        )

        # Now Alt+click the empty target [0,1] at screen (25,5) ->
        # apply_loaded writes the cached green into the target.
        tool.on_press(ctx, 25.0, 5.0, alt=True)
        tool.on_release(ctx, 25.0, 5.0, alt=True)

        fill = model.document.get_element((0, 1)).fill
        assert fill is not None, "apply_loaded wrote the cached fill"
        assert fill.color == _eyedropper_source_color(), (
            "Alt+click must apply the cached green (0,0.6,0.2) to the "
            f"target, got {fill.color}"
        )

    def test_click_empty_is_a_noop(self):
        tool = _load_ws_tool("eyedropper")
        if tool is None:
            pytest.skip("workspace.json not available")
        model = _eyedropper_seam_model()
        ctx, _ = _ctx(model)

        # Snapshot the document before the gesture for an exact-equality
        # no-op proof.
        before = repr(model.document.layers)

        # Plain click on empty canvas (100,100) -> no hit -> no-op.
        tool.on_press(ctx, 100.0, 100.0)
        tool.on_release(ctx, 100.0, 100.0)

        assert repr(model.document.layers) == before, (
            "a click on empty space must not mutate the document"
        )
        # The source fill is untouched; the target is still fill-less.
        assert model.document.get_element((0, 0)).fill.color == \
            _eyedropper_source_color()
        assert model.document.get_element((0, 1)).fill is None, (
            "target remains fill-less after an empty-space click"
        )
