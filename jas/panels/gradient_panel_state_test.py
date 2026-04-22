"""Phase 4 tests for gradient_panel_state.sync_gradient_panel_from_selection.

Mirrors the Rust, Swift, and OCaml gradient-sync test suites.
"""

from __future__ import annotations

from absl.testing import absltest

from panels.gradient_panel_state import sync_gradient_panel_from_selection


class _ElementSelection:
    def __init__(self, path):
        self.path = path


class _Doc:
    def __init__(self, elements_with_paths):
        # selection is a list of objects with a .path attribute.
        self.selection = [_ElementSelection(p) for p, _ in elements_with_paths]
        self._elements = {tuple(p): e for p, e in elements_with_paths}

    def get_element(self, path):
        return self._elements[tuple(path) if isinstance(path, tuple) else path]


class _Model:
    def __init__(self, elements_with_paths):
        self.document = _Doc(elements_with_paths)


def _store():
    from workspace_interpreter.state_store import StateStore
    return StateStore()


def _gradient(**kwargs):
    from geometry.element import (
        Gradient, GradientStop, GradientType, GradientMethod, StrokeSubMode,
    )
    defaults = dict(
        type=GradientType.LINEAR, angle=0, aspect_ratio=100,
        method=GradientMethod.CLASSIC, dither=False,
        stroke_sub_mode=StrokeSubMode.WITHIN,
        stops=(
            GradientStop(color="#000000", opacity=100, location=0,   midpoint_to_next=50),
            GradientStop(color="#ffffff", opacity=100, location=100, midpoint_to_next=50),
        ),
    )
    defaults.update(kwargs)
    return Gradient(**defaults)


class TestSyncGradientPanelFromSelection(absltest.TestCase):

    def test_no_op_when_model_is_none(self):
        store = _store()
        store.set("gradient_type", "radial")
        sync_gradient_panel_from_selection(store, None)
        self.assertEqual(store.get("gradient_type"), "radial")

    def test_empty_selection_no_op(self):
        store = _store()
        store.set("gradient_type", "radial")
        sync_gradient_panel_from_selection(store, _Model([]))
        self.assertEqual(store.get("gradient_type"), "radial")

    def test_uniform_with_gradient_populates_panel(self):
        from geometry.element import Rect, Fill, RgbColor, GradientType, GradientMethod
        g = _gradient(
            type=GradientType.RADIAL, angle=30, aspect_ratio=200,
            method=GradientMethod.SMOOTH, dither=True,
        )
        rect = Rect(x=0, y=0, width=100, height=50,
                    fill=Fill(color=RgbColor(1, 0, 0)),
                    fill_gradient=g)
        store = _store()
        store.set("fill_on_top", True)
        sync_gradient_panel_from_selection(store, _Model([((0, 0), rect)]))
        self.assertEqual(store.get("gradient_type"), "radial")
        self.assertEqual(store.get("gradient_angle"), 30)
        self.assertEqual(store.get("gradient_aspect_ratio"), 200)
        self.assertEqual(store.get("gradient_method"), "smooth")
        self.assertTrue(store.get("gradient_dither"))
        self.assertFalse(store.get("gradient_preview_state"))

    def test_solid_seeds_preview(self):
        from geometry.element import Rect, Fill, RgbColor
        rect = Rect(x=0, y=0, width=100, height=50,
                    fill=Fill(color=RgbColor(1, 0, 0)),
                    fill_gradient=None)
        store = _store()
        store.set("fill_on_top", True)
        sync_gradient_panel_from_selection(store, _Model([((0, 0), rect)]))
        self.assertTrue(store.get("gradient_preview_state"))
        self.assertEqual(store.get("gradient_type"), "linear")
        self.assertEqual(store.get("gradient_seed_first_color"), "#ff0000")

    def test_mixed_gradients_clears_preview_only(self):
        from geometry.element import Rect, Fill, RgbColor, GradientType
        g1 = _gradient(type=GradientType.LINEAR)
        g2 = _gradient(type=GradientType.RADIAL)
        r1 = Rect(x=0, y=0, width=10, height=10, fill=Fill(color=RgbColor(1, 0, 0)), fill_gradient=g1)
        r2 = Rect(x=0, y=0, width=10, height=10, fill=Fill(color=RgbColor(0, 0, 1)), fill_gradient=g2)
        store = _store()
        store.set("fill_on_top", True)
        store.set("gradient_type", "preserved-by-mixed")
        sync_gradient_panel_from_selection(store, _Model([((0, 0), r1), ((0, 1), r2)]))
        # Mixed: gradient_type stays as preserved value; preview_state set false.
        self.assertEqual(store.get("gradient_type"), "preserved-by-mixed")
        self.assertFalse(store.get("gradient_preview_state"))


if __name__ == "__main__":
    absltest.main()
