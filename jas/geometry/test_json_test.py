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


class FillRuleTestJsonTest(absltest.TestCase):
    """A path's fill rule, as the ports carry it (jas_dioxus test_json.rs):
    `"fill_rule":"evenodd"` only when it is not the nonzero default, and an
    absent key reads as nonzero."""

    def _path(self, **kw):
        from geometry.element import LineTo, MoveTo, Path
        return Path(d=(MoveTo(0, 0), LineTo(1, 1)), **kw)

    def test_a_path_defaults_to_nonzero(self):
        from geometry.element import FillRule
        self.assertEqual(self._path().fill_rule, FillRule.NONZERO)

    def test_evenodd_is_written_and_read_back(self):
        from geometry.element import FillRule
        j = _element_json(self._path(fill_rule=FillRule.EVENODD))
        self.assertIn('"fill_rule":"evenodd"', j)
        self.assertEqual(parse_element_json(json.loads(j)).fill_rule, FillRule.EVENODD)

    def test_nonzero_is_omitted_and_an_absent_key_reads_nonzero(self):
        from geometry.element import FillRule
        j = _element_json(self._path())
        self.assertNotIn("fill_rule", j)
        self.assertEqual(parse_element_json(json.loads(j)).fill_rule, FillRule.NONZERO)


PARAGRAPH_STRS = ["jas_role", "jas_list_style", "text_align", "text_align_last",
                  "jas_single_word_justify"]
PARAGRAPH_BOOLS = ["jas_hyphenate", "jas_hanging_punctuation", "jas_hyphenate_capitalized"]
PARAGRAPH_NUMS = ["jas_left_indent", "jas_right_indent", "text_indent", "jas_space_before",
                  "jas_space_after", "jas_word_spacing_min", "jas_word_spacing_desired",
                  "jas_word_spacing_max", "jas_letter_spacing_min", "jas_letter_spacing_desired",
                  "jas_letter_spacing_max", "jas_glyph_scaling_min", "jas_glyph_scaling_desired",
                  "jas_glyph_scaling_max", "jas_auto_leading", "jas_hyphenate_min_word",
                  "jas_hyphenate_min_before", "jas_hyphenate_min_after", "jas_hyphenate_limit",
                  "jas_hyphenate_zone", "jas_hyphenate_bias"]


class TspanParagraphAttributesTest(absltest.TestCase):
    """The paragraph attributes ride the tspan, and the canonical JSON used
    to neither write nor read them, so justify, the indents and the spacing
    ranges reached no read-back. Mirrors Rust's
    ``tspan_paragraph_attributes_round_trip_through_test_json`` and
    ``tspan_json_writes_every_tspan_field``."""

    def test_paragraph_attributes_round_trip(self):
        # Each field gets its OWN value, so a key written under a sibling's
        # name cannot pass.
        tspan = {"id": 1, "content": "t"}
        tspan.update({k: f"v_{k}" for k in PARAGRAPH_STRS})
        tspan.update({k: True for k in PARAGRAPH_BOOLS})
        tspan.update({k: 1.5 + i for i, k in enumerate(PARAGRAPH_NUMS)})
        from geometry.element import Text
        base = json.loads(_element_json(Text(x=0.0, y=0.0, content="t")))
        base["tspans"] = [tspan]
        elem = parse_element_json(base)
        back = json.loads(_element_json(elem))["tspans"][0]
        for k in PARAGRAPH_STRS + PARAGRAPH_BOOLS + PARAGRAPH_NUMS:
            self.assertEqual(back.get(k, "absent"), tspan[k], f"tspan key {k}")

    def test_both_tspan_writers_write_every_tspan_field(self):
        # The key set is the Tspan dataclass's field set, derived, so a field
        # added without a writer line reds here, for the full writer and for
        # the default-tspan writer a flat-content text goes through.
        import dataclasses
        from geometry.tspan import Tspan
        from geometry.test_json import _default_tspan_json, _tspan_json
        fields = {f.name for f in dataclasses.fields(Tspan)}
        self.assertGreater(len(fields), 40)
        full = set(json.loads(_tspan_json(Tspan(id=0, content="t"))))
        default = set(json.loads(_default_tspan_json("t")))
        self.assertEqual(full, fields, f"writer only {full - fields}, struct only {fields - full}")
        self.assertEqual(default, fields, f"writer only {default - fields}, struct only {fields - default}")


if __name__ == "__main__":
    absltest.main()
