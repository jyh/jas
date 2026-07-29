import Testing
@testable import JasLib

/// UNGROUP ALL MUST PRESERVE WHAT IT DOES NOT SPEAK TO.
///
/// `Object → Ungroup All` speaks to exactly one thing: group nesting. Under the
/// Preservation Law (transcripts/EDIT_SEMANTICS_FREEZE.md) everything else in
/// the document — the artboards, the print preferences, a kept locked group's
/// name and identity, a layer's blend mode — is a bystander and must come back
/// unchanged.
///
/// Swift's body rebuilt three values field by field
/// (`Group(children:opacity:transform:locked:)`,
/// `Layer(name:children:opacity:transform:locked:)`,
/// `Document(layers:selectedLayer:selection:)`) against structs carrying 11, 11
/// and 8 stored properties. Every field not on those hand-written lists was
/// reset to its default: the Swift copy-site omission class
/// (EDIT_SEMANTICS_FREEZE.md §3.1), landing at a shipping menu action. Rust
/// never had it — `(**child).clone()` and `new_doc.layers = new_layers`
/// (`jas_dioxus/src/document/controller.rs:2348,2376`) mutate in place.
///
/// EVERY ASSERTION HERE IS BY VALUE, one field at a time. Whole-struct equality
/// or a `Mirror` walk would be structurally BLIND to this defect: both sides
/// would be built through the same truncated initializer and would agree with
/// each other while agreeing with nothing the artist set.
@Suite("Ungroup All preserves bystanders")
struct UngroupAllPreservationTests {

    private func rect(_ x: Double) -> Element {
        .rect(Rect(x: x, y: 0, width: 10, height: 10))
    }

    private func isRect(_ e: Element) -> Bool {
        if case .rect = e { return true }
        return false
    }

    private func isGroup(_ e: Element) -> Bool {
        if case .group = e { return true }
        return false
    }

    /// A group nest that GUARANTEES `changed == true`: an unlocked group with a
    /// rect inside. Ungroup All must flatten it away.
    private var nest: Element {
        .group(Group(children: [rect(1)]))
    }

    // MARK: - 1. Document-level state

    /// A document with artboards, artboard options, document setup and print
    /// preferences the artist chose must come back with all four untouched —
    /// plus its symbol masters and its active layer.
    ///
    /// RED before the fix: `Document(layers:selectedLayer:selection:)` names
    /// three of eight parameters, so `symbols`, `artboards`, `artboardOptions`,
    /// `documentSetup` and `printPreferences` all fell back to their defaults.
    /// Measured RED: `artboards.count` came back **0**, not even the default
    /// Letter board — the at-least-one-artboard invariant is seeded by
    /// `newEmptyDocument()`, not by the generic init, so Ungroup All left the
    /// document with NO artboard at all and reset the Print dialog.
    @Test func documentLevelStateSurvivesUngroupAll() {
        let master = Element.rect(Rect(x: 3, y: 4, width: 5, height: 6)).withId("master-1")
        let board = Artboard(id: "ab-keep", name: "Board Keep",
                             x: 11, y: 22, width: 333, height: 444,
                             showCenterMark: true)
        let doc = Document(
            layers: [Layer(name: "Base", children: [rect(0)]),
                     Layer(name: "Nested", children: [nest])],
            symbols: [master],
            selectedLayer: 1,
            selection: [],
            artboards: [board],
            artboardOptions: ArtboardOptions(fadeRegionOutsideArtboard: false,
                                             updateWhileDragging: false),
            documentSetup: DocumentSetup(bleedTop: 9, bleedRight: 8,
                                         bleedUniform: false,
                                         showImagesOutline: true,
                                         gridSize: 36.0),
            printPreferences: PrintPreferences(presetName: "Proof Sheet",
                                               copies: 7,
                                               collate: true,
                                               artboardRange: "2-4")
        )
        let model = Model(document: doc)
        MenuActions.ungroupAll(model)
        let out = model.document

        // The operation actually ran (guard against a vacuous pass).
        #expect(out.layers[1].children.count == 1)
        #expect(isRect(out.layers[1].children[0]))

        // Artboards — by value, field by field.
        #expect(out.artboards.count == 1)
        #expect(out.artboards.first?.id == "ab-keep")
        #expect(out.artboards.first?.name == "Board Keep")
        #expect(out.artboards.first?.x == 11)
        #expect(out.artboards.first?.y == 22)
        #expect(out.artboards.first?.width == 333)
        #expect(out.artboards.first?.height == 444)
        #expect(out.artboards.first?.showCenterMark == true)

        // Artboard display options.
        #expect(out.artboardOptions.fadeRegionOutsideArtboard == false)
        #expect(out.artboardOptions.updateWhileDragging == false)

        // Document Setup.
        #expect(out.documentSetup.bleedTop == 9)
        #expect(out.documentSetup.bleedRight == 8)
        #expect(out.documentSetup.bleedUniform == false)
        #expect(out.documentSetup.showImagesOutline == true)
        #expect(out.documentSetup.gridSize == 36.0)

        // Print preferences.
        #expect(out.printPreferences.presetName == "Proof Sheet")
        #expect(out.printPreferences.copies == 7)
        #expect(out.printPreferences.collate == true)
        #expect(out.printPreferences.artboardRange == "2-4")

        // Symbol masters (off-canvas store).
        #expect(out.symbols.count == 1)
        #expect(out.symbols.first?.id == "master-1")

        // The active layer, and the selection Ungroup All DOES speak to.
        #expect(out.selectedLayer == 1)
        #expect(out.selection.isEmpty)
    }

    // MARK: - 2. A kept locked group

    /// A LOCKED group is kept (only its children are flattened), so every one
    /// of its own attributes is a bystander.
    ///
    /// RED before the fix: the rebuild named `children`, `opacity`, `transform`
    /// and `locked` out of 11 stored properties, so a named, identified, masked
    /// locked group came back nameless, id-less, unmasked, `.preview`,
    /// `.normal`-blended, with both opacity flags cleared.
    @Test func lockedGroupKeepsEveryAttribute() {
        let mask = Mask(subtreeElement: .circle(Circle(cx: 1, cy: 2, r: 3)),
                        clip: false, invert: true)
        let keeper = Group(children: [nest, rect(50)],
                           opacity: 0.5,
                           transform: .translate(7, 8),
                           locked: true,
                           visibility: .outline,
                           blendMode: .multiply,
                           isolatedBlending: true,
                           knockoutGroup: true,
                           mask: mask,
                           name: "Keeper",
                           id: "g-keep")
        let model = Model(document: Document(
            layers: [Layer(name: "L", children: [.group(keeper)])],
            artboards: [Artboard(id: "ab-1")]))
        MenuActions.ungroupAll(model)

        guard case .group(let g) = model.document.layers[0].children[0] else {
            Issue.record("the locked group was not kept")
            return
        }
        // LOCKINHERIT (transcripts/LAYER_STRUCTURE.md §13): the kept group's
        // CONTENTS are locked too, so the nested group inside it survives as a
        // group. Before the ruling this asserted the opposite — the inner group
        // was dissolved while its locked parent was kept, which is the
        // one-level-deep reading inheritance replaces. `layerKeepsEveryAttribute`
        // is the positive control that ungroupAll still runs.
        #expect(g.children.count == 2)
        #expect(isGroup(g.children[0]),
                "a group inside a LOCKED group is locked, so it is left alone")
        #expect(isRect(g.children[1]))

        // Everything else, by value.
        #expect(g.name == "Keeper")
        #expect(g.id == "g-keep")
        #expect(g.locked == true)
        #expect(g.opacity == 0.5)
        #expect(g.transform == .translate(7, 8))
        #expect(g.visibility == .outline)
        #expect(g.blendMode == .multiply)
        #expect(g.isolatedBlending == true)
        #expect(g.knockoutGroup == true)
        #expect(g.mask?.clip == false)
        #expect(g.mask?.invert == true)
        #expect(g.mask?.subtree.count == 1)
    }

    // MARK: - 3. The layers themselves

    /// Every layer is rebuilt by Ungroup All whether or not it contained a
    /// group, so a layer's own attributes are bystanders too.
    ///
    /// RED before the fix: the rebuild named 5 of 11, so a layer came back with
    /// its `id` DESTROYED, its `visibility` reset to `.preview` (a hidden layer
    /// REAPPEARED), its blend mode reset and its mask dropped.
    @Test func layerKeepsEveryAttribute() {
        let mask = Mask(subtreeElement: .circle(Circle(cx: 4, cy: 5, r: 6)))
        let styled = Layer(name: "Styled", children: [nest],
                           opacity: 0.25,
                           transform: .scale(2, 3),
                           locked: false,
                           visibility: .outline,
                           blendMode: .screen,
                           isolatedBlending: true,
                           knockoutGroup: true,
                           mask: mask,
                           id: "lay-keep")
        let model = Model(document: Document(layers: [styled],
                                             artboards: [Artboard(id: "ab-1")]))
        MenuActions.ungroupAll(model)
        let l = model.document.layers[0]

        // The operation ran.
        #expect(l.children.count == 1)
        #expect(isRect(l.children[0]))

        #expect(l.name == "Styled")
        #expect(l.id == "lay-keep")
        #expect(l.opacity == 0.25)
        #expect(l.transform == .scale(2, 3))
        #expect(l.visibility == .outline)
        #expect(l.blendMode == .screen)
        #expect(l.isolatedBlending == true)
        #expect(l.knockoutGroup == true)
        #expect(l.mask?.subtree.count == 1)
        #expect(l.locked == false)
    }

    /// A LOCKED layer is rebuilt the same way and must keep its lock. Pinned
    /// separately because `locked` was the one flag the old rebuild happened to
    /// carry — this probe stays GREEN across the repair and proves the repair
    /// did not trade one dropped field for another.
    ///
    /// The fact it was written to pin — that a locked LAYER did NOT protect
    /// its contents, so the unlocked group inside one was dissolved anyway —
    /// was banked with the note "if lock becomes INHERITED, this assertion is
    /// what has to move, and it is written so the move is visible instead of
    /// silent". It became inherited (JYH, 2026-07-28,
    /// transcripts/LAYER_STRUCTURE.md §13), and it moved.
    @Test func lockedLayerStaysLocked() {
        let model = Model(document: Document(
            layers: [Layer(name: "Locked", children: [nest], locked: true)],
            artboards: [Artboard(id: "ab-1")]))
        MenuActions.ungroupAll(model)
        #expect(model.document.layers[0].locked == true)
        #expect(model.document.layers[0].children.count == 1)
        // The group inside a LOCKED layer is left alone, structure included.
        #expect(isGroup(model.document.layers[0].children[0]))
    }
}
