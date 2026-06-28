"""Regression: tools that hit-test / edit DOCUMENT geometry must drive their
coordinates from event.doc_x / event.doc_y, never the raw canvas event.x /
event.y.

event.x / event.y are CANVAS/screen coords; event.doc_x / event.doc_y are
document coords = (canvas_x - view_offset_x) / zoom (jas/tools/yaml_tool.py).
A doc.* effect (or hit_test) that compares the incoming x,y against stored
document geometry expects DOC coords and does NOT convert — so passing the
raw event.x silently misses, offset by the view pan/zoom (and the default
view is already offset). path_eraser had this bug; a coord audit
(2026-06-27) found the same class in five more tools. All fixed here.

Known remaining exception: the `artboard` tool also has this bug, but its
fix is non-trivial (its canvas tool-state feeds BOTH a marquee_rect overlay
AND the create/move/resize effects, so it needs the shape-tool preview/commit
coord split, not a blanket swap) — tracked separately, deliberately NOT
asserted here.
"""
import json
import os
from absl.testing import absltest

_WS = os.path.join(os.path.dirname(__file__), "..", "..",
                   "workspace", "workspace.json")

# Tools whose EVERY pointer coordinate is document geometry — must not use raw
# event.x / event.y anywhere.
_FULLY_DOC_TOOLS = [
    "path_eraser",
    "add_anchor_point",
    "delete_anchor_point",
    "anchor_point",
    "magic_wand",
]


class ToolDocCoordsTest(absltest.TestCase):

    def setUp(self):
        self._tools = json.loads(open(_WS).read())["tools"]

    def test_fully_doc_tools_use_only_doc_coords(self):
        for tool in _FULLY_DOC_TOOLS:
            blob = json.dumps(self._tools[tool])
            self.assertIn("event.doc_x", blob, f"{tool} should drive coords from event.doc_x")
            # Substring-safe: "event.doc_x" does not contain "event.x".
            self.assertNotIn("event.x", blob, f"{tool} still uses raw canvas event.x")
            self.assertNotIn("event.y", blob, f"{tool} still uses raw canvas event.y")

    def test_eyedropper_hit_test_uses_doc_coords(self):
        # Eyedropper hit-tests in doc coords but legitimately keeps event.x/y
        # for its screen-space cursor-color-chip overlay (hover_x/hover_y).
        blob = json.dumps(self._tools["eyedropper"])
        self.assertIn("hit_test(event.doc_x, event.doc_y)", blob)
        self.assertNotIn("hit_test(event.x", blob)

    def test_artboard_effects_use_doc_coords_overlay_keeps_canvas(self):
        # The artboard tool is a SPLIT case: its probe / create / move /
        # resize / duplicate effects drive doc geometry (must use doc coords),
        # while the marquee + outline overlays draw in screen space (keep the
        # canvas press_/cursor_ tool-state). So both must be present.
        blob = json.dumps(self._tools["artboard"])
        self.assertIn("tool.artboard.doc_press_x", blob)  # effects read doc state
        self.assertIn("event.doc_x", blob)                # probe/create cursor in doc
        self.assertIn("tool.artboard.press_x", blob)      # overlays keep canvas state


if __name__ == "__main__":
    absltest.main()
