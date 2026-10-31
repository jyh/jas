"""The Color Picker DECLARES its width (STATUS-flask 705 (1a), ruled
2026-10-31).

With no declared width each shell sized the picker its own way: the web shrank
the dialog to its content, and the Windows shell planned it at its 420 default,
where the row squeezed the saturation/brightness field to 135 wide. A declared
`width` is one number every shell reads (the web's `dialog_view.rs`, the plan's
`width`, the Mac's dialog frame).

The number is the web's, measured: the deployed dialog's OUTER frame (the web's
dialog is `box-sizing: border-box`, so `width` includes its 1 px border). In
Edge, by the DevTools protocol, the frame is 509.06 CSS px at a device pixel
ratio of 1 and 2 (508.40 at 1.5, where the border is 2/3 px), and its body is
507.06. Set as the frame's width, 509 is too narrow: the body drops below its
content and 65 of the dialog's 106 elements move (up to 18 px, a wrap). 510 is
the least whole width that moves nothing by 1 px or more and keeps the height.
"""

import json
import pathlib

from workspace_interpreter.panel_layout import layout_panel

WORKSPACE = json.loads(
    (pathlib.Path(__file__).resolve().parents[2] / "workspace" / "workspace.json")
    .read_text(encoding="utf-8")
)
PICKER = WORKSPACE["dialogs"]["color_picker"]

# The Windows shell's plan width for a dialog that declares none
# (`Canvas.DialogAvailW`).
SHELL_DEFAULT_W = 420


def _fields_column_width(avail_w):
    """The width of the main row's cell that holds the HSB fields (``cp_h``).
    Since STATUS-flask 705 (1b) the field keeps its min_width at any width,
    so the declared width shows in this column instead."""
    path = None

    def walk(n, p):
        nonlocal path
        if isinstance(n, dict):
            if n.get("id") == "cp_h" or (n.get("params") or {}).get("input_id") == "cp_h":
                path = p
            for i, c in enumerate(n.get("children") or []):
                walk(c, p + [i])

    walk(PICKER["content"], [])
    assert path is not None and len(path) >= 2, "the picker has no cp_h"
    cell = path[:2]
    rects = layout_panel({"content": PICKER["content"]}, avail_w)
    return next(r["rect"]["w"] for r in rects if r["path"] == cell)


def test_the_color_picker_declares_the_webs_measured_outer_width():
    assert PICKER.get("width") == 510, PICKER.get("width")


def test_the_declared_width_gives_the_fields_column_more_room_than_the_shell_default():
    # A control: what the shell planned before, with no declared width.
    before = _fields_column_width(SHELL_DEFAULT_W)
    after = _fields_column_width(PICKER.get("width") or SHELL_DEFAULT_W)
    assert after > before, (before, after)
