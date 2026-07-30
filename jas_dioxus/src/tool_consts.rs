//! Shared tool constants — the numbers, with no frontend attached.
//!
//! These live at the crate root rather than in `tools::tool` because they are
//! plain scalars with no UI dependency, and `tools` is gated behind
//! `feature = "web"` (it imports `web_sys::CanvasRenderingContext2d`). Before
//! this split, reading `PASTE_OFFSET` required compiling the whole Dioxus tool
//! trait, so `document::controller`'s own test could not build natively — see
//! `scripts/check_native_core_tests.py` for the failure that prompted the move.
//!
//! `tools::tool` re-exports every name here, so `crate::tools::tool::PASTE_OFFSET`
//! keeps resolving in the web build and no call site changed.
//!
//! Forward-looking, not just a test repair: D1 (2026-07-29) rules that port six
//! keeps this core and grows a new native Windows frontend. That frontend needs
//! `HIT_RADIUS`, `DRAG_THRESHOLD` and `PASTE_OFFSET` and must not have to compile
//! a Dioxus tool trait to get them.

/// Pointer-to-geometry hit tolerance, in document units.
pub const HIT_RADIUS: f64 = 8.0;
/// Edge length of a drawn selection handle, in document units.
pub const HANDLE_DRAW_SIZE: f64 = 10.0;
/// Pointer travel before a press becomes a drag, in document units.
pub const DRAG_THRESHOLD: f64 = 4.0;
/// Offset applied to a pasted or duplicated element, in document units.
pub const PASTE_OFFSET: f64 = 24.0;
/// Default side count for the polygon tool.
pub const POLYGON_SIDES: usize = 5;
/// Default eraser radius, in document units.
pub const ERASER_SIZE: f64 = 2.0;
/// Default smooth-tool strength.
pub const SMOOTH_SIZE: f64 = 100.0;

#[cfg(test)]
mod tests {
    use super::*;

    // These pin the VALUES, not the types: each is a cross-port constant that
    // the shared spec and the conformance corpus both assume. They moved here
    // with the constants so they run in a native build too.

    #[test]
    fn hit_radius_value() {
        assert_eq!(HIT_RADIUS, 8.0);
    }

    #[test]
    fn handle_draw_size_value() {
        assert_eq!(HANDLE_DRAW_SIZE, 10.0);
    }

    #[test]
    fn drag_threshold_value() {
        assert_eq!(DRAG_THRESHOLD, 4.0);
    }

    #[test]
    fn paste_offset_value() {
        assert_eq!(PASTE_OFFSET, 24.0);
    }

    #[test]
    fn polygon_sides_value() {
        assert_eq!(POLYGON_SIDES, 5);
    }

    #[test]
    fn eraser_size_value() {
        assert_eq!(ERASER_SIZE, 2.0);
    }

    #[test]
    fn smooth_size_value() {
        assert_eq!(SMOOTH_SIZE, 100.0);
    }
}
