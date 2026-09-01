//! Caller-owned PIXEL SURFACES — the services a display-list `Painter` cannot
//! provide, and by ruling must not grow to provide.
//!
//! WHY THIS MODULE EXISTS. `canvas::render` — the web lane's legacy document
//! walk — reached the browser for three things a display list has no word for:
//! reading pixels back (`getImageData`), writing them (`putImageData`), and
//! compositing one canvas onto another (`drawImage`). Those were the
//! "unmappable" sites of `scripts/check_canvas_portability.py`. The 2026-08-31
//! ruling on the Painter trait (the helm, design word): THE TRAIT DOES NOT
//! GROW — a painter that answered metric queries, read pixels or composited
//! foreign surfaces would stop being a command list, and display-list
//! equivalence is what the cross-backend corpus rests on. So the sites LEAVE
//! `canvas/` as caller-owned services, and this is where they live.
//!
//! What is here is painter-generic: a [`PixelSurface`] is any RGBA8 raster
//! the caller owns, the luminance law is a pure byte transform, and
//! [`MemorySurface`] is a host-independent implementation used by the native
//! suite (and available to any host that needs an in-memory raster). The
//! browser implementation is [`web::WebSurface`], behind `feature = "web"`.
//!
//! ⛔ ONE COPY OF THE LUMINANCE LAW. Before this module the BT.601 promotion
//! lived in `canvas::render` and the web PAINTER reached into the legacy walk
//! for it — a backend depending on the web-only path it is meant to replace.
//! The law is here now; both callers use it; `painter/` references nothing
//! under `canvas/` (the portability gate asserts that).

use std::cell::RefCell;

/// An RGBA8 raster the caller owns. Coordinates and sizes are DEVICE pixels;
/// pixel data is row-major, 4 bytes per pixel, straight (non-premultiplied)
/// alpha, exactly the layout `ImageData` uses.
pub trait PixelSurface {
    /// Width and height in device pixels.
    fn size(&self) -> (u32, u32);
    /// Read the `w × h` rectangle at `(x, y)`. `None` when the rectangle does
    /// not lie inside the surface or the host cannot read pixels.
    fn read_rgba(&self, x: u32, y: u32, w: u32, h: u32) -> Option<Vec<u8>>;
    /// Write `rgba` (exactly `w * h * 4` bytes) into the `w × h` rectangle at
    /// `(x, y)`. `None` when the rectangle does not lie inside the surface,
    /// the byte count is wrong, or the host cannot write pixels.
    fn write_rgba(&self, x: u32, y: u32, w: u32, h: u32, rgba: &[u8]) -> Option<()>;
}

/// Replace each RGBA pixel's alpha with
/// `A' = A * (0.299*R + 0.587*G + 0.114*B) / 255` — the ITU-R BT.601 luma
/// weights, PDF §11's soft-mask convention: a black-opaque mask reads as fully
/// transparent, white-opaque as fully opaque, gray as partially opaque. Pure;
/// testable without any surface.
pub fn promote_bytes_to_luminance(_bytes: &mut [u8]) {
    todo!("promote_bytes_to_luminance: the law moves here from canvas::render")
}

/// Promote the alpha channel of `surface`'s pixels within the `w × h`
/// rectangle at `(x, y)` from raw alpha to luminance-scaled alpha (see
/// [`promote_bytes_to_luminance`]). Pixels OUTSIDE the rectangle are untouched.
/// A zero-area rectangle is a successful no-op. Returns `None` when the
/// surface cannot be read or written (the caller falls back to raw-alpha
/// masking so the mask still has *some* effect).
pub fn promote_to_luminance(
    _surface: &dyn PixelSurface,
    _x: u32,
    _y: u32,
    _w: u32,
    _h: u32,
) -> Option<()> {
    todo!("promote_to_luminance: read, apply the law, write back")
}

/// A host-independent RGBA8 raster. The native suite's surface; also the
/// shape any non-browser host can hand to the services here.
#[derive(Debug)]
pub struct MemorySurface {
    w: u32,
    h: u32,
    px: RefCell<Vec<u8>>,
}

impl MemorySurface {
    /// A transparent-black `w × h` surface.
    pub fn new(_w: u32, _h: u32) -> Self {
        todo!("MemorySurface::new")
    }

    /// Set every pixel to `rgba`.
    pub fn fill(&self, _rgba: [u8; 4]) {
        todo!("MemorySurface::fill")
    }

    /// The pixel at `(x, y)`; panics outside the surface (a test accessor).
    pub fn pixel(&self, _x: u32, _y: u32) -> [u8; 4] {
        todo!("MemorySurface::pixel")
    }
}

impl PixelSurface for MemorySurface {
    fn size(&self) -> (u32, u32) {
        (self.w, self.h)
    }

    fn read_rgba(&self, _x: u32, _y: u32, _w: u32, _h: u32) -> Option<Vec<u8>> {
        let _ = &self.px;
        todo!("MemorySurface::read_rgba")
    }

    fn write_rgba(&self, _x: u32, _y: u32, _w: u32, _h: u32, _rgba: &[u8]) -> Option<()> {
        todo!("MemorySurface::write_rgba")
    }
}

#[cfg(feature = "web")]
pub mod web;

#[cfg(test)]
mod tests {
    use super::*;

    // ── the surface ─────────────────────────────────────────────────────────

    #[test]
    fn a_memory_surface_round_trips_a_write() {
        let s = MemorySurface::new(4, 4);
        let block = [1u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16];
        assert_eq!(s.write_rgba(1, 1, 2, 2, &block), Some(()));
        assert_eq!(s.read_rgba(1, 1, 2, 2).as_deref(), Some(&block[..]));
        // the write landed where it was aimed, not at the origin
        assert_eq!(s.pixel(1, 1), [1, 2, 3, 4]);
        assert_eq!(s.pixel(2, 2), [13, 14, 15, 16]);
        assert_eq!(s.pixel(0, 0), [0, 0, 0, 0], "outside the write: untouched");
    }

    #[test]
    fn a_memory_surface_refuses_a_rect_past_its_edge() {
        let s = MemorySurface::new(4, 4);
        assert_eq!(s.read_rgba(3, 0, 2, 1), None, "read runs off the right edge");
        assert_eq!(s.read_rgba(0, 4, 1, 1), None, "read starts below the bottom");
        assert_eq!(s.write_rgba(0, 3, 1, 2, &[0; 8]), None, "write runs off the bottom");
        assert_eq!(s.write_rgba(0, 0, 1, 1, &[0; 3]), None, "wrong byte count");
        // and none of the refusals scribbled
        assert_eq!(s.pixel(3, 3), [0, 0, 0, 0]);
    }

    #[test]
    fn a_memory_surface_reports_its_size() {
        assert_eq!(MemorySurface::new(7, 3).size(), (7, 3));
    }

    // ── luminance promotion over a surface ──────────────────────────────────

    #[test]
    fn luminance_promotion_touches_only_the_rect() {
        // Opaque black everywhere: under the law its alpha becomes 0 — but
        // ONLY where the promotion was asked for.
        let s = MemorySurface::new(4, 4);
        s.fill([0, 0, 0, 255]);
        assert_eq!(promote_to_luminance(&s, 1, 1, 2, 2), Some(()));
        assert_eq!(s.pixel(1, 1)[3], 0, "inside the rect: black-opaque → transparent");
        assert_eq!(s.pixel(2, 2)[3], 0);
        assert_eq!(s.pixel(0, 0)[3], 255, "outside the rect: untouched");
        assert_eq!(s.pixel(3, 3)[3], 255);
        assert_eq!(s.pixel(3, 1)[3], 255);
    }

    #[test]
    fn luminance_promotion_on_a_surface_applies_the_bytes_law() {
        let s = MemorySurface::new(2, 1);
        assert_eq!(s.write_rgba(0, 0, 2, 1, &[128, 128, 128, 255, 255, 255, 255, 128]), Some(()));
        assert_eq!(promote_to_luminance(&s, 0, 0, 2, 1), Some(()));
        let mid = s.pixel(0, 0)[3] as i32;
        assert!((mid - 128).abs() <= 1, "mid-gray opaque → ~128, got {mid}");
        assert_eq!(s.pixel(1, 0)[3], 128, "white at half alpha keeps half alpha");
        assert_eq!(&s.pixel(0, 0)[..3], &[128, 128, 128], "RGB is never rewritten");
    }

    #[test]
    fn luminance_promotion_of_a_zero_rect_is_a_successful_no_op() {
        let s = MemorySurface::new(2, 2);
        s.fill([0, 0, 0, 255]);
        assert_eq!(promote_to_luminance(&s, 0, 0, 0, 2), Some(()));
        assert_eq!(promote_to_luminance(&s, 0, 0, 2, 0), Some(()));
        assert_eq!(s.pixel(0, 0)[3], 255, "nothing was promoted");
    }

    #[test]
    fn luminance_promotion_refuses_a_rect_the_surface_cannot_serve() {
        let s = MemorySurface::new(2, 2);
        s.fill([0, 0, 0, 255]);
        assert_eq!(promote_to_luminance(&s, 1, 1, 2, 2), None);
        assert_eq!(s.pixel(1, 1)[3], 255, "a refused promotion writes nothing");
    }

    // ── the law itself, moved here with its tests ───────────────────────────

    fn pixel(r: u8, g: u8, b: u8, a: u8) -> [u8; 4] { [r, g, b, a] }

    #[test]
    fn luminance_white_opaque_keeps_alpha() {
        let mut bytes = pixel(255, 255, 255, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 255);
    }

    #[test]
    fn luminance_black_opaque_drops_to_zero() {
        let mut bytes = pixel(0, 0, 0, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 0);
    }

    #[test]
    fn luminance_mid_gray_halves_alpha() {
        let mut bytes = pixel(128, 128, 128, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert!((bytes[3] as i32 - 128).abs() <= 1, "got {}", bytes[3]);
    }

    #[test]
    fn luminance_transparent_stays_transparent() {
        let mut bytes = pixel(255, 255, 255, 0).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 0);
    }

    #[test]
    fn luminance_respects_source_alpha() {
        let mut bytes = pixel(255, 255, 255, 128).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 128);
    }

    #[test]
    fn luminance_bt601_red_weight() {
        // Pure red (255,0,0) → luminance = 0.299 * 255 ≈ 76.
        let mut bytes = pixel(255, 0, 0, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert!((bytes[3] as i32 - 76).abs() <= 1, "got {}", bytes[3]);
    }

    #[test]
    fn luminance_bt601_green_weight() {
        // Pure green (0,255,0) → luminance = 0.587 * 255 ≈ 150.
        let mut bytes = pixel(0, 255, 0, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert!((bytes[3] as i32 - 150).abs() <= 1, "got {}", bytes[3]);
    }

    #[test]
    fn luminance_bt601_blue_weight() {
        // Pure blue (0,0,255) → luminance = 0.114 * 255 ≈ 29.
        let mut bytes = pixel(0, 0, 255, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert!((bytes[3] as i32 - 29).abs() <= 1, "got {}", bytes[3]);
    }

    #[test]
    fn luminance_multi_pixel_buffer() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&pixel(255, 255, 255, 255));
        bytes.extend_from_slice(&pixel(0, 0, 0, 255));
        bytes.extend_from_slice(&pixel(128, 128, 128, 255));
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 255);
        assert_eq!(bytes[7], 0);
        assert!((bytes[11] as i32 - 128).abs() <= 1);
    }
}
