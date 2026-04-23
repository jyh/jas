// Named Bezier-anchor buffers — the Swift analogue of
// jas_dioxus/src/interpreter/anchor_buffers.rs.
//
// Used by the Pen tool (and follow-on anchor-editing variants) where
// each accumulated entry has the anchor position plus incoming and
// outgoing handles plus a smooth/corner flag. Parallels PointBuffers
// but with richer per-entry state.
//
// Exposed to YAML via:
//   effect  anchor.push:          { buffer, x, y }  -> corner anchor
//   effect  anchor.set_last_out:  { buffer, hx, hy } -> smooth (mirrors in)
//   effect  anchor.pop:           { buffer }
//   effect  anchor.clear:         { buffer }
//   primitive anchor_buffer_length("<name>") -> number
//   primitive anchor_buffer_close_hit("<name>", x, y, r) -> bool
//   effect  doc.add_path_from_anchor_buffer: { buffer, closed, fill?, stroke? }
//   overlay render type `pen_overlay`

import Foundation

/// A single Bezier anchor — position plus incoming and outgoing tangent
/// handles, plus a smooth/corner flag.
public struct PenAnchor: Equatable {
    public var x: Double
    public var y: Double
    public var hxIn: Double
    public var hyIn: Double
    public var hxOut: Double
    public var hyOut: Double
    public var smooth: Bool

    /// Corner anchor — both handles coincide with the anchor position.
    public static func corner(_ x: Double, _ y: Double) -> PenAnchor {
        PenAnchor(x: x, y: y, hxIn: x, hyIn: y, hxOut: x, hyOut: y, smooth: false)
    }
}

private var _anchorBuffers: [String: [PenAnchor]] = [:]

func anchorBuffersPush(_ name: String, _ x: Double, _ y: Double) {
    if _anchorBuffers[name] == nil {
        _anchorBuffers[name] = []
    }
    _anchorBuffers[name]?.append(.corner(x, y))
}

func anchorBuffersPop(_ name: String) {
    _anchorBuffers[name]?.removeLast()
    if _anchorBuffers[name]?.isEmpty == true {
        _anchorBuffers.removeValue(forKey: name)
    }
}

func anchorBuffersClear(_ name: String) {
    _anchorBuffersRemove(name)
}

/// Private wrapper to keep the public name in plain `clear`.
private func _anchorBuffersRemove(_ name: String) {
    _anchorBuffers.removeValue(forKey: name)
}

func anchorBuffersLength(_ name: String) -> Int {
    _anchorBuffers[name]?.count ?? 0
}

/// Update the last anchor's out-handle to (hx, hy), mirror the
/// in-handle for tangent continuity, and flip `smooth` to true.
/// No-op when the buffer is empty.
func anchorBuffersSetLastOutHandle(_ name: String, _ hx: Double, _ hy: Double) {
    guard var buf = _anchorBuffers[name], !buf.isEmpty else { return }
    var last = buf[buf.count - 1]
    last.hxOut = hx
    last.hyOut = hy
    last.hxIn = 2 * last.x - hx
    last.hyIn = 2 * last.y - hy
    last.smooth = true
    buf[buf.count - 1] = last
    _anchorBuffers[name] = buf
}

/// First anchor, if any. Used by close-hit detection.
func anchorBuffersFirst(_ name: String) -> PenAnchor? {
    _anchorBuffers[name]?.first
}

/// Borrow the buffer's anchors as an array.
func anchorBuffersAnchors(_ name: String) -> [PenAnchor] {
    _anchorBuffers[name] ?? []
}
