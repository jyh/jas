import Testing
@testable import JasLib

// MARK: - Phase 3: Higher-order functions (PHASE3.md §6.1)

@Test func hofAnyTrue() {
    let r = evaluate("any([1, 2, 3], fun n -> n > 2)", context: [:])
    #expect(r == .bool(true))
}

@Test func hofAnyFalse() {
    let r = evaluate("any([1, 2, 3], fun n -> n > 10)", context: [:])
    #expect(r == .bool(false))
}

@Test func hofAnyEmpty() {
    let r = evaluate("any([], fun n -> true)", context: [:])
    #expect(r == .bool(false))
}

@Test func hofAllTrue() {
    let r = evaluate("all([2, 4, 6], fun n -> n > 0)", context: [:])
    #expect(r == .bool(true))
}

@Test func hofAllFalse() {
    let r = evaluate("all([2, 4, 5], fun n -> n > 3)", context: [:])
    #expect(r == .bool(false))
}

@Test func hofAllEmpty() {
    let r = evaluate("all([], fun n -> false)", context: [:])
    #expect(r == .bool(true))
}

@Test func hofMap() {
    let r = evaluate("map([1, 2, 3], fun n -> n * 10)", context: [:])
    guard case .list(let items) = r else {
        Issue.record("expected list, got \(r)")
        return
    }
    #expect(items.count == 3)
}

@Test func hofFilter() {
    let r = evaluate("filter([1, 2, 3, 4, 5], fun n -> n > 2)", context: [:])
    guard case .list(let items) = r else {
        Issue.record("expected list, got \(r)")
        return
    }
    #expect(items.count == 3)
}

@Test func hofWithCapturedVariable() {
    let r = evaluate("filter([1, 2, 3, 4], fun n -> n > threshold)", context: ["threshold": 2])
    guard case .list(let items) = r else {
        Issue.record("expected list")
        return
    }
    #expect(items.count == 2)
}

// MARK: - Phase 3: Path value type (§6.2)

@Test func pathConstructor() {
    let r = evaluate("path(0, 2, 1)", context: [:])
    #expect(r == .path([0, 2, 1]))
}

@Test func pathConstructorEmpty() {
    let r = evaluate("path()", context: [:])
    #expect(r == .path([]))
}

@Test func pathDepth() {
    #expect(evaluate("path(0, 2, 1).depth", context: [:]) == .number(3))
    #expect(evaluate("path().depth", context: [:]) == .number(0))
}

@Test func pathParent() {
    #expect(evaluate("path(0, 2, 1).parent", context: [:]) == .path([0, 2]))
    #expect(evaluate("path().parent", context: [:]) == .null)
}

@Test func pathId() {
    #expect(evaluate("path(0, 2, 1).id", context: [:]) == .string("0.2.1"))
    #expect(evaluate("path().id", context: [:]) == .string(""))
}

@Test func pathEquality() {
    #expect(evaluate("path(0, 2) == path(0, 2)", context: [:]) == .bool(true))
    #expect(evaluate("path(0, 2) == path(0, 3)", context: [:]) == .bool(false))
    // Path vs List — distinct types
    #expect(evaluate("path(0, 2) == [0, 2]", context: [:]) == .bool(false))
}

@Test func pathChildFn() {
    #expect(evaluate("path_child(path(0, 2), 5)", context: [:]) == .path([0, 2, 5]))
}

@Test func pathFromIdFn() {
    #expect(evaluate("path_from_id('0.2.1')", context: [:]) == .path([0, 2, 1]))
    #expect(evaluate("path_from_id('')", context: [:]) == .path([]))
    #expect(evaluate("path_from_id('not-a-path')", context: [:]) == .null)
}

// MARK: - Phase 4: element_at(path)

@Test func elementAtReturnsTopLevelLayer() {
    let ctx: [String: Any] = [
        "active_document": [
            "top_level_layers": [
                ["kind": "Layer", "name": "A",
                 "common": ["visibility": "preview", "locked": false]],
            ],
        ],
    ]
    let r = evaluate("element_at(path(0)).name", context: ctx)
    #expect(r == .string("A"))
}

@Test func elementAtOutOfRangeReturnsNull() {
    let ctx: [String: Any] = [
        "active_document": [
            "top_level_layers": [
                ["kind": "Layer", "name": "A"],
            ],
        ],
    ]
    let r = evaluate("element_at(path(5))", context: ctx)
    #expect(r == .null)
}

@Test func elementAtNonPathArgReturnsNull() {
    let r = evaluate("element_at('oops')",
                     context: ["active_document": ["top_level_layers": []]])
    #expect(r == .null)
}

@Test func elementAtReadsCommonFields() {
    let ctx: [String: Any] = [
        "active_document": [
            "top_level_layers": [
                ["kind": "Layer", "name": "A",
                 "common": ["visibility": "outline", "locked": true]],
            ],
        ],
    ]
    #expect(evaluate("element_at(path(0)).common.visibility", context: ctx)
            == .string("outline"))
    #expect(evaluate("element_at(path(0)).common.locked", context: ctx)
            == .bool(true))
}

// MARK: - Phase 3: lexical scoping — closure captures shadowed binding (§4.4)

@Test func closureCapturesShadowedBinding() {
    // A closure captured under x=1 must see x=1 forever, even after let
    // x=2 shadows the outer binding. PHASE3.md §4.4 contract test.
    let r = evaluate(
        "let x = 1 in let f = fun _ -> x in let x = 2 in f(null)",
        context: [:]
    )
    #expect(r == .number(1))
}

@Test func closureNamespaceRefreshedAtCall() {
    // The closure reads a namespace (state.x) — this should come from the
    // caller's current context, not the stale captured one.
    let r = evaluate(
        "let f = fun _ -> state.x in f(null)",
        context: ["state": ["x": 42]]
    )
    #expect(r == .number(42))
}

// MARK: - brush_type_of(slug) — Blob Brush dialog gating helper

private func brushLibsCtx() -> [String: Any] {
    [
        "brush_libraries": [
            "mylib": [
                "brushes": [
                    ["slug": "cal_1", "name": "Cal 1", "type": "calligraphic", "size": 5.0],
                    ["slug": "art_1", "name": "Art 1", "type": "art"],
                ],
            ],
            "other": [
                "brushes": [
                    ["slug": "scat_1", "name": "Scat 1", "type": "scatter"],
                ],
            ],
        ],
    ]
}

@Test func brushTypeOfCalligraphic() {
    let r = evaluate("brush_type_of(\"mylib/cal_1\")", context: brushLibsCtx())
    #expect(r == .string("calligraphic"))
}

@Test func brushTypeOfArt() {
    let r = evaluate("brush_type_of(\"mylib/art_1\")", context: brushLibsCtx())
    #expect(r == .string("art"))
}

@Test func brushTypeOfOtherLibrary() {
    let r = evaluate("brush_type_of(\"other/scat_1\")", context: brushLibsCtx())
    #expect(r == .string("scatter"))
}

@Test func brushTypeOfUnknownSlugReturnsNull() {
    let r = evaluate("brush_type_of(\"mylib/missing\")", context: brushLibsCtx())
    #expect(r == .null)
}

@Test func brushTypeOfMissingLibraryReturnsNull() {
    let r = evaluate("brush_type_of(\"nowhere/cal_1\")", context: brushLibsCtx())
    #expect(r == .null)
}

@Test func brushTypeOfMalformedSlugReturnsNull() {
    // Missing slash.
    let r = evaluate("brush_type_of(\"just_a_slug\")", context: brushLibsCtx())
    #expect(r == .null)
}

@Test func brushTypeOfNullWhenNoBrushLibraries() {
    let r = evaluate("brush_type_of(\"mylib/cal_1\")", context: [:])
    #expect(r == .null)
}
