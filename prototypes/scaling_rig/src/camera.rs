//! Deterministic animated camera.
//!
//! A continuous pan + zoom oscillation driven purely by elapsed seconds, so no
//! two consecutive frames are identical (defeats any trivial frame caching) yet
//! the motion is fully reproducible. The camera maps the large document plane
//! into the viewport, so most frames the whole plane is in view — worst-case
//! overdraw, no culling — which is what we want to stress.

use vello::kurbo::Affine;

use crate::scene::{DOC_H, DOC_W};

/// World -> screen transform at time `t` seconds for a `w`x`h` viewport.
pub fn camera(t: f64, w: u32, h: u32) -> Affine {
    let vw = w as f64;
    let vh = h as f64;

    // Base zoom fits the whole document plane into the viewport.
    let fit = (vw / DOC_W).min(vh / DOC_H);
    // Oscillate between ~0.85x and ~1.6x of fit so detail scale keeps changing.
    let zoom = fit * (0.85 + 0.75 * (0.5 + 0.5 * (t * 0.70).sin()));

    // Pan the focus point around the document on a Lissajous path.
    let focus_x = DOC_W * 0.5 + DOC_W * 0.25 * (t * 0.31).sin();
    let focus_y = DOC_H * 0.5 + DOC_H * 0.25 * (t * 0.23).cos();

    Affine::translate((vw * 0.5, vh * 0.5))
        * Affine::scale(zoom)
        * Affine::translate((-focus_x, -focus_y))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_and_moving() {
        // Same time => same transform; different time => different transform.
        assert_eq!(camera(1.0, 1600, 1000).as_coeffs(), camera(1.0, 1600, 1000).as_coeffs());
        assert_ne!(camera(1.0, 1600, 1000).as_coeffs(), camera(1.05, 1600, 1000).as_coeffs());
    }
}
