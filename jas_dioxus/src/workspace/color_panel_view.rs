//! Color panel body component.
//!
//! Renders the inline color panel with swatches, fill/stroke widget,
//! mode-specific sliders, hex input, and a 2D color bar gradient.

use dioxus::prelude::*;
use wasm_bindgen::JsCast;

use super::app_state::{Act, AppHandle, AppState};
use super::theme::*;
use crate::geometry::element::Color;

// ---------------------------------------------------------------------------
// Color mode enum
// ---------------------------------------------------------------------------

/// Panel-local color mode.
// Cmyk variant is reserved for the prepress mode toggle and not yet
// reached by any code path that exercises it at runtime.
#[derive(Debug, Clone, Copy, PartialEq)]
#[allow(dead_code)]
pub(crate) enum ColorMode {
    Grayscale,
    Hsb,
    Rgb,
    Cmyk,
    WebSafeRgb,
}

impl ColorMode {
    pub const ALL: &[ColorMode] = &[
        ColorMode::Grayscale,
        ColorMode::Hsb,
        ColorMode::Rgb,
        ColorMode::Cmyk,
        ColorMode::WebSafeRgb,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::Grayscale => "Grayscale",
            Self::Hsb => "HSB",
            Self::Rgb => "RGB",
            Self::Cmyk => "CMYK",
            Self::WebSafeRgb => "Web Safe RGB",
        }
    }

    pub fn command(self) -> &'static str {
        match self {
            Self::Grayscale => "mode_grayscale",
            Self::Hsb => "mode_hsb",
            Self::Rgb => "mode_rgb",
            Self::Cmyk => "mode_cmyk",
            Self::WebSafeRgb => "mode_web_safe_rgb",
        }
    }

    pub fn from_command(cmd: &str) -> Option<Self> {
        match cmd {
            "mode_grayscale" => Some(Self::Grayscale),
            "mode_hsb" => Some(Self::Hsb),
            "mode_rgb" => Some(Self::Rgb),
            "mode_cmyk" => Some(Self::Cmyk),
            "mode_web_safe_rgb" => Some(Self::WebSafeRgb),
            _ => None,
        }
    }
}

// ---------------------------------------------------------------------------
// Panel-local state
// ---------------------------------------------------------------------------

/// Panel-local color state: working values for all color spaces.
#[derive(Debug, Clone)]
pub(crate) struct PanelColorState {
    pub mode: ColorMode,
    pub h: f64,  // 0..360
    pub s: f64,  // 0..100
    pub b: f64,  // 0..100
    pub r: f64,  // 0..255
    pub g: f64,  // 0..255
    pub bl: f64, // 0..255
    pub c: f64,  // 0..100
    pub m: f64,  // 0..100
    pub y: f64,  // 0..100
    pub k: f64,  // 0..100
    pub hex: String, // 6-char hex, no #
}

impl Default for PanelColorState {
    fn default() -> Self {
        Self {
            mode: ColorMode::Hsb,
            h: 0.0, s: 0.0, b: 100.0,
            r: 255.0, g: 255.0, bl: 255.0,
            c: 0.0, m: 0.0, y: 0.0, k: 0.0,
            hex: "ffffff".to_string(),
        }
    }
}

impl PanelColorState {
    /// Sync all working values from a Color.
    pub fn sync_from_color(&mut self, color: Color) {
        let (r, g, b, _) = color.to_rgba();
        self.r = (r * 255.0).round();
        self.g = (g * 255.0).round();
        self.bl = (b * 255.0).round();

        let (h, s, br, _) = color.to_hsba();
        self.h = h.round();
        self.s = (s * 100.0).round();
        self.b = (br * 100.0).round();

        let (c, m, y, k, _) = color.to_cmyka();
        self.c = (c * 100.0).round();
        self.m = (m * 100.0).round();
        self.y = (y * 100.0).round();
        self.k = (k * 100.0).round();

        self.hex = color.to_hex();
    }

    /// Convert current working values to a Color based on active mode.
    pub fn to_color(&self) -> Color {
        match self.mode {
            ColorMode::Hsb => Color::hsb(self.h, self.s / 100.0, self.b / 100.0),
            ColorMode::Rgb | ColorMode::WebSafeRgb => {
                Color::rgb(self.r / 255.0, self.g / 255.0, self.bl / 255.0)
            }
            ColorMode::Cmyk => {
                Color::cmyk(self.c / 100.0, self.m / 100.0, self.y / 100.0, self.k / 100.0)
            }
            ColorMode::Grayscale => {
                let v = 1.0 - self.k / 100.0;
                Color::rgb(v, v, v)
            }
        }
    }
}

fn get_field(ps: &PanelColorState, field: &str) -> f64 {
    match field {
        "h" => ps.h, "s" => ps.s, "b" => ps.b,
        "r" => ps.r, "g" => ps.g, "bl" => ps.bl,
        "c" => ps.c, "m" => ps.m, "y" => ps.y, "k" => ps.k,
        _ => 0.0,
    }
}

fn set_field(ps: &mut PanelColorState, field: &str, val: f64) {
    match field {
        "h" => ps.h = val, "s" => ps.s = val, "b" => ps.b = val,
        "r" => ps.r = val, "g" => ps.g = val, "bl" => ps.bl = val,
        "c" => ps.c = val, "m" => ps.m = val, "y" => ps.y = val, "k" => ps.k = val,
        _ => {}
    }
}

// ---------------------------------------------------------------------------
// DOM helper
// ---------------------------------------------------------------------------

/// Get the rendered width and height of a DOM element by ID.
/// Falls back to (200, 64) if the element is not found.
fn color_bar_element_size(id: &str) -> (f64, f64) {
    if let Some(el) = web_sys::window()
        .and_then(|w| w.document())
        .and_then(|d| d.get_element_by_id(id))
    {
        let w = el.client_width() as f64;
        let h = el.client_height() as f64;
        if w > 0.0 && h > 0.0 {
            return (w, h);
        }
    }
    (200.0, 64.0)
}

// ---------------------------------------------------------------------------
// Color bar image generation
// ---------------------------------------------------------------------------

/// Build a data URI for the color bar as a BMP image.
/// Split y-axis: top half S 0→100%, B 100→80%; bottom half S 100%, B 80→0%.
/// Uses a 120x32 image (browser scales smoothly).
/// Result is cached — the gradient never changes.
pub(crate) fn build_color_bar_data_uri() -> String {
    use std::sync::OnceLock;
    static CACHE: OnceLock<String> = OnceLock::new();
    CACHE.get_or_init(build_color_bar_data_uri_inner).clone()
}

fn build_color_bar_data_uri_inner() -> String {
    const W: usize = 120;
    const H: usize = 32;
    let mid_y = H as f64 / 2.0;

    // BMP: 54-byte header + W*H*3 pixel data (120*3=360, divisible by 4, no padding)
    let pixel_data_size = W * 3 * H;
    let file_size = 54 + pixel_data_size;

    let mut bmp = Vec::with_capacity(file_size);
    // BMP file header (14 bytes)
    bmp.extend_from_slice(b"BM");
    bmp.extend_from_slice(&(file_size as u32).to_le_bytes());
    bmp.extend_from_slice(&[0u8; 4]); // reserved
    bmp.extend_from_slice(&54u32.to_le_bytes()); // pixel data offset
    // DIB header (40 bytes - BITMAPINFOHEADER)
    bmp.extend_from_slice(&40u32.to_le_bytes());
    bmp.extend_from_slice(&(W as i32).to_le_bytes());
    bmp.extend_from_slice(&(H as i32).to_le_bytes());
    bmp.extend_from_slice(&1u16.to_le_bytes()); // color planes
    bmp.extend_from_slice(&24u16.to_le_bytes()); // bits per pixel
    bmp.extend_from_slice(&[0u8; 24]); // compression, sizes, resolution, colors

    // BMP rows are bottom-to-top, so row 0 in the file is the bottom of the image.
    for bmp_row in 0..H {
        let y = (H - 1 - bmp_row) as f64;
        let (sat, br) = if y <= mid_y {
            let t = y / mid_y;
            (t, 1.0 - t * 0.2)
        } else {
            let t = (y - mid_y) / (H as f64 - mid_y);
            (1.0, 0.8 * (1.0 - t))
        };
        for x in 0..W {
            let hue = 360.0 * x as f64 / W as f64;
            let c = Color::hsb(hue, sat, br);
            let (r, g, b, _) = c.to_rgba();
            // BMP pixel order is BGR
            bmp.push((b * 255.0).round() as u8);
            bmp.push((g * 255.0).round() as u8);
            bmp.push((r * 255.0).round() as u8);
        }
    }

    let encoded = simple_base64(&bmp);
    format!("data:image/bmp;base64,{encoded}")
}

/// Minimal base64 encoder (no external dependency).
fn simple_base64(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((triple >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((triple >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[((triple >> 6) & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(TABLE[(triple & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

// ---------------------------------------------------------------------------
// ColorPanelView component
// ---------------------------------------------------------------------------

#[component]
pub(crate) fn ColorPanelView() -> Element {
    let act = use_context::<Act>();
    let app = use_context::<AppHandle>();
    let revision = use_context::<Signal<u64>>();
    let _ = revision();

    let mut panel_state = use_signal(PanelColorState::default);
    let mut last_synced_hex = use_signal(|| String::new());

    // Read app state
    let st = app.borrow();
    let fill_on_top = st.fill_on_top;
    let active_color = st.active_color();
    let active_is_none = active_color.is_none();
    let recent_colors: Vec<String> = st.recent_colors().to_vec();
    let mode = st.color_panel_mode;

    // Fill/stroke display info
    let default_fill = st.tab().and_then(|t| t.model.default_fill);
    let default_stroke = st.tab().and_then(|t| t.model.default_stroke);
    let fill_css = default_fill
        .map(|f| {
            let (r, g, b, _) = f.color.to_rgba();
            format!("rgb({},{},{})", (r*255.0).round() as u8, (g*255.0).round() as u8, (b*255.0).round() as u8)
        })
        .unwrap_or_else(|| "transparent".to_string());
    let stroke_css = default_stroke
        .map(|s| {
            let (r, g, b, _) = s.color.to_rgba();
            format!("rgb({},{},{})", (r*255.0).round() as u8, (g*255.0).round() as u8, (b*255.0).round() as u8)
        })
        .unwrap_or_else(|| "transparent".to_string());
    let fill_is_none = default_fill.is_none();
    let stroke_is_none = default_stroke.is_none();
    drop(st);

    // Sync panel state from active color when it changes externally
    let current_hex = active_color.map(|c| c.to_hex()).unwrap_or_default();
    if current_hex != last_synced_hex() {
        let mut ps = panel_state();
        if let Some(color) = active_color {
            ps.sync_from_color(color);
        }
        ps.mode = mode;
        panel_state.set(ps);
        last_synced_hex.set(current_hex);
    } else {
        // Keep mode in sync
        let ps = panel_state();
        if ps.mode != mode {
            let mut ps = ps;
            ps.mode = mode;
            panel_state.set(ps);
        }
    }

    let ps = panel_state();
    let disabled = active_is_none;

    // "None" icon
    let none_svg = r##"<svg width="14" height="14" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg"><rect x="1" y="1" width="14" height="14" fill="white" stroke="#888" stroke-width="1"/><line x1="1" y1="15" x2="15" y2="1" stroke="red" stroke-width="1.5"/></svg>"##;
    let none_indicator = r##"<svg width="100%" height="100%" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><line x1="0" y1="24" x2="24" y2="0" stroke="red" stroke-width="2"/></svg>"##;

    // Color bar: pixel-accurate base64 BMP data URI.
    // Split y-axis: top half S 0→100%, B 100→80%; bottom half S 100%, B 80→0%.
    let color_bar_data_uri = build_color_bar_data_uri();

    let bar_opacity = if disabled { "0.4" } else { "1.0" };

    rsx! {
        div {
            style: "padding:4px; font-size:11px; color:{THEME_TEXT_BODY}; display:flex; flex-direction:column; gap:6px;",

            // ── Row 1: Swatches ──
            div {
                style: "display:flex; gap:2px; align-items:center; flex-wrap:nowrap;",
                // None shortcut
                div {
                    style: "width:16px; height:16px; cursor:pointer; flex-shrink:0;",
                    title: "None",
                    dangerous_inner_html: "{none_svg}",
                    onmousedown: {
                        let act = act.clone();
                        move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                                st.set_active_to_none();
                            }));
                        }
                    },
                }
                // Black shortcut
                div {
                    style: "width:16px; height:16px; background:#000; border:1px solid #888; cursor:pointer; flex-shrink:0; box-sizing:border-box;",
                    title: "Black",
                    onmousedown: {
                        let act = act.clone();
                        move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                                st.set_active_color(Color::BLACK);
                            }));
                        }
                    },
                }
                // White shortcut
                div {
                    style: "width:16px; height:16px; background:#fff; border:1px solid #888; cursor:pointer; flex-shrink:0; box-sizing:border-box;",
                    title: "White",
                    onmousedown: {
                        let act = act.clone();
                        move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                                st.set_active_color(Color::WHITE);
                            }));
                        }
                    },
                }
                // Separator
                div {
                    style: "width:1px; height:16px; background:{THEME_BORDER}; flex-shrink:0; margin:0 2px;",
                }
                // Recent color slots
                for i in 0..10 {
                    {
                        let color_hex = recent_colors.get(i).cloned();
                        if let Some(hex) = color_hex {
                            let bg = format!("#{hex}");
                            let act = act.clone();
                            let hex_click = hex.clone();
                            rsx! {
                                div {
                                    style: "width:16px; height:16px; background:{bg}; border:1px solid #888; cursor:pointer; flex-shrink:0; box-sizing:border-box;",
                                    title: "#{hex}",
                                    onmousedown: move |evt: Event<MouseData>| {
                                        evt.stop_propagation();
                                        if let Some(c) = Color::from_hex(&hex_click) {
                                            (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                                st.set_active_color(c);
                                            }));
                                        }
                                    },
                                }
                            }
                        } else {
                            rsx! {
                                div {
                                    style: "width:16px; height:16px; border:1px solid {THEME_BORDER}; background:transparent; flex-shrink:0; box-sizing:border-box;",
                                }
                            }
                        }
                    }
                }
            }

            // ── Row 2: Fill/stroke widget + Sliders ──
            div {
                style: "display:flex; gap:6px; align-items:flex-start;",

                // Left: fill/stroke widget
                div {
                    style: "position:relative; width:52px; height:56px; flex-shrink:0;",
                    // Swap button
                    div {
                        style: "position:absolute; top:0; right:0; cursor:pointer; font-size:11px; color:{THEME_TEXT}; z-index:3; user-select:none; line-height:1;",
                        title: "Swap Fill and Stroke (Shift+X)",
                        onmousedown: {
                            let act = act.clone();
                            move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                                    st.swap_fill_stroke();
                                }));
                            }
                        },
                        "\u{21C4}"
                    }
                    // Default button
                    div {
                        style: "position:absolute; bottom:0; left:0; width:14px; height:14px; cursor:pointer; z-index:3; user-select:none;",
                        title: "Default Fill and Stroke (D)",
                        onmousedown: {
                            let act = act.clone();
                            move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                (act.0.borrow_mut())(Box::new(|st: &mut AppState| {
                                    st.reset_fill_stroke_defaults();
                                }));
                            }
                        },
                        div { style: "position:absolute; top:0; left:0; width:9px; height:9px; background:#000; border:1px solid #888;" }
                        div { style: "position:absolute; bottom:0; right:0; width:9px; height:9px; background:#fff; border:1px solid #888;" }
                    }
                    // Back square
                    if fill_on_top {
                        div {
                            style: "position:absolute; right:2px; bottom:2px; width:28px; height:28px; border:6px solid {stroke_css}; background:transparent; cursor:pointer; z-index:1; box-sizing:border-box;",
                            title: "Stroke",
                            onmousedown: {
                                let act = act.clone();
                                move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| { st.fill_on_top = false; }));
                                }
                            },
                            if stroke_is_none { div { style: "width:100%; height:100%;", dangerous_inner_html: "{none_indicator}" } }
                        }
                    } else {
                        div {
                            style: "position:absolute; left:2px; top:2px; width:28px; height:28px; background:{fill_css}; border:1px solid #888; cursor:pointer; z-index:1; box-sizing:border-box;",
                            title: "Fill",
                            onmousedown: {
                                let act = act.clone();
                                move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    (act.0.borrow_mut())(Box::new(|st: &mut AppState| { st.fill_on_top = true; }));
                                }
                            },
                            if fill_is_none { div { style: "width:100%; height:100%;", dangerous_inner_html: "{none_indicator}" } }
                        }
                    }
                    // Front square
                    if fill_on_top {
                        div {
                            style: "position:absolute; left:2px; top:2px; width:28px; height:28px; background:{fill_css}; border:1px solid #888; cursor:pointer; z-index:2; box-sizing:border-box;",
                            title: "Fill (active)",
                            if fill_is_none { div { style: "width:100%; height:100%;", dangerous_inner_html: "{none_indicator}" } }
                        }
                    } else {
                        div {
                            style: "position:absolute; right:2px; bottom:2px; width:28px; height:28px; border:6px solid {stroke_css}; background:transparent; cursor:pointer; z-index:2; box-sizing:border-box;",
                            title: "Stroke (active)",
                            if stroke_is_none { div { style: "width:100%; height:100%;", dangerous_inner_html: "{none_indicator}" } }
                        }
                    }
                }

                // Right: sliders
                div {
                    style: "flex:1; display:flex; flex-direction:column; gap:2px; min-width:0;",
                    match mode {
                        ColorMode::Grayscale => rsx! {
                            {slider_row(&act, panel_state, last_synced_hex, "K", "k", 0.0, 100.0, 1.0, disabled, Some("%"))}
                        },
                        ColorMode::Hsb => rsx! {
                            {slider_row(&act, panel_state, last_synced_hex, "H", "h", 0.0, 360.0, 1.0, disabled, Some("\u{00B0}"))}
                            {slider_row(&act, panel_state, last_synced_hex, "S", "s", 0.0, 100.0, 1.0, disabled, Some("%"))}
                            {slider_row(&act, panel_state, last_synced_hex, "B", "b", 0.0, 100.0, 1.0, disabled, Some("%"))}
                        },
                        ColorMode::Rgb => rsx! {
                            {slider_row(&act, panel_state, last_synced_hex, "R", "r", 0.0, 255.0, 1.0, disabled, None)}
                            {slider_row(&act, panel_state, last_synced_hex, "G", "g", 0.0, 255.0, 1.0, disabled, None)}
                            {slider_row(&act, panel_state, last_synced_hex, "B", "bl", 0.0, 255.0, 1.0, disabled, None)}
                        },
                        ColorMode::Cmyk => rsx! {
                            {slider_row(&act, panel_state, last_synced_hex, "C", "c", 0.0, 100.0, 1.0, disabled, Some("%"))}
                            {slider_row(&act, panel_state, last_synced_hex, "M", "m", 0.0, 100.0, 1.0, disabled, Some("%"))}
                            {slider_row(&act, panel_state, last_synced_hex, "Y", "y", 0.0, 100.0, 1.0, disabled, Some("%"))}
                            {slider_row(&act, panel_state, last_synced_hex, "K", "k", 0.0, 100.0, 1.0, disabled, Some("%"))}
                        },
                        ColorMode::WebSafeRgb => rsx! {
                            {slider_row(&act, panel_state, last_synced_hex, "R", "r", 0.0, 255.0, 51.0, disabled, None)}
                            {slider_row(&act, panel_state, last_synced_hex, "G", "g", 0.0, 255.0, 51.0, disabled, None)}
                            {slider_row(&act, panel_state, last_synced_hex, "B", "bl", 0.0, 255.0, 51.0, disabled, None)}
                        },
                    }
                }
            }

            // ── Row 3: Hex input ──
            {
                let hex_val = ps.hex.clone();
                let hex_opacity = if disabled { "0.4" } else { "1.0" };
                let act_hex = act.clone();
                rsx! {
                    div {
                        style: "display:flex; gap:2px; align-items:center; opacity:{hex_opacity};",
                        span { style: "font-size:10px; color:{THEME_TEXT};", "#" }
                        input {
                            r#type: "text",
                            value: "{hex_val}",
                            disabled: disabled,
                            maxlength: "6",
                            style: "width:52px; background:{THEME_BG_DARK}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; font-size:10px; padding:2px 4px; font-family:monospace;",
                            onkeydown: move |evt: Event<KeyboardData>| {
                                if evt.data().key() == Key::Enter {
                                    let raw = panel_state().hex.clone();
                                    let raw = raw.trim().trim_start_matches('#').to_string();
                                    if raw.len() == 6 && raw.chars().all(|c| c.is_ascii_hexdigit()) {
                                        if let Some(color) = Color::from_hex(&raw) {
                                            let mut ps = panel_state();
                                            ps.sync_from_color(color);
                                            let m = ps.mode;
                                            ps.mode = m;
                                            last_synced_hex.set(color.to_hex());
                                            panel_state.set(ps);
                                            (act_hex.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                                st.set_active_color(color);
                                            }));
                                        }
                                    }
                                }
                            },
                            oninput: move |evt: Event<FormData>| {
                                let raw = evt.value().trim().trim_start_matches('#').to_lowercase();
                                let filtered: String = raw.chars().filter(|c| c.is_ascii_hexdigit()).take(6).collect();
                                let mut ps = panel_state();
                                ps.hex = filtered;
                                panel_state.set(ps);
                            },
                        }
                    }
                }
            }

            // ── Color bar ──
            div {
                style: "position:relative; width:100%; height:64px; cursor:crosshair; border:1px solid {THEME_BORDER}; border-radius:1px; opacity:{bar_opacity}; overflow:hidden;",
                // Pixel-accurate color bar image
                img {
                    src: "{color_bar_data_uri}",
                    style: "position:absolute; inset:0; width:100%; height:100%; image-rendering:auto;",
                }
                // Interaction overlay
                div {
                    id: "jas-color-bar-overlay",
                    style: "position:absolute; inset:0;",
                    onmousedown: {
                        let act = act.clone();
                        move |evt: Event<MouseData>| {
                            if disabled { return; }
                            evt.stop_propagation();
                            // Get actual element dimensions from the DOM
                            let (w, h) = color_bar_element_size("jas-color-bar-overlay");
                            let coords = evt.data().element_coordinates();
                            let x = coords.x.clamp(0.0, w - 1.0);
                            let y = coords.y.clamp(0.0, h - 1.0);
                            let mid_y = h / 2.0;

                            let hue = 360.0 * x / w;
                            let (sat, br) = if y <= mid_y {
                                let t = y / mid_y;
                                (t * 100.0, 100.0 - t * 20.0)
                            } else {
                                let t = (y - mid_y) / (h - mid_y);
                                (100.0, 80.0 * (1.0 - t))
                            };

                            let color = Color::hsb(hue, sat / 100.0, br / 100.0);
                            let mut ps = panel_state();
                            ps.sync_from_color(color);
                            ps.h = hue.round();
                            ps.s = sat.round();
                            ps.b = br.round();
                            let m = ps.mode;
                            ps.mode = m;
                            last_synced_hex.set(color.to_hex());
                            panel_state.set(ps);
                            (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                st.set_active_color(color);
                            }));
                        }
                    },
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Slider row helper
// ---------------------------------------------------------------------------

fn slider_row(
    act: &Act,
    mut panel_state: Signal<PanelColorState>,
    mut last_synced_hex: Signal<String>,
    label: &'static str,
    field: &'static str,
    min: f64,
    max: f64,
    step: f64,
    disabled: bool,
    suffix: Option<&'static str>,
) -> Element {
    let current_val = get_field(&panel_state(), field);
    let val_str = format!("{}", current_val as i64);
    let slider_val = format!("{current_val}");
    let step_str = format!("{step}");
    let min_str = format!("{min}");
    let max_str = format!("{max}");
    let opacity = if disabled { "0.4" } else { "1.0" };

    let act_input = act.clone();
    let act_change = act.clone();
    let act_num = act.clone();

    rsx! {
        div {
            style: "display:flex; gap:4px; align-items:center; opacity:{opacity};",
            span {
                style: "width:10px; font-size:10px; color:{THEME_TEXT}; flex-shrink:0; text-align:right;",
                "{label}"
            }
            input {
                r#type: "range",
                value: "{slider_val}",
                min: "{min_str}",
                max: "{max_str}",
                step: "{step_str}",
                disabled: disabled,
                style: "flex:1; min-width:0; height:14px; accent-color:{THEME_ACCENT};",
                oninput: move |evt: Event<FormData>| {
                    if let Ok(v) = evt.value().parse::<f64>() {
                        let mut ps = panel_state();
                        set_field(&mut ps, field, v);
                        let color = ps.to_color();
                        ps.sync_from_color(color);
                        let m = ps.mode;
                        set_field(&mut ps, field, v);
                        ps.mode = m;
                        last_synced_hex.set(color.to_hex());
                        panel_state.set(ps);
                        (act_input.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.set_active_color_live(color);
                        }));
                    }
                },
                onchange: move |evt: Event<FormData>| {
                    if let Ok(v) = evt.value().parse::<f64>() {
                        let mut ps = panel_state();
                        set_field(&mut ps, field, v);
                        let color = ps.to_color();
                        (act_change.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.set_active_color(color);
                        }));
                    }
                },
            }
            input {
                r#type: "number",
                value: "{val_str}",
                min: "{min_str}",
                max: "{max_str}",
                disabled: disabled,
                style: "width:36px; background:{THEME_BG_DARK}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; font-size:10px; text-align:right; padding:1px 2px;",
                onchange: move |evt: Event<FormData>| {
                    if let Ok(v) = evt.value().parse::<f64>() {
                        let v = v.clamp(min, max);
                        let mut ps = panel_state();
                        set_field(&mut ps, field, v);
                        let color = ps.to_color();
                        ps.sync_from_color(color);
                        let m = ps.mode;
                        ps.mode = m;
                        last_synced_hex.set(color.to_hex());
                        panel_state.set(ps);
                        (act_num.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.set_active_color(color);
                        }));
                    }
                },
            }
            if let Some(sfx) = suffix {
                span {
                    style: "font-size:10px; color:{THEME_TEXT_DIM}; flex-shrink:0;",
                    "{sfx}"
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panel_color_state_default() {
        let ps = PanelColorState::default();
        assert_eq!(ps.mode, ColorMode::Hsb);
        assert_eq!(ps.hex, "ffffff");
    }

    #[test]
    fn sync_from_black() {
        let mut ps = PanelColorState::default();
        ps.sync_from_color(Color::BLACK);
        assert_eq!(ps.r, 0.0);
        assert_eq!(ps.g, 0.0);
        assert_eq!(ps.bl, 0.0);
        assert_eq!(ps.hex, "000000");
    }

    #[test]
    fn sync_from_red() {
        let mut ps = PanelColorState::default();
        ps.sync_from_color(Color::rgb(1.0, 0.0, 0.0));
        assert_eq!(ps.r, 255.0);
        assert_eq!(ps.g, 0.0);
        assert_eq!(ps.bl, 0.0);
        assert_eq!(ps.hex, "ff0000");
        assert!((ps.h - 0.0).abs() < 1.0);
        assert!((ps.s - 100.0).abs() < 1.0);
        assert!((ps.b - 100.0).abs() < 1.0);
    }

    #[test]
    fn to_color_hsb_mode() {
        let mut ps = PanelColorState::default();
        ps.mode = ColorMode::Hsb;
        ps.h = 0.0;
        ps.s = 100.0;
        ps.b = 100.0;
        let color = ps.to_color();
        let (r, g, b, _) = color.to_rgba();
        assert!((r - 1.0).abs() < 0.01);
        assert!(g.abs() < 0.01);
        assert!(b.abs() < 0.01);
    }

    #[test]
    fn to_color_rgb_mode() {
        let mut ps = PanelColorState::default();
        ps.mode = ColorMode::Rgb;
        ps.r = 128.0;
        ps.g = 64.0;
        ps.bl = 32.0;
        let color = ps.to_color();
        let (r, g, b, _) = color.to_rgba();
        assert!((r - 128.0 / 255.0).abs() < 0.01);
        assert!((g - 64.0 / 255.0).abs() < 0.01);
        assert!((b - 32.0 / 255.0).abs() < 0.01);
    }

    #[test]
    fn to_color_grayscale_mode() {
        let mut ps = PanelColorState::default();
        ps.mode = ColorMode::Grayscale;
        ps.k = 50.0;
        let color = ps.to_color();
        let (r, g, b, _) = color.to_rgba();
        assert!((r - 0.5).abs() < 0.01);
        assert!((g - 0.5).abs() < 0.01);
        assert!((b - 0.5).abs() < 0.01);
    }

    #[test]
    fn color_mode_roundtrip() {
        for mode in ColorMode::ALL {
            let cmd = mode.command();
            let back = ColorMode::from_command(cmd);
            assert_eq!(back, Some(*mode));
        }
    }
}
