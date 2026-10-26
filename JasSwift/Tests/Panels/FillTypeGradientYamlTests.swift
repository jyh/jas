import Foundation
import Testing
@testable import JasLib

// The fill/stroke widget's Gradient button runs its YAML
// (`set_fill_type_gradient` -> `doc.promote_to_gradient`, GRADIENT.md
// §Fill-type coupling): each selected member without a gradient on the active
// attribute takes its OWN seed (red -> [red, white], none -> [black, white]),
// a member holding one keeps it, the solid fill stays; ONE undo. With the
// stroke on top the stroke is promoted and the fill left alone. A second
// click has nothing to promote: the document is not edited.

private let red = Color(r: 1, g: 0, b: 0)

private func model(_ kids: [Element], fillOnTop: Bool = true) -> Model {
    let m = Model()
    m.setDocumentForTest(Document(layers: [Layer(children: kids)], selectedLayer: 0,
                                  selection: kids.indices.map { ElementSelection.all([0, $0]) }))
    m.fillOnTop = fillOnTop
    return m
}

@Test func setFillTypeGradientPromotesEachMemberFromItsOwnSeed() {
    let held = Gradient(type: .radial, angle: 30, stops: seedGradient(Color(r: 0, g: 0, b: 1)).stops)
    let m = model([.rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: Fill(color: red))),
                   .rect(Rect(x: 0, y: 0, width: 10, height: 10)),
                   .rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: Fill(color: red), fillGradient: held))])
    let before = m.document
    LayersPanel.dispatchYamlAction("set_fill_type_gradient", model: m)
    let kids = m.document.layers[0].children
    #expect(kids[0].fillGradient == seedGradient(red), "red promotes from red")
    #expect(kids[0].fill == before.layers[0].children[0].fill, "the solid fill stays: the demote target")
    #expect(kids[1].fillGradient == seedGradient(nil), "none promotes from black")
    #expect(kids[2].fillGradient == held, "a held gradient is kept")
    let generation = m.generation
    LayersPanel.dispatchYamlAction("set_fill_type_gradient", model: m)
    #expect(m.generation == generation, "nothing left to promote: the document is not edited")
    m.undo()
    #expect(m.document.layers == before.layers, "ONE undo")

    let s = model([.rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: Fill(color: red),
                              stroke: Stroke(color: red)))], fillOnTop: false)
    LayersPanel.dispatchYamlAction("set_fill_type_gradient", model: s)
    #expect(s.document.layers[0].children[0].strokeGradient == seedGradient(red), "the stroke on top")
    #expect(s.document.layers[0].children[0].fillGradient == nil, "the fill is not the active attribute")
}

// The builder and the op are guarded on their own, as in Rust: no op when
// promoting would change nothing, and the op on such a document edits nothing.
@Test func promoteToGradientBuildsAndAppliesNothingWhenNothingWouldChange() {
    let line = Element.line(Line(x1: 0, y1: 0, x2: 10, y2: 0))
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: Fill(color: red)))
    let graded = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: Fill(color: red),
                                   fillGradient: seedGradient(red)))
    func ops(_ e: Element, _ f: Bool) -> [Bool] {
        promoteToGradientOps(model([e]).document, fillOnTop: f).map { $0["fill_on_top"] as? Bool ?? !f }
    }
    #expect(ops(rect, true) == [true])
    #expect(ops(graded, true) == [], "already a gradient")
    #expect(ops(line, true) == [], "a line carries no fill gradient")
    #expect(ops(line, false) == [false], "but a stroke one")
    #expect(promoteToGradientOps(Document(layers: [Layer(children: [rect])], selectedLayer: 0, selection: []),
                                 fillOnTop: true).isEmpty, "nothing selected")
    let m = model([graded])
    let generation = m.generation
    _ = opApply(m, Controller(model: m), ["op": "promote_to_gradient", "fill_on_top": true])
    #expect(m.generation == generation, "nothing to promote: the document is not edited")
}

// The Color button demotes (`set_fill_type_solid` -> `doc.demote_to_solid`,
// then its null guard, GRADIENT.md §Demotion to solid): the gradient's FIRST
// stop becomes the solid, the fill's opacity kept, the gradient gone; ONE
// undo. The YAML's KNOWN LIMIT, as in Rust: a member with NO solid under its
// gradient ends on the null guard's black. The builder and the op are guarded
// on their own.
@Test func setFillTypeSolidDemotesAGradientToItsFirstStop() {
    let green = Color(r: 0, g: 1, b: 0), blue = Color(r: 0, g: 0, b: 1)
    let m = model([.rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: Fill(color: red, opacity: 0.5),
                              fillGradient: seedGradient(green)))])
    let before = m.document
    LayersPanel.dispatchYamlAction("set_fill_type_solid", model: m)
    let k = m.document.layers[0].children[0]
    #expect(k.fillGradient == nil, "the gradient goes")
    #expect(k.fill == Fill(color: green, opacity: 0.5), "the first stop, opacity kept")
    m.undo()
    #expect(m.document.layers == before.layers, "ONE undo")

    let bare = model([.rect(Rect(x: 0, y: 0, width: 10, height: 10, fillGradient: seedGradient(blue)))])
    LayersPanel.dispatchYamlAction("set_fill_type_solid", model: bare)
    #expect(bare.document.layers[0].children[0].fill?.color == Color(r: 0, g: 0, b: 0),
            "the KNOWN LIMIT: no solid under the gradient ends on the null guard's black")
    #expect(bare.document.layers[0].children[0].fillGradient == nil)

    let solid = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, fill: Fill(color: red)))
    #expect(demoteToSolidOps(model([solid]).document, fillOnTop: true).isEmpty, "solid already: no op")
    let s = model([solid])
    let generation = s.generation
    _ = opApply(s, Controller(model: s), ["op": "demote_to_solid", "fill_on_top": true])
    #expect(s.generation == generation, "nothing to demote: the document is not edited")
}
