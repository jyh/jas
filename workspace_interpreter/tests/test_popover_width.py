"""A popover (`modal: false`) dialog DECLARES its width (STATUS-flask 692 (2),
ruled 2026-10-31).

Each shell sized a popover its own way: the web shrank it to its content, the
Mac fixed it to its intrinsic size, and the Windows shell planned it at its
420-DIP default, so the same flyout was three widths. A declared `width` is one
number every shell already reads (the web's `dialog_view.rs`, the plan's
`width` in `ffi.rs`, and the Mac's popover), so the three agree by
construction. The 7 tool-alternate flyouts are the population today; a new
popover joins it by being one.
"""

import json
import pathlib

WORKSPACE = json.loads(
    (pathlib.Path(__file__).resolve().parents[2] / "workspace" / "workspace.json")
    .read_text(encoding="utf-8")
)


def _popovers():
    return {k: d for k, d in WORKSPACE["dialogs"].items()
            if isinstance(d, dict) and d.get("modal") is False}


def test_the_popover_population_is_the_seven_tool_flyouts():
    # A floor, so the test below cannot pass on an empty population.
    assert len(_popovers()) >= 7, sorted(_popovers())


def test_every_popover_declares_a_positive_numeric_width():
    missing = {k: d.get("width") for k, d in _popovers().items()
               if not (isinstance(d.get("width"), (int, float))
                       and not isinstance(d.get("width"), bool)
                       and d["width"] > 0)}
    assert not missing, f"popovers without a declared width: {missing}"
