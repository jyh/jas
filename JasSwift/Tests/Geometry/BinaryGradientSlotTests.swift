import Foundation
import Testing
@testable import JasLib

/// I1b, 2026-11-12: the fill and stroke gradients ride the last two slots of
/// every tag, as the canonical test-JSON gradient text. Session restore is
/// binary in both apps (`Canvas/Session.swift`), so before these slots a
/// gradient was lost on every quit and relaunch. Twin of jas_dioxus
/// `binary.rs` `every_carrier_keeps_both_gradients_through_binary` and the
/// reference's `BinaryGradientSlotTest`.

private let i1bLinear = Gradient(
    type: .linear, angle: 30, aspectRatio: 100, method: .classic, dither: false, strokeSubMode: .within,
    stops: [GradientStop(color: "#ff0000", opacity: 100, location: 20, midpointToNext: 40),
            GradientStop(color: "#0000ff", opacity: 40, location: 80)], nodes: [])
private let i1bRadial = Gradient(
    type: .radial, angle: 45, aspectRatio: 200, method: .smooth, dither: true, strokeSubMode: .across,
    stops: [GradientStop(color: "#00ff00", location: 0), GradientStop(color: "#ff00ff", opacity: 0, location: 100)],
    nodes: [])

private func i1bCarriers() -> [Element] {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><g>
      <rect x="0" y="0" width="1" height="2"/><ellipse cx="0" cy="0" rx="1" ry="2"/>
      <polyline points="0,0 1,1"/><polygon points="0,0 1,1 2,0"/><path d="M0 0 L1 1"/>
      <line x1="0" y1="0" x2="1" y2="1"/></g></svg>
    """
    return svgToDocument(svg).layers.first?.children ?? []
}

private func roundTrip(_ e: Element, compress: Bool = false) throws -> Element? {
    let doc = Document(layers: [Layer(children: [e])], selectedLayer: 0)
    return try binaryToDocument(documentToBinary(doc, compress: compress)).layers.first?.children.first
}

@Test func everyCarrierKeepsBothGradientsThroughBinary() throws {
    let carriers = i1bCarriers()
    #expect(carriers.count == 6, "the control: six carriers parsed")
    for c in carriers {
        let e = withFillGradient(withStrokeGradient(c, strokeGradient: i1bRadial), fillGradient: i1bLinear)
        let back = try roundTrip(e)
        #expect(back?.strokeGradient == i1bRadial, "\(e)")
        #expect(back?.fillGradient == e.fillGradient, "\(e)")
        #expect(back == e, "\(e)")
    }
}

@Test func aDocumentKeepsItsGradientsThroughTheSessionCodec() throws {
    let e = withFillGradient(withStrokeGradient(i1bCarriers()[0], strokeGradient: i1bRadial), fillGradient: i1bLinear)
    let back = try roundTrip(e, compress: true)
    #expect(back?.fillGradient == i1bLinear)
    #expect(back?.strokeGradient == i1bRadial)
}

/// A slot whose text is not JSON reads as no gradient rather than an error.
/// The corruption is one byte (`{` → `x`) inside the msgpack string, so the
/// framing stays valid and only the slot's content is bad.
@Test func anUnparsableGradientSlotReadsAsNone() throws {
    let e = withFillGradient(i1bCarriers()[0], fillGradient: i1bLinear)
    let doc = Document(layers: [Layer(children: [e])], selectedLayer: 0)
    var bytes = [UInt8](documentToBinary(doc, compress: false))
    let needle = Array("{\"angle\"".utf8)
    let hits = (0...(bytes.count - needle.count)).filter { Array(bytes[$0..<$0 + needle.count]) == needle }
    #expect(hits.count == 1, "the control: exactly one gradient slot in the blob")
    guard let at = hits.first else { return }
    bytes[at] = UInt8(ascii: "x")
    let back = try binaryToDocument(Data(bytes)).layers.first?.children.first
    #expect(back?.fillGradient == nil)
    #expect(back?.strokeGradient == nil)
}
