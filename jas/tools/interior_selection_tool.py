"""Interior Selection tool: marquee select that picks groups as units."""

from __future__ import annotations

from tools.selection_tool import SelectionToolBase


class InteriorSelectionTool(SelectionToolBase):
    def _select_rect(self, ctx, x, y, w, h, extend):
        ctx.controller.interior_select_rect(x, y, w, h, extend=extend)
