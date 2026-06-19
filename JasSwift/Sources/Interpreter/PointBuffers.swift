// Named point buffers — the Swift analogue of
// jas_dioxus/src/interpreter/point_buffers.rs.
//
// Used by tools that accumulate a sequence of (x, y) points during a
// drag and consume the whole list on mouseup (Lasso for polygonal
// selection, Pencil for freehand path fitting). The tool state scope
// (`$tool.<id>.*`) is scalar-oriented, so these buffers live outside
// the StateStore in module-local storage.
//
// Exposed to YAML via:
//   effect  buffer.push:  { buffer, x, y }
//   effect  buffer.clear: { buffer }
//   primitive buffer_length("<name>") -> number
//   effect  doc.select_polygon_from_buffer: { buffer, additive }
//   effect  doc.add_path_from_buffer: { buffer, fit_error? }
//   overlay render type `buffer_polygon` / `buffer_polyline`

import Foundation

// Thread-local storage — the Swift analogue of Rust's `thread_local!`
// in point_buffers.rs. A drag (press → move* → release) runs entirely
// on one thread (the main thread in the app), so the buffer persists
// across the gesture. A plain process-global `var` would instead be
// shared across threads, which corrupts the swift-testing concurrent
// thread pool: two tests using the same buffer name (e.g. "pencil")
// would clobber each other's points and produce empty/zeroed paths.
// Mirroring Rust's thread-local design isolates each thread's buffers.
private let _bufferKey = "jas.pointBuffers"

private func _bufferStore() -> NSMutableDictionary {
    let dict = Thread.current.threadDictionary
    if let existing = dict[_bufferKey] as? NSMutableDictionary {
        return existing
    }
    let fresh = NSMutableDictionary()
    dict[_bufferKey] = fresh
    return fresh
}

/// Append a point to the named buffer (creates it on first push).
func pointBuffersPush(_ name: String, _ x: Double, _ y: Double) {
    let store = _bufferStore()
    var buf = (store[name] as? [(Double, Double)]) ?? []
    buf.append((x, y))
    store[name] = buf
}

/// Empty the named buffer. No-op if it doesn't exist.
func pointBuffersClear(_ name: String) {
    _bufferStore().removeObject(forKey: name)
}

/// Number of points in the named buffer. 0 if missing.
func pointBuffersLength(_ name: String) -> Int {
    (_bufferStore()[name] as? [(Double, Double)])?.count ?? 0
}

/// Borrow the named buffer's points as an array. Empty if missing.
func pointBuffersPoints(_ name: String) -> [(Double, Double)] {
    (_bufferStore()[name] as? [(Double, Double)]) ?? []
}
