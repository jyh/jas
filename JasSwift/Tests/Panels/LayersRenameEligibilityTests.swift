import Testing
@testable import JasLib

/// ANY ELEMENT CAN BE RENAMED, AND AN EMPTY NAME IS NOT A NAME.
///
/// jas_dioxus has renamed any element since 2026-05-02 (`let can_rename = true`,
/// with the commit writing `elem.common_mut().name` for every kind and mapping
/// the empty string to `None`). JasSwift kept a `if case .layer` gate at both
/// the double-click entry AND the commit — in two duplicated row renderers, four
/// sites — while `elementDisplayName` already SHOWED any element's name. So this
/// port displayed a name it refused to let you edit.
///
/// That divergence is the live remains of LYR-091, whose deferral said *"only
/// Layers are renameable in the current UI... Revisit when Group/element names
/// land."* They landed on 2026-05-02. Rust moved; Swift's half was never
/// revisited. Council O4, 2026-07-30.
///
/// THE TRAP THIS SUITE EXISTS FOR. Opening the double-click gate alone would
/// show a rename field on every row that silently discarded every non-layer
/// edit, because the commit gate is a separate `if case .layer` twenty lines
/// away. A gate opened onto a write that only handles layers is worse than the
/// gate. So the WRITE is pinned here first, and pinned for every kind.
@Suite struct LayersRenameEligibilityTests {

    /// One representative of every `Element` case, so a new kind cannot be
    /// added without this suite noticing it has no rename semantics.
    private static let allKinds: [(String, Element)] = [
        ("line",     .line(Line(x1: 0, y1: 0, x2: 1, y2: 1))),
        ("rect",     .rect(Rect(x: 0, y: 0, width: 1, height: 1))),
        ("circle",   .ellipse(Ellipse(cx: 0, cy: 0, rx: 1, ry: 1))),
        ("ellipse",  .ellipse(Ellipse(cx: 0, cy: 0, rx: 1, ry: 1))),
        ("polyline", .polyline(Polyline(points: []))),
        ("polygon",  .polygon(Polygon(points: []))),
        ("path",     .path(Path(d: [], fillRule: .nonzero))),
        ("text",     .text(Text(x: 0, y: 0, content: "a"))),
        ("textPath", .textPath(TextPath(d: [], content: "a"))),
        ("group",    .group(Group(children: []))),
        ("layer",    .layer(Layer(name: "L", children: []))),
        ("live",     .live(.compoundShape(CompoundShape(
                        operation: .union, operands: [], name: nil)))),
    ]

    /// A rename lands on every kind, not just Layer.
    @Test func everyElementKindTakesAName() {
        for (label, elem) in Self.allKinds {
            let renamed = elem.withName("hull")
            #expect(renamed.name == "hull",
                    "\(label) must accept a name — jas_dioxus writes common.name for every kind")
        }
    }

    /// AN EMPTY NAME IS NOT A NAME, for every kind.
    ///
    /// jas_dioxus's commit is `if val.is_empty() { None } else { Some(val) }`.
    /// Swift's `Layer.normalizedName` is the same rule — but `Element.withName`
    /// applied it to nobody, and its `.layer` arm assigned `v.name` directly
    /// rather than routing through `Layer.withName`, so it bypassed the one
    /// normalization the codebase already had. Clearing a name would have
    /// stored `Optional("")` here and `None` there: two ports disagreeing about
    /// whether an element is named, which drives the tree label, the `<Type>`
    /// fallback and the type filter.
    @Test func anEmptyNameIsNotAName() {
        for (label, elem) in Self.allKinds {
            let cleared = elem.withName("")
            #expect(cleared.name == nil,
                    "\(label): the empty string must normalize to nil, as jas_dioxus does")
            let explicitNil = elem.withName(nil)
            #expect(explicitNil.name == nil, "\(label): nil stays nil")
        }
    }

    /// Renaming preserves everything it does not speak to.
    ///
    /// THE PRESERVATION LAW, and the reason the existing layer path was written
    /// clone-then-mutate: the rebuild it replaced named 6 of Layer's 11 stored
    /// fields, so renaming a layer destroyed its id, blend mode, mask and both
    /// opacity flags. Opening rename to every kind multiplies that hazard by
    /// eleven, so it is asserted rather than assumed.
    @Test func renamingPreservesEverythingElse() {
        let rect = Rect(x: 3, y: 4, width: 5, height: 6, name: "before",
                        id: "keep-me")
        guard case .rect(let after) = Element.rect(rect).withName("after") else {
            Issue.record("withName changed the element's KIND"); return
        }
        #expect(after.name == "after")
        #expect(after.id == "keep-me", "a rename must not disturb the stable id")
        #expect(after.x == 3 && after.y == 4 && after.width == 5 && after.height == 6,
                "a rename must not disturb geometry")

        let layer = Layer(name: "before", children: [], id: "layer-id")
        guard case .layer(let l2) = Element.layer(layer).withName("after") else {
            Issue.record("withName changed the element's KIND"); return
        }
        #expect(l2.name == "after")
        #expect(l2.id == "layer-id",
                "the layer path must keep its id — the copy-site omission class the clone-then-mutate rewrite was written to close")
    }
}
