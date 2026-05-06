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


class OutputMode(Enum):
    """Output mode (PRINT.md §Phase 3). COMPOSITE renders one PDF
    page per artboard; SEPARATIONS renders one page per enabled ink
    in ``Output.inks``."""
    COMPOSITE = "composite"
    SEPARATIONS = "separations"


class Emulsion(Enum):
    """Film emulsion side (PRINT.md §Phase 3). For PDF output this
    has no rendering effect, but the on-disk shape is stable."""
    UP_RIGHT = "up_right"
    DOWN_RIGHT = "down_right"


class ImagePolarity(Enum):
    """PDF page polarity (PRINT.md §Phase 3). NEGATIVE inverts the
    final rasterized output; for PDF this is recorded but not
    applied."""
    POSITIVE = "positive"
    NEGATIVE = "negative"


class FlattenerPreset(Enum):
    """Transparency / overprint flattener preset (PRINT.md §Phase 6).
    Used by both the Print Advanced tab and Document Setup."""
    LOW_RESOLUTION = "low_resolution"
    MEDIUM_RESOLUTION = "medium_resolution"
    HIGH_RESOLUTION = "high_resolution"
    CUSTOM = "custom"


class ColorHandling(Enum):
    """Color-handling mode for the Color Management tab (PRINT.md
    §Phase 5). Three Adobe-standard choices."""
    LET_APP_DETERMINE = "let_app_determine"
    LET_PRINTER_DETERMINE = "let_printer_determine"
    POSTSCRIPT_COLOR_MANAGEMENT = "postscript_color_management"


class RenderingIntent(Enum):
    """PDF rendering intent (PRINT.md §Phase 5). Names match PDF
    1.7 §11.6.5.8 one-for-one."""
    PERCEPTUAL = "perceptual"
    RELATIVE_COLORIMETRIC = "relative_colorimetric"
    SATURATION = "saturation"
    ABSOLUTE_COLORIMETRIC = "absolute_colorimetric"


class FontDownload(Enum):
    """Font-download mode for the Graphics tab (PRINT.md §Phase 4).
    PostScript-era concept; stored for on-disk shape stability but
    not applied by the PDF emitter."""
    NONE = "none"
    SUBSET = "subset"
    COMPLETE = "complete"


class PostScriptLevel(Enum):
    """PostScript output level (PRINT.md §Phase 4). Stored but not
    applied — we emit PDF, not PostScript."""
    LEVEL_2 = "level_2"
    LEVEL_3 = "level_3"


class DataFormat(Enum):
    """Stream encoding for PostScript output (PRINT.md §Phase 4).
    Stored but not applied — we emit PDF."""
    ASCII = "ascii"
    BINARY = "binary"


class DotShape(Enum):
    """Halftone dot shape for an ``InkOverride`` row (PRINT.md
    §Phase 3). Phase 3 stores the choice; halftone screen rendering
    itself is a Phase 7+ deferral."""
    ROUND = "round"
    SQUARE = "square"
    ELLIPSE = "ellipse"
    DIAMOND = "diamond"
    LINE = "line"
    CROSS = "cross"
    EUCLIDEAN = "euclidean"


def _enum_from_string(enum_class, s: str, default):
    """Look up an enum value by its string form; return `default` on miss."""
    for v in enum_class:
        if v.value == s:
            return v
    return default


@dataclass(frozen=True)
class Advanced:
    """Advanced sub-record on PrintPreferences (PRINT.md §Phase 6).
    Phase 6 v1 stores the values; rendering effects deferred."""
    print_as_bitmap: bool = False
    overprint_flattener_preset: FlattenerPreset = FlattenerPreset.MEDIUM_RESOLUTION


DEFAULT_ADVANCED = Advanced()


@dataclass(frozen=True)
class ColorManagement:
    """Color Management sub-record on PrintPreferences (PRINT.md
    §Phase 5). ``rendering_intent`` is applied by the PDF emitter
    via the ``ri`` operator; ICC profile embedding
    (``document_profile`` / ``printer_profile``) is deferred."""
    document_profile: str = "sRGB IEC61966-2.1"
    color_handling: ColorHandling = ColorHandling.LET_APP_DETERMINE
    printer_profile: str = ""
    rendering_intent: RenderingIntent = RenderingIntent.RELATIVE_COLORIMETRIC
    preserve_rgb_numbers: bool = False


DEFAULT_COLOR_MANAGEMENT = ColorManagement()


@dataclass(frozen=True)
class Graphics:
    """Graphics sub-record on PrintPreferences (PRINT.md §Phase 4).
    ``flatness`` is consulted by the PDF emitter as a path-flattening
    tolerance; the others are stored for cross-app round-trip but
    not applied (PostScript-specific)."""
    flatness: float = 1.0
    font_download: FontDownload = FontDownload.SUBSET
    postscript_level: PostScriptLevel = PostScriptLevel.LEVEL_3
    data_format: DataFormat = DataFormat.BINARY
    compatible_gradient_printing: bool = False
    raster_effects_resolution: float = 300.0


DEFAULT_GRAPHICS = Graphics()


@dataclass(frozen=True)
class InkOverride:
    """One row in the per-ink overrides table (PRINT.md §Phase 3)."""
    name: str
    print: bool = True
    frequency: float = 75.0
    angle: float = 45.0
    dot_shape: DotShape = DotShape.ROUND


def _process_cmyk_default_inks() -> tuple[InkOverride, ...]:
    """The default ink list shipped with a fresh Output: the four CMYK
    process inks at standard Western screen angles."""
    return (
        InkOverride(name="Process Cyan",    frequency=75.0, angle=105.0),
        InkOverride(name="Process Magenta", frequency=75.0, angle=75.0),
        InkOverride(name="Process Yellow",  frequency=75.0, angle=90.0),
        InkOverride(name="Process Black",   frequency=75.0, angle=45.0),
    )


@dataclass(frozen=True)
class Output:
    """Output sub-record on PrintPreferences (PRINT.md §Phase 3). The
    Output tab edits these 1:1; in Separations mode the PDF emitter
    produces one page per enabled InkOverride instead of one page
    per artboard."""
    mode: OutputMode = OutputMode.COMPOSITE
    emulsion: Emulsion = Emulsion.UP_RIGHT
    image_polarity: ImagePolarity = ImagePolarity.POSITIVE
    printer_resolution: str = "75 lpi / 600 dpi"
    convert_spot_to_process: bool = False
    overprint_black: bool = False
    inks: tuple[InkOverride, ...] = ()

    def __post_init__(self):
        # frozen dataclass: use object.__setattr__ to seed the default
        # ink list (mutable defaults aren't allowed on dataclass fields,
        # and the empty-tuple sentinel keeps the field's default
        # comparable / hashable).
        if not self.inks:
            object.__setattr__(self, "inks", _process_cmyk_default_inks())


DEFAULT_OUTPUT = Output()


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
    # Output sub-record (PRINT.md §Phase 3).
    output: Output = DEFAULT_OUTPUT
    # Graphics sub-record (PRINT.md §Phase 4).
    graphics: Graphics = DEFAULT_GRAPHICS
    # Color Management sub-record (PRINT.md §Phase 5).
    color_management: ColorManagement = DEFAULT_COLOR_MANAGEMENT
    # Advanced sub-record (PRINT.md §Phase 6).
    advanced: Advanced = DEFAULT_ADVANCED


DEFAULT_PRINT_PREFERENCES = PrintPreferences()


@dataclass(frozen=True)
class PrintPreset:
    """Workspace-level named saved configuration. Phase 1 ships only
    the built-in `[Default]`; save / load / delete is deferred."""
    name: str
    preferences: PrintPreferences


DEFAULT_PRESET = PrintPreset(name="[Default]", preferences=DEFAULT_PRINT_PREFERENCES)
