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
    }
}
