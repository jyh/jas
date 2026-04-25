"""Tests for the Python Magic Wand predicate. Parallels
jas_dioxus/src/algorithms/magic_wand.rs +
JasSwift/Tests/Algorithms/MagicWandTests.swift +
jas_ocaml/test/algorithms/magic_wand_test.ml.
"""

from absl.testing import absltest

from algorithms.magic_wand import MagicWandConfig, magic_wand_match
from geometry.element import BlendMode, Color, Fill, Rect, Stroke


def _make_rect(*, fill=None, stroke=None, opacity=1.0,
               blend_mode=BlendMode.NORMAL) -> Rect:
    return Rect(x=0.0, y=0.0, width=10.0, height=10.0,
                fill=fill, stroke=stroke,
                opacity=opacity, blend_mode=blend_mode)


_RED = Fill(color=Color.rgb(1.0, 0.0, 0.0))
_NEAR_RED = Fill(color=Color.rgb(240.0 / 255.0, 10.0 / 255.0, 10.0 / 255.0))
_DARK_RED = Fill(color=Color.rgb(200.0 / 255.0, 0.0, 0.0))


def _black_stroke(width: float) -> Stroke:
    return Stroke(color=Color.rgb(0.0, 0.0, 0.0), width=width)


class MagicWandPredicateTest(absltest.TestCase):

    def test_all_disabled_never_matches(self):
        cfg = MagicWandConfig(fill_color=False, stroke_color=False,
                              stroke_weight=False, opacity=False,
                              blending_mode=False)
        seed = _make_rect(fill=_RED)
        cand = _make_rect(fill=_RED)
        self.assertFalse(magic_wand_match(seed, cand, cfg))

    def test_identical_elements_match_under_default_config(self):
        cfg = MagicWandConfig()
        seed = _make_rect(fill=_RED, stroke=_black_stroke(2.0))
        cand = _make_rect(fill=_RED, stroke=_black_stroke(2.0))
        self.assertTrue(magic_wand_match(seed, cand, cfg))

    def test_fill_color_within_tolerance_matches(self):
        cfg = MagicWandConfig(stroke_color=False, stroke_weight=False,
                              opacity=False, blending_mode=False)
        seed = _make_rect(fill=_RED)
        cand = _make_rect(fill=_NEAR_RED)
        self.assertTrue(magic_wand_match(seed, cand, cfg))

    def test_fill_color_outside_tolerance_misses(self):
        cfg = MagicWandConfig(stroke_color=False, stroke_weight=False,
                              opacity=False, blending_mode=False,
                              fill_tolerance=10.0)
        seed = _make_rect(fill=_RED)
        cand = _make_rect(fill=_DARK_RED)
        self.assertFalse(magic_wand_match(seed, cand, cfg))

    def test_none_fill_matches_only_none_fill(self):
        cfg = MagicWandConfig(stroke_color=False, stroke_weight=False,
                              opacity=False, blending_mode=False)
        none_fill = _make_rect()
        red = _make_rect(fill=_RED)
        self.assertTrue(magic_wand_match(none_fill, none_fill, cfg))
        self.assertFalse(magic_wand_match(none_fill, red, cfg))
        self.assertFalse(magic_wand_match(red, none_fill, cfg))

    def test_stroke_weight_uses_pt_delta(self):
        cfg = MagicWandConfig(fill_color=False, stroke_color=False,
                              opacity=False, blending_mode=False,
                              stroke_weight_tolerance=1.0)
        s2 = _make_rect(stroke=_black_stroke(2.0))
        s2_5 = _make_rect(stroke=_black_stroke(2.5))
        s4 = _make_rect(stroke=_black_stroke(4.0))
        self.assertTrue(magic_wand_match(s2, s2_5, cfg))   # delta 0.5 <= 1
        self.assertFalse(magic_wand_match(s2, s4, cfg))    # delta 2.0 > 1

    def test_opacity_uses_percentage_point_delta(self):
        cfg = MagicWandConfig(fill_color=False, stroke_color=False,
                              stroke_weight=False, blending_mode=False,
                              opacity_tolerance=5.0)
        a = _make_rect(opacity=1.0)
        b = _make_rect(opacity=0.97)
        c = _make_rect(opacity=0.80)
        self.assertTrue(magic_wand_match(a, b, cfg))    # |delta|*100 = 3
        self.assertFalse(magic_wand_match(a, c, cfg))   # |delta|*100 = 20

    def test_blending_mode_is_exact_match(self):
        cfg = MagicWandConfig(fill_color=False, stroke_color=False,
                              stroke_weight=False, opacity=False,
                              blending_mode=True)
        normal = _make_rect(blend_mode=BlendMode.NORMAL)
        normal2 = _make_rect(blend_mode=BlendMode.NORMAL)
        multiply = _make_rect(blend_mode=BlendMode.MULTIPLY)
        self.assertTrue(magic_wand_match(normal, normal2, cfg))
        self.assertFalse(magic_wand_match(normal, multiply, cfg))

    def test_and_across_criteria_one_failure_misses(self):
        cfg = MagicWandConfig(opacity=False, blending_mode=False,
                              stroke_weight_tolerance=1.0)
        seed = _make_rect(fill=_RED, stroke=_black_stroke(2.0))
        cand = _make_rect(fill=_RED, stroke=_black_stroke(5.0))
        self.assertFalse(magic_wand_match(seed, cand, cfg))


if __name__ == "__main__":
    absltest.main()
