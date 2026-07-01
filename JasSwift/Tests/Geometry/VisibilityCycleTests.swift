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
}
