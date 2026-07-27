import Testing
@testable import JasLib

/// EDIT_SEMANTICS_FREEZE.md **T4 — THE BYSTANDER CLAUSE**: *an edit
/// preserves, unchanged, every element it does not name — including the
/// containers it rebuilds to reach its target.*
///
/// `Document.replaceElement` / `deleteElement` / `insertElementAfter` reach a
/// nested element by rebuilding every container on the path down to it. Those
/// containers are BYSTANDERS: the edit names a grandchild, so the Layer and the
/// Group it passes through must come out byte-identical apart from `children`.
///
/// Rust's twins conform for free — `replace_element` rewrites the child slot in
/// place, so the parent's `common` (id included) is never reconstructed. Swift
/// routed all three mutators through a private `withChildren` that rebuilt
/// Layer/Group from FOUR fields, destroying the container's `id`, `mask`,
/// `blendMode`, `visibility`, `isolatedBlending`, `knockoutGroup` and a Group's
/// `name` on EVERY nested element edit in the port.
///
/// This file is the per-port inner loop. The outer, cross-port gate is
/// `test_fixtures/operations/bystander_containers.json`, which pins the same
/// clause over the SHARED serialized field set in both ports (freeze §4.2). The
/// two are complementary and neither is redundant: the shared test-JSON encoding
/// emits a container's `id`, `name`, `opacity`, `transform`, `locked` and
/// `visibility` but NOT its `mask`, `blendMode`, `isolatedBlending` or
/// `knockoutGroup` — those four are visible only here.
///
/// EXHAUSTIVENESS METHOD (freeze §3.1(i)–(ii), and the same method
/// `MovePathHandleFieldsTests` uses): the comparisons below carry no
/// hand-written field list. They walk `Mirror(reflecting:)` and compare every
/// stored property except `children`, so a field added to `Group` or `Layer`
/// tomorrow is compared without editing this file. Two guards make that walk
/// trustworthy:
///
///   * the ANTI-VACUITY GUARD — `fixtureDiffersFromDefaultInEveryNonChildField`
///     asserts every non-`children` property of the fixtures differs from a
///     default-constructed container's, because "preserved" and "dropped" are
///     indistinguishable for a field whose fixture value IS the default; and
///   * the stored-property COUNT, which fires when a field is added so the
///     fixture can be given a non-default value for it.
///
/// Each structural assertion is additionally paired with a GEOMETRY-VALUE
/// assertion (freeze §4, enforcement doctrine): a field-list-free walk is
/// structurally blind to geometry, so every test below also checks that the
/// edit it drove actually landed on the named target.

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
/// default. (`Layer.name` defaults to nil, so "Stage" is non-default.)
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

/// layer "stage" > group "cluster" > [alpha, beta]. The edits below all name
/// the GRANDCHILD, so both containers are bystanders.
private func nestedDocument() -> Document {
    Document(layers: [fullyPopulatedLayer(children: [
        .group(fullyPopulatedGroup(children: [rect(0, "alpha"), rect(20, "beta")]))
    ])], selectedLayer: 0, selection: [])
}

private func layerAt(_ doc: Document) -> Layer { doc.layers[0] }

private func groupAt(_ doc: Document) -> Group? {
    guard case .group(let g) = doc.getElement([0, 0]) else { return nil }
    return g
}

// MARK: - The Mirror comparison

/// Compare every stored property of `before` and `after` except `children`.
/// Returns the labels it compared, so the caller can assert the walk was not
/// silently vacuous (freeze §3.1(ii): a non-struct payload must not be able to
/// reflect zero children and pass).
@discardableResult
private func expectOnlyChildrenChanged<T>(_ before: T, _ after: T,
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
        guard let label = child.label, label != "children" else { continue }
        compared.append(label)
        #expect(String(describing: child.value) == beforeByLabel[label],
                "\(what) changed \(label)")
    }
    return compared
}

// MARK: - The anti-vacuity guard

@Test func fixtureDiffersFromDefaultInEveryNonChildField() {
    let cases: [(String, Mirror, Mirror, Int)] = [
        ("Group", Mirror(reflecting: fullyPopulatedGroup(children: [])),
         Mirror(reflecting: Group(children: [])), 11),
        ("Layer", Mirror(reflecting: fullyPopulatedLayer(children: [])),
         Mirror(reflecting: Layer(children: [])), 11),
    ]
    for (what, rich, plain, expectedCount) in cases {
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
            guard let label = child.label, label != "children" else { continue }
            #expect(String(describing: child.value) != plainByLabel[label],
                    "\(what).\(label) is at its default in the fixture — a drop of that field would be invisible to the Mirror walk")
        }
    }
}

// MARK: - replace

@Test func everyContainerFieldSurvivesReplaceElement() {
    let doc = nestedDocument()
    let moved = Rect(x: 5, y: 7, width: 10, height: 10, id: "alpha")
    let after = doc.replaceElement([0, 0, 0], with: .rect(moved))

    // GEOMETRY-VALUE pairing: the named edit actually landed.
    guard case .rect(let r) = after.getElement([0, 0, 0]) else {
        Issue.record("target is no longer a Rect"); return
    }
    #expect(r.x == 5 && r.y == 7, "replaceElement did not place the new Rect")

    let compared = expectOnlyChildrenChanged(layerAt(doc), layerAt(after),
                                             "replaceElement on a grandchild")
    #expect(compared.count == 10, "compared \(compared.count) Layer fields: \(compared)")
    guard let gb = groupAt(doc), let ga = groupAt(after) else {
        Issue.record("group vanished"); return
    }
    let comparedG = expectOnlyChildrenChanged(gb, ga,
                                              "replaceElement on a grandchild")
    #expect(comparedG.count == 10, "compared \(comparedG.count) Group fields: \(comparedG)")
}

// MARK: - delete

@Test func everyContainerFieldSurvivesDeleteElement() {
    let doc = nestedDocument()
    let after = doc.deleteElement([0, 0, 1])

    // GEOMETRY-VALUE pairing: "beta" is gone and "alpha" is untouched.
    guard case .group(let g) = after.getElement([0, 0]) else {
        Issue.record("group vanished"); return
    }
    #expect(g.children.count == 1)
    guard case .rect(let r) = after.getElement([0, 0, 0]) else {
        Issue.record("survivor is not a Rect"); return
    }
    #expect(r.id == "alpha" && r.x == 0)

    let compared = expectOnlyChildrenChanged(layerAt(doc), layerAt(after),
                                             "deleteElement of a grandchild")
    #expect(compared.count == 10, "compared \(compared.count) Layer fields: \(compared)")
    guard let gb = groupAt(doc) else { Issue.record("group vanished"); return }
    let comparedG = expectOnlyChildrenChanged(gb, g,
                                              "deleteElement of a grandchild")
    #expect(comparedG.count == 10, "compared \(comparedG.count) Group fields: \(comparedG)")
}

// MARK: - insertAfter

@Test func everyContainerFieldSurvivesInsertElementAfter() {
    let doc = nestedDocument()
    let after = doc.insertElementAfter([0, 0, 0], element: rect(40, "gamma"))

    // GEOMETRY-VALUE pairing: the new element landed at index 1.
    guard case .group(let g) = after.getElement([0, 0]) else {
        Issue.record("group vanished"); return
    }
    #expect(g.children.count == 3)
    guard case .rect(let r) = after.getElement([0, 0, 1]) else {
        Issue.record("inserted element is not a Rect"); return
    }
    #expect(r.id == "gamma" && r.x == 40)

    let compared = expectOnlyChildrenChanged(layerAt(doc), layerAt(after),
                                             "insertElementAfter under a grandchild")
    #expect(compared.count == 10, "compared \(compared.count) Layer fields: \(compared)")
    guard let gb = groupAt(doc) else { Issue.record("group vanished"); return }
    let comparedG = expectOnlyChildrenChanged(gb, g,
                                              "insertElementAfter under a grandchild")
    #expect(comparedG.count == 10, "compared \(comparedG.count) Group fields: \(comparedG)")
}

// MARK: - The losses with named artist-visible consequences

/// Dropping a container's `visibility` UNHIDES it: hide a group, then nudge a
/// shape inside it, and the group paints again. Called out separately from the
/// Mirror walk because the failure is a rendering change, not just a lost tag.
@Test func aHiddenGroupStaysHiddenWhenAChildIsEdited() {
    let doc = nestedDocument()
    let after = doc.replaceElement([0, 0, 0],
                                   with: .rect(Rect(x: 5, y: 7, width: 10, height: 10, id: "alpha")))
    #expect(groupAt(after)?.visibility == .invisible,
            "editing a child un-hid the group that contains it")
}

/// Dropping a container's `id` orphans every reference bound to it and erases
/// the handle the journal and the Arc-3 ledger cite (freeze §3.8).
@Test func containerIdentitySurvivesEveryStructuralMutator() {
    let doc = nestedDocument()
    for (what, after) in [
        ("replace", doc.replaceElement([0, 0, 0],
                                       with: .rect(Rect(x: 5, y: 7, width: 10, height: 10, id: "alpha")))),
        ("delete", doc.deleteElement([0, 0, 1])),
        ("insertAfter", doc.insertElementAfter([0, 0, 0], element: rect(40, "gamma"))),
    ] {
        #expect(layerAt(after).id == "stage", "\(what) destroyed the Layer's id")
        #expect(groupAt(after)?.id == "cluster", "\(what) destroyed the Group's id")
        #expect(groupAt(after)?.name == "Cluster", "\(what) destroyed the Group's name")
    }
}

/// A mask attached to a container is destroyed by the same rebuild — and it is
/// one of the four fields the shared test-JSON encoding cannot see, so this
/// per-port assertion is the ONLY thing watching it.
@Test func containerMaskAndBlendingSurviveAStructuralMutator() {
    let doc = nestedDocument()
    let after = doc.deleteElement([0, 0, 1])
    #expect(groupAt(after)?.mask == distinctMask(11))
    #expect(groupAt(after)?.blendMode == .multiply)
    #expect(groupAt(after)?.isolatedBlending == true)
    #expect(groupAt(after)?.knockoutGroup == true)
    #expect(layerAt(after).mask == distinctMask(23))
    #expect(layerAt(after).blendMode == .screen)
    #expect(layerAt(after).isolatedBlending == true)
    #expect(layerAt(after).knockoutGroup == true)
}
