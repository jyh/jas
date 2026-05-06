//! Per-document settings edited from the Document Setup dialog
//! (PRINT.md §Phase 1A). Bleed values are in points and represent the
//! amount of artwork that extends past each artboard edge for trim
//! tolerance during commercial printing.

#[derive(Debug, Clone, PartialEq)]
pub struct DocumentSetup {
    pub bleed_top: f64,
    pub bleed_right: f64,
    pub bleed_bottom: f64,
    pub bleed_left: f64,
    /// Chain-link state for the bleed inputs in the dialog. When true,
    /// editing any one side propagates to all four. Persisted because
    /// the user expects the chain to stay where they left it across
    /// sessions.
    pub bleed_uniform: bool,
    /// Render image elements as their bounding outline rather than
    /// rasterized content (canvas display only; export ignores this).
    pub show_images_outline: bool,
    /// Tint glyphs that were rendered with a substituted font so the
    /// user can spot missing-font cases.
    pub highlight_substituted_glyphs: bool,
    // ── Phase 6 additions (deferred Phase 1A items) ─────────────
    /// Spacing between major canvas grid lines, in points. Default
    /// 72 = one inch. Stored on disk; the canvas grid renderer
    /// picks up the value when grid display is on.
    pub grid_size: f64,
    /// Hex color for the canvas grid lines (e.g. "#cccccc"). Stored
    /// as a string so SVG round-trip is lossless.
    pub grid_color: String,
    /// Hex color for the simulated paper background. Used by the
    /// canvas when ``simulate_colored_paper`` is on; PDF export
    /// ignores it (the paper is the page itself).
    pub paper_color: String,
    /// When true, the canvas paints the artboard background using
    /// ``paper_color`` so designers working over coloured paper
    /// stocks can preview the appearance.
    pub simulate_colored_paper: bool,
    /// Phase 6: transparency flattener preset for export. Stored
    /// only — the actual flattener pipeline is deferred (would
    /// need a substantial rasterize-then-vectorize pass).
    pub transparency_flattener_preset:
        crate::document::print_preferences::FlattenerPreset,
    /// When true, the PDF emitter discards 100%-white overprint
    /// colors per Adobe convention (eliminates accidental knockout
    /// from white text on a black background being marked
    /// overprint). Stored only in v1.
    pub discard_white_overprint: bool,
}

impl Default for DocumentSetup {
    fn default() -> Self {
        Self {
            bleed_top: 0.0,
            bleed_right: 0.0,
            bleed_bottom: 0.0,
            bleed_left: 0.0,
            bleed_uniform: true,
            show_images_outline: false,
            highlight_substituted_glyphs: false,
            grid_size: 72.0,
            grid_color: "#cccccc".to_string(),
            paper_color: "#ffffff".to_string(),
            simulate_colored_paper: false,
            transparency_flattener_preset:
                crate::document::print_preferences::FlattenerPreset::MediumResolution,
            discard_white_overprint: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn document_setup_defaults() {
        let s = DocumentSetup::default();
        assert_eq!(s.bleed_top, 0.0);
        assert_eq!(s.bleed_right, 0.0);
        assert_eq!(s.bleed_bottom, 0.0);
        assert_eq!(s.bleed_left, 0.0);
        assert!(s.bleed_uniform);
        assert!(!s.show_images_outline);
        assert!(!s.highlight_substituted_glyphs);
        // Phase 6 additions.
        assert_eq!(s.grid_size, 72.0);
        assert_eq!(s.grid_color, "#cccccc");
        assert_eq!(s.paper_color, "#ffffff");
        assert!(!s.simulate_colored_paper);
        assert_eq!(s.transparency_flattener_preset,
                   crate::document::print_preferences::FlattenerPreset::MediumResolution);
        assert!(!s.discard_white_overprint);
    }
}
