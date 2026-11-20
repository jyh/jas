/// A YAML container paints its `background`, whether declared in `style` or
/// bound in `bind` (row 190).
///
/// Found while fixing row 189: JasSwift's default YAML path
/// (`containerStyledBody`) drew a container's border and never its
/// background. Five of the nine containers in `workspace/` that declare one
/// are `bind.background` selection highlights (Layers, Artboards, Symbols,
/// Concepts), so a panel-selected row there showed no highlight on the Mac.
/// The arms render through `ImageRenderer` and read the centre pixel.

import Foundation
import Testing
import SwiftUI
import AppKit
@testable import JasLib

@MainActor
private func centrePixel(_ element: [String: Any], context: [String: Any]) -> (Int, Int, Int)? {
    let view = ZStack(alignment: .topLeading) {
        Rectangle().fill(Color.black)
        YamlElementView(element: element, context: context)
    }
    .frame(width: 40, height: 20, alignment: .topLeading)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1.0
    guard let img = renderer.cgImage else { return nil }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let i = ((h / 2) * w + w / 2) * 4
    return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
}

private func box(style extra: [String: Any] = [:], bind: [String: Any]? = nil) -> [String: Any] {
    var style: [String: Any] = ["width": 40, "height": 20]
    for (k, v) in extra { style[k] = v }
    var e: [String: Any] = ["type": "container", "layout": "row", "style": style, "children": [[String: Any]]()]
    if let b = bind { e["bind"] = b }
    return e
}

private func isRed(_ p: (Int, Int, Int)) -> Bool { p.0 > 200 && p.1 < 60 && p.2 < 60 }
private func isGreen(_ p: (Int, Int, Int)) -> Bool { p.1 > 200 && p.0 < 60 && p.2 < 60 }
private func isBlack(_ p: (Int, Int, Int)) -> Bool { p.0 < 20 && p.1 < 20 && p.2 < 20 }

@Suite("YAML container background (row 190)") @MainActor
struct YamlContainerBackgroundRenderTest {

    @Test("A style background paints")
    func styleBackgroundPaints() throws {
        let p = try #require(centrePixel(box(style: ["background": "#00ff00"]), context: [:]))
        #expect(isGreen(p), "centre pixel \(p), expected green")
    }

    @Test("A style background that is a template is evaluated")
    func styleBackgroundTemplatePaints() throws {
        let p = try #require(centrePixel(box(style: ["background": "{{c}}"]), context: ["c": "#ff0000"]))
        #expect(isRed(p), "centre pixel \(p), expected red")
    }

    @Test("A bound background paints (the selection highlight, selected)")
    func boundBackgroundPaints() throws {
        let e = box(bind: ["background": "if node.panel_selected then '#ff0000' else 'transparent'"])
        let p = try #require(centrePixel(e, context: ["node": ["panel_selected": true]]))
        #expect(isRed(p), "centre pixel \(p), expected red")
    }

    @Test("A bound 'transparent' paints nothing (unselected, the control)")
    func boundTransparentPaintsNothing() throws {
        let e = box(bind: ["background": "if node.panel_selected then '#ff0000' else 'transparent'"])
        let p = try #require(centrePixel(e, context: ["node": ["panel_selected": false]]))
        #expect(isBlack(p), "centre pixel \(p), expected the black ground")
    }

    @Test("A container with no background paints nothing (control)")
    func noBackgroundPaintsNothing() throws {
        let p = try #require(centrePixel(box(), context: [:]))
        #expect(isBlack(p), "centre pixel \(p), expected the black ground")
    }
}
