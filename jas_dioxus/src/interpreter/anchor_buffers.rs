//! Thread-local named buffers of Bezier anchor points.
//!
//! The point-buffer module (`point_buffers.rs`) holds plain `(x, y)`
//! tuples — enough for Lasso/Pencil. The Pen tool needs richer per-
//! entry state: each anchor has incoming and outgoing Bezier handles
//! plus a smooth/corner flag. Storing this inside the tool's YAML
//! state scope would require nested-field reads the evaluator can't
//! traverse naturally, so we keep anchor buffers parallel to point
//! buffers.
//!
//! Buffer names are free-form (conventionally the tool id:
//! `"pen"`). Each buffer is an independent `Vec<Anchor>`. Tools clear
//! their buffer at drag start and on tool-switch.
//!
//! Exposed to YAML via:
//!   - effect `anchor.push:           { buffer, x, y }`
//!   - effect `anchor.set_last_out:   { buffer, hx, hy }`  mirrors in-handle
//!   - effect `anchor.pop:            { buffer }`
//!   - effect `anchor.clear:          { buffer }`
//!   - primitive `anchor_buffer_length("<name>") -> number`
//!   - primitive `anchor_buffer_close_hit("<name>", x, y, radius) -> bool`
//!   - effect `doc.add_path_from_anchor_buffer: { buffer, closed }`
//!   - overlay render type `pen_overlay`

use std::cell::RefCell;
use std::collections::HashMap;

/// A single Bezier anchor — position plus the incoming and outgoing
/// tangent handles. `smooth` is `true` when the anchor was placed
/// with a drag (out-handle set explicitly); `false` for plain
/// click-placed corner anchors.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Anchor {
    pub x: f64,
    pub y: f64,
    pub hx_in: f64,
    pub hy_in: f64,
    pub hx_out: f64,
    pub hy_out: f64,
    pub smooth: bool,
}

impl Anchor {
    /// Construct a corner anchor at `(x, y)` — both handles coincide
    /// with the anchor position. Drag on mouse-down converts this
    /// into a smooth anchor via [`set_last_out_handle`].
    pub fn corner(x: f64, y: f64) -> Self {
        Self {
            x,
            y,
            hx_in: x,
            hy_in: y,
            hx_out: x,
            hy_out: y,
            smooth: false,
        }
    }
}

thread_local! {
    static BUFFERS: RefCell<HashMap<String, Vec<Anchor>>> =
        RefCell::new(HashMap::new());
}

pub fn push(name: &str, x: f64, y: f64) {
    BUFFERS.with(|b| {
        b.borrow_mut()
            .entry(name.to_string())
            .or_default()
            .push(Anchor::corner(x, y));
    });
}

pub fn pop(name: &str) {
    BUFFERS.with(|b| {
        if let Some(v) = b.borrow_mut().get_mut(name) {
            v.pop();
        }
    });
}

pub fn clear(name: &str) {
    BUFFERS.with(|b| {
        b.borrow_mut().remove(name);
    });
}

pub fn length(name: &str) -> usize {
    BUFFERS.with(|b| b.borrow().get(name).map(|v| v.len()).unwrap_or(0))
}

/// Update the last anchor's outgoing handle to `(hx, hy)`, and mirror
/// the incoming handle around the anchor so the curve through this
/// point is tangent-continuous. Flips `smooth` to true. No-op if the
/// buffer is empty.
pub fn set_last_out_handle(name: &str, hx: f64, hy: f64) {
    BUFFERS.with(|b| {
        if let Some(v) = b.borrow_mut().get_mut(name) {
            if let Some(last) = v.last_mut() {
                last.hx_out = hx;
                last.hy_out = hy;
                last.hx_in = 2.0 * last.x - hx;
                last.hy_in = 2.0 * last.y - hy;
                last.smooth = true;
            }
        }
    });
}

/// Return the first anchor, if any. Used by close-hit detection —
/// the user closes a Pen path by clicking near the starting anchor.
pub fn first(name: &str) -> Option<Anchor> {
    BUFFERS.with(|b| b.borrow().get(name).and_then(|v| v.first().copied()))
}

/// Run `f` with a borrowed view of the named buffer; empty slice
/// when the buffer doesn't exist.
pub fn with_anchors<F, R>(name: &str, f: F) -> R
where
    F: FnOnce(&[Anchor]) -> R,
{
    BUFFERS.with(|b| {
        let borrowed = b.borrow();
        f(borrowed.get(name).map(|v| v.as_slice()).unwrap_or(&[]))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_creates_corner_anchor() {
        clear("test_a");
        push("test_a", 10.0, 20.0);
        let a = first("test_a").unwrap();
        assert_eq!(a.x, 10.0);
        assert_eq!(a.y, 20.0);
        assert_eq!(a.hx_in, 10.0);
        assert_eq!(a.hy_in, 20.0);
        assert_eq!(a.hx_out, 10.0);
        assert_eq!(a.hy_out, 20.0);
        assert!(!a.smooth);
        clear("test_a");
    }

    #[test]
    fn set_last_out_handle_mirrors_in_handle() {
        clear("test_b");
        push("test_b", 50.0, 50.0);
        // Drag out-handle to (60, 50) — in-handle mirrors to (40, 50).
        set_last_out_handle("test_b", 60.0, 50.0);
        let a = with_anchors("test_b", |pts| pts[0]);
        assert_eq!(a.hx_out, 60.0);
        assert_eq!(a.hy_out, 50.0);
        assert_eq!(a.hx_in, 40.0);
        assert_eq!(a.hy_in, 50.0);
        assert!(a.smooth);
        clear("test_b");
    }

    #[test]
    fn pop_removes_last() {
        clear("test_c");
        push("test_c", 1.0, 2.0);
        push("test_c", 3.0, 4.0);
        assert_eq!(length("test_c"), 2);
        pop("test_c");
        assert_eq!(length("test_c"), 1);
        let kept = first("test_c").unwrap();
        assert_eq!((kept.x, kept.y), (1.0, 2.0));
        clear("test_c");
    }

    #[test]
    fn set_last_out_handle_on_empty_is_noop() {
        clear("test_d");
        set_last_out_handle("test_d", 10.0, 20.0);
        assert_eq!(length("test_d"), 0);
    }

    #[test]
    fn buffers_are_independent() {
        clear("test_e");
        clear("test_f");
        push("test_e", 1.0, 2.0);
        push("test_f", 10.0, 20.0);
        assert_eq!(length("test_e"), 1);
        assert_eq!(length("test_f"), 1);
        clear("test_e");
        clear("test_f");
    }
}
