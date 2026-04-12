//! Theme constants and fill/stroke display helpers.

use crate::geometry::element::Color;

/// Brand logo SVG (color-baked, for use in menu bar, dialogs, and empty-state canvas).
pub(crate) const BRAND_LOGO_SVG: &str = include_str!("../../../assets/brand/logo-baked.svg");
/// Brand color (brass gold).
pub(crate) const BRAND_COLOR: &str = "#C9900A";

/// Eyedropper SVG icon for the color picker.
pub(crate) const EYEDROPPER_SVG: &str = r##"<svg width="16" height="16" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg"><path d="M13.354 2.646a2.121 2.121 0 0 0-3 0l-1.5 1.5-.708-.708a.5.5 0 0 0-.707.708l.353.353-5.146 5.146A1.5 1.5 0 0 0 2.2 10.5L1.5 14a.5.5 0 0 0 .6.6l3.5-.7a1.5 1.5 0 0 0 .854-.44l5.146-5.146.354.354a.5.5 0 0 0 .707-.708l-.707-.707 1.5-1.5a2.121 2.121 0 0 0 0-3.001zM5.39 12.4a.5.5 0 0 1-.285.147L2.65 13.05l.504-2.454a.5.5 0 0 1 .147-.285L8.5 5.111l1.389 1.389z" fill="#ccc"/></svg>"##;

/// What to show in a fill or stroke square.
pub(crate) enum FsDisplay {
    Color(Color),
    None,
    Mixed,
}

/// CSS background string for a fill/stroke display state.
pub(crate) fn fs_display_bg(d: &FsDisplay) -> String {
    match d {
        FsDisplay::Color(c) => {
            let (r, g, b, _) = c.to_rgba();
            format!("rgb({},{},{})", (r * 255.0).round() as u8, (g * 255.0).round() as u8, (b * 255.0).round() as u8)
        }
        FsDisplay::None => "linear-gradient(to bottom right, #fff 45%, transparent 45%, transparent 50%, #f00 50%, #f00 55%, transparent 55%, transparent 100%, #fff 100%)".into(),
        FsDisplay::Mixed => "#888".into(),
    }
}

/// Label to show inside the square, if any.
pub(crate) fn fs_display_label(d: &FsDisplay) -> Option<&'static str> {
    match d {
        FsDisplay::Mixed => Some("?"),
        _ => Option::None,
    }
}

// ---------------------------------------------------------------------------
// Theme colors — CSS variable references for dynamic appearance switching.
// Each constant maps to a --jas-* CSS custom property with a fallback value
// matching the Dark Gray appearance (the default).
// ---------------------------------------------------------------------------

pub(crate) const THEME_BG: &str = "var(--jas-pane-bg,#3c3c3c)";
pub(crate) const THEME_BG_DARK: &str = "var(--jas-pane-bg-dark,#333)";
pub(crate) const THEME_BG_ACTIVE: &str = "var(--jas-button-checked,#505050)";
pub(crate) const THEME_BG_TAB: &str = "var(--jas-tab-active,#4a4a4a)";
pub(crate) const THEME_BG_TAB_INACTIVE: &str = "var(--jas-tab-inactive,#353535)";
pub(crate) const THEME_BG_TOOLBAR_BTN: &str = "var(--jas-button-checked,#505050)";
pub(crate) const THEME_BORDER: &str = "var(--jas-border,#555)";
pub(crate) const THEME_TEXT: &str = "var(--jas-text,#ccc)";
pub(crate) const THEME_TEXT_DIM: &str = "var(--jas-text-dim,#999)";
pub(crate) const THEME_TEXT_BODY: &str = "var(--jas-text-body,#aaa)";
pub(crate) const THEME_TEXT_HINT: &str = "var(--jas-text-hint,#777)";
pub(crate) const THEME_TEXT_BUTTON: &str = "var(--jas-text-button,#888)";
pub(crate) const THEME_ACCENT: &str = "var(--jas-accent,#4a90d9)";

// Additional CSS variable constants for elements not previously in theme.rs.
pub(crate) const THEME_WINDOW_BG: &str = "var(--jas-window-bg,#2e2e2e)";
pub(crate) const THEME_TITLE_BAR_BG: &str = "var(--jas-title-bar-bg,#2a2a2a)";
pub(crate) const THEME_TITLE_BAR_TEXT: &str = "var(--jas-title-bar-text,#d9d9d9)";
pub(crate) const THEME_PANE_SHADOW: &str = "var(--jas-pane-shadow,rgba(0,0,0,0.3))";
