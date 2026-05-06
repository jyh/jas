"""Per-document settings edited from the Document Setup dialog
(PRINT.md §Phase 1A). Bleed values are in points and represent the
amount of artwork that extends past each artboard edge for trim
tolerance during commercial printing."""

from __future__ import annotations

from dataclasses import dataclass

from document.artboard import Artboard
from document.print_preferences import FlattenerPreset


@dataclass(frozen=True)
class DocumentSetup:
    bleed_top: float = 0.0
    bleed_right: float = 0.0
    bleed_bottom: float = 0.0
    bleed_left: float = 0.0
    # Chain-link state for the bleed inputs in the dialog. When True,
    # editing any one side propagates to all four. Persisted because
    # the user expects the chain to stay where they left it across
    # sessions.
    bleed_uniform: bool = True
    # Render image elements as their bounding outline rather than
    # rasterized content (canvas display only; export ignores this).
    show_images_outline: bool = False
    # Tint glyphs that were rendered with a substituted font so the
    # user can spot missing-font cases.
    highlight_substituted_glyphs: bool = False
    # Phase 6 additions (deferred Phase 1A items).
    grid_size: float = 72.0
    grid_color: str = "#cccccc"
    paper_color: str = "#ffffff"
    simulate_colored_paper: bool = False
    transparency_flattener_preset: FlattenerPreset = FlattenerPreset.MEDIUM_RESOLUTION
    discard_white_overprint: bool = False

    def bleed_rect_for_artboard(
        self, ab: Artboard
    ) -> tuple[float, float, float, float] | None:
        """Outset rect of one artboard by the per-side bleed values, in
        document points. Returns None when all four bleeds are zero."""
        if (self.bleed_top == 0.0 and self.bleed_right == 0.0
                and self.bleed_bottom == 0.0 and self.bleed_left == 0.0):
            return None
        return (
            ab.x - self.bleed_left,
            ab.y - self.bleed_top,
            ab.width + self.bleed_left + self.bleed_right,
            ab.height + self.bleed_top + self.bleed_bottom,
        )


DEFAULT_DOCUMENT_SETUP = DocumentSetup()
