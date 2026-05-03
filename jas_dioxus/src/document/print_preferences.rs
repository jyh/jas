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
    }

    #[test]
    fn unknown_enum_strings_fall_back_to_default() {
        assert_eq!(artboard_range_mode_from("garbage"), ArtboardRangeMode::All);
        assert_eq!(media_size_from("garbage"), MediaSize::DefinedByDriver);
        assert_eq!(orientation_from("garbage"), Orientation::Portrait);
        assert_eq!(print_layers_from("garbage"), PrintLayers::VisiblePrintable);
        assert_eq!(scaling_mode_from("garbage"), ScalingMode::DoNotScale);
    }
}
