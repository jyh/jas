"""Tests for ColorPickerState."""

import sys

from absl.testing import absltest

from tools.color_picker import ColorPickerState, RadioChannel, snap_web
from geometry.element import RgbColor, HsbColor, CmykColor


# -- Creation --

class ColorPickerNewTest(absltest.TestCase):

    def test_new_from_black(self):
        cp = ColorPickerState(RgbColor(0, 0, 0), for_fill=True)
        self.assertEqual(cp.rgb_u8(), (0, 0, 0))
        self.assertEqual(cp.hex_str(), "000000")
        self.assertTrue(cp.for_fill)

    def test_new_from_red(self):
        cp = ColorPickerState(RgbColor(1.0, 0.0, 0.0), for_fill=False)
        self.assertEqual(cp.rgb_u8(), (255, 0, 0))
        self.assertEqual(cp.hex_str(), "ff0000")
        self.assertFalse(cp.for_fill)

    def test_new_from_white(self):
        cp = ColorPickerState(RgbColor(1.0, 1.0, 1.0), for_fill=True)
        self.assertEqual(cp.rgb_u8(), (255, 255, 255))
        self.assertEqual(cp.hex_str(), "ffffff")


# -- set_rgb --

class SetRgbTest(absltest.TestCase):

    def test_set_rgb(self):
        cp = ColorPickerState(RgbColor(0, 0, 0), for_fill=True)
        cp.set_rgb(128, 64, 32)
        self.assertEqual(cp.rgb_u8(), (128, 64, 32))


# -- set_hsb --

class SetHsbTest(absltest.TestCase):

    def test_set_hsb_pure_red(self):
        cp = ColorPickerState(RgbColor(0, 0, 0), for_fill=True)
        cp.set_hsb(0.0, 100.0, 100.0)
        self.assertEqual(cp.rgb_u8(), (255, 0, 0))

    def test_set_hsb_pure_green(self):
        cp = ColorPickerState(RgbColor(0, 0, 0), for_fill=True)
        cp.set_hsb(120.0, 100.0, 100.0)
        self.assertEqual(cp.rgb_u8(), (0, 255, 0))


# -- set_cmyk --

class SetCmykTest(absltest.TestCase):

    def test_set_cmyk_white(self):
        cp = ColorPickerState(RgbColor(0, 0, 0), for_fill=True)
        cp.set_cmyk(0.0, 0.0, 0.0, 0.0)
        self.assertEqual(cp.rgb_u8(), (255, 255, 255))

    def test_set_cmyk_black(self):
        cp = ColorPickerState(RgbColor(1, 1, 1), for_fill=True)
        cp.set_cmyk(0.0, 0.0, 0.0, 100.0)
        self.assertEqual(cp.rgb_u8(), (0, 0, 0))


# -- set_hex --

class SetHexTest(absltest.TestCase):

    def test_set_hex(self):
        cp = ColorPickerState(RgbColor(0, 0, 0), for_fill=True)
        cp.set_hex("ff8000")
        self.assertEqual(cp.rgb_u8(), (255, 128, 0))

    def test_set_hex_invalid(self):
        cp = ColorPickerState(RgbColor(0, 0, 0), for_fill=True)
        cp.set_hex("xyz")
        self.assertEqual(cp.rgb_u8(), (0, 0, 0))


# -- hsb_vals --

class HsbValsTest(absltest.TestCase):

    def test_hsb_vals_red(self):
        cp = ColorPickerState(RgbColor(1.0, 0.0, 0.0), for_fill=True)
        h, s, b = cp.hsb_vals()
        self.assertAlmostEqual(h, 0.0, delta=1.0)
        self.assertAlmostEqual(s, 100.0, delta=1.0)
        self.assertAlmostEqual(b, 100.0, delta=1.0)


# -- cmyk_vals --

class CmykValsTest(absltest.TestCase):

    def test_cmyk_vals_white(self):
        cp = ColorPickerState(RgbColor(1, 1, 1), for_fill=True)
        c, m, y, k = cp.cmyk_vals()
        self.assertAlmostEqual(c, 0.0, delta=1.0)
        self.assertAlmostEqual(m, 0.0, delta=1.0)
        self.assertAlmostEqual(y, 0.0, delta=1.0)
        self.assertAlmostEqual(k, 0.0, delta=1.0)


# -- Web snap --

class WebSnapTest(absltest.TestCase):

    def test_snap_web_zero(self):
        self.assertEqual(snap_web(0.0), 0.0)

    def test_snap_web_one(self):
        self.assertEqual(snap_web(1.0), 1.0)

    def test_snap_web_near_0_2(self):
        self.assertEqual(snap_web(0.19), 0.2)

    def test_snap_web_equidistant(self):
        # equidistant between 0.4 and 0.6, snaps to 0.4
        self.assertEqual(snap_web(0.5), 0.4)

    def test_web_only_snaps(self):
        cp = ColorPickerState(RgbColor(0, 0, 0), for_fill=True)
        cp.web_only = True
        cp.set_rgb(100, 150, 200)
        r, g, b = cp.rgb_u8()
        web_vals = {0, 51, 102, 153, 204, 255}
        self.assertIn(r, web_vals)
        self.assertIn(g, web_vals)
        self.assertIn(b, web_vals)


# -- Colorbar position --

class ColorbarPosTest(absltest.TestCase):

    def test_colorbar_pos_hue(self):
        cp = ColorPickerState(HsbColor(180.0, 0.5, 0.8), for_fill=True)
        cp.radio = RadioChannel.H
        pos = cp.colorbar_pos()
        self.assertAlmostEqual(pos, 0.5, delta=0.01)


# -- Gradient position --

class GradientPosTest(absltest.TestCase):

    def test_gradient_pos_hue(self):
        cp = ColorPickerState(HsbColor(120.0, 0.7, 0.9), for_fill=True)
        cp.radio = RadioChannel.H
        x, y = cp.gradient_pos()
        self.assertAlmostEqual(x, 0.7, delta=0.01)
        self.assertAlmostEqual(y, 0.1, delta=0.01)


# -- Radio channel --

class RadioChannelTest(absltest.TestCase):

    def test_all_channels(self):
        self.assertEqual(len(RadioChannel), 6)
        for ch in (RadioChannel.H, RadioChannel.S, RadioChannel.B,
                   RadioChannel.R, RadioChannel.G, RadioChannel.BLUE):
            self.assertIsInstance(ch, RadioChannel)


# -- Color roundtrip --

class ColorRoundtripTest(absltest.TestCase):

    def test_roundtrip(self):
        original = RgbColor(0.5, 0.3, 0.8)
        cp = ColorPickerState(original, for_fill=True)
        result = cp.color()
        r1, g1, b1, _ = original.to_rgba()
        r2, g2, b2, _ = result.to_rgba()
        self.assertAlmostEqual(r1, r2, delta=0.001)
        self.assertAlmostEqual(g1, g2, delta=0.001)
        self.assertAlmostEqual(b1, b2, delta=0.001)


# -- Preserved hue/sat --

class PreservedHueSatTest(absltest.TestCase):

    def test_preserved_hue_at_black(self):
        cp = ColorPickerState(HsbColor(200.0, 0.8, 1.0), for_fill=True)
        cp.set_hsb(200.0, 80.0, 0.0)
        h, _, _ = cp.hsb_vals()
        self.assertAlmostEqual(h, 200.0, delta=1.0)


if __name__ == "__main__":
    absltest.main()
