import CoreGraphics
import Foundation
import Testing
@testable import JasLib

/// THE LIVE TRANSFORM OPERATION (council 2026-10-16, ruling 4), the Swift twin
/// of jas_dioxus `a_transformed_rect_draws_its_stroke_by_scale_strokes`.
///
/// His arm: a 200 % × 300 % scale of a 1 pt rectangle. Scale Strokes OFF:
/// "the stroke should stay 1pt" on all four edges. ON: "identical to
/// converting the stroke to outlines, then scaling", so the vertical edges
/// draw 2 pt and the horizontal ones 3 pt.
///
/// This port draws straight into CoreGraphics, so the arm reads PIXELS: the
/// canvas is drawn at 4 px per pt, and every edge is chosen to land on whole
/// pixels (a 1 pt edge at x = 4 pt covers 14…18 px), so each pixel is fully
/// in or fully out and a count is exact, not a threshold.
///
/// ⛔ A WIDTH ALONE CANNOT TELL OFF FROM "THE MATRIX WAS DROPPED": an unscaled
/// 1 pt rect also reads 1 pt. So each case also asserts WHERE the edges are.

private let pxPerPt = 4.0
private let size = 200

private func render(_ elem: Element) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: size * size * 4)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(pxPerPt), y: CGFloat(pxPerPt))
        drawElement(ctx, elem)
    }
    return buf
}

/// The runs of covered pixels (alpha > 127) along one row or one column, as
/// `(first, last)` pixel indices. Row/column orientation in the buffer does not
/// matter for a symmetric count; a flip only mirrors the indices, so each case
/// below also asserts the runs' mirror-free STARTS against both orientations.
private func runs(_ buf: [UInt8], row: Int? = nil, col: Int? = nil) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    var start: Int? = nil
    for i in 0..<size {
        let (x, y) = row != nil ? (i, row!) : (col!, i)
        let on = buf[(y * size + x) * 4 + 3] > 127
        if on, start == nil { start = i }
        if !on, let s = start { out.append((s, i - 1)); start = nil }
    }
    if let s = start { out.append((s, size - 1)) }
    return out
}

private let black = Color(r: 0, g: 0, b: 0)

/// A 10 × 10 rect at (2, 2), stroked 1 pt, no fill. Under 2 × 3 it lands on
/// 4…24 × 6…36 pt = 16…96 × 24…144 px.
private let rect: Element = .rect(Rect(x: 2, y: 2, width: 10, height: 10,
                                      stroke: Stroke(color: black, width: 1)))

private func wrap(_ child: Element, _ m: Transform, _ scaleStrokes: Bool) -> Element {
    .live(.transformed(TransformedElem(child: child, matrix: m, scaleStrokes: scaleStrokes)))
}

/// Per-edge thickness in pt, and the edges' outer starts in px, measured
/// through the middle of the drawn rect.
private func measure(_ buf: [UInt8]) -> (vertical: [Double], horizontal: [Double], xStart: Int, yStarts: Set<Int>) {
    let across = runs(buf, row: 84)      // crosses the two vertical edges
    let down = runs(buf, col: 56)        // crosses the two horizontal edges
    let w = { (r: (Int, Int)) in Double(r.1 - r.0 + 1) / pxPerPt }
    let ys = Set(down.map { $0.0 })
    return (across.map(w), down.map(w), across.first?.0 ?? -1, ys)
}

@Test func aTransformedRectDrawsItsStrokeByScaleStrokes() {
    // OFF: 1 pt everywhere; the left edge (x = 16 px) starts at 14 px.
    let off = measure(render(wrap(rect, .scale(2, 3), false)))
    #expect(off.vertical == [1, 1], "OFF vertical edges \(off.vertical)")
    #expect(off.horizontal == [1, 1], "OFF horizontal edges \(off.horizontal)")
    #expect(off.xStart == 14, "OFF drawn from x = \(off.xStart) px, want 14 (the matrix applied)")
    // ON: vertical edges 2 pt, horizontal 3 pt; the left edge starts at 12 px.
    let on = measure(render(wrap(rect, .scale(2, 3), true)))
    #expect(on.vertical == [2, 2], "ON vertical edges \(on.vertical)")
    #expect(on.horizontal == [3, 3], "ON horizontal edges \(on.horizontal)")
    #expect(on.xStart == 12, "ON drawn from x = \(on.xStart) px, want 12")
}

/// The stack order decides the case: OFF 2 × 3 inside ON 2 × 2 keeps 1 pt,
/// then the ON scale doubles it on every edge. The 5 × 5 rect at (1, 1) lands
/// on 4…24 × 6…36 pt (16…96 × 24…144 px, all on the 200 px canvas), so the
/// left edge (2 pt wide at 16 px) starts at 12 px.
@Test func anOffWrapperInsideAnOnWrapperScalesTheKeptStroke() {
    let small: Element = .rect(Rect(x: 1, y: 1, width: 5, height: 5,
                                    stroke: Stroke(color: black, width: 1)))
    let buf = render(wrap(wrap(small, .scale(2, 3), false), .scale(2, 2), true))
    let across = runs(buf, row: 84)
    let down = runs(buf, col: 56)
    let w = { (r: (Int, Int)) in Double(r.1 - r.0 + 1) / pxPerPt }
    #expect(across.map(w) == [2, 2], "vertical edges \(across.map(w))")
    #expect(down.map(w) == [2, 2], "horizontal edges \(down.map(w))")
    #expect(across.first?.0 == 12, "drawn from x = \(String(describing: across.first?.0)) px, want 12")
}

/// An ellipse's image under an affine map is an ellipse; `ellipseAxesThrough`
/// must name it. Each point of the original, mapped, must lie on the image at
/// the mapped angle. Driven over a non-uniform scale, a rotated one, a shear
/// and a mirror.
@Test func ellipseAxesThroughNamesTheImageEllipse() {
    let (rx, ry, rot) = (5.0, 2.0, 0.3)
    let point = { (rx: Double, ry: Double, rot: Double, t: Double) -> (Double, Double) in
        let x = rx * cos(t), y = ry * sin(t)
        return (cos(rot) * x - sin(rot) * y, sin(rot) * x + cos(rot) * y)
    }
    let mats: [(String, Transform)] = [
        ("scale 2x3", .scale(2, 3)),
        ("rotate*scale", Transform.rotate(30).multiply(.scale(2, 0.5))),
        ("shear", .shear(0.4, 0.1)),
        ("mirror", .scale(-1, 2)),
    ]
    for (name, m) in mats {
        let ax = ellipseAxesThrough(m, rx: rx, ry: ry, rotation: rot)
        for k in 0...8 {
            let t = Double(k) * 0.7
            let p = point(rx, ry, rot, t)
            let want = (m.a * p.0 + m.c * p.1, m.b * p.0 + m.d * p.1)
            let tm = (ax.mirrored ? -t : t) + ax.theta
            let got = point(ax.rx, ax.ry, ax.rotation, tm)
            #expect(abs(want.0 - got.0) < 1e-9 && abs(want.1 - got.1) < 1e-9,
                    "\(name) at t=\(t): want \(want) got \(got)")
        }
    }
}

/// The wrapper round-trips WHOLE through test JSON and binary: the child with
/// its own paint and transform, the matrix, and both Scale Strokes values,
/// nested one wrapper in another.
@Test func aTransformedWrapperRoundTripsThroughBothCodecs() throws {
    let child: Element = .rect(Rect(x: 1, y: 2, width: 10, height: 5,
                                    fill: Fill(color: black), stroke: Stroke(color: black, width: 1.5),
                                    transform: .rotate(30)))
    for scaleStrokes in [false, true] {
        let elem = wrap(wrap(child, .scale(2, 3), scaleStrokes), .shear(0.25, 0), !scaleStrokes)
        let json = elementJson(elem)
        #expect(json.contains("\"kind\":\"transformed\""), "\(json)")
        let parsed = parseElement(try JSONSerialization.jsonObject(with: Data(json.utf8)))
        #expect(elementJson(parsed) == json, "test JSON, scaleStrokes=\(scaleStrokes)")
        let doc = Document(layers: [Layer(name: "L", children: [elem])], selectedLayer: 0, selection: [])
        let back = try binaryToDocument(documentToBinary(doc, compress: false))
        #expect(back.layers[0].children.first == elem, "binary, scaleStrokes=\(scaleStrokes)")
    }
}

/// ⚠️ TODAY'S ANSWER, RECORDED, NOT A LAW (the helm, 2026-10-16 20:27, item 4;
/// coverage gap `stored-transform-stroke-law-differs-by-renderer`). Under a
/// STORED transform this canvas COUNTER-SCALES the stroke
/// (`counterScaledElement`), so a 1 pt stroke under a stored scale(2, 2) draws
/// 1 pt. jas_dioxus's native seam draws the same element 2 pt
/// (`a_stored_scale_strokes_at_the_scaled_width_in_the_native_seam`). No law
/// is ruled yet; whichever one the Captain rules turns exactly one of the two
/// arms red, and that arm's port is the one to repair.
@Test func aStoredScaleDrawsTheStrokeAtItsAuthoredWidthOnThisCanvasToday() {
    let stored: Element = .rect(Rect(x: 2, y: 2, width: 10, height: 10,
                                     stroke: Stroke(color: black, width: 1), transform: .scale(2, 2)))
    let control: Element = .rect(Rect(x: 4, y: 4, width: 20, height: 20,
                                      stroke: Stroke(color: black, width: 1)))
    // Both land on 4…24 pt = 16…96 px. The bitmap's rows run bottom-up, so
    // row 140 (y = 59 px) and col 56 are the lines that cross every edge.
    for (label, elem) in [("stored scale(2,2)", stored), ("control, drawn at 2x size", control)] {
        let buf = render(elem)
        let w = { (r: (Int, Int)) in Double(r.1 - r.0 + 1) / pxPerPt }
        #expect(runs(buf, row: 140).map(w) == [1, 1], "\(label): vertical edges \(runs(buf, row: 140).map(w))")
        #expect(runs(buf, col: 56).map(w) == [1, 1], "\(label): horizontal edges \(runs(buf, col: 56).map(w))")
    }
}

// MARK: - Release Transform (route 4 slice 3a)

/// RELEASE TRANSFORM, Scale Strokes OFF, LEAVES THE PICTURE UNCHANGED: the
/// wrapper and its released form render to the same pixels, for a rect, a
/// rotated rect, a polygon, a line and an ellipse, under a non-uniform scale,
/// a rotated one and a shear, with and without a wrapper transform. (Scale
/// Strokes ON is NOT claimed here: it composes into a stored transform, and
/// this canvas counter-scales a stored transform's stroke; see the coverage
/// gap `stored-transform-stroke-law-differs-by-renderer`.)
@Test func releasingAnOffWrapperLeavesThePictureUnchanged() {
    let s = Stroke(color: black, width: 1.5)
    let children: [(String, Element)] = [
        ("rect", .rect(Rect(x: 2, y: 1, width: 10, height: 4, stroke: s))),
        ("rotated rect", .rect(Rect(x: 2, y: 1, width: 10, height: 4, stroke: s, transform: .rotate(30)))),
        ("polygon", .polygon(Polygon(points: [(0, 0), (6, 1), (3, 5)], stroke: s))),
        ("line", .line(Line(x1: 1, y1: 1, x2: 9, y2: 4, stroke: s))),
        ("ellipse", .ellipse(Ellipse(cx: 6, cy: 4, rx: 4, ry: 2, stroke: s))),
    ]
    let mats: [(String, Transform)] = [
        ("scale 2x3", .scale(2, 3)),
        ("rotate*scale", Transform.rotate(30).multiply(.scale(2, 0.5)).translated(10, 0)),
        ("shear", .shear(0.4, 0)),
    ]
    var cases = 0
    for (cname, child) in children {
        for (mname, m) in mats {
            for outer in [nil, Transform.translate(5, 7)] as [Transform?] {
                let t = TransformedElem(child: child, matrix: m, scaleStrokes: false, transform: outer)
                let before = render(.live(.transformed(t))), after = render(t.released())
                cases += 1
                #expect(before.contains { $0 != 0 }, "\(cname) / \(mname): nothing drawn")
                #expect(before == after, "\(cname) / \(mname) / outer=\(outer != nil): release changed the picture")
            }
        }
    }
    #expect(cases == 30)
}

/// Release keeps the child's KIND where it can (mirrors jas_dioxus
/// `a_released_wrapper_keeps_its_childs_kind_where_it_can`).
@Test func aReleasedWrapperKeepsItsChildsKindWhereItCan() {
    let r: Element = .rect(Rect(x: 1, y: 1, width: 4, height: 2, rx: 1, ry: 0.5,
                                stroke: Stroke(color: black, width: 1), id: "child"))
    let off = TransformedElem(child: r, matrix: .scale(2, 3), scaleStrokes: false, id: "wrapper")
    guard case .rect(let e) = off.released() else { Issue.record("OFF axis-aligned should stay a rect"); return }
    #expect((e.x, e.y, e.width, e.height, e.rx, e.ry) == (2, 3, 8, 6, 2, 1.5))
    #expect(e.stroke?.width == 1 && e.transform == nil && e.id == "child")
    if case .path = TransformedElem(child: r, matrix: .rotate(30), scaleStrokes: false).released() {} else {
        Issue.record("a rotated rect is a path")
    }
    guard case .rect(let on) = TransformedElem(child: r, matrix: .scale(2, 3), scaleStrokes: true).released() else {
        Issue.record("ON should stay a rect"); return
    }
    #expect(on.x == 1 && on.width == 4 && on.transform == .scale(2, 3))
}

/// The controller replaces the wrapper IN PLACE, keeps the selection, and is
/// one undo step; nothing to release is no change and no step. Mirrors
/// jas_dioxus `release_transform_replaces_the_wrapper_in_place_and_undo_restores_it`.
@Test func releaseTransformReplacesTheWrapperInPlaceAndUndoRestoresIt() {
    let child: Element = .rect(Rect(x: 2, y: 2, width: 10, height: 10,
                                    fill: Fill(color: black), stroke: Stroke(color: black, width: 1), id: "child"))
    let w = TransformedElem(child: child, matrix: .scale(2, 3), scaleStrokes: false)
    let model = Model(document: Document(layers: [Layer(name: "L", children: [.live(.transformed(w))])],
                                         selectedLayer: 0, selection: []))
    let before = model.document
    let ctl = Controller(model: model)
    ctl.setSelection([ElementSelection.all([0, 0])])
    ctl.releaseTransform()
    guard case .rect(let r) = model.document.getElement([0, 0]) else {
        Issue.record("released to a rect: \(model.document.getElement([0, 0]))"); return
    }
    #expect((r.x, r.y, r.width, r.height) == (4, 6, 20, 30))
    #expect(r.id == "child")
    #expect(model.document.selection == [ElementSelection.all([0, 0])])
    model.undo()
    #expect(model.document.layers == before.layers, "undo restores the wrapper")
    let plain = Model(document: Document(layers: [Layer(name: "L", children: [child])], selectedLayer: 0, selection: []))
    let pctl = Controller(model: plain)
    pctl.setSelection([ElementSelection.all([0, 0])])
    let layers = plain.document.layers
    pctl.releaseTransform()
    #expect(plain.document.layers == layers && !plain.canUndo, "a no-op release leaves no undo step")
}

// MARK: - SVG round trip (twins of Rust svg.rs)

/// A Transformed wrapper ROUND-TRIPS through SVG, both Scale Strokes values,
/// with its own transform W and its matrix M kept apart. The standard
/// `transform` stays W·M for foreign viewers; `data-jas-matrix` (M) and
/// `data-jas-own-transform` (W) carry the split. Coordinates are multiples of
/// 3 pt so the px wire values are exact. Twin of Rust
/// `a_transformed_wrapper_round_trips_through_svg`.
@Test func aTransformedWrapperRoundTripsThroughSvg() {
    for (own, scaleStrokes) in [(Transform?.some(.translate(6, 9)), false), (nil, true)] {
        let child: Element = .rect(Rect(x: 3, y: 3, width: 12, height: 12,
                                        stroke: Stroke(color: black, width: 3), id: "c"))
        let w = TransformedElem(child: child, matrix: .scale(2, 3), scaleStrokes: scaleStrokes,
                                id: "w", transform: own)
        let doc = Document(layers: [Layer(name: "Layer", children: [.live(.transformed(w))])],
                           selectedLayer: 0, selection: [])
        let svg = documentToSvg(doc)
        #expect(svg.contains(" data-jas-matrix=\""), "\(svg)")
        #expect(svg.contains("data-jas-own-transform") == (own != nil), "\(svg)")
        let back = svgToDocument(svg)
        #expect(back.layers[0].children == doc.layers[0].children, "round trip, own=\(String(describing: own)): \(svg)")
    }
}

/// Without the split attributes the whole `transform` is the matrix and there
/// is no wrapper transform: the same picture. Twin of Rust
/// `a_transformed_group_without_the_split_reads_its_transform_as_the_matrix`.
@Test func aTransformedGroupWithoutTheSplitReadsItsTransformAsTheMatrix() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape">
      <g inkscape:groupmode="layer" inkscape:label="L">
        <g data-jas-live="transformed" data-jas-scale-strokes="false" transform="matrix(2,0,0,3,0,0)">
          <rect x="4" y="4" width="16" height="16"/>
        </g>
      </g>
    </svg>
    """
    guard case .live(.transformed(let t)) = svgToDocument(svg).getElement([0, 0]) else {
        Issue.record("a wrapper"); return
    }
    #expect(t.matrix == .scale(2, 3))
    #expect(t.transform == nil)
    #expect(!t.scaleStrokes)
    guard case .rect(let r) = t.child else { Issue.record("a rect child"); return }
    #expect(r.x == 3 && r.width == 12)
}

// MARK: - Route 4 slice 3b: editing a wrapped child through a path

private func wrappedChildModel() -> Model {
    let child: Element = .rect(Rect(x: 2, y: 2, width: 10, height: 10,
                                    fill: Fill(color: black), stroke: Stroke(color: black, width: 1), id: "child"))
    let w = TransformedElem(child: child, matrix: .scale(2, 3), scaleStrokes: false)
    return Model(document: Document(layers: [Layer(name: "L", children: [.live(.transformed(w))])],
                                    selectedLayer: 0, selection: []))
}

/// A wrapper is a container with exactly one slot, so `[layer, w, 0]` addresses
/// its child. A document-space drag of one corner reaches the child in its OWN
/// space (the wrapper's frame is `W·M`, here scale(2,3)); the matrix, flag and
/// own props are untouched; one undo restores it. Twin of Rust
/// `moving_a_wrapped_childs_corner_edits_the_child_in_its_own_space`. Before
/// slice 3b the path trapped in `childrenOf`.
@Test func movingAWrappedChildsCornerEditsTheChildInItsOwnSpace() {
    let model = wrappedChildModel()
    let before = model.document
    guard case .live(.transformed(let t0)) = before.getElement([0, 0]) else { Issue.record("a wrapper"); return }
    let ctl = Controller(model: model)
    ctl.setSelection([ElementSelection.partial([0, 0, 0], [2])])
    ctl.moveSelection(dx: 4, dy: 3)
    guard case .live(.transformed(let t)) = model.document.getElement([0, 0]) else {
        Issue.record("still a wrapper"); return
    }
    let p0 = t0.child.controlPointPositions, p = t.child.controlPointPositions
    #expect(p[2].0 - p0[2].0 == 2 && p[2].1 - p0[2].1 == 1, "moved (4,3)/(2,3) locally: \(p)")
    for i in p.indices where i != 2 { #expect(p[i] == p0[i], "only the selected corner moves") }
    #expect(t.matrix == t0.matrix && t.scaleStrokes == t0.scaleStrokes && t.transform == t0.transform)
    model.undo()
    #expect(model.document.layers == before.layers, "one undo restores it")
}

/// The frame a wrapper gives its child is its transform after its matrix, `W·M`.
@Test func theAccumulatedTransformOfAWrappedChildIncludesTheMatrix() {
    let model = wrappedChildModel()
    #expect(accumulatedTransform(model.document, [0, 0, 0], includeOwn: true) == .scale(2, 3))
    guard case .live(.transformed(var w)) = model.document.getElement([0, 0]) else { return }
    w.transform = .translate(5, 7)
    let doc = model.document.replaceElement([0, 0], with: .live(.transformed(w)))
    let t = accumulatedTransform(doc, [0, 0, 0], includeOwn: true)!
    let (x, y) = t.applyPoint(1, 1)
    #expect(x == 7 && y == 10, "scale first, then translate")
}

/// A wrapped child's handles sit on its DRAWN corners. Twin of Rust
/// `a_wrapped_childs_highlight_sits_where_the_child_is_drawn` (its squares).
@Test func aWrappedChildsHandlesSitWhereTheChildIsDrawn() {
    let doc = wrappedChildModel().document
    let half = handleDrawSize / 2
    let centres = selectionHandleRects(doc, [0, 0, 0]).map { ($0.minX + half, $0.minY + half) }
        .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    #expect(centres.map { [$0.0, $0.1] } == [[4, 6], [4, 36], [24, 6], [24, 36]], "\(centres)")
    #expect(selectionOutlineScale(doc, [0, 0, 0]) == 6.0.squareRoot(), "the pen counter-scales W·M")
}

/// DELETING A WRAPPED CHILD DELETES ITS WRAPPER: a wrapper never loses its
/// child. Selecting the wrapper AND its child is one deletion. Twin of Rust
/// `deleting_a_wrapped_child_deletes_its_wrapper`.
@Test func deletingAWrappedChildDeletesItsWrapper() {
    let doc = wrappedChildModel().document
    let sel = Document(layers: doc.layers, selectedLayer: 0,
                       selection: [ElementSelection.partial([0, 0, 0], [2])])
    #expect(sel.deleteSelection().layers[0].children.isEmpty, "the wrapper is gone")
    let grown = doc.insertElementAfter([0, 0], element: .rect(Rect(x: 50, y: 50, width: 5, height: 5)))
    let two = Document(layers: grown.layers, selectedLayer: 0,
                       selection: [ElementSelection.all([0, 0]), ElementSelection.all([0, 0, 0])])
    #expect(two.deleteSelection().layers[0].children.count == 1, "only the wrapper went; the rect stays")
}

// MARK: - Route 4 slice 5: Scale wraps (twins of Rust `wrap_scale_tests`)

private func strokedRounded(_ id: String) -> Element {
    .rect(Rect(x: 0, y: 0, width: 10, height: 10, rx: 2, ry: 2,
               stroke: Stroke(color: black, width: 1), id: id))
}

private func docOf(_ children: [Element], _ selection: [ElementSelection]) -> Document {
    Document(layers: [Layer(name: "L", children: children)], selectedLayer: 0, selection: selection)
}

@Test func aScaledLeafBecomesAWrapperAroundTheUntouchedElement() {
    for flag in [false, true] {
        let doc = docOf([strokedRounded("r")], [ElementSelection.partial([0, 0], [1])])
        let out = wrapScaleOverPaths(doc, [[0, 0]], .scale(1.5, 1.5), scaleStrokes: flag, corners: nil)
        guard case .live(.transformed(let w)) = out.getElement([0, 0]) else { Issue.record("a wrapper"); return }
        #expect(w.child == strokedRounded("r"))
        #expect(w.matrix == .scale(1.5, 1.5) && w.scaleStrokes == flag && w.transform == nil && w.id == nil)
        #expect(out.selection == [ElementSelection.all([0, 0])], "a partial entry becomes the whole wrapper")
    }
}

@Test func cornersOffDividesTheChildsRadii() {
    let doc = docOf([strokedRounded("r")], [ElementSelection.all([0, 0])])
    let out = wrapScaleOverPaths(doc, [[0, 0]], .scale(2, 4), scaleStrokes: false,
                                 corners: cornerCompensation(sx: 2, sy: 4, scaleCorners: false))
    guard case .live(.transformed(let w)) = out.getElement([0, 0]), case .rect(let r) = w.child else {
        Issue.record("a wrapped rect"); return
    }
    #expect(r.rx == 1 && r.ry == 0.5)
}

@Test func aWrapperAbsorbsAMatchingScaleAndOtherwiseIsWrappedAgain() {
    let m = Transform.scale(2, 3), s = Transform.scale(1.5, 1.5)
    for flag in [false, true] {
        let w = TransformedElem(child: strokedRounded("r"), matrix: m, scaleStrokes: flag, transform: .translate(5, 7))
        let doc = docOf([.live(.transformed(w))], [ElementSelection.all([0, 0])])
        guard case .live(.transformed(let a)) = wrapScaleOverPaths(doc, [[0, 0]], s, scaleStrokes: flag, corners: nil).getElement([0, 0])
        else { Issue.record("a wrapper"); return }
        #expect(a.child == strokedRounded("r"), "absorbed: still ONE wrapper, flag=\(flag)")
        #expect(a.matrix == s.multiply(.translate(5, 7)).multiply(m) && a.transform == nil)
        guard case .live(.transformed(let outer)) = wrapScaleOverPaths(doc, [[0, 0]], s, scaleStrokes: !flag, corners: nil).getElement([0, 0]),
              case .live(.transformed) = outer.child else { Issue.record("a different flag nests"); return }
        #expect(outer.matrix == s && outer.scaleStrokes == !flag)
    }
    let rot = TransformedElem(child: strokedRounded("r"), matrix: m, scaleStrokes: false, transform: .rotate(30))
    let doc = docOf([.live(.transformed(rot))], [ElementSelection.all([0, 0])])
    guard case .live(.transformed(let o)) = wrapScaleOverPaths(doc, [[0, 0]], s, scaleStrokes: false, corners: nil).getElement([0, 0]),
          case .live(.transformed) = o.child else { Issue.record("a rotated own transform is wrapped again"); return }
}
