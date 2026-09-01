//! The BROWSER implementation of the caller-owned surface services: a
//! [`WebSurface`] is an `HtmlCanvasElement` plus its 2D context, and it is the
//! ONLY place in the crate that reads pixels (`getImageData`), writes them
//! (`putImageData`) or composites one canvas onto another (`drawImage`).
//!
//! `canvas::render` — the web lane's legacy walk — owns its scratch surfaces
//! through this type and never names a `web_sys` pixel call itself; the
//! portability gate (`scripts/check_canvas_portability.py`) is what keeps that
//! true. The web PAINTER (`painter::canvas2d`) does its own layer compositing
//! — that is backend business, inside a backend — but takes the luminance law
//! from `surface`, never from `canvas/`.

use super::PixelSurface;
use crate::geometry::element::BlendMode;
use wasm_bindgen::JsCast;
use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

/// How a surface lands on a destination when composited.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CompositeOp {
    /// Keep the destination only where the source has alpha; the source's
    /// colour never lands (`destination-in`).
    DestinationIn,
    /// Erase the destination where the source has alpha (`destination-out`).
    DestinationOut,
    /// Draw the source's pixels over the destination under a blend mode
    /// (`source-over` for `Normal`).
    Blend(BlendMode),
}

impl CompositeOp {
    /// The Canvas2D `globalCompositeOperation` keyword.
    pub fn css(self) -> &'static str {
        match self {
            CompositeOp::DestinationIn => "destination-in",
            CompositeOp::DestinationOut => "destination-out",
            CompositeOp::Blend(mode) => blend_mode_css(mode),
        }
    }
}

/// Map a document blend mode to its Canvas2D `globalCompositeOperation`
/// keyword. Lives with the surface because compositing is the surface's verb;
/// `canvas::render` and the web painter both take it from here.
pub fn blend_mode_css(_mode: BlendMode) -> &'static str {
    todo!("blend_mode_css moves here from canvas::render")
}

/// A canvas the caller owns, with its 2D context.
#[derive(Debug, Clone)]
pub struct WebSurface {
    canvas: HtmlCanvasElement,
    ctx: CanvasRenderingContext2d,
}

impl WebSurface {
    /// A detached `w × h` canvas — never appended to the document, so it
    /// costs no layout and is collected with its owner. `None` when there is
    /// no DOM or the element or its context cannot be made.
    pub fn offscreen(_w: u32, _h: u32) -> Option<Self> {
        todo!("WebSurface::offscreen")
    }

    /// Wrap an existing canvas. `None` when its 2D context cannot be made.
    pub fn from_canvas(_canvas: HtmlCanvasElement) -> Option<Self> {
        todo!("WebSurface::from_canvas")
    }

    pub fn canvas(&self) -> &HtmlCanvasElement {
        &self.canvas
    }

    pub fn ctx(&self) -> &CanvasRenderingContext2d {
        &self.ctx
    }

    /// Make the canvas `w × h`. Setting a canvas dimension CLEARS it and
    /// resets its context state, so this touches only the dimension that
    /// actually differs — at the same size it is a no-op and the pixels
    /// survive.
    pub fn resize(&self, _w: u32, _h: u32) {
        todo!("WebSurface::resize")
    }

    /// Identity transform, `source-over`, alpha 1.0, every pixel transparent:
    /// the state a fresh scratch surface starts in.
    pub fn reset(&self) {
        todo!("WebSurface::reset")
    }

    /// Composite this surface's pixels onto `dst` in DEVICE space (identity
    /// transform, pixel `(0, 0)` to pixel `(0, 0)`) under `op` at `alpha`. Any
    /// clip already set on `dst` still applies — a clip is rasterised into
    /// device space when it is set. `dst`'s transform, alpha and composite
    /// operation are exactly as they were when this returns.
    pub fn composite_onto(&self, _dst: &CanvasRenderingContext2d, _op: CompositeOp, _alpha: f64) {
        todo!("WebSurface::composite_onto")
    }
}

impl PixelSurface for WebSurface {
    fn size(&self) -> (u32, u32) {
        (self.canvas.width(), self.canvas.height())
    }

    fn read_rgba(&self, _x: u32, _y: u32, _w: u32, _h: u32) -> Option<Vec<u8>> {
        let _ = (&self.ctx, JsCast::dyn_ref::<HtmlCanvasElement>(&self.canvas));
        todo!("WebSurface::read_rgba")
    }

    fn write_rgba(&self, _x: u32, _y: u32, _w: u32, _h: u32, _rgba: &[u8]) -> Option<()> {
        todo!("WebSurface::write_rgba")
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Browser fixtures. Module-level cfg, like every other wasm test module in
// this crate — `scripts/check_wasm_canvas_count.py` derives its expected
// count from `#[wasm_bindgen_test]` attributes on that assumption.
// ═══════════════════════════════════════════════════════════════════════════
#[cfg(all(test, target_arch = "wasm32"))]
mod tests {
    use super::*;
    use crate::surface::promote_to_luminance;
    use wasm_bindgen_test::*;

    wasm_bindgen_test_configure!(run_in_browser);

    /// TEST-SIDE readback through the raw context. The service's own
    /// `read_rgba` is a subject here, so the pixel oracle must not be it.
    fn rgba_via_ctx(ctx: &CanvasRenderingContext2d, x: f64, y: f64) -> [u8; 4] {
        let d = ctx.get_image_data(x, y, 1.0, 1.0).unwrap().data();
        [d[0], d[1], d[2], d[3]]
    }

    fn fill(ctx: &CanvasRenderingContext2d, css: &str, x: f64, y: f64, w: f64, h: f64) {
        ctx.set_fill_style_str(css);
        ctx.fill_rect(x, y, w, h);
    }

    #[wasm_bindgen_test]
    fn an_offscreen_surface_has_the_size_it_was_asked_for() {
        let s = WebSurface::offscreen(5, 3).expect("a DOM is present in the browser lane");
        assert_eq!(s.size(), (5, 3));
        assert_eq!((s.canvas().width(), s.canvas().height()), (5, 3));
        assert!(s.canvas().parent_node().is_none(), "offscreen means never appended");
    }

    #[wasm_bindgen_test]
    fn a_web_surface_reads_what_the_context_painted() {
        let s = WebSurface::offscreen(4, 1).unwrap();
        fill(s.ctx(), "#ff0000", 0.0, 0.0, 2.0, 1.0);
        let px = s.read_rgba(0, 0, 4, 1).expect("readable");
        assert_eq!(px.len(), 16);
        assert_eq!(&px[0..4], &[255, 0, 0, 255], "painted red");
        assert_eq!(&px[4..8], &[255, 0, 0, 255]);
        assert_eq!(&px[12..16], &[0, 0, 0, 0], "unpainted: transparent");
        // and a sub-rect read is offset, not origin-anchored
        let one = s.read_rgba(3, 0, 1, 1).unwrap();
        assert_eq!(one, vec![0, 0, 0, 0]);
    }

    #[wasm_bindgen_test]
    fn a_web_surface_write_lands_in_the_pixels() {
        let s = WebSurface::offscreen(3, 1).unwrap();
        assert_eq!(s.write_rgba(1, 0, 1, 1, &[0, 255, 0, 255]), Some(()));
        assert_eq!(rgba_via_ctx(s.ctx(), 1.0, 0.0), [0, 255, 0, 255], "written green at x=1");
        assert_eq!(rgba_via_ctx(s.ctx(), 0.0, 0.0), [0, 0, 0, 0], "x=0 untouched");
    }

    #[wasm_bindgen_test]
    fn a_web_surface_refuses_a_rect_past_its_edge() {
        // The browser would silently pad a readback past the edge with
        // transparent pixels; the service contract is a refusal, so the
        // caller cannot mistake padding for pixels.
        let s = WebSurface::offscreen(2, 2).unwrap();
        assert_eq!(s.read_rgba(1, 0, 2, 1), None);
        assert_eq!(s.write_rgba(0, 1, 1, 2, &[0; 8]), None);
        assert_eq!(s.write_rgba(0, 0, 1, 1, &[0; 5]), None, "wrong byte count");
    }

    #[wasm_bindgen_test]
    fn destination_in_keeps_the_destination_only_under_the_source() {
        let dst = WebSurface::offscreen(8, 8).unwrap();
        fill(dst.ctx(), "#ff0000", 0.0, 0.0, 8.0, 8.0);
        let src = WebSurface::offscreen(8, 8).unwrap();
        fill(src.ctx(), "#0000ff", 0.0, 0.0, 4.0, 8.0); // left half only
        src.composite_onto(dst.ctx(), CompositeOp::DestinationIn, 1.0);
        assert_eq!(rgba_via_ctx(dst.ctx(), 1.0, 4.0), [255, 0, 0, 255],
                   "under the source: the destination's OWN colour survives");
        assert_eq!(rgba_via_ctx(dst.ctx(), 6.0, 4.0)[3], 0, "beside the source: cut");
    }

    #[wasm_bindgen_test]
    fn destination_out_erases_the_destination_under_the_source() {
        let dst = WebSurface::offscreen(8, 8).unwrap();
        fill(dst.ctx(), "#ff0000", 0.0, 0.0, 8.0, 8.0);
        let src = WebSurface::offscreen(8, 8).unwrap();
        fill(src.ctx(), "#0000ff", 0.0, 0.0, 4.0, 8.0);
        src.composite_onto(dst.ctx(), CompositeOp::DestinationOut, 1.0);
        assert_eq!(rgba_via_ctx(dst.ctx(), 1.0, 4.0)[3], 0, "under the source: erased");
        assert_eq!(rgba_via_ctx(dst.ctx(), 6.0, 4.0), [255, 0, 0, 255], "beside it: kept");
    }

    #[wasm_bindgen_test]
    fn a_normal_composite_at_half_alpha_lands_at_half() {
        let dst = WebSurface::offscreen(2, 2).unwrap();
        let src = WebSurface::offscreen(2, 2).unwrap();
        fill(src.ctx(), "#000000", 0.0, 0.0, 2.0, 2.0);
        src.composite_onto(dst.ctx(), CompositeOp::Blend(BlendMode::Normal), 0.5);
        let a = rgba_via_ctx(dst.ctx(), 1.0, 1.0)[3] as i32;
        assert!((a - 128).abs() <= 1, "half alpha composite, got {a}");
    }

    #[wasm_bindgen_test]
    fn a_composite_lands_in_device_space_whatever_the_destination_transform() {
        // The destination is panned; the source must still land pixel-for-pixel.
        let dst = WebSurface::offscreen(8, 1).unwrap();
        dst.ctx().translate(4.0, 0.0).ok();
        let src = WebSurface::offscreen(8, 1).unwrap();
        fill(src.ctx(), "#000000", 0.0, 0.0, 1.0, 1.0); // device pixel 0 only
        src.composite_onto(dst.ctx(), CompositeOp::Blend(BlendMode::Normal), 1.0);
        assert_eq!(rgba_via_ctx(dst.ctx(), 0.0, 0.0)[3], 255, "device (0,0), not (4,0)");
        assert_eq!(rgba_via_ctx(dst.ctx(), 4.0, 0.0)[3], 0);
    }

    #[wasm_bindgen_test]
    fn a_composite_restores_the_destination_state() {
        let dst = WebSurface::offscreen(8, 1).unwrap();
        dst.ctx().set_global_alpha(0.5);
        dst.ctx().translate(3.0, 0.0).ok();
        let src = WebSurface::offscreen(8, 1).unwrap();
        fill(src.ctx(), "#000000", 0.0, 0.0, 8.0, 1.0);
        src.composite_onto(dst.ctx(), CompositeOp::DestinationOut, 1.0);
        assert_eq!(dst.ctx().global_alpha(), 0.5, "alpha as it was");
        assert_eq!(dst.ctx().global_composite_operation().unwrap(), "source-over", "op as it was");
        // the transform is back too: a fill at the origin lands at x=3
        fill(dst.ctx(), "#00ff00", 0.0, 0.0, 1.0, 1.0);
        assert_eq!(rgba_via_ctx(dst.ctx(), 3.0, 0.0)[1], 255, "translate(3,0) survived");
        assert_eq!(rgba_via_ctx(dst.ctx(), 0.0, 0.0)[3], 0);
    }

    #[wasm_bindgen_test]
    fn luminance_promotion_on_a_real_canvas() {
        let s = WebSurface::offscreen(2, 1).unwrap();
        fill(s.ctx(), "#000000", 0.0, 0.0, 1.0, 1.0); // black opaque at x=0
        fill(s.ctx(), "#ffffff", 1.0, 0.0, 1.0, 1.0); // white opaque at x=1
        assert_eq!(promote_to_luminance(&s, 0, 0, 2, 1), Some(()));
        assert_eq!(rgba_via_ctx(s.ctx(), 0.0, 0.0)[3], 0, "black-opaque → transparent");
        assert_eq!(rgba_via_ctx(s.ctx(), 1.0, 0.0)[3], 255, "white-opaque → opaque");
    }

    #[wasm_bindgen_test]
    fn reset_clears_and_returns_to_identity() {
        let s = WebSurface::offscreen(4, 1).unwrap();
        fill(s.ctx(), "#ff0000", 0.0, 0.0, 4.0, 1.0);
        s.ctx().translate(2.0, 0.0).ok();
        s.ctx().set_global_alpha(0.25);
        s.ctx().set_global_composite_operation("destination-in").ok();
        s.reset();
        assert_eq!(rgba_via_ctx(s.ctx(), 0.0, 0.0)[3], 0, "cleared");
        assert_eq!(s.ctx().global_alpha(), 1.0);
        assert_eq!(s.ctx().global_composite_operation().unwrap(), "source-over");
        fill(s.ctx(), "#00ff00", 0.0, 0.0, 1.0, 1.0);
        assert_eq!(rgba_via_ctx(s.ctx(), 0.0, 0.0)[1], 255, "identity: lands at the origin");
        assert_eq!(rgba_via_ctx(s.ctx(), 2.0, 0.0)[3], 0);
    }

    #[wasm_bindgen_test]
    fn resize_at_the_same_size_keeps_the_pixels_and_at_a_new_size_takes_effect() {
        let s = WebSurface::offscreen(2, 2).unwrap();
        fill(s.ctx(), "#ff0000", 0.0, 0.0, 2.0, 2.0);
        s.resize(2, 2);
        assert_eq!(rgba_via_ctx(s.ctx(), 0.0, 0.0), [255, 0, 0, 255], "same size: untouched");
        s.resize(3, 2);
        assert_eq!(s.size(), (3, 2));
    }
}
