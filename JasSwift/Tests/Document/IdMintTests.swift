import Testing
@testable import JasLib

/// THE ONE MINT LOOP, Swift half.
///
/// `mintUniqueIds` is the twin of Rust's `mint_unique_ids`
/// (`jas_dioxus/src/document/artboard.rs`); before it existed the same
/// retry loop was open-coded at seven sites in this port. These tests drive
/// the SAME per-char counter the corpus runners install (0,1,2,… so each
/// 8-char draw walks the base-36 alphabet in order) and assert the SAME
/// literal ids as the Rust tests, so neither the number of draws a batch
/// consumes nor the give-up behaviour can drift between the ports.

/// Install the corpus counter for the duration of `body`, then clear it.
private func withCorpusIdCounter<T>(_ body: () -> T) -> T {
    var ctr = 0
    setTestIdRng({ defer { ctr += 1 }; return ctr })
    defer { setTestIdRng(nil) }
    return body()
}

@Test func mintUniqueIdsBatchIsSequentialAndDistinct() {
    withCorpusIdCounter {
        var existing: Set<String> = []
        let ids = mintUniqueIds(3, existing: &existing,
                               mint: { generateElementId() })
        #expect(ids == ["01234567", "89abcdef", "ghijklmn"])
        // Every accepted id is folded back into `existing`, which is what
        // keeps one batch internally distinct.
        #expect(existing.count == 3)
        for id in ids ?? [] {
            #expect(existing.contains(id), "\(id) was not recorded in existing")
        }
    }
}

@Test func mintUniqueIdsSkipsATakenId() {
    withCorpusIdCounter {
        var existing: Set<String> = ["01234567"]
        // The FIRST draw collides with the taken id, so the loop redraws.
        let ids = mintUniqueIds(1, existing: &existing,
                               mint: { generateElementId() })
        #expect(ids == ["89abcdef"])
    }
}

@Test func mintUniqueIdsGivesUpAfterTheRetryBudget() {
    var existing: Set<String> = ["aaaaaaaa"]
    var draws = 0
    // A CONSTANT minter: every draw collides, so the budget is the only exit.
    // nil means the caller mints nothing and aborts.
    let ids = mintUniqueIds(1, existing: &existing, mint: {
        draws += 1
        return "aaaaaaaa"
    })
    #expect(ids == nil)
    #expect(draws == idMintRetryBudget)
}

@Test func mintUniqueIdsZeroCountIsAnEmptyBatch() {
    var existing: Set<String> = []
    var draws = 0
    let ids = mintUniqueIds(0, existing: &existing, mint: {
        draws += 1
        return "unused"
    })
    #expect(ids == [])
    #expect(draws == 0, "count 0 must not draw")
}

/// `elementIds` is the avoid-set every id mint is checked against, so it must
/// see NESTED elements and the off-canvas symbol masters, not just top-level
/// layer children. Rust's `Document::element_ids` is the twin.
@Test func elementIdsWalksNestingAndSymbolMasters() {
    let inner = Element.rect(Rect(x: 0, y: 0, width: 1, height: 1, id: "inner"))
    let group = Element.group(Group(children: [inner], id: "grp"))
    // An id-less sibling contributes nothing (and must not trip the walk).
    let bare = Element.line(Line(x1: 0, y1: 0, x2: 1, y2: 1))
    let layer = Layer(name: "L", children: [group, bare], id: "lyr")
    let master = Element.rect(Rect(x: 0, y: 0, width: 2, height: 2, id: "master"))
    let doc = Document(layers: [layer], symbols: [master],
                       selectedLayer: 0, selection: [])
    #expect(doc.elementIds.sorted() == ["grp", "inner", "lyr", "master"])
}

/// A compound shape OWNS its operands (`CompoundShape.operands` is `[Element]`),
/// and each operand is a real element carrying its own id. Those ids are part
/// of the document's id space (REFERENCE_GRAPH.md §2.5 uniqueness), so the mint
/// avoid-set must see them — otherwise a fresh mint can land on an operand id.
/// The walk must also keep recursing THROUGH an operand subtree (an operand
/// that is itself a group). Rust's `element_ids_sees_ids_inside_live_elements`
/// is the twin.
@Test func elementIdsSeesIdsInsideLiveElements() {
    // Operand 1 is a plain rect; operand 2 is a GROUP whose child also
    // carries an id, so the walk has to descend past the operand itself.
    let operandA = Element.rect(Rect(x: 0, y: 0, width: 1, height: 1, id: "op-a"))
    let nested = Element.rect(Rect(x: 2, y: 2, width: 1, height: 1, id: "op-b-inner"))
    let operandB = Element.group(Group(children: [nested], id: "op-b"))
    // An id-less operand contributes nothing (and must not trip the walk).
    let operandC = Element.line(Line(x1: 0, y1: 0, x2: 1, y2: 1))
    let compound = Element.live(.compoundShape(CompoundShape(
        operation: .union,
        operands: [operandA, operandB, operandC], name: nil,
        id: "cmp")))

    // The other three LiveVariant payloads own NO child elements — they name
    // their inputs by id — so each contributes exactly its own id.
    let reference = Element.live(.reference(ReferenceElem(
        target: ElementRef("op-a"), name: nil, id: "ref")))
    let recorded = Element.live(.recorded(RecordedElem(
        ops: [], inputs: [ElementRef("op-a")], name: nil, id: "rec")))
    let generated = Element.live(.generated(GeneratedElem(
        conceptId: "concept", params: [:], name: nil, id: "gen")))

    let layer = Layer(name: "L",
                      children: [compound, reference, recorded, generated],
                      id: "lyr")
    let doc = Document(layers: [layer], symbols: [],
                       selectedLayer: 0, selection: [])
    #expect(doc.elementIds.sorted()
            == ["cmp", "gen", "lyr", "op-a", "op-b", "op-b-inner", "rec", "ref"])
}
