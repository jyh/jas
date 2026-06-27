"""Properties panel field EDITING — apply to selection (decision-5 Part B.2).

X/Y move (bake), W/H scale local axes by ratio (single selection), rotation
sets absolute angle about the bbox center (single selection), opacity/blend
set the attribute on every selected element.
"""
import math
from absl.testing import absltest

from workspace_interpreter.effects import (
    apply_properties_field,
    selection_evaluated_bounds,
    _scaled_transform_tuple,
    _rotated_transform_tuple,
    _PROP_IDENTITY,
)
from document.document import Document, ElementSelection
from document.model import Model
from document.controller import Controller
from geometry.element import Rect, Layer, BlendMode


def _ctrl(elements, selected):
    layer = Layer(children=tuple(elements))
    sel = frozenset(ElementSelection.all((0, i)) for i in selected)
    return Controller(Model(document=Document(layers=(layer,), selection=sel)))


def _elem(ctrl, idx=0):
    return ctrl.model.document.get_element((0, idx))


class TransformMathTest(absltest.TestCase):

    def test_scale_local_x_grows_bbox(self):
        mp = _scaled_transform_tuple(_PROP_IDENTITY, (0, 0, 10, 10), 2.0, 1.0)
        # bbox top-left preserved, width doubled.
        from workspace_interpreter.effects import _aabb_through
        self.assertEqual(_aabb_through((0, 0, 10, 10), mp), (0, 0, 20, 10))

    def test_rotate_90_swaps_extents_keeps_center(self):
        mp = _rotated_transform_tuple(_PROP_IDENTITY, (0, 0, 100, 50), 90.0)
        from workspace_interpreter.effects import _aabb_through
        x, y, w, h = _aabb_through((0, 0, 100, 50), mp)
        self.assertAlmostEqual(w, 50.0, places=6)
        self.assertAlmostEqual(h, 100.0, places=6)
        # center preserved at (50, 25)
        self.assertAlmostEqual(x + w / 2, 50.0, places=6)
        self.assertAlmostEqual(y + h / 2, 25.0, places=6)

    def test_shear_sets_angle_keeps_rotation(self):
        from workspace_interpreter.effects import (
            _sheared_transform_tuple, _shear_angle_deg)
        mp = _sheared_transform_tuple(_PROP_IDENTITY, (0, 0, 100, 50), 30.0)
        self.assertAlmostEqual(_shear_angle_deg(mp), 30.0, places=4)
        # rotation stays 0
        self.assertAlmostEqual(math.degrees(math.atan2(mp[1], mp[0])),
                               0.0, places=4)


class ApplyPropertiesFieldTest(absltest.TestCase):

    def test_x_moves_selection(self):
        ctrl = _ctrl([Rect(x=10, y=20, width=30, height=40)], [0])
        apply_properties_field(ctrl, "x", 50)
        self.assertEqual(selection_evaluated_bounds(ctrl.model.document)[0], 50.0)

    def test_y_moves_selection(self):
        ctrl = _ctrl([Rect(x=10, y=20, width=30, height=40)], [0])
        apply_properties_field(ctrl, "y", 5)
        self.assertEqual(selection_evaluated_bounds(ctrl.model.document)[1], 5.0)

    def test_w_scales_to_value(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=100, height=50)], [0])
        apply_properties_field(ctrl, "w", 200)
        x, y, w, h = selection_evaluated_bounds(ctrl.model.document)
        self.assertAlmostEqual(w, 200.0, places=6)
        self.assertAlmostEqual(h, 50.0, places=6)   # H unchanged

    def test_w_with_constrain_scales_both_axes(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=100, height=50)], [0])
        apply_properties_field(ctrl, "w", 200, constrain=True)
        _, _, w, h = selection_evaluated_bounds(ctrl.model.document)
        self.assertAlmostEqual(w, 200.0, places=6)
        self.assertAlmostEqual(h, 100.0, places=6)  # H follows (×2)

    def test_h_scales_to_value(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=100, height=50)], [0])
        apply_properties_field(ctrl, "h", 150)
        _, _, w, h = selection_evaluated_bounds(ctrl.model.document)
        self.assertAlmostEqual(w, 100.0, places=6)
        self.assertAlmostEqual(h, 150.0, places=6)

    def test_rotation_sets_angle(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=100, height=50)], [0])
        apply_properties_field(ctrl, "rotation", 90)
        t = _elem(ctrl).transform
        self.assertAlmostEqual(math.degrees(math.atan2(t.b, t.a)), 90.0, places=4)
        # evaluated bbox swaps to 50 x 100
        _, _, w, h = selection_evaluated_bounds(ctrl.model.document)
        self.assertAlmostEqual(w, 50.0, places=6)
        self.assertAlmostEqual(h, 100.0, places=6)

    def test_opacity_sets_attribute(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=10, height=10)], [0])
        apply_properties_field(ctrl, "opacity", 50)
        self.assertEqual(_elem(ctrl).opacity, 0.5)

    def test_blend_sets_attribute(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=10, height=10)], [0])
        apply_properties_field(ctrl, "blend", "multiply")
        self.assertEqual(_elem(ctrl).blend_mode, BlendMode.MULTIPLY)

    def test_opacity_applies_to_all_selected(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=10, height=10),
                      Rect(x=20, y=0, width=10, height=10)], [0, 1])
        apply_properties_field(ctrl, "opacity", 25)
        self.assertEqual(_elem(ctrl, 0).opacity, 0.25)
        self.assertEqual(_elem(ctrl, 1).opacity, 0.25)

    def test_w_multi_selection_scales_group(self):
        # Two 100x50 rects at x=0 and x=200 -> union bbox W = 300. Setting
        # W=600 scales the GROUP about the bbox top-left by 2 (x only).
        ctrl = _ctrl([Rect(x=0, y=0, width=100, height=50),
                      Rect(x=200, y=0, width=100, height=50)], [0, 1])
        apply_properties_field(ctrl, "w", 600)
        x, _, w, h = selection_evaluated_bounds(ctrl.model.document)
        self.assertAlmostEqual(w, 600.0, places=6)
        self.assertAlmostEqual(x, 0.0, places=6)   # bbox top-left preserved
        self.assertAlmostEqual(h, 50.0, places=6)  # H unchanged (no constrain)

    def test_rotation_multi_selection_rotates_group(self):
        # Two 10x10 rects at x=0 and x=100 -> union (0,0,110,10). A 90deg
        # group rotation about the bbox center swaps the union to 10 x 110.
        ctrl = _ctrl([Rect(x=0, y=0, width=10, height=10),
                      Rect(x=100, y=0, width=10, height=10)], [0, 1])
        apply_properties_field(ctrl, "rotation", 90)
        _, _, w, h = selection_evaluated_bounds(ctrl.model.document)
        self.assertAlmostEqual(w, 10.0, places=4)
        self.assertAlmostEqual(h, 110.0, places=4)

    def test_shear_sets_angle(self):
        from workspace_interpreter.effects import _shear_angle_deg
        ctrl = _ctrl([Rect(x=0, y=0, width=100, height=50)], [0])
        apply_properties_field(ctrl, "shear", 30)
        t = _elem(ctrl).transform
        self.assertAlmostEqual(
            _shear_angle_deg((t.a, t.b, t.c, t.d, t.e, t.f)), 30.0, places=4)

    def test_rotation_preserves_shear(self):
        # Shear then rotate: rotation must keep the shear angle (the upgraded
        # decompose-preserve-recompose, not the old shear-free rebuild).
        from workspace_interpreter.effects import _shear_angle_deg
        ctrl = _ctrl([Rect(x=0, y=0, width=100, height=50)], [0])
        apply_properties_field(ctrl, "shear", 30)
        apply_properties_field(ctrl, "rotation", 45)
        t = _elem(ctrl).transform
        self.assertAlmostEqual(
            _shear_angle_deg((t.a, t.b, t.c, t.d, t.e, t.f)), 30.0, places=4)
        self.assertAlmostEqual(math.degrees(math.atan2(t.b, t.a)),
                               45.0, places=4)

    def test_shear_multi_selection_shears_group(self):
        # Two 10x10 rects at x=0 and x=100 -> union (0,0,110,10), center (55,5).
        # A 45deg group x-shear about the center widens the union to 120 (each
        # corner's x shifts by tan(45)*(y-5) = +/-5 -> [-5,115]).
        ctrl = _ctrl([Rect(x=0, y=0, width=10, height=10),
                      Rect(x=100, y=0, width=10, height=10)], [0, 1])
        apply_properties_field(ctrl, "shear", 45)
        x, _, w, h = selection_evaluated_bounds(ctrl.model.document)
        self.assertAlmostEqual(w, 120.0, places=4)
        self.assertAlmostEqual(h, 10.0, places=4)
        self.assertAlmostEqual(x, -5.0, places=4)

    def test_no_selection_does_not_raise(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=10, height=10)], [])
        apply_properties_field(ctrl, "w", 200)  # must not raise


class SubscribeDispatchTest(absltest.TestCase):
    """The full edit dispatch: a widget commit writes the panel key via
    set_panel, which subscribe_properties_panel turns into an apply. This is
    what a GUI field edit exercises end-to-end."""

    def _wire(self, ctrl):
        from workspace_interpreter.effects import subscribe_properties_panel
        from workspace_interpreter.state_store import StateStore
        store = StateStore()
        store.init_panel("properties_panel_content",
                         {"prop_x": 0, "prop_y": 0, "prop_w": 0, "prop_h": 0,
                          "prop_rotation": 0, "prop_opacity": 100,
                          "prop_blend": "normal", "prop_shear": 0})
        subscribe_properties_panel(store, lambda: ctrl.model)
        return store

    def test_panel_write_w_applies(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=100, height=50)], [0])
        store = self._wire(ctrl)
        store.set_panel("properties_panel_content", "prop_w", 200)
        _, _, w, _ = selection_evaluated_bounds(ctrl.model.document)
        self.assertAlmostEqual(w, 200.0, places=6)

    def test_panel_write_x_moves(self):
        ctrl = _ctrl([Rect(x=10, y=20, width=30, height=40)], [0])
        store = self._wire(ctrl)
        store.set_panel("properties_panel_content", "prop_x", 100)
        self.assertEqual(selection_evaluated_bounds(ctrl.model.document)[0], 100.0)

    def test_panel_write_opacity_applies(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=10, height=10)], [0])
        store = self._wire(ctrl)
        store.set_panel("properties_panel_content", "prop_opacity", 40)
        self.assertEqual(ctrl.model.document.get_element((0, 0)).opacity, 0.4)

    def test_panel_write_blend_applies(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=10, height=10)], [0])
        store = self._wire(ctrl)
        store.set_panel("properties_panel_content", "prop_blend", "screen")
        self.assertEqual(ctrl.model.document.get_element((0, 0)).blend_mode,
                         BlendMode.SCREEN)

    def test_panel_write_shear_applies(self):
        from workspace_interpreter.effects import _shear_angle_deg
        ctrl = _ctrl([Rect(x=0, y=0, width=100, height=50)], [0])
        store = self._wire(ctrl)
        store.set_panel("properties_panel_content", "prop_shear", 30)
        t = ctrl.model.document.get_element((0, 0)).transform
        self.assertAlmostEqual(
            _shear_angle_deg((t.a, t.b, t.c, t.d, t.e, t.f)), 30.0, places=4)

    def test_constrain_toggle_then_w_scales_both(self):
        # Toggling prop_constrain does NOT apply; a later W edit then scales
        # both axes (the subscribe reads the stored constrain flag).
        ctrl = _ctrl([Rect(x=0, y=0, width=100, height=50)], [0])
        store = self._wire(ctrl)
        store.set_panel("properties_panel_content", "prop_constrain", True)
        store.set_panel("properties_panel_content", "prop_w", 200)
        _, _, w, h = selection_evaluated_bounds(ctrl.model.document)
        self.assertAlmostEqual(w, 200.0, places=6)
        self.assertAlmostEqual(h, 100.0, places=6)


if __name__ == "__main__":
    absltest.main()
