import os
import sys

from absl.testing import absltest

# Ensure repo root is on sys.path so sibling package imports resolve
# when the test runs via pytest from the repo root.
_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from geometry.element import Rect
from geometry.test_json import _element_json, parse_element_json
import json


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
