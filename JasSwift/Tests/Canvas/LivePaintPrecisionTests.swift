import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// Row 203: the canvas paints live geometry at the store's
/// `boolean_precision`, as the web's `render::render` does and the engine's
/// frame does (Rust `a_frame_paints_live_geometry_at_the_stores_boolean_precision`).
/// `draw(_:)` installs it with `withCanvasPaintPrecision`; these arms drive
/// that scope. A live union of two ELLIPSES (curves, so the flattening depends
/// on the precision; rects would not) gives different pixels at a coarse
/// precision than at the default, and the default again gives the default
/// pixels.

private let size = 120

private func renderBytes(_ elem: Element, precision: Double) -> [UInt8] {
    let bytes = size * size * 4
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes)
    defer { buf.deallocate() }
    buf.initialize(repeating: 0, count: bytes)
    let ctx = CGContext(
        data: buf, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    withCanvasPaintPrecision(precision) { drawElement(ctx, elem) }
    return Array(UnsafeBufferPointer(start: buf, count: bytes))
}

private let union = Element.live(.compoundShape(CompoundShape(
    operation: .union,
    operands: [.ellipse(Ellipse(cx: 40, cy: 60, rx: 35, ry: 35)),
               .ellipse(Ellipse(cx: 80, cy: 60, rx: 35, ry: 35))],
    name: nil,
    fill: Fill(color: Color(r: 0, g: 0, b: 0)))))

@Test func theCanvasPaintsLiveGeometryAtTheInstalledPrecision() {
    let atDefault = renderBytes(union, precision: DEFAULT_PRECISION)
    #expect(atDefault.contains { $0 != 0 }, "POSITIVE CONTROL: the union must paint")
    let coarse = renderBytes(union, precision: 8.0)
    #expect(coarse != atDefault, "a coarse precision paints different pixels")
    #expect(renderBytes(union, precision: DEFAULT_PRECISION) == atDefault,
            "the control: the default again paints the default pixels")
}

@Test func theCanvasPaintPrecisionReadsTheStoresBooleanPrecision() {
    let store = StateStore()
    #expect(canvasPaintPrecision(store: store) == DEFAULT_PRECISION, "absent, the default")
    store.set("boolean_precision", 0.5)
    #expect(canvasPaintPrecision(store: store) == 0.5)
}
