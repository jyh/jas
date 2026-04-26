"""Tests for the Python Eyedropper extract / apply helpers. Parallels
jas_dioxus/src/algorithms/eyedropper.rs +
JasSwift/Tests/Algorithms/EyedropperTests.swift +
jas_ocaml/test/algorithms/eyedropper_test.ml.
"""

from absl.testing import absltest

from algorithms.eyedropper import (
    Appearance,
    EyedropperConfig,
    apply_appearance,
    appearance_from_dict,
    appearance_to_dict,
    extract_appearance,
    is_source_eligible,
    is_target_eligible,
)
from geometry.element import (
    BlendMode,
    Color,
    Fill,
    Group,
    Layer,
    Line,
    LineCap,
    LineJoin,
    Rect,
    Stroke,
    StrokeAlign,
    Visibility,
)


def _make_rect(*, fill=None, stroke=None, opacity=1.0,
               blend_mode=BlendMode.NORMAL,
               locked=False, visibility=Visibility.PREVIEW) -> Rect:
    return Rect(x=0.0, y=0.0, width=100.0, height=100.0,
                fill=fill, stroke=stroke,
                opacity=opacity, blend_mode=blend_mode,
                locked=locked, visibility=visibility)


def _make_line(*, stroke=None, width_points=()) -> Line:
    return Line(x1=0.0, y1=0.0, x2=10.0, y2=10.0,
                stroke=stroke, width_points=width_points)


_RED_FILL = Fill(color=Color.rgb(1.0, 0.0, 0.0))
_BLUE_STROKE = Stroke(
    color=Color.rgb(0.0, 0.0, 1.0),
    width=4.0,
    linecap=LineCap.ROUND,
    linejoin=LineJoin.BEVEL,
    align=StrokeAlign.INSIDE,
)


class EyedropperExtractApplyTest(absltest.TestCase):

    def test_extract_rect_with_fill_and_stroke(self):
        el = _make_rect(fill=_RED_FILL, stroke=_BLUE_STROKE)
        app = extract_appearance(el)
        self.assertEqual(app.fill, _RED_FILL)
        self.assertEqual(app.stroke, _BLUE_STROKE)
        self.assertEqual(app.opacity, 1.0)
        self.assertEqual(app.blend_mode, BlendMode.NORMAL)
        self.assertIsNone(app.stroke_brush)
        self.assertEqual(app.width_points, ())

    def test_extract_line_has_no_fill(self):
        el = _make_line(stroke=_BLUE_STROKE)
        app = extract_appearance(el)
        self.assertIsNone(app.fill)
        self.assertEqual(app.stroke, _BLUE_STROKE)

    def test_appearance_dict_roundtrip(self):
        app = Appearance(
            fill=_RED_FILL,
            stroke=_BLUE_STROKE,
            opacity=0.75,
            blend_mode=BlendMode.MULTIPLY,
            stroke_brush="calligraphic_default",
            width_points=(),
            character=None,
            paragraph=None,
        )
        d = appearance_to_dict(app)
        back = appearance_from_dict(d)
        self.assertEqual(back.fill, app.fill)
        self.assertEqual(back.stroke, app.stroke)
        self.assertEqual(back.opacity, app.opacity)
        self.assertEqual(back.blend_mode, app.blend_mode)
        self.assertEqual(back.stroke_brush, app.stroke_brush)
        self.assertEqual(back.width_points, app.width_points)

    def test_apply_master_off_skips_group(self):
        src = _make_rect(fill=_RED_FILL, stroke=_BLUE_STROKE)
        app = extract_appearance(src)
        target = _make_rect()
        cfg = EyedropperConfig(fill=False, stroke=False, opacity=False)
        out = apply_appearance(target, app, cfg)
        self.assertIsNone(getattr(out, "fill"))
        self.assertIsNone(getattr(out, "stroke"))

    def test_apply_stroke_color_sub_only(self):
        src = _make_rect(stroke=_BLUE_STROKE)
        app = extract_appearance(src)
        existing = Stroke(
            color=Color.rgb(0.5, 0.5, 0.5),
            width=2.0,
            linecap=LineCap.SQUARE,
        )
        target = _make_rect(stroke=existing)
        cfg = EyedropperConfig(
            fill=False, opacity=False,
            stroke=True,
            stroke_color=True,
            stroke_weight=False,
            stroke_cap_join=False,
            stroke_align=False,
            stroke_dash=False,
            stroke_arrowheads=False,
            stroke_brush=False,
            stroke_profile=False,
        )
        out = apply_appearance(target, app, cfg)
        out_stroke = getattr(out, "stroke")
        self.assertIsNotNone(out_stroke)
        # Color copied from source...
        r, g, b, _ = out_stroke.color.to_rgba()
        self.assertEqual((r, g, b), (0.0, 0.0, 1.0))
        # ...but weight, cap, etc. preserved from target.
        self.assertEqual(out_stroke.width, 2.0)
        self.assertEqual(out_stroke.linecap, LineCap.SQUARE)

    def test_apply_opacity_alpha_only(self):
        src = _make_rect(opacity=0.4, blend_mode=BlendMode.SCREEN)
        app = extract_appearance(src)
        target = _make_rect()
        cfg = EyedropperConfig(
            fill=False, stroke=False,
            opacity=True,
            opacity_alpha=True,
            opacity_blend=False,
        )
        out = apply_appearance(target, app, cfg)
        self.assertEqual(out.opacity, 0.4)
        self.assertEqual(out.blend_mode, BlendMode.NORMAL)

    def test_source_eligibility_filters_hidden_and_containers(self):
        hidden = _make_rect(visibility=Visibility.INVISIBLE)
        self.assertFalse(is_source_eligible(hidden))

        visible = _make_rect()
        self.assertTrue(is_source_eligible(visible))

        # Locked is OK on source side.
        locked = _make_rect(locked=True)
        self.assertTrue(is_source_eligible(locked))

        group = Group(children=())
        self.assertFalse(is_source_eligible(group))

    def test_target_eligibility_filters_locked_and_containers(self):
        unlocked = _make_rect()
        self.assertTrue(is_target_eligible(unlocked))

        locked = _make_rect(locked=True)
        self.assertFalse(is_target_eligible(locked))

        # Hidden is OK on target side (writes persist).
        hidden = _make_rect(visibility=Visibility.INVISIBLE)
        self.assertTrue(is_target_eligible(hidden))

        layer = Layer(name="L", children=())
        self.assertFalse(is_target_eligible(layer))


if __name__ == "__main__":
    absltest.main()
