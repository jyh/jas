import os
import sys

from absl.testing import absltest

# Ensure repo root is on sys.path so sibling package imports resolve
# when the test runs via pytest from the repo root.
_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from geometry.element import Rect
from geometry.test_json import _element_json, _fmt, parse_element_json
import json


class FloatFormattingTest(absltest.TestCase):
    """R3: the canonical-JSON oracle prints SIX decimals, in every port.

    The active ports moved from 4dp to 6dp on 2026-08-02 (`test_json.rs`
    `fmt`, `TestJson.swift` `fmt`). At 4dp the oracle shared the SVG
    writer's position quantizer, so a divergence below 1e-4 was invisible by
    construction. The reference never received the change, and 46 cases of
    its own corpus harness then failed on precision alone. The values below
    are the Rust arm's `float_formatting`, value for value, so the three
    formatters are pinned against one table.
    """

    def test_integral_values_keep_one_fractional_digit(self):
        self.assertEqual(_fmt(1.0), "1.0")
        self.assertEqual(_fmt(0.0), "0.0")
        self.assertEqual(_fmt(72.0), "72.0")
        self.assertEqual(_fmt(0.5), "0.5")

    def test_six_decimals_not_four(self):
        # At 4dp these were "3.1416" and "0.1235".
        self.assertEqual(_fmt(3.14159), "3.14159")
        self.assertEqual(_fmt(0.12345), "0.12345")

    def test_rounding_happens_two_digits_later(self):
        self.assertEqual(_fmt(3.14159265), "3.141593")
        self.assertEqual(_fmt(0.123456789), "0.123457")

    def test_the_band_4dp_could_not_resolve(self):
        # 1pt written to SVG as px at 4dp (4/3 -> 1.3333) and read back is
        # 1.3333 * 0.75 = 0.999975; at 4dp that printed as "1.0".
        self.assertEqual(_fmt(0.999975), "0.999975")
        self.assertNotEqual(_fmt(0.999975), _fmt(1.0))

    def test_trailing_zeros_stripped_to_one_digit(self):
        self.assertEqual(_fmt(2.5000004), "2.5")
        self.assertEqual(_fmt(1.100000), "1.1")


class CommonIdTest(absltest.TestCase):
    """Stable element identity (VISION.md §6.2) round-trips through the
    canonical test JSON, mirroring the lead Rust implementation."""

    def test_common_id_round_trips(self):
        # An element's id survives the canonical test_json round-trip.
        elem = Rect(x=0.0, y=0.0, width=10.0, height=10.0, id="e1")
        s = _element_json(elem)
        self.assertIn('"id":"e1"', s, f"id should serialize: {s}")
        parsed = parse_element_json(json.loads(s))
        self.assertEqual(parsed.id, "e1")

    def test_id_absent_is_byte_identical(self):
        # Additive invariant: an id-less element emits no "id" key, so
        # every existing document serializes exactly as before.
        elem = Rect(x=0.0, y=0.0, width=10.0, height=10.0)
        s = _element_json(elem)
        self.assertNotIn('"id"', s,
                         f"id-less element must not emit id key: {s}")


if __name__ == "__main__":
    absltest.main()
