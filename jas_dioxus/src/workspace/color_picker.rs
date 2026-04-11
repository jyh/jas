//! Color Picker modal dialog.
//!
//! Renders a modal overlay with:
//! - A 2D color gradient (256x256)
//! - A vertical colorbar (20xN) with slider
//! - Radio buttons for H, S, B, R, G, Blue
//! - Text inputs for HSB, RGB, CMYK, and hex
//! - A color swatch preview
//! - OK / Cancel buttons
//! - Eyedropper tool
//! - Only Web Colors checkbox

use crate::geometry::element::Color;

// ---------------------------------------------------------------------------
// Color picker state
// ---------------------------------------------------------------------------

/// Which radio button is selected.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum RadioChannel {
    H, S, B, R, G, Blue,
}

/// State for the color picker dialog.
#[derive(Debug, Clone)]
pub struct ColorPickerState {
    /// Whether the dialog is for fill or stroke.
    pub for_fill: bool,
    /// Current working color (always stored as RGB internally).
    r: f64, g: f64, b: f64,
    /// Preserved hue (0..360) — survives when brightness or saturation is 0.
    hue: f64,
    /// Preserved saturation (0..1) — survives when brightness is 0.
    sat: f64,
    /// Selected radio button.
    pub radio: RadioChannel,
    /// Only web colors checkbox.
    pub web_only: bool,
    /// Eyedropper sampling mode active.
    pub eyedropper_active: bool,
    /// Raw text override — when the user is mid-edit and the value doesn't parse yet
    /// (e.g. deleted "0" to type a new number), store the raw text here so the
    /// value binding doesn't overwrite it. Cleared on successful parse.
    pub input_override: Option<(&'static str, String)>,
}

impl ColorPickerState {
    /// Create a new color picker state with the given initial color.
    pub fn new(color: Color, for_fill: bool) -> Self {
        let (r, g, b, _) = color.to_rgba();
        let (h, s, _, _) = color.to_hsba();
        Self { for_fill, r, g, b, hue: h, sat: s, radio: RadioChannel::H, web_only: false, eyedropper_active: false, input_override: None }
    }

    /// Get the current color as an RGB Color.
    pub fn color(&self) -> Color {
        Color::rgb(self.r, self.g, self.b)
    }

    /// Update preserved hue/sat from the current RGB, but only when the
    /// conversion is meaningful (brightness > 0 for hue, saturation > 0 for hue).
    fn sync_hue_sat(&mut self) {
        let (h, s, br, _) = Color::rgb(self.r, self.g, self.b).to_hsba();
        // Only update hue when it's meaningful (brightness > 0 and saturation > 0)
        if br > 0.001 && s > 0.001 {
            self.hue = h;
        }
        // Only update saturation when brightness > 0
        if br > 0.001 {
            self.sat = s;
        }
    }

    /// Set the color from RGB components (0-255 integer scale).
    pub fn set_rgb(&mut self, r: u8, g: u8, b: u8) {
        self.r = r as f64 / 255.0;
        self.g = g as f64 / 255.0;
        self.b = b as f64 / 255.0;
        if self.web_only { self.snap_to_web(); }
        self.sync_hue_sat();
    }

    /// Set the color from HSB components (h: 0-360, s: 0-100, b: 0-100).
    pub fn set_hsb(&mut self, h: f64, s: f64, b: f64) {
        self.hue = h;
        self.sat = s / 100.0;
        let c = Color::hsb(h, s / 100.0, b / 100.0);
        let (r, g, bl, _) = c.to_rgba();
        self.r = r;
        self.g = g;
        self.b = bl;
        if self.web_only { self.snap_to_web(); }
    }

    /// Set the color from CMYK components (all 0-100).
    pub fn set_cmyk(&mut self, c: f64, m: f64, y: f64, k: f64) {
        let color = Color::cmyk(c / 100.0, m / 100.0, y / 100.0, k / 100.0);
        let (r, g, b, _) = color.to_rgba();
        self.r = r;
        self.g = g;
        self.b = b;
        if self.web_only { self.snap_to_web(); }
        self.sync_hue_sat();
    }

    /// Set the color from a hex string.
    pub fn set_hex(&mut self, hex: &str) {
        if let Some(c) = Color::from_hex(hex) {
            let (r, g, b, _) = c.to_rgba();
            self.r = r;
            self.g = g;
            self.b = b;
            if self.web_only { self.snap_to_web(); }
            self.sync_hue_sat();
        }
    }

    /// Get RGB values as 0-255 integers.
    pub fn rgb_u8(&self) -> (u8, u8, u8) {
        (
            (self.r * 255.0).round() as u8,
            (self.g * 255.0).round() as u8,
            (self.b * 255.0).round() as u8,
        )
    }

    /// Get HSB values (h: 0-360, s: 0-100, b: 0-100).
    /// Uses preserved hue/sat when the derived values would be lost.
    pub fn hsb_vals(&self) -> (f64, f64, f64) {
        let (dh, ds, db, _) = Color::rgb(self.r, self.g, self.b).to_hsba();
        let h = if db < 0.001 || ds < 0.001 { self.hue } else { dh };
        let s = if db < 0.001 { self.sat } else { ds };
        (h, s * 100.0, db * 100.0)
    }

    /// Get CMYK values (all 0-100).
    pub fn cmyk_vals(&self) -> (f64, f64, f64, f64) {
        let (c, m, y, k, _) = Color::rgb(self.r, self.g, self.b).to_cmyka();
        (c * 100.0, m * 100.0, y * 100.0, k * 100.0)
    }

    /// Get the display value for a field. If the user is mid-edit on this field
    /// (e.g. deleted "0"), return the raw text; otherwise return the computed value.
    pub fn field_display(&self, field: &str, computed: &str) -> String {
        if let Some((f, ref txt)) = self.input_override {
            if f == field {
                return txt.clone();
            }
        }
        computed.to_string()
    }

    /// Called when an input value doesn't parse. Stores the raw text so the
    /// value binding doesn't overwrite the user's typing.
    pub fn set_input_override(&mut self, field: &'static str, text: String) {
        self.input_override = Some((field, text));
    }

    /// Clear the input override (called when a valid value is parsed).
    pub fn clear_input_override(&mut self) {
        self.input_override = None;
    }

    /// Get hex string (no #).
    pub fn hex_str(&self) -> String {
        Color::rgb(self.r, self.g, self.b).to_hex()
    }

    /// Snap RGB to web-safe colors.
    fn snap_to_web(&mut self) {
        self.r = snap_web(self.r);
        self.g = snap_web(self.g);
        self.b = snap_web(self.b);
    }

    /// Set the color from gradient position (x, y normalized 0..1),
    /// given the current radio button.
    pub fn set_from_gradient(&mut self, x: f64, y: f64) {
        let x = x.clamp(0.0, 1.0);
        let y = y.clamp(0.0, 1.0);
        match self.radio {
            RadioChannel::H => {
                // Gradient: x=S, y=B (top=1, bottom=0); colorbar=H
                self.sat = x;
                let c = Color::hsb(self.hue, x, 1.0 - y);
                let (r, g, b, _) = c.to_rgba();
                self.r = r; self.g = g; self.b = b;
            }
            RadioChannel::S => {
                // Gradient: x=H, y=B; colorbar=S
                self.hue = x * 360.0;
                let c = Color::hsb(x * 360.0, self.sat, 1.0 - y);
                let (r, g, b, _) = c.to_rgba();
                self.r = r; self.g = g; self.b = b;
            }
            RadioChannel::B => {
                // Gradient: x=H, y=S; colorbar=B
                self.hue = x * 360.0;
                self.sat = 1.0 - y;
                let (_, _, br, _) = Color::rgb(self.r, self.g, self.b).to_hsba();
                let c = Color::hsb(x * 360.0, 1.0 - y, br);
                let (r, g, b, _) = c.to_rgba();
                self.r = r; self.g = g; self.b = b;
            }
            RadioChannel::R => {
                self.b = x;
                self.g = 1.0 - y;
                self.sync_hue_sat();
            }
            RadioChannel::G => {
                self.b = x;
                self.r = 1.0 - y;
                self.sync_hue_sat();
            }
            RadioChannel::Blue => {
                self.r = x;
                self.g = 1.0 - y;
                self.sync_hue_sat();
            }
        }
        if self.web_only { self.snap_to_web(); }
    }

    /// Set the color from colorbar position (t: 0..1, top=0, bottom=1).
    pub fn set_from_colorbar(&mut self, t: f64) {
        let t = t.clamp(0.0, 1.0);
        match self.radio {
            RadioChannel::H => {
                self.hue = t * 360.0;
                let c = Color::hsb(t * 360.0, self.sat, {
                    let (_, _, b, _) = Color::rgb(self.r, self.g, self.b).to_hsba();
                    b
                });
                let (r, g, bl, _) = c.to_rgba();
                self.r = r; self.g = g; self.b = bl;
            }
            RadioChannel::S => {
                self.sat = 1.0 - t;
                let c = Color::hsb(self.hue, 1.0 - t, {
                    let (_, _, b, _) = Color::rgb(self.r, self.g, self.b).to_hsba();
                    b
                });
                let (r, g, bl, _) = c.to_rgba();
                self.r = r; self.g = g; self.b = bl;
            }
            RadioChannel::B => {
                let c = Color::hsb(self.hue, self.sat, 1.0 - t);
                let (r, g, bl, _) = c.to_rgba();
                self.r = r; self.g = g; self.b = bl;
            }
            RadioChannel::R => { self.r = 1.0 - t; self.sync_hue_sat(); }
            RadioChannel::G => { self.g = 1.0 - t; self.sync_hue_sat(); }
            RadioChannel::Blue => { self.b = 1.0 - t; self.sync_hue_sat(); }
        }
        if self.web_only { self.snap_to_web(); }
    }

    /// Get colorbar position (0..1, 0=top) for current color.
    pub fn colorbar_pos(&self) -> f64 {
        match self.radio {
            RadioChannel::H => self.hue / 360.0,
            RadioChannel::S => 1.0 - self.sat,
            RadioChannel::B => { let (_, _, b, _) = Color::rgb(self.r, self.g, self.b).to_hsba(); 1.0 - b }
            RadioChannel::R => 1.0 - self.r,
            RadioChannel::G => 1.0 - self.g,
            RadioChannel::Blue => 1.0 - self.b,
        }
    }

    /// Get gradient position (x, y: 0..1) for current color.
    pub fn gradient_pos(&self) -> (f64, f64) {
        let (_, _, db, _) = Color::rgb(self.r, self.g, self.b).to_hsba();
        match self.radio {
            RadioChannel::H => (self.sat, 1.0 - db),
            RadioChannel::S => (self.hue / 360.0, 1.0 - db),
            RadioChannel::B => (self.hue / 360.0, 1.0 - self.sat),
            RadioChannel::R => (self.b, 1.0 - self.g),
            RadioChannel::G => (self.b, 1.0 - self.r),
            RadioChannel::Blue => (self.r, 1.0 - self.g),
        }
    }
}

/// Snap a 0..1 component to the nearest web-safe value.
fn snap_web(v: f64) -> f64 {
    let steps = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]; // 00, 33, 66, 99, CC, FF
    let mut best = steps[0];
    for &s in &steps {
        if (v - s).abs() < (v - best).abs() {
            best = s;
        }
    }
    best
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_from_black() {
        let cp = ColorPickerState::new(Color::BLACK, true);
        assert_eq!(cp.rgb_u8(), (0, 0, 0));
        assert_eq!(cp.hex_str(), "000000");
    }

    #[test]
    fn new_from_red() {
        let cp = ColorPickerState::new(Color::rgb(1.0, 0.0, 0.0), false);
        assert_eq!(cp.rgb_u8(), (255, 0, 0));
        assert_eq!(cp.hex_str(), "ff0000");
    }

    #[test]
    fn set_rgb() {
        let mut cp = ColorPickerState::new(Color::BLACK, true);
        cp.set_rgb(128, 64, 32);
        assert_eq!(cp.rgb_u8(), (128, 64, 32));
    }

    #[test]
    fn set_hsb() {
        let mut cp = ColorPickerState::new(Color::BLACK, true);
        cp.set_hsb(0.0, 100.0, 100.0); // pure red
        assert_eq!(cp.rgb_u8(), (255, 0, 0));
    }

    #[test]
    fn set_cmyk() {
        let mut cp = ColorPickerState::new(Color::BLACK, true);
        cp.set_cmyk(0.0, 0.0, 0.0, 0.0); // white
        assert_eq!(cp.rgb_u8(), (255, 255, 255));
    }

    #[test]
    fn set_hex() {
        let mut cp = ColorPickerState::new(Color::BLACK, true);
        cp.set_hex("ff8000");
        assert_eq!(cp.rgb_u8(), (255, 128, 0));
    }

    #[test]
    fn hsb_vals_red() {
        let cp = ColorPickerState::new(Color::rgb(1.0, 0.0, 0.0), true);
        let (h, s, b) = cp.hsb_vals();
        assert!((h - 0.0).abs() < 1.0);
        assert!((s - 100.0).abs() < 1.0);
        assert!((b - 100.0).abs() < 1.0);
    }

    #[test]
    fn cmyk_vals_white() {
        let cp = ColorPickerState::new(Color::WHITE, true);
        let (c, m, y, k) = cp.cmyk_vals();
        assert!((c).abs() < 1.0);
        assert!((m).abs() < 1.0);
        assert!((y).abs() < 1.0);
        assert!((k).abs() < 1.0);
    }

    #[test]
    fn web_snap() {
        assert_eq!(snap_web(0.0), 0.0);
        assert_eq!(snap_web(1.0), 1.0);
        assert_eq!(snap_web(0.19), 0.2);
        assert_eq!(snap_web(0.5), 0.4); // 0.5 is equidistant, snaps to 0.4
    }

    #[test]
    fn web_only_snaps() {
        let mut cp = ColorPickerState::new(Color::BLACK, true);
        cp.web_only = true;
        cp.set_rgb(100, 150, 200); // not web-safe
        let (r, g, b) = cp.rgb_u8();
        // Should snap to nearest web color
        let web_vals = [0u8, 51, 102, 153, 204, 255];
        assert!(web_vals.contains(&r));
        assert!(web_vals.contains(&g));
        assert!(web_vals.contains(&b));
    }

    #[test]
    fn colorbar_pos_roundtrip_h() {
        let mut cp = ColorPickerState::new(Color::hsb(180.0, 0.5, 0.8), true);
        cp.radio = RadioChannel::H;
        let pos = cp.colorbar_pos();
        assert!((pos - 0.5).abs() < 0.01); // 180/360 = 0.5
    }

    #[test]
    fn gradient_pos_roundtrip_h() {
        let mut cp = ColorPickerState::new(Color::hsb(120.0, 0.7, 0.9), true);
        cp.radio = RadioChannel::H;
        let (x, y) = cp.gradient_pos();
        assert!((x - 0.7).abs() < 0.01); // S
        assert!((y - 0.1).abs() < 0.01); // 1-B = 1-0.9
    }
}
