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

private var _buffers: [String: [(Double, Double)]] = [:]

/// Append a point to the named buffer (creates it on first push).
func pointBuffersPush(_ name: String, _ x: Double, _ y: Double) {
    if _buffers[name] == nil {
        _buffers[name] = []
    }
    _buffers[name]?.append((x, y))
}

/// Empty the named buffer. No-op if it doesn't exist.
func pointBuffersClear(_ name: String) {
    _buffers.removeValue(forKey: name)
}

/// Number of points in the named buffer. 0 if missing.
func pointBuffersLength(_ name: String) -> Int {
    _buffers[name]?.count ?? 0
}

/// Borrow the named buffer's points as an array. Empty if missing.
func pointBuffersPoints(_ name: String) -> [(Double, Double)] {
    _buffers[name] ?? []
}
