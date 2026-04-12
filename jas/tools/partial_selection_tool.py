"""Partial Selection tool: select control points and drag Bezier handles."""

from __future__ import annotations

from tools.selection_tool import SelectionToolBase


class PartialSelectionTool(SelectionToolBase):
    def __init__(self):
        super().__init__()
        # Live Bezier-handle drag. (path, anchor_idx, handle_type, last_x, last_y)
        self._handle_drag: tuple[tuple[int, ...], int, str, float, float] | None = None

    def _select_rect(self, ctx, x, y, w, h, extend):
        ctx.controller.direct_select_rect(x, y, w, h, extend=extend)

    def _check_handle_hit(self, ctx, x, y):
        hit = ctx.hit_test_handle(x, y)
        if hit is not None:
            ctx.snapshot()
            path, anchor_idx, handle_type = hit
            self._handle_drag = (path, anchor_idx, handle_type, x, y)
            return True
        return False

    def on_move(self, ctx, x, y, shift=False, dragging=False):
        if self._handle_drag is not None:
            path, anchor_idx, handle_type, lx, ly = self._handle_drag
            dx, dy = x - lx, y - ly
            ctx.controller.move_path_handle(path, anchor_idx, handle_type, dx, dy)
            self._handle_drag = (path, anchor_idx, handle_type, x, y)
            ctx.request_update()
            return
        super().on_move(ctx, x, y, shift, dragging)

    def on_release(self, ctx, x, y, shift=False, alt=False):
        if self._handle_drag is not None:
            self._handle_drag = None
            ctx.request_update()
            return
        super().on_release(ctx, x, y, shift, alt)

    def draw_overlay(self, ctx, painter):
        # Live edits — no ghost. Marquee overlay still comes from base.
        super().draw_overlay(ctx, painter)
