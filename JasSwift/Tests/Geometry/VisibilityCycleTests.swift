import Testing
@testable import JasLib

// Layers-panel eye-button visibility cycle. Visibility.cycled advances
// preview -> outline -> invisible -> preview, used by the tree-row eye
// button. Cross-app equivalent of OCaml Element.cycle_visibility, Python
// _cycle_visibility, Rust cycle_element_visibility.
@Suite struct VisibilityCycleTests {
    @Test func cycleOrder() {
        #expect(Visibility.preview.cycled == .outline)
        #expect(Visibility.outline.cycled == .invisible)
        #expect(Visibility.invisible.cycled == .preview)
    }

    @Test func fullLoopReturnsToStart() {
        #expect(Visibility.preview.cycled.cycled.cycled == .preview)
    }

    // Document.cyclingElementVisibility(at:) — the eye handler cycles the
    // element and drops it from the selection when it becomes Invisible.
    // Mirrors Rust cycle_element_visibility_at + OCaml/Python eye handlers.
    @Test func deselectOnInvisible() {
        let layer = Layer(children: [.rect(Rect(x: 0, y: 0, width: 10, height: 10))])
        let path: ElementPath = [0, 0]
        let doc = Document(layers: [layer], selectedLayer: 0,
                           selection: Set([ElementSelection.all(path)]))
        #expect(doc.selection.contains { $0.path == path })
        // Preview -> Outline: still selected.
        let d1 = doc.cyclingElementVisibility(at: path)
        #expect(d1.getElement(path).visibility == .outline)
        #expect(d1.selection.contains { $0.path == path })
        // Outline -> Invisible: deselected.
        let d2 = d1.cyclingElementVisibility(at: path)
        #expect(d2.getElement(path).visibility == .invisible)
        #expect(!d2.selection.contains { $0.path == path })
    }
}
