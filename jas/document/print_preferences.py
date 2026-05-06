"""Per-document Print dialog state (PRINT.md §Phase 1B). Remembers
the last-used choices in the General tab so reopening Print restores
them. Later phases extend with sub-records for marks, output,
graphics, color management, advanced.

`PrintPreset` is the workspace-level named saved configuration of
the same fields. Phase 1 ships exactly one built-in `[Default]`;
save / load / delete is deferred (PRINT.md §Phase 7+)."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class ArtboardRangeMode(Enum):
    ALL = "all"
    RANGE = "range"


class MediaSize(Enum):
    DEFINED_BY_DRIVER = "defined_by_driver"
    LETTER = "letter"
    LEGAL = "legal"
    TABLOID = "tabloid"
    A3 = "a3"
    A4 = "a4"
    A5 = "a5"
    CUSTOM = "custom"


class Orientation(Enum):
    PORTRAIT = "portrait"
    LANDSCAPE = "landscape"


class PrintLayers(Enum):
    """Visible & Printable: honor visibility != Invisible AND a future
    Layer.print flag. Until that flag lands this collapses to VISIBLE."""
    VISIBLE_PRINTABLE = "visible_printable"
    VISIBLE = "visible"
    ALL = "all"


class ScalingMode(Enum):
    DO_NOT_SCALE = "do_not_scale"
    FIT_TO_PAGE = "fit_to_page"
    CUSTOM = "custom"


class PrinterMarkType(Enum):
    """Two cultural variants of printer's marks. ``ROMAN`` ships the
    standard Western trim/registration marks; ``JAPANESE`` swaps in
    the kasen-style marks used by Japanese commercial print shops.
    Phase 2 stores the choice but the renderer only differentiates in
    a follow-up — the on-disk shape is stable now."""
    ROMAN = "roman"
    JAPANESE = "japanese"


def _enum_from_string(enum_class, s: str, default):
    """Look up an enum value by its string form; return `default` on miss."""
    for v in enum_class:
        if v.value == s:
            return v
    return default


@dataclass(frozen=True)
class MarksAndBleed:
    """Marks-and-bleed sub-record on PrintPreferences (PRINT.md §Phase 2).
    The Marks tab exposes these 1:1 as widgets; the PDF renderer
    extends each page by the active bleed and overlays mark geometry
    around the trim rect.

    ``use_document_bleed`` controls whether bleeds come from the
    document-level ``DocumentSetup`` or from the per-print ``bleed_*``
    overrides on this struct. Defaulting to True keeps document and
    print in lockstep until the user opts out."""
    all_printer_marks: bool = False
    trim_marks: bool = False
    registration_marks: bool = False
    color_bars: bool = False
    page_information: bool = False
    printer_mark_type: PrinterMarkType = PrinterMarkType.ROMAN
    trim_mark_weight: float = 0.25
    mark_offset: float = 6.0
    use_document_bleed: bool = True
    bleed_top: float = 0.0
    bleed_right: float = 0.0
    bleed_bottom: float = 0.0
    bleed_left: float = 0.0


DEFAULT_MARKS_AND_BLEED = MarksAndBleed()


@dataclass(frozen=True)
class PrintPreferences:
    preset_name: str = "[Default]"
    printer_name: str | None = None
    copies: int = 1
    collate: bool = False
    reverse_order: bool = False
    artboard_range_mode: ArtboardRangeMode = ArtboardRangeMode.ALL
    artboard_range: str = ""
    ignore_artboards: bool = False
    skip_blank_artboards: bool = False
    media_size: MediaSize = MediaSize.DEFINED_BY_DRIVER
    media_width: float = 612.0
    media_height: float = 792.0
    orientation: Orientation = Orientation.PORTRAIT
    auto_rotate: bool = True
    transverse: bool = False
    print_layers: PrintLayers = PrintLayers.VISIBLE_PRINTABLE
    placement_x: float = 0.0
    placement_y: float = 0.0
    scaling_mode: ScalingMode = ScalingMode.DO_NOT_SCALE
    custom_scale: float = 100.0
    # Reserved for Phase 7 tiling. Stored now so the on-disk shape is
    # stable across phases.
    tile_overlap_h: float = 0.0
    tile_overlap_v: float = 0.0
    tile_range: str = ""
    # Marks-and-bleed sub-record (PRINT.md §Phase 2).
    marks_and_bleed: MarksAndBleed = DEFAULT_MARKS_AND_BLEED


DEFAULT_PRINT_PREFERENCES = PrintPreferences()


@dataclass(frozen=True)
class PrintPreset:
    """Workspace-level named saved configuration. Phase 1 ships only
    the built-in `[Default]`; save / load / delete is deferred."""
    name: str
    preferences: PrintPreferences


DEFAULT_PRESET = PrintPreset(name="[Default]", preferences=DEFAULT_PRINT_PREFERENCES)
