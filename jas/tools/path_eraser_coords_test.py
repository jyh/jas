"""Regression: the Path Eraser must hit-test in DOCUMENT coords.

`doc.path.erase_at_rect` operates on path geometry stored in document
coordinates (the pencil/pen commit paths from `event.doc_x` / `event.doc_y`,
i.e. `(canvas_x - view_offset_x) / zoom`). The path_eraser tool therefore
has to pass `event.doc_x` / `event.doc_y` — NOT the raw `event.x` / `event.y`
(canvas/screen coords). It originally used `event.x`, so the eraser rect was
offset by the view pan/zoom and silently MISSED every path unless the view
happened to sit at zoom=1 with zero offset. GUI-found across all apps
2026-06-27; the bug lived in the shared bundle so every app was affected.
"""
import json
import os
from absl.testing import absltest

_WS = os.path.join(os.path.dirname(__file__), "..", "..",
                   "workspace", "workspace.json")


class PathEraserCoordsTest(absltest.TestCase):

    def test_path_eraser_uses_document_coords(self):
        ws = json.loads(open(_WS).read())
        blob = json.dumps(ws["tools"]["path_eraser"])
        # Must drive erase_at_rect from document coords.
        self.assertIn("event.doc_x", blob)
        self.assertIn("event.doc_y", blob)
        # Must NOT use raw canvas coords (substring-safe: "event.doc_x" does
        # not contain "event.x").
        self.assertNotIn("event.x", blob)
        self.assertNotIn("event.y", blob)


if __name__ == "__main__":
    absltest.main()
