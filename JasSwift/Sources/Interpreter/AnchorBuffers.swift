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

// Thread-local storage — the Swift analogue of Rust's `thread_local!`
// in anchor_buffers.rs. Same rationale as PointBuffers: a pen gesture
// runs on one thread, and a process-global `var` would be shared across
// the swift-testing concurrent thread pool, letting two tests using the
// same buffer name corrupt each other's anchors. Thread-local isolates
// per-thread buffers, matching Rust.
private let _anchorBufferKey = "jas.anchorBuffers"

private func _anchorBufferStore() -> NSMutableDictionary {
    let dict = Thread.current.threadDictionary
    if let existing = dict[_anchorBufferKey] as? NSMutableDictionary {
        return existing
    }
    let fresh = NSMutableDictionary()
    dict[_anchorBufferKey] = fresh
    return fresh
}

private func _anchorBufferGet(_ name: String) -> [PenAnchor] {
    (_anchorBufferStore()[name] as? [PenAnchor]) ?? []
}

func anchorBuffersPush(_ name: String, _ x: Double, _ y: Double) {
    let store = _anchorBufferStore()
    var buf = (store[name] as? [PenAnchor]) ?? []
    buf.append(.corner(x, y))
    store[name] = buf
}

func anchorBuffersPop(_ name: String) {
    let store = _anchorBufferStore()
    guard var buf = store[name] as? [PenAnchor], !buf.isEmpty else { return }
    buf.removeLast()
    if buf.isEmpty {
        store.removeObject(forKey: name)
    } else {
        store[name] = buf
    }
}

func anchorBuffersClear(_ name: String) {
    _anchorBufferStore().removeObject(forKey: name)
}

func anchorBuffersLength(_ name: String) -> Int {
    _anchorBufferGet(name).count
}

/// Update the last anchor's out-handle to (hx, hy), mirror the
/// in-handle for tangent continuity, and flip `smooth` to true.
/// No-op when the buffer is empty.
func anchorBuffersSetLastOutHandle(_ name: String, _ hx: Double, _ hy: Double) {
    let store = _anchorBufferStore()
    guard var buf = store[name] as? [PenAnchor], !buf.isEmpty else { return }
    var last = buf[buf.count - 1]
    last.hxOut = hx
    last.hyOut = hy
    last.hxIn = 2 * last.x - hx
    last.hyIn = 2 * last.y - hy
    last.smooth = true
    buf[buf.count - 1] = last
    store[name] = buf
}

/// First anchor, if any. Used by close-hit detection.
func anchorBuffersFirst(_ name: String) -> PenAnchor? {
    _anchorBufferGet(name).first
}

/// Borrow the buffer's anchors as an array.
func anchorBuffersAnchors(_ name: String) -> [PenAnchor] {
    _anchorBufferGet(name)
}
