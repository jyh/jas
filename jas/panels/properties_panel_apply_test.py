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

    def test_w_noop_for_multi_selection(self):
        ctrl = _ctrl([Rect(x=0, y=0, width=100, height=50),
                      Rect(x=200, y=0, width=100, height=50)], [0, 1])
        before = ctrl.model.document
        apply_properties_field(ctrl, "w", 999)
        self.assertIs(ctrl.model.document, before)  # unchanged

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
                          "prop_blend": "normal"})
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


if __name__ == "__main__":
    absltest.main()
