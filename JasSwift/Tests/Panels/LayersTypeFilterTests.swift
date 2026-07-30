import Testing
@testable import JasLib

/// THE LAYERS TYPE FILTER READS THE ELEMENT, NOT ITS LABEL.
///
/// `workspace/panels/layers.yaml` (`lp_filter_button`): "Unchecking a type
/// hides all elements of that type from the tree." ALL of that type — a
/// rectangle the artist has named "roof" is still a rectangle.
///
/// This port has always matched on the element. jas_dioxus recovered the type
/// by PARSING THE ROW LABEL until 2026-07-29 — `<Rectangle>` was matched apart
/// and everything else fell through to `""` — which was correct by
/// construction only while Layers alone could carry a name. The commit that
/// let every element carry one made every NAMED element unfilterable over
/// there, because `""` matches nothing hidden. So this suite pins the side
/// that was right, to keep it right: the twin is
/// `the_type_filter_reads_the_element_not_its_label` in
/// jas_dioxus/src/interpreter/renderer.rs.
///
/// WHY VALUE ASSERTIONS. `layersTypeValue` and `layersTypeFilterKeep` were
/// `private` methods on the tree view until this wave, reachable only by
/// rendering it — which is why the divergence survived: no test on either side
/// could see the filter at all, and `transcripts/LAYERS_TESTS.md` LYR-091 was
/// deferred on the grounds that naming a non-layer was impossible. It stopped
/// being impossible and nobody revisited it. The end-to-end path (flatten,
/// then filter) belongs to the shared corpus rather than here.
@Suite struct LayersTypeFilterTests {

    private func rect(_ name: String?) -> Element {
        .rect(Rect(x: 0, y: 0, width: 10, height: 10, name: name))
    }

    /// A NAME IS NOT A TYPE. This is the whole defect, stated on the side that
    /// never had it.
    @Test func aNameDoesNotChangeAnElementsType() {
        #expect(layersTypeValue(rect(nil)) == "rectangle")
        #expect(layersTypeValue(rect("roof")) == "rectangle")
        #expect(layersTypeValue(.circle(Circle(cx: 0, cy: 0, r: 5, name: "sun"))) == "circle")
        #expect(layersTypeValue(.group(Group(children: [], name: "mast"))) == "group")
        #expect(layersTypeValue(.layer(Layer(name: "Sketch", children: []))) == "layer")
        // An EMPTY name is not a name either, and must not perturb the type.
        #expect(layersTypeValue(rect("")) == "rectangle")
    }

    /// Every value the filter MENU offers must be answerable by some element,
    /// and every token an element answers must be offerable. The eleven menu
    /// values are `layers.yaml`'s `lp_filter_button.items`; `scripts/
    /// check_layers_type_filter.py` is what holds this against the YAML in
    /// both ports — this half pins the port side of that pairing.
    @Test func everyMenuValueIsSomeElementsType() {
        let menuValues: Set<String> = [
            "layer", "group", "path", "rectangle", "circle", "ellipse",
            "polyline", "polygon", "text", "text_path", "line",
        ]
        let answered: Set<String> = Set([
            Element.line(Line(x1: 0, y1: 0, x2: 1, y2: 1)),
            .rect(Rect(x: 0, y: 0, width: 1, height: 1)),
            .circle(Circle(cx: 0, cy: 0, r: 1)),
            .ellipse(Ellipse(cx: 0, cy: 0, rx: 1, ry: 1)),
            .polyline(Polyline(points: [])),
            .polygon(Polygon(points: [])),
            .path(Path(d: [], fillRule: .nonzero)),
            .text(Text(x: 0, y: 0, content: "a")),
            .textPath(TextPath(d: [], content: "a")),
            .group(Group(children: [])),
            .layer(Layer(name: "L", children: [])),
        ].map(layersTypeValue))
        #expect(answered == menuValues,
                "menu offers \(menuValues.subtracting(answered)) that no element answers; elements answer \(answered.subtracting(menuValues)) the menu cannot offer")

        // `.live` answers a token the menu does NOT offer, so a live element
        // cannot be hidden in EITHER port. Asserted so the shared gap is a
        // recorded agreement: jas_dioxus's `tree_type_value` spells it the
        // same, and whoever adds the menu option must change both.
        let live = Element.live(.compoundShape(CompoundShape(
            operation: .union, operands: [], name: "prow")))
        #expect(layersTypeValue(live) == "live")
        #expect(!menuValues.contains("live"))
    }

    /// Hiding a type removes its rows — named ones included — and keeps
    /// everything else.
    @Test func hidingATypeRemovesItsRowsWhateverTheyAreCalled() {
        let rows: [(path: ElementPath, typeValue: String)] = [
            (path: [0], typeValue: "layer"),
            (path: [0, 0], typeValue: "rectangle"),   // unnamed
            (path: [0, 1], typeValue: "rectangle"),   // named "roof"
            (path: [0, 2], typeValue: "circle"),
        ]
        let keep = layersTypeFilterKeep(rows, hidden: ["rectangle"])
        #expect(keep == Set([[0], [0, 2]]),
                "both rectangles must go; the layer stays as the circle's ancestor")

        // A hidden type nothing has removes nothing.
        #expect(layersTypeFilterKeep(rows, hidden: ["text"]).count == rows.count)
    }

    /// THE ANCESTOR RULE, as its own claim. Hiding a CONTAINER type does not
    /// remove it while any descendant survives, because a tree cannot draw a
    /// child without its parent row. Deliberate, and identical in jas_dioxus —
    /// whether it is what "hides all elements of that type" ought to mean is a
    /// question for council, so it is pinned here rather than assumed.
    @Test func hidingAContainerTypeIsInoperativeWhileAChildSurvives() {
        let rows: [(path: ElementPath, typeValue: String)] = [
            (path: [0], typeValue: "layer"),
            (path: [0, 0], typeValue: "group"),
            (path: [0, 0, 0], typeValue: "rectangle"),
        ]
        #expect(layersTypeFilterKeep(rows, hidden: ["group"]) == Set([[0], [0, 0], [0, 0, 0]]),
                "the group is retained as an ancestor of its visible rectangle")

        // Hide the container AND its only descendant type, and the container
        // does disappear — which is the sense in which the rule is a
        // reachability rule rather than an exemption.
        #expect(layersTypeFilterKeep(rows, hidden: ["group", "rectangle"]) == Set([[0]]))
    }
}
