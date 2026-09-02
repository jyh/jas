//! Text measurement helpers used by the text editor, the renderer and
//! `Element::bounds`.
//!
//! Builds a `Box<dyn Fn(&str) -> f64>` measurer for a given font, backed by
//! a hidden `<canvas>` in the browser. When no DOM is available — cargo tests
//! on the host, and every native build — falls back to a deterministic stub.
//!
//! AT THE CRATE ROOT, and NOT gated behind `feature = "web"`. It used to live
//! in `tools`, which is web-gated because it imports `web_sys`, while being the
//! ONLY definition of the shared character-width law. `Element::bounds` could
//! not reach it in a native build and carried a second, DIVERGENT arm instead
//! (see the CHARWIDTH note in `geometry::element`). `tools::text_measure`
//! re-exports everything here, so existing call sites are unchanged.

#[cfg(all(target_arch = "wasm32", feature = "web"))]
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
    #[cfg(not(all(target_arch = "wasm32", feature = "web")))]
    {
        let _ = font;
        Box::new(fallback_width(font_size))
    }
    #[cfg(all(target_arch = "wasm32", feature = "web"))]
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

/// A measurer that answers from REAL font metrics, or `None` when the face
/// cannot be resolved.
///
/// ⭐ ROW DR (2026-09-02). [`make_measurer`] above always answers: in the
/// browser from a hidden canvas, and on every native build from a **stub** —
/// `font_size × 0.55` per character. Row DQ measured what that costs the
/// moment anything POSITIONS text by it:
///
/// | string @16 | stub | DirectWrite | error |
/// |---|---|---|---|
/// | `"iiii"` | 35.200 | 15.500 | **+127.1 %** |
/// | `"MMMM"` | 35.200 | 57.469 | **−38.7 %** |
///
/// The stub is **width-blind by construction** (it counts characters) and
/// weight-blind besides. Segmented text advances the pen by it between tspans,
/// and text-on-path advances by it between GLYPHS, where the error compounds —
/// 20.590 units of drift by the tenth glyph of `"Hello Path"`, 11 % of the
/// path, placing every glyph at a wrong point AND a wrong tangent angle.
///
/// ⛔ IT RETURNS `Option`, AND THAT IS THE "FAIL CLOSED" HALF OF THE ROW.
/// [`make_measurer`] answers 0.55-per-char for a family that does not exist —
/// a confident wrong number. A caller that POSITIONS by it would lay text out
/// against metrics belonging to no font at all. `None` lets the caller refuse
/// the element instead, which is what every other seam in this lane does with
/// a capability it cannot honour.
///
/// ⚠️ IT IS NOT A REPLACEMENT FOR [`make_measurer`]. That function keeps its
/// signature and its callers (the web walk, `Element::bounds`, the text
/// pipeline), where a total function over an approximate answer is the right
/// shape. This one is for the callers that must be RIGHT or refuse.
#[cfg(all(feature = "d2d", windows))]
pub fn try_make_measurer(font: &str, font_size: f64) -> Option<Box<dyn Fn(&str) -> f64 + 'static>> {
    let advance = crate::painter::direct2d::text::try_advance_of(font, font_size)?;
    Some(Box::new(advance))
}

/// The non-Direct2D answer: there is no real measurer, so there is no measurer.
///
/// ⛔ IT REFUSES RATHER THAN FALLING BACK TO [`make_measurer`]. Returning the
/// stub here would defeat the whole point: the caller asked for metrics it can
/// position by, and silently handing it the 0.55 approximation is the confident
/// wrong number this function exists to avoid.
#[cfg(not(all(feature = "d2d", windows)))]
pub fn try_make_measurer(font: &str, font_size: f64) -> Option<Box<dyn Fn(&str) -> f64 + 'static>> {
    let _ = (font, font_size);
    None
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
