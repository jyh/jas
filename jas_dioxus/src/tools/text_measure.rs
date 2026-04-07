//! Text measurement helpers used by the text editor and renderer.
//!
//! Builds a `Box<dyn Fn(&str) -> f64>` measurer for a given font, backed by
//! a hidden `<canvas>` in the browser. When no DOM is available (cargo
//! tests on the host), falls back to a deterministic stub measurer.

#[cfg(target_arch = "wasm32")]
use wasm_bindgen::JsCast;

/// Build the CSS font shorthand used by canvas `set_font`.
pub fn font_string(style: &str, weight: &str, size: f64, family: &str) -> String {
    format!("{style} {weight} {size}px {family}")
}

/// Approximate fallback when no DOM is available (cargo test on the host).
fn fallback_width(font_size: f64) -> impl Fn(&str) -> f64 {
    let per_char = font_size * 0.55;
    move |s: &str| s.chars().count() as f64 * per_char
}

/// Return a measurer that reports pixel widths for the supplied font.
///
/// Reuses a single hidden `<canvas>` element appended to `<body>` (created
/// lazily on first use). Falls back to a stub if there is no `window`.
pub fn make_measurer(font: &str, font_size: f64) -> Box<dyn Fn(&str) -> f64> {
    #[cfg(not(target_arch = "wasm32"))]
    {
        let _ = font;
        return Box::new(fallback_width(font_size));
    }
    #[cfg(target_arch = "wasm32")]
    {
    let Some(window) = web_sys::window() else {
        return Box::new(fallback_width(font_size));
    };
    let Some(doc) = window.document() else {
        return Box::new(fallback_width(font_size));
    };
    let canvas: web_sys::HtmlCanvasElement = match doc.get_element_by_id("jas-text-measure") {
        Some(el) => el.unchecked_into(),
        None => {
            let el = match doc.create_element("canvas") {
                Ok(e) => e,
                Err(_) => return Box::new(fallback_width(font_size)),
            };
            let canvas: web_sys::HtmlCanvasElement = el.unchecked_into();
            canvas.set_id("jas-text-measure");
            // Hide it.
            if let Some(style) = canvas.get_attribute("style") {
                let _ = style; // not used
            }
            canvas
                .set_attribute("style", "display:none;position:absolute;top:-9999px")
                .ok();
            if let Some(body) = doc.body() {
                body.append_child(&canvas).ok();
            }
            canvas
        }
    };
    let ctx: web_sys::CanvasRenderingContext2d = match canvas.get_context("2d") {
        Ok(Some(c)) => c.unchecked_into(),
        _ => return Box::new(fallback_width(font_size)),
    };
    ctx.set_font(font);
    Box::new(move |s: &str| {
        ctx.measure_text(s)
            .map(|m: web_sys::TextMetrics| m.width())
            .unwrap_or(0.0)
    })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn font_string_concatenates_components() {
        assert_eq!(
            font_string("italic", "bold", 16.0, "sans-serif"),
            "italic bold 16px sans-serif"
        );
    }

    #[test]
    fn fallback_returns_positive_widths() {
        let m = fallback_width(16.0);
        assert!(m("a") > 0.0);
        assert!(m("ab") > m("a"));
        assert_eq!(m(""), 0.0);
    }

    #[test]
    fn make_measurer_in_test_env_uses_fallback() {
        // No DOM in cargo test → make_measurer falls back to stub.
        let m = make_measurer("16px sans", 16.0);
        assert!(m("hello") > 0.0);
    }
}
