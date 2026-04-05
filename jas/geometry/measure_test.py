from absl.testing import absltest

from geometry.measure import Unit, Measure, px, pt


class MeasureTest(absltest.TestCase):

    def test_px_identity(self):
        m = Measure(100, Unit.PX)
        self.assertEqual(m.to_px(), 100)

    def test_pt_to_px(self):
        m = Measure(72, Unit.PT)
        self.assertAlmostEqual(m.to_px(), 96.0)

    def test_pc_to_px(self):
        m = Measure(1, Unit.PC)
        self.assertAlmostEqual(m.to_px(), 16.0)

    def test_in_to_px(self):
        m = Measure(1, Unit.IN)
        self.assertAlmostEqual(m.to_px(), 96.0)

    def test_cm_to_px(self):
        m = Measure(2.54, Unit.CM)
        self.assertAlmostEqual(m.to_px(), 96.0)

    def test_mm_to_px(self):
        m = Measure(25.4, Unit.MM)
        self.assertAlmostEqual(m.to_px(), 96.0)

    def test_em_to_px(self):
        m = Measure(2, Unit.EM)
        self.assertAlmostEqual(m.to_px(), 32.0)

    def test_em_custom_font_size(self):
        m = Measure(2, Unit.EM)
        self.assertAlmostEqual(m.to_px(font_size=24.0), 48.0)

    def test_rem_to_px(self):
        m = Measure(1.5, Unit.REM)
        self.assertAlmostEqual(m.to_px(), 24.0)

    def test_default_unit_is_px(self):
        m = Measure(10)
        self.assertEqual(m.unit, Unit.PX)
        self.assertEqual(m.to_px(), 10)

    def test_shorthand_px(self):
        m = px(50)
        self.assertEqual(m.value, 50)
        self.assertEqual(m.unit, Unit.PX)

    def test_shorthand_pt(self):
        m = pt(72)
        self.assertEqual(m.value, 72)
        self.assertEqual(m.unit, Unit.PT)

    def test_measure_immutable(self):
        m = Measure(10, Unit.PX)
        with self.assertRaises(AttributeError):
            m.value = 20


if __name__ == "__main__":
    absltest.main()
