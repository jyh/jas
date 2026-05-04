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


def _enum_from_string(enum_class, s: str, default):
    """Look up an enum value by its string form; return `default` on miss."""
    for v in enum_class:
        if v.value == s:
            return v
    return default


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


DEFAULT_PRINT_PREFERENCES = PrintPreferences()


@dataclass(frozen=True)
class PrintPreset:
    """Workspace-level named saved configuration. Phase 1 ships only
    the built-in `[Default]`; save / load / delete is deferred."""
    name: str
    preferences: PrintPreferences


DEFAULT_PRESET = PrintPreset(name="[Default]", preferences=DEFAULT_PRINT_PREFERENCES)
