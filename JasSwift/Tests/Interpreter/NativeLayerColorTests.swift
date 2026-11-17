import Testing
import Foundation
@testable import JasLib

/// STATUS-jas row 146: the Mac native Layers tree draws a layer's STORED
/// colour (#962) and keeps the nine-colour index cycle only for a layer that
/// has none. Before, every top-level layer drew `layerColors[i % 9]`, so a
/// stored colour was drawn as a different one. `#ff8000` is no preset, so no
/// index can produce it by accident. Mirrors Rust's
/// `the_web_tree_draws_a_stored_layer_colour_and_cycles_only_without_one`.
@Test func nativeTreeDrawsAStoredLayerColourAndCyclesOnlyWithoutOne() {
    let stored = Element.layer(Layer(children: [], color: "#ff8000"))
    let plain = Element.layer(Layer(children: []))
    let group = Element.group(Group(children: []))
    #expect(rowLayerColor(stored, indexAtTop: 0, inherited: "") == "#ff8000", "the stored colour wins")
    #expect(rowLayerColor(stored, indexAtTop: nil, inherited: "#4a90d9") == "#ff8000",
            "a nested layer's stored colour wins over the inherited one")
    #expect(rowLayerColor(plain, indexAtTop: 1, inherited: "") == "#d94a4a",
            "a top-level layer with none keeps its index colour")
    #expect(rowLayerColor(plain, indexAtTop: nil, inherited: "#ff8000") == "#ff8000",
            "a nested layer with none inherits")
    #expect(rowLayerColor(group, indexAtTop: 0, inherited: "#ff8000") == "#ff8000",
            "a non-layer inherits even at the top")
}
