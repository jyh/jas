import Testing
@testable import JasLib

/// EDIT_SEMANTICS_FREEZE.md **T4 — THE BYSTANDER CLAUSE**: *an edit preserves,
/// unchanged, every element it does not name — including the containers it
/// rebuilds to reach its target.*
///
/// `BystanderContainerTests` watches the three `Document` path mutators.
/// This file watches the **Controller entry points that rebuild a container
/// inline instead of going through a mutator** — a class no per-copy-API
/// battery reaches, because an inline `Layer(...)` / `Group(...)` literal is
/// not a copy API (freeze §4.1). Seven such literals lived in
/// `Sources/Document/Controller.swift`, plus one inline `Document(...)`
/// rebuild, and none of the eight is reachable from any op verb in the shared
/// `op_apply` vocabulary — so the preservation corpus (which drives everything
/// through `op_apply`) is structurally blind to all of them and this per-port
/// battery is the only thing that can see them.
///
/// Rust's twins conform for free: `Controller::add_element` and friends reach
/// the layer with `layers[i].children_mut()`, so the parent's `common` is never
/// reconstructed, and `Document` is mutated field-wise rather than rebuilt.
///
/// EXHAUSTIVENESS METHOD (the same method as `BystanderContainerTests` and
/// `MovePathHandleFieldsTests`): the comparisons carry no hand-written field
/// list. They walk `Mirror(reflecting:)` and compare every stored property
/// except the one the edit is allowed to change (`children`, or `layers` for a
/// Document), so a field added to `Group`, `Layer` or `Document` tomorrow is
/// compared without editing this file. Two guards make the walk trustworthy:
///
///   * the ANTI-VACUITY GUARD — every fixture's every compared property is
///     asserted to differ from a default-constructed value's, because
///     "preserved" and "dropped" are indistinguishable for a field whose
///     fixture value IS the default; and
///   * the stored-property COUNT, which fires when a field is added so the
///     fixture can be given a non-default value for it.
///
/// Every structural assertion is paired with a GEOMETRY-VALUE assertion
/// (freeze §4): a field-list-free walk is structurally blind to where the
/// edit actually landed.

// MARK: - Fixtures

private func distinctMask(_ tag: Double) -> Mask {
    Mask(subtreeElement: .rect(Rect(x: tag, y: tag, width: 3, height: 4)),
         clip: false, invert: true, disabled: true, linked: false,
         unlinkTransform: Transform.translate(tag, tag))
}

private func rect(_ x: Double, _ id: String) -> Element {
    .rect(Rect(x: x, y: 0, width: 10, height: 10, id: id))
}

/// A Group whose EVERY field other than `children` is set away from its
/// default, so a dropped field is distinguishable from a preserved one.
private func fullyPopulatedGroup(children: [Element]) -> Group {
    Group(children: children,
          opacity: 0.37,
          transform: Transform.translate(3, 5),
          locked: true,
          visibility: .invisible,
          blendMode: .multiply,
          isolatedBlending: true,
          knockoutGroup: true,
          mask: distinctMask(11),
          name: "Cluster",
          id: "cluster")
}

/// A Layer whose EVERY field other than `children` is set away from its
/// default. Deliberately NOT `locked`/`invisible`-only: the whole point is that
/// every one of the eleven fields is observable.
private func fullyPopulatedLayer(children: [Element]) -> Layer {
    Layer(name: "Stage",
          children: children,
          opacity: 0.61,
          transform: Transform.translate(2, 9),
          locked: true,
          visibility: .outline,
          blendMode: .screen,
          isolatedBlending: true,
          knockoutGroup: true,
          mask: distinctMask(23),
          id: "stage")
}

/// A Document whose every field other than `layers` is away from its default,
/// so `addLayer`'s inline `Document(...)` rebuild cannot drop one invisibly.
private func fullyPopulatedDocument(children: [Element],
                                    selection: Selection = []) -> Document {
    Document(
        layers: [Layer(children: []), fullyPopulatedLayer(children: children)],
        symbols: [rect(99, "master")],
        selectedLayer: 1,
        selection: selection.isEmpty ? [ElementSelection.all([1, 0])] : selection,
        artboards: [Artboard(id: "ab1", name: "Board", x: 4, y: 5,
                             width: 100, height: 200)],
        artboardOptions: ArtboardOptions(fadeRegionOutsideArtboard: false,
                                         updateWhileDragging: false),
        documentSetup: DocumentSetup(bleedTop: 9),
        printPreferences: PrintPreferences(copies: 7)
    )
}

private func stageLayer(_ doc: Document) -> Layer { doc.layers[1] }

// MARK: - The Mirror comparison

/// Compare every stored property of `before` and `after` except those named in
/// `except`. Returns the labels it compared so the caller can assert the walk
/// was not silently vacuous (freeze §3.1(ii)).
@discardableResult
private func expectOnlyChanged<T>(_ before: T, _ after: T,
                                  except: Set<String>,
                                  _ what: String) -> [String] {
    let mb = Mirror(reflecting: before)
    let ma = Mirror(reflecting: after)
    #expect(mb.children.count > 0, "\(what): reflected zero stored properties")
    let beforeByLabel = Dictionary(uniqueKeysWithValues:
        mb.children.compactMap { c -> (String, String)? in
            guard let l = c.label else { return nil }
            return (l, String(describing: c.value))
        })
    var compared: [String] = []
    for child in ma.children {
        guard let label = child.label, !except.contains(label) else { continue }
        compared.append(label)
        #expect(String(describing: child.value) == beforeByLabel[label],
                "\(what) changed \(label)")
    }
    return compared
}

// MARK: - The anti-vacuity guard

@Test func controllerFixturesDifferFromDefaultInEveryComparedField() {
    let cases: [(String, Mirror, Mirror, Int, Set<String>)] = [
        ("Group", Mirror(reflecting: fullyPopulatedGroup(children: [])),
         Mirror(reflecting: Group(children: [])), 11, ["children"]),
        ("Layer", Mirror(reflecting: fullyPopulatedLayer(children: [])),
         Mirror(reflecting: Layer(children: [])), 11, ["children"]),
        ("Document", Mirror(reflecting: fullyPopulatedDocument(children: [])),
         Mirror(reflecting: Document(layers: [])), 8, ["layers"]),
    ]
    for (what, rich, plain, expectedCount, except) in cases {
        #expect(rich.children.count == expectedCount,
                """
                \(what)'s stored-property count changed. Give the new field a \
                NON-DEFAULT value in the fixture above — otherwise the Mirror \
                comparisons cannot tell "preserved" from "dropped" for it — \
                then update this count.
                """)
        let plainByLabel = Dictionary(uniqueKeysWithValues:
            plain.children.compactMap { c -> (String, String)? in
                guard let l = c.label else { return nil }
                return (l, String(describing: c.value))
            })
        for child in rich.children {
            guard let label = child.label, !except.contains(label) else { continue }
            #expect(String(describing: child.value) != plainByLabel[label],
                    "\(what).\(label) is at its default in the fixture — a drop of that field would be invisible to the Mirror walk")
        }
    }
}

// MARK: - addElement (content mode)

@Test func addElementPreservesEveryFieldOfTheTargetLayer() {
    let doc = fullyPopulatedDocument(children: [rect(0, "alpha")])
    let model = Model(document: doc)
    Controller(model: model).addElement(rect(40, "gamma"))
    let after = model.document

    // GEOMETRY-VALUE pairing: the element really was appended, in place.
    #expect(stageLayer(after).children.count == 2)
    guard case .rect(let r) = after.getElement([1, 1]) else {
        Issue.record("appended element is not a Rect"); return
    }
    #expect(r.id == "gamma" && r.x == 40)

    let compared = expectOnlyChanged(stageLayer(doc), stageLayer(after),
                                     except: ["children"],
                                     "addElement into a layer")
    #expect(compared.count == 10, "compared \(compared.count) Layer fields: \(compared)")
}

// MARK: - addElement (mask-editing mode)

@Test func addElementIntoAMaskPreservesEveryFieldOfTheMaskSubtreeGroup() {
    let masked = withMask(rect(0, "alpha"),
                          mask: Mask(subtreeElement:
                                        .group(fullyPopulatedGroup(children: [])),
                                     clip: false, invert: true, disabled: true,
                                     linked: false,
                                     unlinkTransform: Transform.translate(7, 7)))
    let doc = fullyPopulatedDocument(children: [masked])
    let model = Model(document: doc)
    model.editingTarget = .mask([1, 0])
    Controller(model: model).addElement(rect(40, "gamma"))
    let after = model.document

    func subtreeGroup(_ d: Document) -> Group? {
        guard let m = d.getElement([1, 0]).mask,
              case .group(let g) = m.subtreeElement else { return nil }
        return g
    }
    guard let gb = subtreeGroup(doc), let ga = subtreeGroup(after) else {
        Issue.record("mask subtree is not a Group"); return
    }

    // GEOMETRY-VALUE pairing: the stroke landed INSIDE the mask, not on the
    // layer (the fall-through path), and it landed where it was drawn.
    #expect(ga.children.count == 1)
    #expect(stageLayer(after).children.count == 1,
            "the element leaked out of the mask onto the layer")
    guard case .rect(let r) = ga.children[0] else {
        Issue.record("mask child is not a Rect"); return
    }
    #expect(r.id == "gamma" && r.x == 40)

    let compared = expectOnlyChanged(gb, ga, except: ["children"],
                                     "addElement into a mask subtree")
    #expect(compared.count == 10, "compared \(compared.count) Group fields: \(compared)")
}

// MARK: - group / ungroup

@Test func groupSelectionPreservesEveryFieldOfTheEnclosingLayer() {
    let doc = fullyPopulatedDocument(
        children: [rect(0, "alpha"), rect(20, "beta")],
        selection: [ElementSelection.all([1, 0]), ElementSelection.all([1, 1])])
    let model = Model(document: doc)
    Controller(model: model).groupSelection()
    let after = model.document

    // GEOMETRY-VALUE pairing: one group now holds both rects, at their coords.
    #expect(stageLayer(after).children.count == 1)
    guard case .group(let g) = after.getElement([1, 0]) else {
        Issue.record("the wrapper is not a Group"); return
    }
    #expect(g.children.count == 2)
    guard case .rect(let r0) = g.children[0], case .rect(let r1) = g.children[1] else {
        Issue.record("wrapped children are not Rects"); return
    }
    #expect(r0.x == 0 && r0.id == "alpha")
    #expect(r1.x == 20 && r1.id == "beta")

    let compared = expectOnlyChanged(stageLayer(doc), stageLayer(after),
                                     except: ["children"],
                                     "groupSelection inside a layer")
    #expect(compared.count == 10, "compared \(compared.count) Layer fields: \(compared)")
}

@Test func ungroupSelectionPreservesEveryFieldOfTheEnclosingLayer() {
    let inner = Element.group(Group(children: [rect(0, "alpha"), rect(20, "beta")],
                                    id: "inner"))
    let doc = fullyPopulatedDocument(children: [inner],
                                     selection: [ElementSelection.all([1, 0])])
    let model = Model(document: doc)
    Controller(model: model).ungroupSelection()
    let after = model.document

    // GEOMETRY-VALUE pairing: both children are now direct layer children, at
    // their original coordinates and with their own ids.
    #expect(stageLayer(after).children.count == 2)
    guard case .rect(let r0) = after.getElement([1, 0]),
          case .rect(let r1) = after.getElement([1, 1]) else {
        Issue.record("released children are not Rects"); return
    }
    #expect(r0.x == 0 && r0.id == "alpha")
    #expect(r1.x == 20 && r1.id == "beta")

    let compared = expectOnlyChanged(stageLayer(doc), stageLayer(after),
                                     except: ["children"],
                                     "ungroupSelection inside a layer")
    #expect(compared.count == 10, "compared \(compared.count) Layer fields: \(compared)")
}

// MARK: - the compound-shape lifecycle

private func overlappingRects() -> [Element] {
    [.rect(Rect(x: 0, y: 0, width: 20, height: 20, id: "alpha")),
     .rect(Rect(x: 10, y: 0, width: 20, height: 20, id: "beta"))]
}

@Test func makeCompoundShapePreservesEveryFieldOfTheEnclosingLayer() {
    let doc = fullyPopulatedDocument(
        children: overlappingRects(),
        selection: [ElementSelection.all([1, 0]), ElementSelection.all([1, 1])])
    let model = Model(document: doc)
    Controller(model: model).makeCompoundShape()
    let after = model.document

    // GEOMETRY-VALUE pairing: one live compound now holds both operands.
    #expect(stageLayer(after).children.count == 1)
    guard case .live(.compoundShape(let cs)) = after.getElement([1, 0]) else {
        Issue.record("the wrapper is not a compound shape"); return
    }
    #expect(cs.operands.count == 2)
    guard case .rect(let r0) = cs.operands[0] else {
        Issue.record("operand is not a Rect"); return
    }
    #expect(r0.x == 0 && r0.id == "alpha")

    let compared = expectOnlyChanged(stageLayer(doc), stageLayer(after),
                                     except: ["children"],
                                     "makeCompoundShape inside a layer")
    #expect(compared.count == 10, "compared \(compared.count) Layer fields: \(compared)")
}

private func documentWithCompound() -> Document {
    let cs = CompoundShape(operation: .union, operands: overlappingRects(),
                           id: "cs1")
    return fullyPopulatedDocument(children: [.live(.compoundShape(cs))],
                                  selection: [ElementSelection.all([1, 0])])
}

@Test func releaseCompoundShapePreservesEveryFieldOfTheEnclosingLayer() {
    let doc = documentWithCompound()
    let model = Model(document: doc)
    Controller(model: model).releaseCompoundShape()
    let after = model.document

    // GEOMETRY-VALUE pairing: the operands are back as siblings, unmoved.
    #expect(stageLayer(after).children.count == 2)
    guard case .rect(let r0) = after.getElement([1, 0]),
          case .rect(let r1) = after.getElement([1, 1]) else {
        Issue.record("released operands are not Rects"); return
    }
    #expect(r0.x == 0 && r0.id == "alpha")
    #expect(r1.x == 10 && r1.id == "beta")

    let compared = expectOnlyChanged(stageLayer(doc), stageLayer(after),
                                     except: ["children"],
                                     "releaseCompoundShape inside a layer")
    #expect(compared.count == 10, "compared \(compared.count) Layer fields: \(compared)")
}

@Test func expandCompoundShapePreservesEveryFieldOfTheEnclosingLayer() {
    let doc = documentWithCompound()
    let model = Model(document: doc)
    Controller(model: model).expandCompoundShape()
    let after = model.document

    // GEOMETRY-VALUE pairing: the union of [0,20]x[0,20] and [10,30]x[0,20] is
    // one ring spanning x in [0,30] — the expansion really evaluated the
    // boolean rather than dropping the compound on the floor.
    #expect(stageLayer(after).children.count == 1)
    let bounds = after.getElement([1, 0]).bounds
    #expect(bounds.x == 0)
    #expect(bounds.width == 30)

    let compared = expectOnlyChanged(stageLayer(doc), stageLayer(after),
                                     except: ["children"],
                                     "expandCompoundShape inside a layer")
    #expect(compared.count == 10, "compared \(compared.count) Layer fields: \(compared)")
}

// MARK: - the nested-Layer arms the corpus fixture cannot reach

// `unlockChildren` and `showIn` each carry a `.layer` arm for a Layer nested
// inside another Layer. The preservation corpus's setup SVG has no
// Layer-inside-Layer, so its vectors exercise those two arms' failure mode only
// via the top-level layer map — a different line. These two tests are the only
// thing watching the arms themselves.

@Test func unlockAllPreservesEveryFieldOfANestedLayer() {
    let nested = Element.layer(fullyPopulatedLayer(children: [
        .rect(Rect(x: 0, y: 0, width: 10, height: 10, locked: true, id: "alpha"))
    ]))
    let doc = Document(layers: [Layer(children: [nested], locked: true)])
    let model = Model(document: doc)
    Controller(model: model).unlockAll()
    let after = model.document

    guard case .layer(let lb) = doc.getElement([0, 0]),
          case .layer(let la) = after.getElement([0, 0]) else {
        Issue.record("the nested layer is gone"); return
    }
    // GEOMETRY-VALUE pairing: the unlock reached the nested layer AND the leaf
    // inside it, and the leaf is still where it was.
    #expect(la.locked == false, "the nested layer was not unlocked")
    guard case .rect(let r) = after.getElement([0, 0, 0]) else {
        Issue.record("the leaf is not a Rect"); return
    }
    #expect(r.locked == false && r.x == 0 && r.id == "alpha")

    let compared = expectOnlyChanged(lb, la, except: ["children", "locked"],
                                     "unlockAll over a nested layer")
    #expect(compared.count == 9, "compared \(compared.count) Layer fields: \(compared)")
}

@Test func showAllPreservesEveryFieldOfANestedLayer() {
    // The nested layer's own visibility is `.outline`, which show-all leaves
    // alone (only `.invisible` is reset) — so here EVERY field including
    // `visibility` is a bystander field, and the invisible leaf inside it is
    // what makes the walk do work.
    let nested = Element.layer(fullyPopulatedLayer(children: [
        .rect(Rect(x: 0, y: 0, width: 10, height: 10,
                   visibility: .invisible, id: "alpha"))
    ]))
    let doc = Document(layers: [Layer(children: [nested])])
    let model = Model(document: doc)
    Controller(model: model).showAll()
    let after = model.document

    guard case .layer(let lb) = doc.getElement([0, 0]),
          case .layer(let la) = after.getElement([0, 0]) else {
        Issue.record("the nested layer is gone"); return
    }
    // GEOMETRY-VALUE pairing: the show reached the leaf inside the nested
    // layer, and left it where it was.
    guard case .rect(let r) = after.getElement([0, 0, 0]) else {
        Issue.record("the leaf is not a Rect"); return
    }
    #expect(r.visibility == .preview, "the nested leaf was not shown")
    #expect(r.x == 0 && r.id == "alpha")

    let compared = expectOnlyChanged(lb, la, except: ["children"],
                                     "showAll over a nested layer")
    #expect(compared.count == 10, "compared \(compared.count) Layer fields: \(compared)")
}

// MARK: - addLayer: the Document is a bystander container too

/// `addLayer` speaks to `layers`. The inline `Document(...)` it rebuilt passed
/// five of eight fields, so the off-canvas symbol masters (SYMBOLS.md §6), the
/// Document Setup record and the Print preferences were erased every time a
/// layer was added — the same defect `addElement` carries a comment about, one
/// method above it in the same file.
@Test func addLayerPreservesEveryOtherDocumentField() {
    let doc = fullyPopulatedDocument(children: [rect(0, "alpha")])
    let model = Model(document: doc)
    Controller(model: model).addLayer(Layer(name: "Fresh", children: []))
    let after = model.document

    // GEOMETRY-VALUE pairing: the layer really was appended, at the end.
    #expect(after.layers.count == 3)
    #expect(after.layers[2].name == "Fresh")
    #expect(after.layers[1].id == "stage", "the existing layers were disturbed")

    let compared = expectOnlyChanged(doc, after, except: ["layers"],
                                     "addLayer")
    #expect(compared.count == 7, "compared \(compared.count) Document fields: \(compared)")
}
