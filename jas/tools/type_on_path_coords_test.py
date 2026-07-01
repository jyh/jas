"""Regression: Type-on-Path must convert screen (widget px) -> document
coords in its pointer handlers, exactly like the Type tool and the Rust
reference. Before the fix it fed raw widget coords straight into path
hit-testing / geometry, so it drifted under zoom/pan.
"""

from document.document import Document
from document.model import Model
from tools.type_on_path_tool import TypeOnPathTool


def _ctx(model: Model):
    ctx = type("Ctx", (), {})()
    ctx.model = model
    ctx.document = model.document
    ctx.request_update = lambda: None
    ctx.app_state = None
    ctx.snapshot = lambda: None
    return ctx


def _zoomed_model() -> Model:
    m = Model(Document())
    m.zoom_level = 2.0
    m.view_offset_x = 100.0
    m.view_offset_y = 50.0
    return m


def test_on_press_converts_screen_to_doc():
    # Empty canvas -> on_press falls through to storing the drag-create anchor.
    # screen (300, 250) with zoom 2 + offset (100, 50) -> doc (100, 100).
    tool = TypeOnPathTool()
    tool.on_press(_ctx(_zoomed_model()), 300.0, 250.0)
    assert tool._drag_start == (100.0, 100.0)


def test_on_move_converts_screen_to_doc():
    m = _zoomed_model()
    ctx = _ctx(m)
    tool = TypeOnPathTool()
    tool.on_press(ctx, 300.0, 250.0)                 # doc (100, 100)
    tool.on_move(ctx, 500.0, 250.0, dragging=True)   # doc (200, 100)
    assert tool._drag_end == (200.0, 100.0)


def test_identity_transform_is_a_noop():
    # At default zoom/pan raw == doc, so behavior is unchanged.
    tool = TypeOnPathTool()
    tool.on_press(_ctx(Model(Document())), 42.0, 17.0)
    assert tool._drag_start == (42.0, 17.0)
