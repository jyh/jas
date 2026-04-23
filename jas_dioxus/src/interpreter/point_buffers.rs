//! Thread-local named point buffers.
//!
//! Some tools need to accumulate a sequence of (x, y) points during a
//! drag and consume the whole list on mouseup (Lasso for polygonal
//! selection, Pencil for freehand path fitting). The tool state scope
//! (`$tool.<id>.*`) is scalar-oriented — a list would need nested
//! reads the evaluator can't easily traverse — so we keep these
//! buffers outside the scope in a thread-local namespace.
//!
//! Buffer names are free-form strings (conventionally the tool id:
//! `"lasso"`, `"pencil"`, …). Each buffer is an independent `Vec`.
//! Tools clear their buffer at the start of each drag; mismatched
//! tool-switch mid-drag leaves a stale buffer but never corrupts the
//! next drag since the next clear wipes it.
//!
//! Exposed to YAML handlers via:
//!   - effect  `buffer.push:  { buffer: "<name>", x: <expr>, y: <expr> }`
//!   - effect  `buffer.clear: { buffer: "<name>" }`
//!   - primitive `buffer_length("<name>")  -> number`
//!   - effect  `doc.select_polygon_from_buffer: { buffer, additive }`
//!   - overlay render type `buffer_polygon` (reads the named buffer)

use std::cell::RefCell;
use std::collections::HashMap;

thread_local! {
    static BUFFERS: RefCell<HashMap<String, Vec<(f64, f64)>>> =
        RefCell::new(HashMap::new());
}

/// Append a point to the named buffer, creating the buffer on first
/// write.
pub fn push(name: &str, x: f64, y: f64) {
    BUFFERS.with(|b| {
        b.borrow_mut()
            .entry(name.to_string())
            .or_default()
            .push((x, y));
    });
}

/// Empty the named buffer. No-op if it doesn't exist.
pub fn clear(name: &str) {
    BUFFERS.with(|b| {
        b.borrow_mut().remove(name);
    });
}

/// Number of points currently in the named buffer. Returns 0 if the
/// buffer has never been pushed to.
pub fn length(name: &str) -> usize {
    BUFFERS.with(|b| b.borrow().get(name).map(|v| v.len()).unwrap_or(0))
}

/// Run `f` with a borrowed view of the named buffer. The callback
/// receives an empty slice if the buffer doesn't exist, which lets
/// consumers write straight-line code without option-handling.
pub fn with_points<F, R>(name: &str, f: F) -> R
where
    F: FnOnce(&[(f64, f64)]) -> R,
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
    fn push_length_roundtrip() {
        clear("test_a");
        assert_eq!(length("test_a"), 0);
        push("test_a", 1.0, 2.0);
        push("test_a", 3.0, 4.0);
        assert_eq!(length("test_a"), 2);
        clear("test_a");
    }

    #[test]
    fn clear_removes_all_points() {
        push("test_b", 1.0, 2.0);
        assert!(length("test_b") > 0);
        clear("test_b");
        assert_eq!(length("test_b"), 0);
    }

    #[test]
    fn with_points_gives_stored_sequence() {
        clear("test_c");
        push("test_c", 1.0, 2.0);
        push("test_c", 3.0, 4.0);
        let got: Vec<(f64, f64)> =
            with_points("test_c", |pts| pts.to_vec());
        assert_eq!(got, vec![(1.0, 2.0), (3.0, 4.0)]);
        clear("test_c");
    }

    #[test]
    fn with_points_on_missing_buffer_is_empty_slice() {
        clear("test_d");
        let len = with_points("test_d", |pts| pts.len());
        assert_eq!(len, 0);
    }

    #[test]
    fn buffers_are_independent_by_name() {
        clear("test_e");
        clear("test_f");
        push("test_e", 1.0, 2.0);
        push("test_f", 10.0, 20.0);
        push("test_f", 30.0, 40.0);
        assert_eq!(length("test_e"), 1);
        assert_eq!(length("test_f"), 2);
        clear("test_e");
        clear("test_f");
    }
}
