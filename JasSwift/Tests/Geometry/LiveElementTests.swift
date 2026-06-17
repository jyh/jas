import Testing
@testable import JasLib

/// Tests for the LiveElement framework — mirror jas_dioxus live.rs
/// tests.

private func rectAt(_ x: Double, _ y: Double) -> Element {
    .rect(Rect(x: x, y: y, width: 10, height: 10))
}

private func bboxOfRing(_ ring: BoolRing) -> (Double, Double, Double, Double) {
    let xs = ring.map { $0.0 }
    let ys = ring.map { $0.1 }
    return (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
}

@Test func elementToPolygonSetRect() {
    let ps = elementToPolygonSet(rectAt(0, 0), precision: DEFAULT_PRECISION)
    #expect(ps.count == 1)
}

@Test func compoundShapeUnionOfTwoRects() {
    let cs = CompoundShape(
        operation: .union,
        operands: [rectAt(0, 0), rectAt(5, 0)]
    )
    let polygons = cs.evaluate(precision: DEFAULT_PRECISION)
    #expect(polygons.count == 1)
    let (minX, _, maxX, _) = bboxOfRing(polygons[0])
    #expect(abs(minX - 0) < 1e-6)
    #expect(abs(maxX - 15) < 1e-6)
}

@Test func compoundShapeIntersection() {
    let cs = CompoundShape(
        operation: .intersection,
        operands: [rectAt(0, 0), rectAt(5, 0)]
    )
    let polygons = cs.evaluate(precision: DEFAULT_PRECISION)
    #expect(polygons.count == 1)
    let (minX, _, maxX, _) = bboxOfRing(polygons[0])
    #expect(abs(minX - 5) < 1e-6)
    #expect(abs(maxX - 10) < 1e-6)
}

@Test func compoundShapeExclude() {
    let cs = CompoundShape(
        operation: .exclude,
        operands: [rectAt(0, 0), rectAt(5, 0)]
    )
    let polygons = cs.evaluate(precision: DEFAULT_PRECISION)
    #expect(polygons.count == 2)
}

@Test func compoundShapeSubtractFront() {
    let cs = CompoundShape(
        operation: .subtractFront,
        operands: [rectAt(0, 0), rectAt(5, 0)]
    )
    let polygons = cs.evaluate(precision: DEFAULT_PRECISION)
    #expect(polygons.count == 1)
    let (minX, _, maxX, _) = bboxOfRing(polygons[0])
    #expect(abs(minX - 0) < 1e-6)
    #expect(abs(maxX - 5) < 1e-6)
}

@Test func compoundShapeBoundsReflectEvaluation() {
    let cs = CompoundShape(
        operation: .union,
        operands: [rectAt(0, 0), rectAt(5, 0)]
    )
    let (bx, by, bw, bh) = cs.bounds
    #expect(abs(bx - 0) < 1e-6)
    #expect(abs(by - 0) < 1e-6)
    #expect(abs(bw - 15) < 1e-6)
    #expect(abs(bh - 10) < 1e-6)
}

@Test func emptyCompoundHasEmptyBounds() {
    let cs = CompoundShape(operation: .union, operands: [])
    let (bx, by, bw, bh) = cs.bounds
    #expect(bx == 0 && by == 0 && bw == 0 && bh == 0)
}

@Test func expandProducesPolygonPerRing() {
    let red = Fill(color: Color(r: 1, g: 0, b: 0))
    let cs = CompoundShape(
        operation: .exclude,
        operands: [rectAt(0, 0), rectAt(5, 0)],
        fill: red
    )
    let expanded = cs.expand(precision: DEFAULT_PRECISION)
    #expect(expanded.count == 2)  // XOR → 2 rings → 2 polygons
    for e in expanded {
        if case .polygon(let p) = e {
            #expect(p.fill == red)
        } else {
            Issue.record("expected polygon element")
        }
    }
}

@Test func releaseReturnsOperandsVerbatim() {
    let r1 = rectAt(0, 0)
    let r2 = rectAt(5, 0)
    let cs = CompoundShape(operation: .union, operands: [r1, r2])
    let released = cs.release()
    #expect(released.count == 2)
}

@Test func pathFlattensIntoPolygonSet() {
    let path = Element.path(Path(d: [
        .moveTo(0, 0),
        .lineTo(10, 0),
        .lineTo(10, 10),
        .lineTo(0, 10),
        .closePath,
    ]))
    let ps = elementToPolygonSet(path, precision: DEFAULT_PRECISION)
    #expect(ps.count == 1)
}

// MARK: - ReferenceElem (REFERENCE_GRAPH.md Phase 1a)

/// A test resolver backed by an id→element map. Mirrors Rust `MapResolver`.
private struct MapResolver: ElementResolver {
    let map: [String: Element]
    func resolve(_ id: ElementRef) -> Element? { map[id.id] }
}

/// A resolver where id "a" resolves to a reference back to "a" — a
/// self-cycle. Mirrors Rust `CycleResolver`.
private struct CycleResolver: ElementResolver {
    func resolve(_ id: ElementRef) -> Element? {
        id.id == "a"
            ? .live(.reference(ReferenceElem(target: ElementRef("a"))))
            : nil
    }
}

@Test func referenceEvaluatesToTargetGeometry() {
    let resolver = MapResolver(map: ["r1": rectAt(0, 0)])
    let reference = ReferenceElem(target: ElementRef("r1"))
    var visiting = VisitSet()
    let ps = reference.evaluateWith(
        precision: DEFAULT_PRECISION, resolver: resolver, visiting: &visiting)
    #expect(ps.count == 1)  // resolves to the target rect's ring
    let (minX, _, maxX, _) = bboxOfRing(ps[0])
    #expect(abs(minX - 0) < 1e-6)
    #expect(abs(maxX - 10) < 1e-6)
    // The cycle-guard set is left clean after a successful resolve.
    #expect(visiting.isEmpty)
}

@Test func danglingReferenceEvaluatesEmpty() {
    let reference = ReferenceElem(target: ElementRef("missing"))
    var visiting = VisitSet()
    let ps = reference.evaluateWith(
        precision: DEFAULT_PRECISION, resolver: NullResolver(), visiting: &visiting)
    #expect(ps.isEmpty)  // dangling reference evaluates to empty, never traps
}

@Test func referenceCycleBreaksToEmpty() {
    let reference = ReferenceElem(target: ElementRef("a"))
    var visiting = VisitSet()
    let ps = reference.evaluateWith(
        precision: DEFAULT_PRECISION, resolver: CycleResolver(), visiting: &visiting)
    #expect(ps.isEmpty)  // cycle breaks to empty, no infinite recursion
    #expect(visiting.isEmpty)  // cycle-guard set is restored after evaluation
}

@Test func referenceReportsItsTargetAsDependency() {
    let reference = ReferenceElem(target: ElementRef("t"))
    #expect(reference.dependencies == [ElementRef("t")])
    let lv = LiveVariant.reference(reference)
    #expect(lv.dependencies == [ElementRef("t")])
    #expect(lv.operands.isEmpty)
}

@Test func referenceRoundTripsThroughElementToPolygonSet() {
    // elementToPolygonSetWith resolves a reference nested in a layer.
    let resolver = MapResolver(map: ["r1": rectAt(0, 0)])
    let reference = Element.live(.reference(ReferenceElem(target: ElementRef("r1"))))
    var visiting = VisitSet()
    let ps = elementToPolygonSetWith(
        reference, precision: DEFAULT_PRECISION, resolver: resolver, visiting: &visiting)
    #expect(ps.count == 1)
}

// MARK: - RebuildResolver (REFERENCE_GRAPH.md Phase 1b render wiring)

@Test func renderRefIndexResolvesReferenceToTarget() {
    // RebuildResolver builds the per-paint id→element index from the
    // document; the canvas reads it, so a reference resolves and evaluates
    // to its target's geometry (Phase 1b render wiring). Mirrors Rust
    // `render_ref_index_resolves_reference_to_target`.
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, id: "r1"))
    let doc = Document(layers: [Layer(name: "Layer", children: [rect])])
    let resolver = RebuildResolver(document: doc)
    // The index has the rect by its id.
    #expect(resolver.resolve(ElementRef("r1")) != nil)
    // A reference targeting "r1" evaluates to the rect's single ring.
    let reference = ReferenceElem(target: ElementRef("r1"))
    var visiting = VisitSet()
    let ps = reference.evaluateWith(
        precision: DEFAULT_PRECISION, resolver: resolver, visiting: &visiting)
    #expect(ps.count == 1)
    // An unindexed id resolves to nil (dangling).
    #expect(resolver.resolve(ElementRef("missing")) == nil)
}

@Test func rebuildIdIndexIndexesDescendantsAndSortedMasters() {
    // The pure builder (REFERENCE_GRAPH.md §2.3) indexes id-bearing layer
    // descendants and doc.symbols masters; top-level layers are skipped. This
    // is the single canonical walk shared by paint and the gate, so its result
    // must match what IdIndexResolver reads. Mirrors Rust
    // `rebuild_id_index_indexes_descendants_and_sorted_masters`.
    let rect = Element.rect(Rect(x: 0, y: 0, width: 10, height: 10, id: "r1"))
    // The layer carries an id; it must NOT be a resolution target.
    let layer = Layer(name: "layer0", children: [rect], id: "layer0")
    let master = Element.rect(Rect(x: 1, y: 2, width: 3, height: 4, id: "m1"))
    let doc = Document(layers: [layer], symbols: [master])

    let index = rebuildIdIndex(doc)
    #expect(index["r1"] != nil, "descendant rect is indexed by id")
    #expect(index["m1"] != nil, "master is indexed from doc.symbols")
    #expect(index["layer0"] == nil,
        "a top-level layer's own id is not a resolution target")
    // The persistent map equals itself rebuilt (the gate's equality used by the
    // Model) — and an IdIndexResolver over it resolves identically.
    #expect(index == rebuildIdIndex(doc), "rebuild is deterministic")
    let resolver = IdIndexResolver(index: index)
    #expect(resolver.resolve(ElementRef("r1")) != nil)
    #expect(resolver.resolve(ElementRef("m1")) != nil)
    // RebuildResolver delegates to the same walk, so its results match.
    let rebuild = RebuildResolver(document: doc)
    #expect(rebuild.resolve(ElementRef("r1")) == resolver.resolve(ElementRef("r1")))
    #expect(rebuild.resolve(ElementRef("m1")) == resolver.resolve(ElementRef("m1")))
}

// MARK: - Symbols P1: an instance resolves a master from doc.symbols

@Test func instanceResolvesToMasterGeometryFromSymbols() {
    // SYMBOLS.md §10 RESOLVE gate: the symbols_basic doc — ONE master rect
    // (id "m1") in doc.symbols and ONE instance (a ReferenceElem id "i1"
    // targeting "m1") in a layer. A resolver that indexes doc.symbols (as
    // RebuildResolver does) makes the instance evaluate to the master's
    // geometry — non-empty and equal to the rect's polygon set. This is the
    // whole point of the off-canvas store: masters are resolvable but never in
    // `layers`. Mirrors Rust `instance_resolves_to_master_geometry_from_symbols`.
    let masterRect = Rect(x: 9, y: 18, width: 27, height: 36, id: "m1")
    let instance = Element.live(.reference(ReferenceElem(target: ElementRef("m1"), id: "i1")))
    let doc = Document(
        layers: [Layer(name: "Layer", children: [instance])],
        symbols: [.rect(masterRect)])

    // RebuildResolver indexes doc.symbols (the symbols half): a master's OWN
    // id is the target. The master (off-canvas) resolves by its own id.
    let resolver = RebuildResolver(document: doc)
    #expect(resolver.resolve(ElementRef("m1")) != nil,
        "RebuildResolver must index masters from doc.symbols")

    // The instance evaluates to the master rect's single ring.
    var visiting = VisitSet()
    let resolved = elementToPolygonSetWith(
        instance, precision: DEFAULT_PRECISION, resolver: resolver, visiting: &visiting)
    #expect(!resolved.isEmpty, "instance must resolve to the master geometry")
    // Equal to evaluating the master rect directly. BoolPolygonSet is
    // [[(Double, Double)]] (tuples are not Equatable), so compare the rings
    // coordinate-by-coordinate.
    let masterPs = elementToPolygonSet(.rect(masterRect), precision: DEFAULT_PRECISION)
    #expect(resolved.count == masterPs.count,
        "instance resolves to the master rect's single ring")
    if resolved.count == masterPs.count {
        for (rr, mr) in zip(resolved, masterPs) {
            #expect(rr.count == mr.count)
            for (rp, mp) in zip(rr, mr) {
                #expect(rp.0 == mp.0 && rp.1 == mp.1,
                    "resolved instance geometry must equal the master rect's polygon set")
            }
        }
    }
    #expect(visiting.isEmpty, "cycle-guard set restored after resolve")

    // Masters are never painted: the master appears only in doc.symbols, never
    // in the layer tree (the off-canvas guarantee).
    #expect(doc.layers[0].children.count == 1, "layer holds only the instance")
    #expect(doc.symbols.count == 1, "the master lives only in doc.symbols")
}

// MARK: - Moving a reference (Make Instance; mirrors Rust element.rs
// move_reference_* / translate_reference_* tests).
//
// A reference has no geometry of its own; a whole-element move rides on
// its transform (the live render seam applies it). Swift's ReferenceElem
// carries a single `transform` field that plays the role of Rust's
// `common.transform`.

/// Build a bare reference to `target` with no transform.
private func bareReference(_ target: String) -> Element {
    .live(.reference(ReferenceElem(target: ElementRef(target))))
}

@Test func moveReferenceAllSetsTransform() {
    let r = bareReference("tgt")
    let moved = r.moveControlPoints(.all, dx: 24, dy: 24)
    guard case .live(.reference(let re)) = moved else {
        Issue.record("expected a Reference")
        return
    }
    let t = re.transform
    #expect(t != nil)
    #expect((t!.a, t!.b, t!.c, t!.d, t!.e, t!.f) == (1, 0, 0, 1, 24, 24))
}

@Test func moveReferenceComposesOntoExistingTransform() {
    // A second move composes onto the existing transform: the two
    // translations sum (translated() only touches e/f).
    let r = bareReference("tgt")
    let once = r.moveControlPoints(.all, dx: 10, dy: 5)
    let twice = once.moveControlPoints(.all, dx: 4, dy: 7)
    guard case .live(.reference(let re)) = twice else {
        Issue.record("expected a Reference")
        return
    }
    #expect((re.transform!.e, re.transform!.f) == (14, 12))
}

@Test func translateReferenceSetsTransform() {
    // translated() mirrors moveControlPoints for references: it rides on
    // the reference's transform too (used by paste / copy / group paths).
    let r = bareReference("tgt")
    let moved = r.translated(dx: 24, dy: 24)
    guard case .live(.reference(let re)) = moved else {
        Issue.record("expected a Reference")
        return
    }
    #expect((re.transform!.e, re.transform!.f) == (24, 24))
}

// MARK: - Symbols P4: the instance `transform` field (SYMBOLS.md §4 / Fork F2)
//
// Swift's ReferenceElem carries TWO transforms: `transform` plays Rust's
// render-only `common.transform` (the CTM), and `instanceTransform` plays
// Rust's instance `transform` field — the affine applied to the resolved
// geometry at eval time, so an instance can be mirrored/scaled relative to
// its master. Mirrors Rust live.rs reference_instance_transform_* tests.

@Test func referenceInstanceTransformScalesTargetGeometry() {
    // A reference whose instance `transform` is scale(2,2), targeting a 10x10
    // rect at the origin, evaluates to the rect geometry scaled 2x (a 20x20
    // ring). The instance transform is applied to every point of the resolved
    // PolygonSet (composition: instanceTransform ∘ geometry). Mirrors Rust
    // `reference_instance_transform_scales_target_geometry`.
    let resolver = MapResolver(map: ["r1": rectAt(0, 0)])
    var reference = ReferenceElem(target: ElementRef("r1"))
    reference.instanceTransform = Transform.scale(2, 2)
    var visiting = VisitSet()
    let scaled = reference.evaluateWith(
        precision: DEFAULT_PRECISION, resolver: resolver, visiting: &visiting)

    // Unscaled reference for comparison.
    let plain = ReferenceElem(target: ElementRef("r1"))
    let resolver2 = MapResolver(map: ["r1": rectAt(0, 0)])
    var visiting2 = VisitSet()
    let unscaled = plain.evaluateWith(
        precision: DEFAULT_PRECISION, resolver: resolver2, visiting: &visiting2)

    #expect(scaled.count == unscaled.count)  // same ring count, just scaled
    let (sminx, sminy, smaxx, smaxy) = bboxOfRing(scaled[0])
    let (uminx, uminy, umaxx, umaxy) = bboxOfRing(unscaled[0])
    #expect(abs(sminx - uminx * 2) < 1e-6)
    #expect(abs(sminy - uminy * 2) < 1e-6)
    #expect(abs(smaxx - umaxx * 2) < 1e-6)
    #expect(abs(smaxy - umaxy * 2) < 1e-6)
    // Concretely: the 10x10 rect at origin scales to a 20x20 box.
    #expect(abs(sminx - 0) < 1e-6 && abs(sminy - 0) < 1e-6)
    #expect(abs(smaxx - 20) < 1e-6 && abs(smaxy - 20) < 1e-6)
    #expect(visiting.isEmpty)
}

@Test func referenceNoneInstanceTransformLeavesEvalUnchanged() {
    // The default instance transform is nil; eval is identical to the resolved
    // target geometry (no transform applied, no double-apply). Mirrors Rust
    // `reference_none_instance_transform_leaves_eval_unchanged`.
    let resolver = MapResolver(map: ["r1": rectAt(0, 0)])
    let reference = ReferenceElem(target: ElementRef("r1"))
    #expect(reference.instanceTransform == nil, "instance transform defaults to nil")
    var visiting = VisitSet()
    let viaRef = reference.evaluateWith(
        precision: DEFAULT_PRECISION, resolver: resolver, visiting: &visiting)
    // Equal to evaluating the target rect directly, coordinate-by-coordinate
    // (BoolPolygonSet tuples are not Equatable).
    let direct = elementToPolygonSet(rectAt(0, 0), precision: DEFAULT_PRECISION)
    #expect(viaRef.count == direct.count,
        "nil instance transform leaves the resolved geometry unchanged")
    for (rr, dr) in zip(viaRef, direct) {
        #expect(rr.count == dr.count)
        for (rp, dp) in zip(rr, dr) {
            #expect(rp.0 == dp.0 && rp.1 == dp.1)
        }
    }
}
