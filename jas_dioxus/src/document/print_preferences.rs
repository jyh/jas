//! Per-document Print dialog state (PRINT.md §Phase 1B). Remembers
//! the last-used choices in the General tab so reopening Print
//! restores them. Later phases extend with sub-records for marks,
//! output, graphics, color management, advanced.
//!
//! `PrintPreset` is the workspace-level named saved configuration of
//! the same fields. Phase 1 ships exactly one built-in `[Default]`;
//! save / load / delete is deferred (PRINT.md §Phase 7+).

#[derive(Debug, Clone, PartialEq)]
pub enum ArtboardRangeMode {
    All,
    Range,
}

#[derive(Debug, Clone, PartialEq)]
pub enum MediaSize {
    DefinedByDriver,
    Letter,
    Legal,
    Tabloid,
    A3,
    A4,
    A5,
    Custom,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Orientation {
    Portrait,
    Landscape,
}

#[derive(Debug, Clone, PartialEq)]
pub enum PrintLayers {
    /// Visible & Printable: honor both Layer.visibility != Invisible
    /// AND Layer.print = true.
    VisiblePrintable,
    /// Visible Layers: honor only Layer.visibility != Invisible.
    Visible,
    /// All Layers: ignore both flags.
    All,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ScalingMode {
    DoNotScale,
    FitToPage,
    Custom,
}

/// Two cultural variants of printer's marks. ``Roman`` ships the
/// standard Western trim/registration marks; ``Japanese`` swaps in
/// the kasen-style marks used by Japanese commercial print shops.
/// Phase 2 stores the choice but the renderer only differentiates in
/// a follow-up — the on-disk shape is stable now.
#[derive(Debug, Clone, PartialEq)]
pub enum PrinterMarkType {
    Roman,
    Japanese,
}

/// Output mode (PRINT.md §Phase 3): Composite renders the document
/// as a single PDF page per artboard (Phase 1B behavior); Separations
/// renders one PDF page per enabled ink in [`Output::inks`].
#[derive(Debug, Clone, PartialEq)]
pub enum OutputMode {
    Composite,
    Separations,
}

/// Film emulsion side (PRINT.md §Phase 3). Names mirror Adobe's
/// "Emulsion Up" / "Emulsion Down" — film output convention; for
/// PDF output this currently has no rendering effect, but the
/// on-disk shape is stable.
#[derive(Debug, Clone, PartialEq)]
pub enum Emulsion {
    UpRight,
    DownRight,
}

/// PDF page polarity (PRINT.md §Phase 3). Negative inverts the final
/// rasterized output; for PDF this is recorded but not applied.
#[derive(Debug, Clone, PartialEq)]
pub enum ImagePolarity {
    Positive,
    Negative,
}

/// Halftone dot shape for an InkOverride row (PRINT.md §Phase 3).
/// Phase 3 stores the choice; halftone screen rendering itself is a
/// Phase 7+ deferral.
#[derive(Debug, Clone, PartialEq)]
pub enum DotShape {
    Round,
    Square,
    Ellipse,
    Diamond,
    Line,
    Cross,
    Euclidean,
}

/// One row in the per-ink overrides table (PRINT.md §Phase 3 Output).
/// The default ink list is the four CMYK process inks at standard
/// Western screen angles (45 / 75 / 90 / 105 degrees).
#[derive(Debug, Clone, PartialEq)]
pub struct InkOverride {
    pub name: String,
    pub print: bool,
    pub frequency: f64,
    pub angle: f64,
    pub dot_shape: DotShape,
}

impl InkOverride {
    pub fn process_cmyk_defaults() -> Vec<InkOverride> {
        vec![
            InkOverride { name: "Process Cyan".into(),    print: true, frequency: 75.0, angle: 105.0, dot_shape: DotShape::Round },
            InkOverride { name: "Process Magenta".into(), print: true, frequency: 75.0, angle:  75.0, dot_shape: DotShape::Round },
            InkOverride { name: "Process Yellow".into(),  print: true, frequency: 75.0, angle:  90.0, dot_shape: DotShape::Round },
            InkOverride { name: "Process Black".into(),   print: true, frequency: 75.0, angle:  45.0, dot_shape: DotShape::Round },
        ]
    }
}

/// Output sub-record on PrintPreferences (PRINT.md §Phase 3). The
/// Output tab exposes these 1:1 as widgets; in Separations mode the
/// PDF emitter produces one page per enabled [`InkOverride`] in
/// [`inks`] instead of one page per artboard.
#[derive(Debug, Clone, PartialEq)]
pub struct Output {
    pub mode: OutputMode,
    pub emulsion: Emulsion,
    pub image_polarity: ImagePolarity,
    pub printer_resolution: String,
    pub convert_spot_to_process: bool,
    pub overprint_black: bool,
    pub inks: Vec<InkOverride>,
}

impl Default for Output {
    fn default() -> Self {
        Self {
            mode: OutputMode::Composite,
            emulsion: Emulsion::UpRight,
            image_polarity: ImagePolarity::Positive,
            printer_resolution: "75 lpi / 600 dpi".to_string(),
            convert_spot_to_process: false,
            overprint_black: false,
            inks: InkOverride::process_cmyk_defaults(),
        }
    }
}

/// Font-download mode for the Graphics tab (PRINT.md §Phase 4).
/// PostScript-era concept; stored for on-disk shape stability but
/// not applied by the PDF emitter (we always embed-by-subset).
#[derive(Debug, Clone, PartialEq)]
pub enum FontDownload {
    None,
    Subset,
    Complete,
}

/// PostScript output level (PRINT.md §Phase 4). Stored but not
/// applied — we emit PDF, not PostScript.
#[derive(Debug, Clone, PartialEq)]
pub enum PostScriptLevel {
    Level2,
    Level3,
}

/// Stream encoding for PostScript output (PRINT.md §Phase 4).
/// Stored but not applied — we emit PDF.
#[derive(Debug, Clone, PartialEq)]
pub enum DataFormat {
    Ascii,
    Binary,
}

/// Graphics sub-record on PrintPreferences (PRINT.md §Phase 4). The
/// Graphics tab edits these 1:1; ``flatness`` is consulted by the
/// PDF emitter as a path-flattening tolerance, the others are stored
/// for stable on-disk shape but not applied (PostScript-specific).
#[derive(Debug, Clone, PartialEq)]
pub struct Graphics {
    /// Path-flattening tolerance in device units; range Quality (0.2)
    /// ↔ Speed (10.0). Smaller values = smoother curves at higher
    /// emit cost; larger values = coarser approximation, faster.
    pub flatness: f64,
    pub font_download: FontDownload,
    pub postscript_level: PostScriptLevel,
    pub data_format: DataFormat,
    pub compatible_gradient_printing: bool,
    pub raster_effects_resolution: f64,
}

impl Default for Graphics {
    fn default() -> Self {
        Self {
            flatness: 1.0,
            font_download: FontDownload::Subset,
            postscript_level: PostScriptLevel::Level3,
            data_format: DataFormat::Binary,
            compatible_gradient_printing: false,
            raster_effects_resolution: 300.0,
        }
    }
}

/// Color-handling mode for the Color Management tab (PRINT.md §Phase 5).
/// Three Adobe-standard choices: let the app, let the printer, or
/// hand the data straight to the PostScript driver. PDF output
/// honours the choice for ``RenderingIntent`` only — full ICC profile
/// management is a Phase 5+ deferral.
#[derive(Debug, Clone, PartialEq)]
pub enum ColorHandling {
    LetAppDetermine,
    LetPrinterDetermine,
    PostscriptColorManagement,
}

/// PDF rendering intent (PRINT.md §Phase 5). Names match the four
/// PDF 1.7 §11.6.5.8 intents one-for-one. Stored case-insensitively
/// on disk via snake_case wire forms; the PDF emitter writes the
/// intent string into a ``ri`` operator.
#[derive(Debug, Clone, PartialEq)]
pub enum RenderingIntent {
    Perceptual,
    RelativeColorimetric,
    Saturation,
    AbsoluteColorimetric,
}

/// Color Management sub-record on PrintPreferences (PRINT.md §Phase 5).
/// The Color Management tab edits these 1:1; the PDF emitter applies
/// ``rendering_intent`` via the PDF ``ri`` operator. ICC profile
/// embedding (document_profile / printer_profile) is deferred —
/// Phase 5 stores the names so the on-disk shape is stable.
#[derive(Debug, Clone, PartialEq)]
pub struct ColorManagement {
    pub document_profile: String,
    pub color_handling: ColorHandling,
    pub printer_profile: String,
    pub rendering_intent: RenderingIntent,
    pub preserve_rgb_numbers: bool,
}

impl Default for ColorManagement {
    fn default() -> Self {
        Self {
            document_profile: "sRGB IEC61966-2.1".to_string(),
            color_handling: ColorHandling::LetAppDetermine,
            printer_profile: String::new(),
            rendering_intent: RenderingIntent::RelativeColorimetric,
            preserve_rgb_numbers: false,
        }
    }
}

/// Marks-and-bleed sub-record on PrintPreferences (PRINT.md §Phase 2).
/// The Marks tab exposes these 1:1 as widgets; the PDF renderer
/// extends each page by the active bleed and overlays mark geometry
/// around the trim rect.
///
/// ``use_document_bleed`` controls whether bleeds come from the
/// document-level ``DocumentSetup`` or from the per-print
/// ``bleed_*`` overrides on this struct. Defaulting to true keeps
/// document and print in lockstep until the user opts out.
#[derive(Debug, Clone, PartialEq)]
pub struct MarksAndBleed {
    pub all_printer_marks: bool,
    pub trim_marks: bool,
    pub registration_marks: bool,
    pub color_bars: bool,
    pub page_information: bool,
    pub printer_mark_type: PrinterMarkType,
    pub trim_mark_weight: f64,
    pub mark_offset: f64,
    pub use_document_bleed: bool,
    pub bleed_top: f64,
    pub bleed_right: f64,
    pub bleed_bottom: f64,
    pub bleed_left: f64,
}

impl Default for MarksAndBleed {
    fn default() -> Self {
        Self {
            all_printer_marks: false,
            trim_marks: false,
            registration_marks: false,
            color_bars: false,
            page_information: false,
            printer_mark_type: PrinterMarkType::Roman,
            trim_mark_weight: 0.25,
            mark_offset: 6.0,
            use_document_bleed: true,
            bleed_top: 0.0,
            bleed_right: 0.0,
            bleed_bottom: 0.0,
            bleed_left: 0.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PrintPreferences {
    pub preset_name: String,
    pub printer_name: Option<String>,
    pub copies: u32,
    pub collate: bool,
    pub reverse_order: bool,
    pub artboard_range_mode: ArtboardRangeMode,
    pub artboard_range: String,
    pub ignore_artboards: bool,
    pub skip_blank_artboards: bool,
    pub media_size: MediaSize,
    pub media_width: f64,
    pub media_height: f64,
    pub orientation: Orientation,
    pub auto_rotate: bool,
    pub transverse: bool,
    pub print_layers: PrintLayers,
    pub placement_x: f64,
    pub placement_y: f64,
    pub scaling_mode: ScalingMode,
    pub custom_scale: f64,
    /// Reserved for Phase 7 tiling. Stored now so the on-disk shape
    /// is stable across phases.
    pub tile_overlap_h: f64,
    pub tile_overlap_v: f64,
    pub tile_range: String,
    /// Marks-and-bleed sub-record (PRINT.md §Phase 2).
    pub marks_and_bleed: MarksAndBleed,
    /// Output sub-record (PRINT.md §Phase 3).
    pub output: Output,
    /// Graphics sub-record (PRINT.md §Phase 4).
    pub graphics: Graphics,
    /// Color Management sub-record (PRINT.md §Phase 5).
    pub color_management: ColorManagement,
}

impl Default for PrintPreferences {
    fn default() -> Self {
        Self {
            preset_name: "[Default]".to_string(),
            printer_name: None,
            copies: 1,
            collate: false,
            reverse_order: false,
            artboard_range_mode: ArtboardRangeMode::All,
            artboard_range: String::new(),
            ignore_artboards: false,
            skip_blank_artboards: false,
            media_size: MediaSize::DefinedByDriver,
            media_width: 612.0,
            media_height: 792.0,
            orientation: Orientation::Portrait,
            auto_rotate: true,
            transverse: false,
            print_layers: PrintLayers::VisiblePrintable,
            placement_x: 0.0,
            placement_y: 0.0,
            scaling_mode: ScalingMode::DoNotScale,
            custom_scale: 100.0,
            tile_overlap_h: 0.0,
            tile_overlap_v: 0.0,
            tile_range: String::new(),
            marks_and_bleed: MarksAndBleed::default(),
            output: Output::default(),
            graphics: Graphics::default(),
            color_management: ColorManagement::default(),
        }
    }
}

/// Workspace-level named saved configuration. Phase 1 ships only the
/// built-in `[Default]`; save / load / delete is deferred (PRINT.md
/// §Phase 7+).
#[derive(Debug, Clone, PartialEq)]
pub struct PrintPreset {
    pub name: String,
    pub preferences: PrintPreferences,
}

impl PrintPreset {
    /// The single built-in preset. Name is bracketed so user presets
    /// can never collide with it.
    pub fn default_preset() -> Self {
        Self {
            name: "[Default]".to_string(),
            preferences: PrintPreferences::default(),
        }
    }
}

// ── Stable string forms for the Test JSON codec ────────────────
//
// Keep these snake_case for cross-language byte parity. The variant
// → string mapping is part of the wire format; renaming a variant is
// fine but the string form must stay.

pub fn artboard_range_mode_str(m: &ArtboardRangeMode) -> &'static str {
    match m {
        ArtboardRangeMode::All => "all",
        ArtboardRangeMode::Range => "range",
    }
}
pub fn artboard_range_mode_from(s: &str) -> ArtboardRangeMode {
    match s {
        "range" => ArtboardRangeMode::Range,
        _ => ArtboardRangeMode::All,
    }
}

pub fn media_size_str(m: &MediaSize) -> &'static str {
    match m {
        MediaSize::DefinedByDriver => "defined_by_driver",
        MediaSize::Letter => "letter",
        MediaSize::Legal => "legal",
        MediaSize::Tabloid => "tabloid",
        MediaSize::A3 => "a3",
        MediaSize::A4 => "a4",
        MediaSize::A5 => "a5",
        MediaSize::Custom => "custom",
    }
}
pub fn media_size_from(s: &str) -> MediaSize {
    match s {
        "letter" => MediaSize::Letter,
        "legal" => MediaSize::Legal,
        "tabloid" => MediaSize::Tabloid,
        "a3" => MediaSize::A3,
        "a4" => MediaSize::A4,
        "a5" => MediaSize::A5,
        "custom" => MediaSize::Custom,
        _ => MediaSize::DefinedByDriver,
    }
}

pub fn orientation_str(o: &Orientation) -> &'static str {
    match o {
        Orientation::Portrait => "portrait",
        Orientation::Landscape => "landscape",
    }
}
pub fn orientation_from(s: &str) -> Orientation {
    match s {
        "landscape" => Orientation::Landscape,
        _ => Orientation::Portrait,
    }
}

pub fn print_layers_str(p: &PrintLayers) -> &'static str {
    match p {
        PrintLayers::VisiblePrintable => "visible_printable",
        PrintLayers::Visible => "visible",
        PrintLayers::All => "all",
    }
}
pub fn print_layers_from(s: &str) -> PrintLayers {
    match s {
        "visible" => PrintLayers::Visible,
        "all" => PrintLayers::All,
        _ => PrintLayers::VisiblePrintable,
    }
}

pub fn scaling_mode_str(m: &ScalingMode) -> &'static str {
    match m {
        ScalingMode::DoNotScale => "do_not_scale",
        ScalingMode::FitToPage => "fit_to_page",
        ScalingMode::Custom => "custom",
    }
}
pub fn scaling_mode_from(s: &str) -> ScalingMode {
    match s {
        "fit_to_page" => ScalingMode::FitToPage,
        "custom" => ScalingMode::Custom,
        _ => ScalingMode::DoNotScale,
    }
}

pub fn printer_mark_type_str(t: &PrinterMarkType) -> &'static str {
    match t {
        PrinterMarkType::Roman => "roman",
        PrinterMarkType::Japanese => "japanese",
    }
}
pub fn printer_mark_type_from(s: &str) -> PrinterMarkType {
    match s {
        "japanese" => PrinterMarkType::Japanese,
        _ => PrinterMarkType::Roman,
    }
}

pub fn output_mode_str(m: &OutputMode) -> &'static str {
    match m {
        OutputMode::Composite => "composite",
        OutputMode::Separations => "separations",
    }
}
pub fn output_mode_from(s: &str) -> OutputMode {
    match s {
        "separations" => OutputMode::Separations,
        _ => OutputMode::Composite,
    }
}

pub fn emulsion_str(e: &Emulsion) -> &'static str {
    match e {
        Emulsion::UpRight => "up_right",
        Emulsion::DownRight => "down_right",
    }
}
pub fn emulsion_from(s: &str) -> Emulsion {
    match s {
        "down_right" => Emulsion::DownRight,
        _ => Emulsion::UpRight,
    }
}

pub fn image_polarity_str(p: &ImagePolarity) -> &'static str {
    match p {
        ImagePolarity::Positive => "positive",
        ImagePolarity::Negative => "negative",
    }
}
pub fn image_polarity_from(s: &str) -> ImagePolarity {
    match s {
        "negative" => ImagePolarity::Negative,
        _ => ImagePolarity::Positive,
    }
}

pub fn color_handling_str(c: &ColorHandling) -> &'static str {
    match c {
        ColorHandling::LetAppDetermine => "let_app_determine",
        ColorHandling::LetPrinterDetermine => "let_printer_determine",
        ColorHandling::PostscriptColorManagement => "postscript_color_management",
    }
}
pub fn color_handling_from(s: &str) -> ColorHandling {
    match s {
        "let_printer_determine" => ColorHandling::LetPrinterDetermine,
        "postscript_color_management" => ColorHandling::PostscriptColorManagement,
        _ => ColorHandling::LetAppDetermine,
    }
}

pub fn rendering_intent_str(r: &RenderingIntent) -> &'static str {
    match r {
        RenderingIntent::Perceptual => "perceptual",
        RenderingIntent::RelativeColorimetric => "relative_colorimetric",
        RenderingIntent::Saturation => "saturation",
        RenderingIntent::AbsoluteColorimetric => "absolute_colorimetric",
    }
}
pub fn rendering_intent_from(s: &str) -> RenderingIntent {
    match s {
        "perceptual" => RenderingIntent::Perceptual,
        "saturation" => RenderingIntent::Saturation,
        "absolute_colorimetric" => RenderingIntent::AbsoluteColorimetric,
        _ => RenderingIntent::RelativeColorimetric,
    }
}

pub fn font_download_str(f: &FontDownload) -> &'static str {
    match f {
        FontDownload::None => "none",
        FontDownload::Subset => "subset",
        FontDownload::Complete => "complete",
    }
}
pub fn font_download_from(s: &str) -> FontDownload {
    match s {
        "none" => FontDownload::None,
        "complete" => FontDownload::Complete,
        _ => FontDownload::Subset,
    }
}

pub fn postscript_level_str(p: &PostScriptLevel) -> &'static str {
    match p {
        PostScriptLevel::Level2 => "level_2",
        PostScriptLevel::Level3 => "level_3",
    }
}
pub fn postscript_level_from(s: &str) -> PostScriptLevel {
    match s {
        "level_2" => PostScriptLevel::Level2,
        _ => PostScriptLevel::Level3,
    }
}

pub fn data_format_str(d: &DataFormat) -> &'static str {
    match d {
        DataFormat::Ascii => "ascii",
        DataFormat::Binary => "binary",
    }
}
pub fn data_format_from(s: &str) -> DataFormat {
    match s {
        "ascii" => DataFormat::Ascii,
        _ => DataFormat::Binary,
    }
}

pub fn dot_shape_str(d: &DotShape) -> &'static str {
    match d {
        DotShape::Round => "round",
        DotShape::Square => "square",
        DotShape::Ellipse => "ellipse",
        DotShape::Diamond => "diamond",
        DotShape::Line => "line",
        DotShape::Cross => "cross",
        DotShape::Euclidean => "euclidean",
    }
}
pub fn dot_shape_from(s: &str) -> DotShape {
    match s {
        "square" => DotShape::Square,
        "ellipse" => DotShape::Ellipse,
        "diamond" => DotShape::Diamond,
        "line" => DotShape::Line,
        "cross" => DotShape::Cross,
        "euclidean" => DotShape::Euclidean,
        _ => DotShape::Round,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn print_preferences_defaults_match_spec() {
        let p = PrintPreferences::default();
        assert_eq!(p.preset_name, "[Default]");
        assert_eq!(p.printer_name, None);
        assert_eq!(p.copies, 1);
        assert!(!p.collate);
        assert!(!p.reverse_order);
        assert_eq!(p.artboard_range_mode, ArtboardRangeMode::All);
        assert_eq!(p.artboard_range, "");
        assert!(!p.ignore_artboards);
        assert!(!p.skip_blank_artboards);
        assert_eq!(p.media_size, MediaSize::DefinedByDriver);
        assert_eq!(p.media_width, 612.0);
        assert_eq!(p.media_height, 792.0);
        assert_eq!(p.orientation, Orientation::Portrait);
        assert!(p.auto_rotate);
        assert!(!p.transverse);
        assert_eq!(p.print_layers, PrintLayers::VisiblePrintable);
        assert_eq!(p.placement_x, 0.0);
        assert_eq!(p.placement_y, 0.0);
        assert_eq!(p.scaling_mode, ScalingMode::DoNotScale);
        assert_eq!(p.custom_scale, 100.0);
        assert_eq!(p.tile_overlap_h, 0.0);
        assert_eq!(p.tile_overlap_v, 0.0);
        assert_eq!(p.tile_range, "");
        assert_eq!(p.marks_and_bleed, MarksAndBleed::default());
        assert_eq!(p.output, Output::default());
        assert_eq!(p.graphics, Graphics::default());
        assert_eq!(p.color_management, ColorManagement::default());
    }

    #[test]
    fn color_management_defaults_match_spec() {
        let c = ColorManagement::default();
        assert_eq!(c.document_profile, "sRGB IEC61966-2.1");
        assert_eq!(c.color_handling, ColorHandling::LetAppDetermine);
        assert_eq!(c.printer_profile, "");
        assert_eq!(c.rendering_intent, RenderingIntent::RelativeColorimetric);
        assert!(!c.preserve_rgb_numbers);
    }

    #[test]
    fn graphics_defaults_match_spec() {
        let g = Graphics::default();
        assert_eq!(g.flatness, 1.0);
        assert_eq!(g.font_download, FontDownload::Subset);
        assert_eq!(g.postscript_level, PostScriptLevel::Level3);
        assert_eq!(g.data_format, DataFormat::Binary);
        assert!(!g.compatible_gradient_printing);
        assert_eq!(g.raster_effects_resolution, 300.0);
    }

    #[test]
    fn output_defaults_match_spec() {
        let o = Output::default();
        assert_eq!(o.mode, OutputMode::Composite);
        assert_eq!(o.emulsion, Emulsion::UpRight);
        assert_eq!(o.image_polarity, ImagePolarity::Positive);
        assert_eq!(o.printer_resolution, "75 lpi / 600 dpi");
        assert!(!o.convert_spot_to_process);
        assert!(!o.overprint_black);
        assert_eq!(o.inks.len(), 4);
        assert_eq!(o.inks[0].name, "Process Cyan");
        assert_eq!(o.inks[0].angle, 105.0);
        assert_eq!(o.inks[1].name, "Process Magenta");
        assert_eq!(o.inks[1].angle, 75.0);
        assert_eq!(o.inks[2].name, "Process Yellow");
        assert_eq!(o.inks[2].angle, 90.0);
        assert_eq!(o.inks[3].name, "Process Black");
        assert_eq!(o.inks[3].angle, 45.0);
        for ink in &o.inks {
            assert!(ink.print);
            assert_eq!(ink.frequency, 75.0);
            assert_eq!(ink.dot_shape, DotShape::Round);
        }
    }

    #[test]
    fn marks_and_bleed_defaults_match_spec() {
        let m = MarksAndBleed::default();
        assert!(!m.all_printer_marks);
        assert!(!m.trim_marks);
        assert!(!m.registration_marks);
        assert!(!m.color_bars);
        assert!(!m.page_information);
        assert_eq!(m.printer_mark_type, PrinterMarkType::Roman);
        assert_eq!(m.trim_mark_weight, 0.25);
        assert_eq!(m.mark_offset, 6.0);
        assert!(m.use_document_bleed);
        assert_eq!(m.bleed_top, 0.0);
        assert_eq!(m.bleed_right, 0.0);
        assert_eq!(m.bleed_bottom, 0.0);
        assert_eq!(m.bleed_left, 0.0);
    }

    #[test]
    fn default_preset_holds_print_preferences_defaults() {
        let p = PrintPreset::default_preset();
        assert_eq!(p.name, "[Default]");
        assert_eq!(p.preferences, PrintPreferences::default());
    }

    #[test]
    fn enum_strings_round_trip() {
        for m in [ArtboardRangeMode::All, ArtboardRangeMode::Range] {
            assert_eq!(artboard_range_mode_from(artboard_range_mode_str(&m)), m);
        }
        for m in [
            MediaSize::DefinedByDriver, MediaSize::Letter, MediaSize::Legal,
            MediaSize::Tabloid, MediaSize::A3, MediaSize::A4, MediaSize::A5,
            MediaSize::Custom,
        ] {
            assert_eq!(media_size_from(media_size_str(&m)), m);
        }
        for o in [Orientation::Portrait, Orientation::Landscape] {
            assert_eq!(orientation_from(orientation_str(&o)), o);
        }
        for p in [PrintLayers::VisiblePrintable, PrintLayers::Visible, PrintLayers::All] {
            assert_eq!(print_layers_from(print_layers_str(&p)), p);
        }
        for m in [ScalingMode::DoNotScale, ScalingMode::FitToPage, ScalingMode::Custom] {
            assert_eq!(scaling_mode_from(scaling_mode_str(&m)), m);
        }
        for t in [PrinterMarkType::Roman, PrinterMarkType::Japanese] {
            assert_eq!(printer_mark_type_from(printer_mark_type_str(&t)), t);
        }
        for m in [OutputMode::Composite, OutputMode::Separations] {
            assert_eq!(output_mode_from(output_mode_str(&m)), m);
        }
        for e in [Emulsion::UpRight, Emulsion::DownRight] {
            assert_eq!(emulsion_from(emulsion_str(&e)), e);
        }
        for p in [ImagePolarity::Positive, ImagePolarity::Negative] {
            assert_eq!(image_polarity_from(image_polarity_str(&p)), p);
        }
        for d in [
            DotShape::Round, DotShape::Square, DotShape::Ellipse,
            DotShape::Diamond, DotShape::Line, DotShape::Cross, DotShape::Euclidean,
        ] {
            assert_eq!(dot_shape_from(dot_shape_str(&d)), d);
        }
        for f in [FontDownload::None, FontDownload::Subset, FontDownload::Complete] {
            assert_eq!(font_download_from(font_download_str(&f)), f);
        }
        for p in [PostScriptLevel::Level2, PostScriptLevel::Level3] {
            assert_eq!(postscript_level_from(postscript_level_str(&p)), p);
        }
        for d in [DataFormat::Ascii, DataFormat::Binary] {
            assert_eq!(data_format_from(data_format_str(&d)), d);
        }
        for c in [
            ColorHandling::LetAppDetermine,
            ColorHandling::LetPrinterDetermine,
            ColorHandling::PostscriptColorManagement,
        ] {
            assert_eq!(color_handling_from(color_handling_str(&c)), c);
        }
        for r in [
            RenderingIntent::Perceptual,
            RenderingIntent::RelativeColorimetric,
            RenderingIntent::Saturation,
            RenderingIntent::AbsoluteColorimetric,
        ] {
            assert_eq!(rendering_intent_from(rendering_intent_str(&r)), r);
        }
    }

    #[test]
    fn unknown_enum_strings_fall_back_to_default() {
        assert_eq!(artboard_range_mode_from("garbage"), ArtboardRangeMode::All);
        assert_eq!(media_size_from("garbage"), MediaSize::DefinedByDriver);
        assert_eq!(orientation_from("garbage"), Orientation::Portrait);
        assert_eq!(print_layers_from("garbage"), PrintLayers::VisiblePrintable);
        assert_eq!(scaling_mode_from("garbage"), ScalingMode::DoNotScale);
        assert_eq!(printer_mark_type_from("garbage"), PrinterMarkType::Roman);
        assert_eq!(output_mode_from("garbage"), OutputMode::Composite);
        assert_eq!(emulsion_from("garbage"), Emulsion::UpRight);
        assert_eq!(image_polarity_from("garbage"), ImagePolarity::Positive);
        assert_eq!(dot_shape_from("garbage"), DotShape::Round);
        assert_eq!(font_download_from("garbage"), FontDownload::Subset);
        assert_eq!(postscript_level_from("garbage"), PostScriptLevel::Level3);
        assert_eq!(data_format_from("garbage"), DataFormat::Binary);
        assert_eq!(color_handling_from("garbage"), ColorHandling::LetAppDetermine);
        assert_eq!(rendering_intent_from("garbage"), RenderingIntent::RelativeColorimetric);
    }
}
