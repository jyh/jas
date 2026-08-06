import Testing
@testable import JasLib

@Test func svgEmptyDocument() {
    let doc = Document(layers: [Layer(children: [])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("<?xml version=\"1.0\""))
    #expect(svg.contains("<svg xmlns="))
    #expect(svg.contains("</svg>"))
}

@Test func svgLineCoordinatesConverted() {
    let doc = Document(layers: [Layer(children: [
        .line(Line(x1: 0, y1: 0, x2: 72, y2: 36,
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let svg = documentToSvg(doc)
    // 72pt -> 96px, 36pt -> 48px
    #expect(svg.contains("x2=\"96\""))
    #expect(svg.contains("y2=\"48\""))
}

@Test func svgRectFillStroke() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                      fill: Fill(color: Color(r: 1, g: 0, b: 0)),
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("<rect"))
    #expect(svg.contains("fill=\"rgb(255,0,0)\""))
    #expect(svg.contains("stroke=\"rgb(0,0,0)\""))
    #expect(svg.contains("width=\"96\""))
}

/// Unique-id invariant on import (REFERENCE_GRAPH.md §2.5): two rects both
/// carry id="dup" in the source SVG. After dedupe the first (pre-order)
/// rect keeps the id and the second has its id cleared to nil.
@Test func svgDedupeImportIds() {
    let svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" \
    xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" \
    viewBox="0 0 192 96" width="192" height="96">
      <g inkscape:groupmode="layer" inkscape:label="Layer 1">
        <rect x="0" y="0" width="96" height="96" fill="rgb(255,0,0)" stroke="none" id="dup"/>
        <rect x="96" y="0" width="96" height="96" fill="rgb(0,0,255)" stroke="none" id="dup"/>
      </g>
    </svg>
    """
    let doc = svgToDocument(svg)
    let children = doc.layers[0].children
    #expect(children.count == 2)
    #expect(children[0].id == "dup")
    #expect(children[1].id == nil)
}

@Test func svgRectRounded() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72, rx: 6, ry: 6))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("rx=\"8\""))
    #expect(svg.contains("ry=\"8\""))
}

@Test func svgCircle() {
    let doc = Document(layers: [Layer(children: [
        .ellipse(Ellipse(cx: 36, cy: 36, rx: 18, ry: 18,
                          fill: Fill(color: Color(r: 0, g: 0, b: 1))))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("cx=\"48\""))
    #expect(svg.contains("r=\"24\""))
    #expect(svg.contains("fill=\"rgb(0,0,255)\""))
}

@Test func svgEllipse() {
    let doc = Document(layers: [Layer(children: [
        .ellipse(Ellipse(cx: 36, cy: 36, rx: 24, ry: 12))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("<ellipse"))
    #expect(svg.contains("rx=\"32\""))
    #expect(svg.contains("ry=\"16\""))
}

@Test func svgPolygon() {
    let doc = Document(layers: [Layer(children: [
        .polygon(Polygon(points: [(0, 0), (72, 0), (36, 72)],
                            stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("<polygon"))
    #expect(svg.contains("0,0 96,0 48,96"))
}

@Test func svgPolyline() {
    let doc = Document(layers: [Layer(children: [
        .polyline(Polyline(points: [(0, 0), (36, 72)],
                              stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("<polyline"))
    #expect(svg.contains("0,0 48,96"))
}

@Test func svgPath() {
    let doc = Document(layers: [Layer(children: [
        .path(Path(d: [.moveTo(0, 0), .lineTo(72, 72), .closePath],
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0)), fillRule: .nonzero))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("<path"))
    #expect(svg.contains("M0,0"))
    #expect(svg.contains("L96,96"))
    #expect(svg.contains("Z"))
}

@Test func svgPathCurveCommands() {
    let doc = Document(layers: [Layer(children: [
        .path(Path(d: [
            .moveTo(0, 0),
            .curveTo(x1: 0, y1: 36, x2: 36, y2: 72, x: 72, y: 72),
            .smoothCurveTo(x2: 108, y2: 72, x: 144, y: 0),
            .quadTo(x1: 36, y1: 36, x: 72, y: 0),
            .smoothQuadTo(144, 0),
            .arcTo(rx: 36, ry: 36, rotation: 0, largeArc: true, sweep: false, x: 72, y: 72),
        ], stroke: Stroke(color: Color(r: 0, g: 0, b: 0)), fillRule: .nonzero))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("C0,48 48,96 96,96"))
    #expect(svg.contains("S144,96 192,0"))
    #expect(svg.contains("Q48,48 96,0"))
    #expect(svg.contains("T192,0"))
    #expect(svg.contains("A48,48 0 1,0 96,96"))
}

@Test func svgText() {
    let doc = Document(layers: [Layer(children: [
        .text(Text(x: 10, y: 20, content: "Hello", fontFamily: "Arial",
                      fontSize: 12, fill: Fill(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("<text"))
    #expect(svg.contains("font-family=\"Arial\""))
    #expect(svg.contains(">Hello</text>"))
}

@Test func svgTextEscaping() {
    let doc = Document(layers: [Layer(children: [
        .text(Text(x: 0, y: 0, content: "<b>&</b>"))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("&lt;b&gt;&amp;&lt;/b&gt;"))
}

@Test func svgNoFill() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("fill=\"none\""))
}

@Test func svgNoStroke() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                      fill: Fill(color: Color(r: 1, g: 1, b: 1))))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("stroke=\"none\""))
}

@Test func svgOpacity() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72, opacity: 0.5))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("opacity=\"0.5\""))
}

@Test func svgFullOpacityOmitted() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72, opacity: 1.0))
    ])])
    let svg = documentToSvg(doc)
    #expect(!svg.contains("opacity="))
}

@Test func svgTransform() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                      transform: Transform(e: 36, f: 18)))
    ])])
    let svg = documentToSvg(doc)
    // translate(36pt, 18pt) -> e=48px, f=24px. The four MULTIPLIERS ride the
    // matrix-entry spelling rule (R2) and so always carry a decimal point;
    // e/f are POSITIONS and stay on the 4dp `fmt`. See `fmtMatrixEntry`.
    #expect(svg.contains("transform=\"matrix(1.0,0.0,0.0,1.0,48,24)\""))
}

@Test func svgStrokeLinecapLinejoin() {
    let doc = Document(layers: [Layer(children: [
        .line(Line(x1: 0, y1: 0, x2: 72, y2: 72,
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0),
                                        linecap: .round, linejoin: .bevel)))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("stroke-linecap=\"round\""))
    #expect(svg.contains("stroke-linejoin=\"bevel\""))
}

@Test func svgColorAlpha() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                      fill: Fill(color: Color(r: 1, g: 0, b: 0, a: 0.5))))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("rgba(255,0,0,0.5)"))
}

@Test func svgLayerName() {
    let doc = Document(layers: [
        Layer(name: "Background", children: [
            .rect(Rect(x: 0, y: 0, width: 72, height: 72))
        ])
    ])
    let svg = documentToSvg(doc)
    #expect(svg.contains("inkscape:label=\"Background\""))
}

@Test func svgMultipleLayers() {
    let doc = Document(layers: [
        Layer(name: "L1", children: [
            .line(Line(x1: 0, y1: 0, x2: 72, y2: 72,
                          stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
        ]),
        Layer(name: "L2", children: [
            .ellipse(Ellipse(cx: 36, cy: 36, rx: 18, ry: 18))
        ]),
    ])
    let svg = documentToSvg(doc)
    #expect(svg.contains("inkscape:label=\"L1\""))
    #expect(svg.contains("inkscape:label=\"L2\""))
}

@Test func svgViewBox() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 10, y: 20, width: 72, height: 36))
    ])])
    let svg = documentToSvg(doc)
    // bounds (10,20,72,36) in pt -> px
    #expect(svg.contains("viewBox=\"13.3333 26.6667 96 48\""))
}

// MARK: - SVG Import Tests

private func roundtrip(_ doc: Document) -> Document {
    let svg = documentToSvg(doc)
    return svgToDocument(svg)
}

@Test func svgImportEmpty() {
    let doc = Document(layers: [Layer(children: [])])
    let doc2 = roundtrip(doc)
    #expect(doc2.layers.count == 1)
}

@Test func svgImportLine() {
    let doc = Document(layers: [Layer(children: [
        .line(Line(x1: 0, y1: 0, x2: 72, y2: 36,
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let doc2 = roundtrip(doc)
    if case .line(let v) = doc2.layers[0].children[0] {
        #expect(abs(v.x2 - 72) < 0.1)
        #expect(abs(v.y2 - 36) < 0.1)
    } else {
        Issue.record("Expected line")
    }
}

@Test func svgImportRect() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 10, y: 20, width: 72, height: 36,
                      fill: Fill(color: Color(r: 1, g: 0, b: 0)),
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let doc2 = roundtrip(doc)
    if case .rect(let v) = doc2.layers[0].children[0] {
        #expect(abs(v.width - 72) < 0.1)
        #expect(v.fill != nil)
        #expect(abs(v.fill!.color.toRgba().0 - 1.0) < 0.1)
    } else {
        Issue.record("Expected rect")
    }
}

@Test func svgImportCircle() {
    let doc = Document(layers: [Layer(children: [
        .ellipse(Ellipse(cx: 36, cy: 36, rx: 18, ry: 18,
                          fill: Fill(color: Color(r: 0, g: 0, b: 1))))
    ])])
    let doc2 = roundtrip(doc)
    if case .ellipse(let v) = doc2.layers[0].children[0] {
        #expect(abs(v.rx - 18) < 0.1)
    } else {
        Issue.record("Expected a round ellipse")
    }
}

@Test func svgImportPolygon() {
    let doc = Document(layers: [Layer(children: [
        .polygon(Polygon(points: [(0, 0), (72, 0), (36, 72)],
                            stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let doc2 = roundtrip(doc)
    if case .polygon(let v) = doc2.layers[0].children[0] {
        #expect(v.points.count == 3)
        #expect(abs(v.points[1].0 - 72) < 0.1)
    } else {
        Issue.record("Expected polygon")
    }
}

@Test func svgImportPath() {
    let doc = Document(layers: [Layer(children: [
        .path(Path(d: [.moveTo(0, 0), .lineTo(72, 72), .closePath],
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0)), fillRule: .nonzero))
    ])])
    let doc2 = roundtrip(doc)
    if case .path(let v) = doc2.layers[0].children[0] {
        #expect(v.d.count == 3)
        if case .lineTo(let x, let y) = v.d[1] {
            #expect(abs(x - 72) < 0.1)
            #expect(abs(y - 72) < 0.1)
        } else {
            Issue.record("Expected lineTo")
        }
    } else {
        Issue.record("Expected path")
    }
}

@Test func svgImportText() {
    let doc = Document(layers: [Layer(children: [
        .text(Text(x: 10, y: 20, content: "Hello", fontFamily: "Arial",
                      fontSize: 12, fill: Fill(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let doc2 = roundtrip(doc)
    if case .text(let v) = doc2.layers[0].children[0] {
        #expect(v.content == "Hello")
        #expect(v.fontFamily == "Arial")
    } else {
        Issue.record("Expected text")
    }
}

@Test func svgFlatTextHasNoTspanWrapper() {
    // A Text with a single no-override tspan should round-trip as
    // flat SVG — no <tspan> wrapper, no xml:space="preserve".
    let doc = Document(layers: [Layer(children: [
        .text(Text(x: 0, y: 0, content: "Hello"))
    ])])
    let svg = documentToSvg(doc)
    #expect(!svg.contains("<tspan"))
    #expect(!svg.contains("xml:space"))
    #expect(svg.contains(">Hello</text>"))
}

@Test func svgMultiTspanTextEmitsTspanChildren() {
    // Two tspans with distinct overrides round-trip as <tspan>
    // children + xml:space="preserve" on the parent <text>.
    let tspans = [
        Tspan(id: 0, content: "Hello "),
        Tspan(id: 1, content: "world", fontWeight: "bold"),
    ]
    let doc = Document(layers: [Layer(children: [
        .text(Text(x: 0, y: 0, tspans: tspans))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("xml:space=\"preserve\""))
    #expect(svg.contains("<tspan>Hello </tspan>"))
    #expect(svg.contains("<tspan font-weight=\"bold\">world</tspan>"))
}

@Test func svgJasRoleEmittedOnTspan() {
    // Phase 1a: a wrapper Tspan with jasRole="paragraph" emits
    // urn:jas:1:role="paragraph" on the <tspan> element. Full
    // document round-trip through XMLDocument is deferred to
    // Phase 1b alongside the xmlns:jas namespace work.
    let tspans = [
        Tspan(id: 0, content: "", jasRole: "paragraph"),
        Tspan(id: 1, content: "hello"),
    ]
    let doc = Document(layers: [Layer(children: [
        .text(Text(x: 0, y: 0, tspans: tspans))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("urn:jas:1:role=\"paragraph\""),
            "expected urn:jas:1:role in serialised SVG, got: \(svg)")
    #expect(svg.contains(">hello</tspan>"))
}

@Test func svgTspanRoundTripPreservesOverrides() {
    // Round-trip a two-tspan text through SVG and back: content,
    // override attributes, and tspan count are preserved.
    let tspans = [
        Tspan(id: 0, content: "A"),
        Tspan(id: 1, content: "B", fontFamily: "Courier", fontWeight: "bold",
              textDecoration: ["line-through", "underline"]),
    ]
    let doc = Document(layers: [Layer(children: [
        .text(Text(x: 0, y: 0, tspans: tspans))
    ])])
    let doc2 = roundtrip(doc)
    guard case .text(let t) = doc2.layers[0].children[0] else {
        Issue.record("expected text"); return
    }
    #expect(t.tspans.count == 2)
    #expect(t.tspans[0].content == "A")
    #expect(t.tspans[0].hasNoOverrides)
    #expect(t.tspans[1].content == "B")
    #expect(t.tspans[1].fontFamily == "Courier")
    #expect(t.tspans[1].fontWeight == "bold")
    #expect(t.tspans[1].textDecoration == ["line-through", "underline"])
}

@Test func svgTextPathTspanRoundTrip() {
    let tspans = [
        Tspan(id: 0, content: "foo "),
        Tspan(id: 1, content: "bar", fontStyle: "italic"),
    ]
    let doc = Document(layers: [Layer(children: [
        .textPath(TextPath(d: [.moveTo(0, 0), .lineTo(100, 0)],
                               tspans: tspans))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("<tspan>foo </tspan>"))
    #expect(svg.contains("<tspan font-style=\"italic\">bar</tspan>"))
    let doc2 = roundtrip(doc)
    guard case .textPath(let tp) = doc2.layers[0].children[0] else {
        Issue.record("expected text path"); return
    }
    #expect(tp.tspans.count == 2)
    #expect(tp.tspans[1].fontStyle == "italic")
}

@Test func svgRoundTripTextYPreservesTop() {
    // Internally `Text.y` is the top of the layout box. Round-tripping
    // through SVG (where `y` is the baseline) must put us back at the
    // same top-of-box position.
    let doc = Document(layers: [Layer(children: [
        .text(Text(x: 10, y: 20, content: "Hi", fontFamily: "Arial",
                      fontSize: 16, fill: Fill(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let doc2 = roundtrip(doc)
    if case .text(let v) = doc2.layers[0].children[0] {
        #expect(abs(v.y - 20.0) < 1e-3)
        #expect(abs(v.x - 10.0) < 1e-3)
    } else {
        Issue.record("Expected text")
    }
}

@Test func svgImportOpacity() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72, opacity: 0.5))
    ])])
    let doc2 = roundtrip(doc)
    if case .rect(let v) = doc2.layers[0].children[0] {
        #expect(abs(v.opacity - 0.5) < 0.1)
    } else {
        Issue.record("Expected rect")
    }
}

@Test func svgImportTransform() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                      transform: Transform(e: 36, f: 18)))
    ])])
    let doc2 = roundtrip(doc)
    if case .rect(let v) = doc2.layers[0].children[0] {
        #expect(v.transform != nil)
        #expect(abs(v.transform!.e - 36) < 0.1)
        #expect(abs(v.transform!.f - 18) < 0.1)
    } else {
        Issue.record("Expected rect")
    }
}

@Test func svgImportLayerName() {
    let doc = Document(layers: [
        Layer(name: "Background", children: [
            .rect(Rect(x: 0, y: 0, width: 72, height: 72))
        ])
    ])
    let doc2 = roundtrip(doc)
    #expect(doc2.layers[0].name == "Background")
}

@Test func svgImportMultipleLayers() {
    let doc = Document(layers: [
        Layer(name: "L1", children: [
            .line(Line(x1: 0, y1: 0, x2: 72, y2: 72,
                          stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
        ]),
        Layer(name: "L2", children: [
            .ellipse(Ellipse(cx: 36, cy: 36, rx: 18, ry: 18))
        ]),
    ])
    let doc2 = roundtrip(doc)
    #expect(doc2.layers.count == 2)
    #expect(doc2.layers[0].name == "L1")
    #expect(doc2.layers[1].name == "L2")
}

// MARK: - Stable element id SVG round-trip (increment 2b)

@Test func svgElementIdWritten() {
    // A leaf element with an id emits a standard SVG `id` attribute,
    // mirroring how the name emits inkscape:label.
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72, id: "shape-7"))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("id=\"shape-7\""))
}

@Test func svgElementIdRoundTrip() {
    // An element's id survives a full document -> SVG -> document
    // round-trip, mirroring the existing name round-trip test.
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72, id: "rect-id-1")),
        .ellipse(Ellipse(cx: 36, cy: 36, rx: 18, ry: 18, id: "circ-id-2")),
    ])])
    let doc2 = roundtrip(doc)
    #expect(doc2.layers[0].children[0].id == "rect-id-1")
    #expect(doc2.layers[0].children[1].id == "circ-id-2")
}

@Test func svgGroupAndLayerIdRoundTrip() {
    // Container ids (Layer + nested Group) survive the round-trip too.
    let doc = Document(layers: [
        Layer(name: "L1", children: [
            .group(Group(children: [
                .rect(Rect(x: 0, y: 0, width: 10, height: 10))
            ], name: "G1", id: "group-id-9"))
        ], id: "layer-id-3")
    ])
    let doc2 = roundtrip(doc)
    #expect(doc2.layers[0].id == "layer-id-3")
    if case .group(let g) = doc2.layers[0].children[0] {
        #expect(g.id == "group-id-9")
    } else {
        Issue.record("Expected nested group")
    }
}

@Test func svgTextFamilyIdRoundTrip() {
    // The text family (Text/TextPath) hand-inlines its SVG attributes, so
    // its id needs the same round-trip guard as the shapes and containers.
    // This is precisely the element kind whose id the reference writer once
    // dropped, so every app pins it.
    let doc = Document(layers: [Layer(children: [
        .text(Text(x: 10, y: 20, content: "Hi", id: "text-id-1")),
        .textPath(TextPath(d: [.moveTo(0, 0), .lineTo(50, 0)],
                           content: "Hi", id: "textpath-id-1")),
    ])])
    let doc2 = roundtrip(doc)
    #expect(doc2.layers[0].children[0].id == "text-id-1")
    #expect(doc2.layers[0].children[1].id == "textpath-id-1")
}

@Test func svgIdlessOutputUnchanged() {
    // An element with no id must NOT emit any `id="..."` attribute on
    // its own tag, so id-less output stays byte-identical to before
    // this feature. The surviving inkscape:label name attribute proves
    // the writer ran. (We scope the check to the <rect> line so the
    // header's sodipodi:namedview id, if present, doesn't interfere.)
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72, name: "Box"))
    ])])
    let svg = documentToSvg(doc)
    let rectLine = svg.split(separator: "\n").first { $0.contains("<rect") }
    #expect(rectLine != nil)
    #expect(!(rectLine?.contains(" id=\"") ?? true))
    #expect(rectLine?.contains("inkscape:label=\"Box\"") ?? false)
    // Round-trip: an id-less element loads back with no id.
    let doc2 = roundtrip(doc)
    #expect(doc2.layers[0].children[0].id == nil)
}

@Test func svgImportColorAlpha() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                      fill: Fill(color: Color(r: 1, g: 0, b: 0, a: 0.5))))
    ])])
    let doc2 = roundtrip(doc)
    if case .rect(let v) = doc2.layers[0].children[0] {
        #expect(v.fill != nil)
        // After roundtrip + normalization, alpha moves to fill.opacity
        #expect(abs(v.fill!.color.alpha - 1.0) < 0.01)
        #expect(abs(v.fill!.opacity - 0.5) < 0.1)
    } else {
        Issue.record("Expected rect")
    }
}

@Test func svgImportHexColor6() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg">\
    <g><rect x="0" y="0" width="96" height="96" fill="#ff8000"/></g></svg>
    """
    let doc = svgToDocument(svg)
    if case .rect(let v) = doc.layers[0].children[0] {
        #expect(v.fill != nil)
        #expect(abs(v.fill!.color.toRgba().0 - 1.0) < 0.01)
        #expect(abs(v.fill!.color.toRgba().1 - 128.0 / 255.0) < 0.01)
        #expect(abs(v.fill!.color.toRgba().2 - 0.0) < 0.01)
    } else {
        Issue.record("Expected rect")
    }
}

@Test func svgImportHexColor3() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg">\
    <g><rect x="0" y="0" width="96" height="96" fill="#f00"/></g></svg>
    """
    let doc = svgToDocument(svg)
    if case .rect(let v) = doc.layers[0].children[0] {
        #expect(v.fill != nil)
        #expect(abs(v.fill!.color.toRgba().0 - 1.0) < 0.01)
        #expect(abs(v.fill!.color.toRgba().1 - 0.0) < 0.01)
    } else {
        Issue.record("Expected rect")
    }
}

@Test func svgImportHexStroke() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg">\
    <g><line x1="0" y1="0" x2="96" y2="96" stroke="#0000ff" stroke-width="2"/></g></svg>
    """
    let doc = svgToDocument(svg)
    if case .line(let v) = doc.layers[0].children[0] {
        #expect(v.stroke != nil)
        #expect(abs(v.stroke!.color.toRgba().2 - 1.0) < 0.01)
    } else {
        Issue.record("Expected line")
    }
}

private func pt(_ px: Double) -> Double { px * 72.0 / 96.0 }

@Test func svgImportRelativePathCommands() {
    // m 10,20 l 30,0 l 0,40 z => absolute M(10,20) L(40,20) L(40,60) Z
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg">\
    <g><path d="m 10,20 l 30,0 l 0,40 z" stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>
    """
    let doc = svgToDocument(svg)
    if case .path(let v) = doc.layers[0].children[0] {
        #expect(v.d.count == 4)
        if case .moveTo(let x, let y) = v.d[0] {
            #expect(abs(x - pt(10)) < 0.1)
            #expect(abs(y - pt(20)) < 0.1)
        } else { Issue.record("Expected moveTo") }
        if case .lineTo(let x, let y) = v.d[1] {
            #expect(abs(x - pt(40)) < 0.1)
            #expect(abs(y - pt(20)) < 0.1)
        } else { Issue.record("Expected lineTo") }
        if case .lineTo(let x, let y) = v.d[2] {
            #expect(abs(x - pt(40)) < 0.1)
            #expect(abs(y - pt(60)) < 0.1)
        } else { Issue.record("Expected lineTo") }
        if case .closePath = v.d[3] {} else { Issue.record("Expected closePath") }
    } else {
        Issue.record("Expected path")
    }
}

@Test func svgImportRelativeCurve() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg">\
    <g><path d="M 0,0 c 10,20 30,40 50,60" stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>
    """
    let doc = svgToDocument(svg)
    if case .path(let v) = doc.layers[0].children[0] {
        if case .curveTo(let x1, let y1, _, _, let x, let y) = v.d[1] {
            #expect(abs(x1 - pt(10)) < 0.1)
            #expect(abs(y1 - pt(20)) < 0.1)
            #expect(abs(x - pt(50)) < 0.1)
            #expect(abs(y - pt(60)) < 0.1)
        } else { Issue.record("Expected curveTo") }
    } else {
        Issue.record("Expected path")
    }
}

@Test func svgImportHVCommands() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg">\
    <g><path d="M 10,10 H 50 V 80 h -20 v -30" stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>
    """
    let doc = svgToDocument(svg)
    if case .path(let v) = doc.layers[0].children[0] {
        #expect(v.d.count == 5)
        // H 50 => LineTo(pt(50), pt(10))
        if case .lineTo(let x, let y) = v.d[1] {
            #expect(abs(x - pt(50)) < 0.1)
            #expect(abs(y - pt(10)) < 0.1)
        } else { Issue.record("Expected lineTo") }
        // V 80 => LineTo(pt(50), pt(80))
        if case .lineTo(let x, let y) = v.d[2] {
            #expect(abs(x - pt(50)) < 0.1)
            #expect(abs(y - pt(80)) < 0.1)
        } else { Issue.record("Expected lineTo") }
        // h -20 => LineTo(pt(30), pt(80))
        if case .lineTo(let x, let y) = v.d[3] {
            #expect(abs(x - pt(30)) < 0.1)
            #expect(abs(y - pt(80)) < 0.1)
        } else { Issue.record("Expected lineTo") }
        // v -30 => LineTo(pt(30), pt(50))
        if case .lineTo(let x, let y) = v.d[4] {
            #expect(abs(x - pt(30)) < 0.1)
            #expect(abs(y - pt(50)) < 0.1)
        } else { Issue.record("Expected lineTo") }
    } else {
        Issue.record("Expected path")
    }
}

// MARK: - Arc round-trip tests

@Test func svgRoundtripArcLargeSweep() {
    let layer = Layer(children: [
        .path(Path(d: [.moveTo(0, 0), .arcTo(rx: 36, ry: 36, rotation: 0, largeArc: true, sweep: true, x: 72, y: 0)],
                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0)), fillRule: .nonzero))
    ])
    let doc = Document(layers: [layer])
    let svg = documentToSvg(doc)
    let doc2 = svgToDocument(svg)
    if case .path(let v) = doc2.layers[0].children[0] {
        if case .arcTo(let rx, _, _, let la, let sw, let x, _) = v.d[1] {
            #expect(abs(rx - 36) < 0.1)
            #expect(la == true)
            #expect(sw == true)
            #expect(abs(x - 72) < 0.1)
        } else { Issue.record("Expected arcTo") }
    } else { Issue.record("Expected path") }
}

@Test func svgRoundtripArcSmallNoSweep() {
    let layer = Layer(children: [
        .path(Path(d: [.moveTo(0, 0), .arcTo(rx: 36, ry: 18, rotation: 30, largeArc: false, sweep: false, x: 72, y: 36)],
                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0)), fillRule: .nonzero))
    ])
    let doc = Document(layers: [layer])
    let svg = documentToSvg(doc)
    let doc2 = svgToDocument(svg)
    if case .path(let v) = doc2.layers[0].children[0] {
        if case .arcTo(_, let ry, let rot, let la, let sw, _, _) = v.d[1] {
            #expect(abs(ry - 18) < 0.1)
            #expect(abs(rot - 30) < 0.1)
            #expect(la == false)
            #expect(sw == false)
        } else { Issue.record("Expected arcTo") }
    } else { Issue.record("Expected path") }
}

// MARK: - Named color tests

@Test func svgImportNamedColorRed() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg"><g><rect x="0" y="0" width="96" height="96" fill="red"/></g></svg>
    """
    let doc = svgToDocument(svg)
    if case .rect(let v) = doc.layers[0].children[0] {
        #expect(abs(v.fill!.color.toRgba().0 - 1.0) < 0.01)
        #expect(abs(v.fill!.color.toRgba().1 - 0.0) < 0.01)
    } else { Issue.record("Expected rect") }
}

@Test func svgImportNamedColorSteelblue() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg"><g><rect x="0" y="0" width="96" height="96" fill="steelblue"/></g></svg>
    """
    let doc = svgToDocument(svg)
    if case .rect(let v) = doc.layers[0].children[0] {
        #expect(abs(v.fill!.color.toRgba().0 - 70.0/255.0) < 0.01)
        #expect(abs(v.fill!.color.toRgba().1 - 130.0/255.0) < 0.01)
        #expect(abs(v.fill!.color.toRgba().2 - 180.0/255.0) < 0.01)
    } else { Issue.record("Expected rect") }
}

// MARK: - Hex color parsing (4-digit and 8-digit)

@Test func parseColor4DigitHex() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="96" height="96" fill="#F00A"/></svg>
    """
    let doc = svgToDocument(svg)
    if case .rect(let v) = doc.layers[0].children[0] {
        let c = v.fill!.color
        let (r, g, b, _) = c.toRgba()
        #expect(abs(r - 1.0) < 0.01)
        #expect(abs(g) < 0.01)
        #expect(abs(b) < 0.01)
        // Alpha extracted to fill.opacity by normalizer
        #expect(abs(v.fill!.opacity - 0.667) < 0.01)
        #expect(abs(c.alpha - 1.0) < 1e-9)
    } else { Issue.record("Expected rect") }
}

@Test func parseColor8DigitHex() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="96" height="96" fill="#FF000080"/></svg>
    """
    let doc = svgToDocument(svg)
    if case .rect(let v) = doc.layers[0].children[0] {
        let c = v.fill!.color
        let (r, _, _, _) = c.toRgba()
        #expect(abs(r - 1.0) < 0.01)
        #expect(abs(v.fill!.opacity - 0.502) < 0.01)
        #expect(abs(c.alpha - 1.0) < 1e-9)
    } else { Issue.record("Expected rect") }
}

// MARK: - fill-opacity / stroke-opacity

@Test func importFillOpacity() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="96" height="96" fill="red" fill-opacity="0.5"/></svg>
    """
    let doc = svgToDocument(svg)
    if case .rect(let v) = doc.layers[0].children[0] {
        #expect(abs(v.fill!.opacity - 0.5) < 0.01)
    } else { Issue.record("Expected rect") }
}

@Test func importStrokeOpacity() {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="96" height="96" stroke="blue" stroke-width="2" stroke-opacity="0.3"/></svg>
    """
    let doc = svgToDocument(svg)
    if case .rect(let v) = doc.layers[0].children[0] {
        #expect(abs(v.stroke!.opacity - 0.3) < 0.01)
    } else { Issue.record("Expected rect") }
}

@Test func exportFillOpacity() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                    fill: Fill(color: Color(r: 1, g: 0, b: 0), opacity: 0.5)))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("fill-opacity=\"0.5\""))
}

@Test func exportStrokeOpacity() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                    stroke: Stroke(color: .black, opacity: 0.4)))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("stroke-opacity=\"0.4\""))
}

@Test func exportOmitsOpacityWhenOne() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72, fill: Fill(color: .black)))
    ])])
    let svg = documentToSvg(doc)
    #expect(!svg.contains("fill-opacity"))
    #expect(!svg.contains("stroke-opacity"))
}

// MARK: - Normalizer

@Test func normalizeExtractsFillAlpha() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                    fill: Fill(color: Color(r: 1, g: 0, b: 0, a: 0.5))))
    ])])
    let doc2 = normalizeDocument(doc)
    if case .rect(let v) = doc2.layers[0].children[0] {
        #expect(abs(v.fill!.opacity - 0.5) < 1e-9)
        #expect(abs(v.fill!.color.alpha - 1.0) < 1e-9)
    } else { Issue.record("Expected rect") }
}

@Test func normalizeMultipliesExisting() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                    fill: Fill(color: Color(r: 1, g: 0, b: 0, a: 0.5), opacity: 0.8)))
    ])])
    let doc2 = normalizeDocument(doc)
    if case .rect(let v) = doc2.layers[0].children[0] {
        #expect(abs(v.fill!.opacity - 0.4) < 1e-9)
        #expect(abs(v.fill!.color.alpha - 1.0) < 1e-9)
    } else { Issue.record("Expected rect") }
}

@Test func normalizeIdempotent() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                    fill: Fill(color: Color(r: 1, g: 0, b: 0, a: 0.5), opacity: 0.8)))
    ])])
    let doc2 = normalizeDocument(doc)
    let doc3 = normalizeDocument(doc2)
    if case .rect(let v2) = doc2.layers[0].children[0],
       case .rect(let v3) = doc3.layers[0].children[0] {
        #expect(abs(v2.fill!.opacity - v3.fill!.opacity) < 1e-9)
    } else { Issue.record("Expected rect") }
}

@Test func roundtripFillOpacity() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 10, y: 20, width: 72, height: 72,
                    fill: Fill(color: Color(r: 1, g: 0, b: 0), opacity: 0.5)))
    ])])
    let svg = documentToSvg(doc)
    let doc2 = svgToDocument(svg)
    if case .rect(let v) = doc2.layers[0].children[0] {
        #expect(abs(v.fill!.opacity - 0.5) < 0.01)
    } else { Issue.record("Expected rect") }
}

// MARK: - Color.withAlpha

@Test func colorWithAlphaRgb() {
    let c = Color(r: 1, g: 0, b: 0).withAlpha(0.5)
    #expect(c == Color.rgb(r: 1, g: 0, b: 0, a: 0.5))
}

@Test func colorWithAlphaHsb() {
    let c = Color.hsb(h: 180, s: 1, b: 1, a: 1).withAlpha(0.3)
    #expect(c == Color.hsb(h: 180, s: 1, b: 1, a: 0.3))
}

@Test func colorWithAlphaCmyk() {
    let c = Color.cmyk(c: 0, m: 1, y: 1, k: 0, a: 1).withAlpha(0.7)
    #expect(c == Color.cmyk(c: 0, m: 1, y: 1, k: 0, a: 0.7))
}

@Test func fillDefaultOpacity() {
    #expect(Fill(color: .black).opacity == 1.0)
}

@Test func strokeDefaultOpacity() {
    #expect(Stroke(color: .black).opacity == 1.0)
}

// MARK: - Tspan rotate roundtrip (multi-value handling)

private func svgWithTspanMarkup(_ markup: String) -> String {
    return """
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
<text x="0" y="20" font-size="12">\(markup)</text>
</svg>
"""
}

@Test func svgSingleValueTspanRotateRoundtrip() {
    let svg = svgWithTspanMarkup(#"<tspan rotate="30">abc</tspan>"#)
    let doc = svgToDocument(svg)
    guard case .text(let t) = doc.layers[0].children[0] else {
        Issue.record("expected Text"); return
    }
    #expect(t.tspans.count == 1)
    #expect(t.tspans[0].content == "abc")
    #expect(t.tspans[0].rotate == 30.0)
}

@Test func svgMultiValueTspanRotateSplitsPerGlyph() {
    let svg = svgWithTspanMarkup(#"<tspan rotate="45 90 0">abc</tspan>"#)
    let doc = svgToDocument(svg)
    guard case .text(let t) = doc.layers[0].children[0] else {
        Issue.record("expected Text"); return
    }
    #expect(t.tspans.count == 3)
    #expect(t.tspans[0].content == "a")
    #expect(t.tspans[0].rotate == 45.0)
    #expect(t.tspans[1].content == "b")
    #expect(t.tspans[1].rotate == 90.0)
    #expect(t.tspans[2].content == "c")
    #expect(t.tspans[2].rotate == 0.0)
    #expect(t.tspans[0].id == 0)
    #expect(t.tspans[1].id == 1)
    #expect(t.tspans[2].id == 2)
}

@Test func svgMultiValueTspanRotateReusesLastAngle() {
    let svg = svgWithTspanMarkup(#"<tspan rotate="45 90">abcd</tspan>"#)
    let doc = svgToDocument(svg)
    guard case .text(let t) = doc.layers[0].children[0] else {
        Issue.record("expected Text"); return
    }
    #expect(t.tspans.count == 4)
    #expect(t.tspans[0].rotate == 45.0)
    #expect(t.tspans[1].rotate == 90.0)
    #expect(t.tspans[2].rotate == 90.0)
    #expect(t.tspans[3].rotate == 90.0)
}

/// TSPAN.md specifies nested-tspan flattening on import (unimplemented in
/// the active ports); leading-whitespace-in-tspan also diverges (Rust
/// trims, Swift preserves) and is corpus-unexercised; implementation
/// deferred to the Paragraph-panel phase.
///
/// This probe pins CURRENT behavior, not the spec: the Swift parser reads
/// the outer <tspan>'s stringValue, which CONCATENATES the nested
/// <tspan>'s content, yielding one tspan "ab". Rust's mirror probe
/// (svg.rs `nested_tspan_current_behavior_probe`) observes "a" — the
/// active ports diverge on nested-tspan input today, which is why no
/// cross-language fixture carries one.
@Test func nestedTspanCurrentBehaviorProbe() {
    let svg = """
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
<text y="20" font-size="10"><tspan>a<tspan>b</tspan></tspan></text>
</svg>
"""
    let doc = svgToDocument(svg)
    guard case .text(let t) = doc.layers[0].children[0] else {
        Issue.record("expected Text"); return
    }
    #expect(t.tspans.count == 1)
    #expect(t.tspans[0].content == "ab",
            "current Swift behavior: the nested tspan's content concatenates via stringValue")
}

@Test func svgPerGlyphTspanRotateFullRoundtrip() {
    var doc = Document(layers: [Layer(children: [
        .text(emptyTextElem(x: 10, y: 20, width: 0, height: 0))
    ])])
    if case .text(let t0) = doc.layers[0].children[0] {
        let tspans = [
            Tspan(id: 0, content: "a", rotate: 45),
            Tspan(id: 1, content: "b", rotate: 90),
            Tspan(id: 2, content: "c", rotate: 0),
        ]
        doc = doc.replaceElement([0, 0], with: .text(t0.withTspans(tspans)))
    }
    let svg = documentToSvg(doc)
    let doc2 = svgToDocument(svg)
    guard case .text(let t) = doc2.layers[0].children[0] else {
        Issue.record("expected Text"); return
    }
    #expect(t.tspans.count == 3)
    #expect(t.tspans[0].rotate == 45.0)
    #expect(t.tspans[1].rotate == 90.0)
    #expect(t.tspans[2].rotate == 0.0)
}

// MARK: - DASH_ALIGN.md §Persistence

@Test func dashAlignAnchorsRoundtripsWhenTrue() {
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0,
                        dashAlignAnchors: true)
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 100, height: 60, fill: nil, stroke: stroke))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("data-jas-dash-align-anchors=\"true\""))
    let doc2 = svgToDocument(svg)
    guard case .rect(let r) = doc2.layers[0].children[0] else {
        Issue.record("expected Rect"); return
    }
    #expect(r.stroke?.dashAlignAnchors == true)
}

@Test func dashAlignAnchorsOmittedWhenFalse() {
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 1.0)
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 100, height: 60, fill: nil, stroke: stroke))
    ])])
    let svg = documentToSvg(doc)
    #expect(!svg.contains("data-jas-dash-align-anchors"))
}

@Test func dashAlignAnchorsDefaultsFalseOnImport() {
    let svg = "<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\"><rect x=\"0\" y=\"0\" width=\"100\" height=\"60\" stroke=\"black\" stroke-width=\"1\"/></svg>"
    let doc = svgToDocument(svg)
    guard case .rect(let r) = doc.layers[0].children[0] else {
        Issue.record("expected Rect"); return
    }
    #expect(r.stroke?.dashAlignAnchors == false)
}

// MARK: - DocumentSetup + PrintPreferences SVG persistence (PRINT.md §Phase 2)

@Test func defaultDocSetupAndPrefsEmitNoJasBlocks() {
    // Pristine doc must not produce any <jas:*> metadata or
    // sodipodi:namedview wrapper — keeps minimal SVGs minimal.
    let doc = Document(layers: [Layer(children: [])])
    let svg = documentToSvg(doc)
    #expect(!svg.contains("<jas:document-setup"))
    #expect(!svg.contains("<jas:print-preferences"))
    #expect(!svg.contains("<sodipodi:namedview"))
}

@Test func documentSetupRoundTripsThroughSvg() {
    let s = DocumentSetup(
        bleedTop: 9, bleedRight: 18, bleedBottom: 36, bleedLeft: 12,
        bleedUniform: false,
        showImagesOutline: true,
        highlightSubstitutedGlyphs: true
    )
    let doc = Document(layers: [Layer(children: [])], documentSetup: s)
    let svg = documentToSvg(doc)
    #expect(svg.contains("<jas:document-setup"))
    #expect(svg.contains("xmlns:jas="))

    let parsed = svgToDocument(svg)
    #expect(parsed.documentSetup == s)
}

@Test func advancedSubRecordRoundTripsThroughSvg() {
    let a = Advanced(printAsBitmap: true, overprintFlattenerPreset: .highResolution)
    let p = PrintPreferences(advanced: a)
    let doc = Document(layers: [Layer(children: [])], printPreferences: p)
    let svg = documentToSvg(doc)
    #expect(svg.contains("<jas:advanced"))
    #expect(svg.contains("print-as-bitmap=\"true\""))
    #expect(svg.contains("overprint-flattener-preset=\"high_resolution\""))
    let parsed = svgToDocument(svg)
    #expect(parsed.printPreferences.advanced == a)
}

@Test func documentSetupPhase6FieldsRoundTripThroughSvg() {
    let s = DocumentSetup(
        gridSize: 36,
        gridColor: "#0099ff",
        paperColor: "#fff8e7",
        simulateColoredPaper: true,
        transparencyFlattenerPreset: .highResolution,
        discardWhiteOverprint: true
    )
    let doc = Document(layers: [Layer(children: [])], documentSetup: s)
    let svg = documentToSvg(doc)
    #expect(svg.contains("grid-size=\"36\""))
    #expect(svg.contains("paper-color=\"#fff8e7\""))
    #expect(svg.contains("simulate-colored-paper=\"true\""))
    #expect(svg.contains("transparency-flattener-preset=\"high_resolution\""))
    let parsed = svgToDocument(svg)
    #expect(parsed.documentSetup == s)
}

@Test func colorManagementSubRecordRoundTripsThroughSvg() {
    let c = ColorManagement(
        documentProfile: "sRGB IEC61966-2.1",
        colorHandling: .postscriptColorManagement,
        printerProfile: "U.S. Web Coated (SWOP) v2",
        renderingIntent: .saturation,
        preserveRgbNumbers: true
    )
    let p = PrintPreferences(colorManagement: c)
    let doc = Document(layers: [Layer(children: [])], printPreferences: p)
    let svg = documentToSvg(doc)
    #expect(svg.contains("<jas:color-management"))
    #expect(svg.contains("color-handling=\"postscript_color_management\""))
    #expect(svg.contains("rendering-intent=\"saturation\""))
    #expect(svg.contains("sRGB IEC61966-2.1"))
    let parsed = svgToDocument(svg)
    #expect(parsed.printPreferences.colorManagement == c)
}

@Test func graphicsSubRecordRoundTripsThroughSvg() {
    let g = Graphics(
        flatness: 0.4,
        fontDownload: .complete,
        postscriptLevel: .level2,
        dataFormat: .ascii,
        compatibleGradientPrinting: true,
        rasterEffectsResolution: 600.0
    )
    let p = PrintPreferences(graphics: g)
    let doc = Document(layers: [Layer(children: [])], printPreferences: p)
    let svg = documentToSvg(doc)
    #expect(svg.contains("<jas:graphics"))
    #expect(svg.contains("flatness=\"0.4\""))
    #expect(svg.contains("font-download=\"complete\""))
    let parsed = svgToDocument(svg)
    #expect(parsed.printPreferences.graphics == g)
}

@Test func outputSubRecordRoundTripsThroughSvg() {
    let o = Output(
        mode: .separations,
        emulsion: .downRight,
        imagePolarity: .negative,
        printerResolution: "150 lpi / 1200 dpi",
        convertSpotToProcess: true,
        overprintBlack: true,
        inks: [
            InkOverride(name: "Process Cyan", print: false, frequency: 100, angle: 105, dotShape: .ellipse),
            InkOverride(name: "PANTONE 185 C", print: true, frequency: 85, angle: 45, dotShape: .square),
        ]
    )
    let p = PrintPreferences(output: o)
    let doc = Document(layers: [Layer(children: [])], printPreferences: p)
    let svg = documentToSvg(doc)
    #expect(svg.contains("<jas:output"))
    #expect(svg.contains("<jas:ink"))
    #expect(svg.contains("PANTONE 185 C"))
    let parsed = svgToDocument(svg)
    #expect(parsed.printPreferences.output == o)
}

@Test func printPreferencesRoundTripThroughSvg() {
    let p = PrintPreferences(
        presetName: "My Preset",
        printerName: "LaserJet 5000",
        copies: 3,
        collate: true,
        reverseOrder: true,
        artboardRangeMode: .range,
        artboardRange: "1-3,5",
        ignoreArtboards: true,
        skipBlankArtboards: true,
        mediaSize: .a4,
        mediaWidth: 595,
        mediaHeight: 842,
        orientation: .landscape,
        autoRotate: false,
        transverse: true,
        printLayers: .visible,
        placementX: 12.5,
        placementY: -3.25,
        scalingMode: .custom,
        customScale: 75,
        tileOverlapH: 1,
        tileOverlapV: 2,
        tileRange: "1-2",
        marksAndBleed: MarksAndBleed(
            allPrinterMarks: true,
            trimMarks: true,
            registrationMarks: true,
            colorBars: true,
            pageInformation: true,
            printerMarkType: .japanese,
            trimMarkWeight: 0.5,
            markOffset: 12,
            useDocumentBleed: false,
            bleedTop: 4, bleedRight: 5,
            bleedBottom: 6, bleedLeft: 7
        )
    )
    let doc = Document(layers: [Layer(children: [])], printPreferences: p)
    let svg = documentToSvg(doc)
    #expect(svg.contains("<jas:print-preferences"))
    #expect(svg.contains("<jas:marks-and-bleed"))

    let parsed = svgToDocument(svg)
    #expect(parsed.printPreferences == p)
}

@Test func liveReferenceAndCompoundRoundTripThroughSvg() {
    // REFERENCE_GRAPH.md Phase 2a SVG codec: a reference emits/parses as
    // <use href="#id"> and a compound as <g data-jas-live="compound_shape"
    // data-jas-operation=...> — both round-trip (the compound previously
    // demoted to a plain Group and lost its operation). Mirrors Rust's
    // `live_reference_and_compound_round_trip_through_svg`.
    func rectAt(_ x: Double, id: String? = nil) -> Rect {
        Rect(x: x, y: 0, width: 10, height: 10,
             fill: Fill(color: Color(r: 0, g: 0, b: 0)), id: id)
    }
    let target = rectAt(0, id: "r1")
    let reference = ReferenceElem(target: ElementRef("r1"), name: nil, id: "ref1")
    let compound = CompoundShape(
        operation: .subtractFront,
        operands: [.rect(rectAt(0)), .rect(rectAt(5))], name: nil)
    let doc = Document(layers: [Layer(children: [
        .rect(target),
        .live(.reference(reference)),
        .live(.compoundShape(compound)),
    ])], artboards: [])

    let svg = documentToSvg(doc)
    #expect(svg.contains("<use href=\"#r1\""), "reference -> <use href: \(svg)")
    #expect(svg.contains("data-jas-operation=\"subtract_front\""),
            "compound emits its operation: \(svg)")

    let parsed = svgToDocument(svg)
    let kids = parsed.layers[0].children
    guard case .live(.reference(let r)) = kids[1] else {
        Issue.record("expected a Reference, got \(kids[1])"); return
    }
    #expect(r.target.id == "r1")
    #expect(r.id == "ref1", "reference id round-trips")
    guard case .live(.compoundShape(let cs)) = kids[2] else {
        Issue.record("expected a CompoundShape, got \(kids[2])"); return
    }
    #expect(cs.operation == .subtractFront)
    #expect(cs.operands.count == 2)
}

// MARK: - Arrowhead SVG persistence (ARROWFIX2 item 2)

@Test func svgArrowheadsRoundtripOnLine() {
    // All five arrow fields survive save->load on a line.
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 2,
                        startArrow: .simpleArrow, endArrow: .diamond,
                        startArrowScale: 150, endArrowScale: 200,
                        arrowAlign: .centerAtEnd)
    let doc = Document(layers: [Layer(children: [
        .line(Line(x1: 0, y1: 0, x2: 100, y2: 0, stroke: stroke))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("jas:start-arrow=\"simple_arrow\""), "\(svg)")
    #expect(svg.contains("jas:end-arrow=\"diamond\""), "\(svg)")
    #expect(svg.contains("jas:start-arrow-scale=\"150\""), "\(svg)")
    #expect(svg.contains("jas:end-arrow-scale=\"200\""), "\(svg)")
    #expect(svg.contains("jas:arrow-align=\"center_at_end\""), "\(svg)")
    let doc2 = svgToDocument(svg)
    guard case .line(let l) = doc2.layers[0].children[0], let s = l.stroke else {
        Issue.record("expected a stroked Line"); return
    }
    #expect(s.startArrow == .simpleArrow)
    #expect(s.endArrow == .diamond)
    #expect(s.startArrowScale == 150)
    #expect(s.endArrowScale == 200)
    #expect(s.arrowAlign == .centerAtEnd)
}

@Test func svgArrowheadsRoundtripOnPath() {
    // A one-armed arrowed path: end arrow only, default scale + align.
    let stroke = Stroke(color: Color(r: 0, g: 0, b: 0), width: 6.6667,
                        endArrow: .stealthArrow)
    let doc = Document(layers: [Layer(children: [
        .path(Path(d: [.moveTo(0, 0), .curveTo(x1: 0, y1: 40, x2: 40, y2: 40, x: 40, y: 0)],
                   stroke: stroke, fillRule: .nonzero))
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("jas:end-arrow=\"stealth_arrow\""), "\(svg)")
    #expect(!svg.contains("jas:start-arrow"), "\(svg)")
    #expect(!svg.contains("jas:start-arrow-scale"), "\(svg)")
    #expect(!svg.contains("jas:end-arrow-scale"), "\(svg)")
    #expect(!svg.contains("jas:arrow-align"), "\(svg)")
    let doc2 = svgToDocument(svg)
    guard case .path(let p) = doc2.layers[0].children[0], let s = p.stroke else {
        Issue.record("expected a stroked Path"); return
    }
    #expect(s.startArrow == .none)
    #expect(s.endArrow == .stealthArrow)
    #expect(s.startArrowScale == 100)
    #expect(s.endArrowScale == 100)
    #expect(s.arrowAlign == .tipAtEnd)
}

@Test func svgPlainStrokeEmitsNoJasArrowAttrs() {
    // Byte-cleanliness: an ordinary stroke emits none of the jas:arrow attrs.
    let doc = Document(layers: [Layer(children: [
        .line(Line(x1: 0, y1: 0, x2: 50, y2: 50,
                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
    ])])
    let svg = documentToSvg(doc)
    #expect(!svg.contains("jas:start-arrow"), "\(svg)")
    #expect(!svg.contains("jas:end-arrow"), "\(svg)")
    #expect(!svg.contains("jas:arrow-align"), "\(svg)")
}

@Test func svgPlainImportDefaultsArrowsToNone() {
    // Cross-tool: plain SVG (no jas attrs) parses to no arrows.
    let svg = """
    <?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">\
    <line x1="0" y1="0" x2="100" y2="0" stroke="black" stroke-width="2"/></svg>
    """
    let doc = svgToDocument(svg)
    guard case .line(let l) = doc.layers[0].children[0], let s = l.stroke else {
        Issue.record("expected a stroked Line"); return
    }
    #expect(s.startArrow == .none)
    #expect(s.endArrow == .none)
    #expect(s.startArrowScale == 100)
    #expect(s.endArrowScale == 100)
    #expect(s.arrowAlign == .tipAtEnd)
}

// MARK: - Matrix entry precision (R2, ruled 2026-07-31)
//
// These tests measure the PROPERTY -- that a matrix which leaves the writer
// and comes back is still the SAME LINEAR MAP -- not the spelling that
// achieves it. The spelling is pinned separately, and only because it is a
// cross-port contract; if a future edit finds a better spelling, only those
// tests should have to move. Mirrors the `MATRIX ENTRY PRECISION` block in
// jas_dioxus/src/geometry/svg.rs.

/// One save-and-reopen for an element-level transform: doc -> svg -> doc.
/// Returns the matrix as the reopened document sees it. Mirrors Rust's
/// `reopen`.
private func reopenTransform(_ t: Transform) -> Transform {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 100, height: 50,
                   fill: Fill(color: Color(r: 1, g: 0, b: 0)),
                   transform: t))
    ])])
    let reopened = svgToDocument(documentToSvg(doc))
    guard let m = reopened.layers[0].children[0].transform else {
        Issue.record("the SVG round trip dropped the transform entirely")
        return Transform.identity
    }
    return m
}

/// A rotation matrix is ORTHONORMAL: `a² + b² == 1`, to within the ulp or two
/// that `cos`/`sin` themselves cost. Quantising the multipliers destroys that
/// -- at 4dp cos30 lands on `0.866`, the reopened map shrinks by 2.2e-5 and
/// carries a shear it never had.
///
/// Fuzzed over the whole circle rather than pinned at 30°: a rule about a
/// MULTIPLIER has no lucky angles the way DYADICSIDE's round trip had lucky
/// zooms, but a single vector would still leave a future edit free to be
/// right in one place and wrong everywhere.
@Test func rotationStaysOrthonormalAcrossASaveAndReopen() {
    let tol = 4.0 * Double.ulpOfOne
    var worstDeg = 0.0
    var worstErr = 0.0
    for deg in 0..<360 {
        let angle = Double(deg)
        let m = reopenTransform(Transform.rotate(angle))
        let err = abs(m.a * m.a + m.b * m.b - 1.0)
        if err > worstErr { worstErr = err; worstDeg = angle }
    }
    #expect(worstErr <= tol,
            "a reopened rotation is no longer orthonormal: worst |a²+b²-1| = \(worstErr) at \(worstDeg)°, tolerance \(tol)")
}

/// The four MULTIPLIERS survive a save-and-reopen BIT-EXACTLY.
///
/// They can, and so they must: `a`/`b`/`c`/`d` are unitless, so unlike `e`/`f`
/// they never pass through the pt<->px conversion, and nothing but the
/// writer's own precision stands between the value that was saved and the
/// value that comes back.
@Test func matrixMultipliersSurviveASaveAndReopenBitExactly() {
    for deg in 0..<360 {
        let t = Transform.rotate(Double(deg))
        let m = reopenTransform(t)
        for (name, got, want) in [("a", m.a, t.a), ("b", m.b, t.b),
                                  ("c", m.c, t.c), ("d", m.d, t.d)] {
            #expect(got.bitPattern == want.bitPattern,
                    "rotate(\(deg)°) came back with \(name) = \(got), saved \(want)")
        }
    }
}

/// Once reopened, a matrix is a FIXPOINT: saving and reopening it again
/// changes not one bit of any of the SIX entries.
///
/// This is the property that keeps drift from COMPOUNDING across sessions,
/// and it is stated over all six deliberately. `e`/`f` are POSITIONS and stay
/// at 4dp, so they are NOT expected to survive the first save unchanged --
/// they are expected to SETTLE on it, and then never move again however many
/// times the file is opened.
@Test func aReopenedMatrixIsBitIdenticalOnEveryLaterSaveAndReopen() {
    for deg in 0..<360 {
        for (tx, ty) in [(0.0, 0.0), (12.3456789, -98.7654321), (0.00001, 5000.25)] {
            let r = Transform.rotate(Double(deg))
            let t = Transform(a: r.a, b: r.b, c: r.c, d: r.d, e: tx, f: ty)
            let m1 = reopenTransform(t)
            let m2 = reopenTransform(m1)
            for (name, got, want) in [("a", m2.a, m1.a), ("b", m2.b, m1.b),
                                      ("c", m2.c, m1.c), ("d", m2.d, m1.d),
                                      ("e", m2.e, m1.e), ("f", m2.f, m1.f)] {
                #expect(got.bitPattern == want.bitPattern,
                        "rotate(\(deg)°)+translate(\(tx),\(ty)) is not a fixpoint: \(name) moved from \(want) to \(got) on the second reopen")
            }
        }
    }
}

/// THE ARTIST SYMPTOM, in one test: rotate a logo, save, reopen, rotate back
/// -- and land on the guides you started from.
@Test func rotateSaveReopenRotateBackReturnsToTheIdentity() {
    let tol = 4.0 * Double.ulpOfOne
    for step in 0..<720 {
        let angle = Double(step) * 0.5
        let there = reopenTransform(Transform.rotate(angle))
        let back = Transform.rotate(-angle).multiply(there)
        for (name, got, want) in [("a", back.a, 1.0), ("b", back.b, 0.0),
                                  ("c", back.c, 0.0), ("d", back.d, 1.0)] {
            #expect(abs(got - want) <= tol,
                    "rotate(\(angle)°), save, reopen, rotate(-\(angle)°) did not return to the identity: \(name) = \(got), expected \(want)")
        }
    }
}

/// And the error does not merely persist, it COMPOUNDS. Each new transform
/// composes onto the reloaded one (the Rust twin's `op_apply.rs`
/// `matrix.multiply(&current)`), so a per-save error in the multipliers is
/// re-multiplied on every subsequent edit.
///
/// SEVERAL ANGLES, AND ORTHONORMALITY CHECKED AT EVERY CYCLE, because a
/// single angle can be lucky in a way that hides the whole defect: 15° at 4dp
/// is a PERIODIC orbit -- `(0.9659, 0.2588)` and its rotations are each
/// other's quantised images, so after 24 cycles it lands back on an exact
/// `(1, 0)` and the accumulated drift cancels to nothing.
@Test func repeatedSaveAndReopenCyclesDoNotAccumulateScaleDrift() {
    // 64 ulp: 24 chained `multiply` calls cost ~12 ulp of their own even with
    // a perfect writer, and the defect this guards against is 3e-5 to 6e-4 --
    // nine orders of magnitude away.
    let tol = 64.0 * Double.ulpOfOne
    for stepDeg in [7.0, 15.0, 30.0, 41.3, 0.5, 123.456] {
        var m = Transform.identity
        for cycle in 1...24 {
            m = reopenTransform(Transform.rotate(stepDeg).multiply(m))
            let err = abs(m.a * m.a + m.b * m.b - 1.0)
            #expect(err <= tol,
                    "after \(cycle) rotate(\(stepDeg)°)/save/reopen cycles the element is scaled by \((m.a * m.a + m.b * m.b).squareRoot()): |a²+b²-1| = \(err), tolerance \(tol)")
        }
    }
}

// MARK: - The matrix-entry SPELLING rule (the cross-port contract)

/// The `matrix(...)` argument list of the first `transform=` attribute in the
/// document, as emitted.
private func emittedMatrixArgs(_ t: Transform) -> String {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 100, height: 50, transform: t))
    ])])
    let svg = documentToSvg(doc)
    guard let open = svg.range(of: " transform=\"matrix("),
          let close = svg.range(of: ")\"", range: open.upperBound..<svg.endIndex) else {
        Issue.record("no transform=\"matrix(...)\" in:\n\(svg)")
        return ""
    }
    return String(svg[open.upperBound..<close.lowerBound])
}

/// The spelling of one multiplier, as the writer emits it.
private func spelledMultiplier(_ v: Double) -> String {
    let args = emittedMatrixArgs(Transform(a: v))
    return args.split(separator: ",", omittingEmptySubsequences: false)
        .first.map(String.init) ?? ""
}

/// The multiplier spelling, pinned value by value.
///
/// This is a BYTE-LEVEL CROSS-PORT CONTRACT and the only place in the SVG
/// writer that is one: jas_dioxus and JasSwift must spell a matrix multiplier
/// the same way or the same artwork saved by the two ports differs on disk.
/// The three languages in this project spell a float three different ways by
/// default (Rust's `Display` never uses exponent notation and never appends
/// `.0`; Swift's `.description` and Python's `repr` do both, outside
/// [1e-4, 1e16)), so neither port may use its default -- the rule is written
/// out explicitly in both. Mirrors the Rust twin's spelling tests.
@Test func matrixMultiplierSpelling() {
    // (value, expected spelling) -- fed through the `a` slot.
    let cases: [(Double, String)] = [
        (1.0, "1.0"),                                   // integral: one kept digit
        (0.0, "0.0"),
        (-0.0, "-0.0"),                                 // the sign survives
        (2.0, "2.0"),
        (-1.0, "-1.0"),
        (0.5, "0.5"),
        (-2.5, "-2.5"),
        (0.1, "0.1"),                                   // shortest, not 0.1000000000000000055
        (0.7071, "0.7071"),                             // a 4dp value is untouched
        (1.0 / 3.0, "0.3333333333333333"),
        (0.8660254037844387, "0.8660254037844387"),     // cos 30°
        (0.49999999999999994, "0.49999999999999994"),   // sin 30°
        (0.7071067811865476, "0.7071067811865476"),     // cos 45°
        (1e-5, "0.00001"),                              // NOT 1e-05
        (1e-7, "0.0000001"),
        (1e16, "10000000000000000.0"),                  // NOT 1e+16
        // SHORTEST, not EXACT. Above 2^53 the two part company: the double
        // nearest 1e23 has the exact value 99999999999999991611392, and
        // printing THAT would round-trip perfectly while disagreeing with
        // the Rust twin byte for byte. Rule 3 says shortest.
        (1e23, "100000000000000000000000.0"),
        (2.5e18, "2500000000000000000.0"),
        (-1e17, "-100000000000000000.0"),
    ]
    for (v, want) in cases {
        let got = spelledMultiplier(v)
        #expect(got == want, "matrix multiplier \(v) spelled '\(got)', expected '\(want)'")
    }
}

/// Clause 1: no exponent notation, at any magnitude. A bare Swift
/// `.description` would spell `1e-5` as `1e-05`, agreeing on the value and
/// disagreeing on the bytes.
@Test func matrixEntrySpellingNeverUsesExponentNotation() {
    for v in [1e-5, 1.5e-7, -3e-9, 1e20, 2.5e18, 1e16, -1e17,
              Double.leastNormalMagnitude, Double.greatestFiniteMagnitude, 5e-324] {
        let s = spelledMultiplier(v)
        #expect(!s.contains("e") && !s.contains("E"),
                "\(v) was spelled \(s), which is exponent notation")
    }
}

/// Clauses 2 and 3: exactly one decimal point, always present, with a
/// fraction that is never empty and never has a strippable trailing zero.
/// A bare Rust `Display` would spell `1.0` as `1`.
@Test func matrixEntrySpellingAlwaysHasExactlyOnePointAndNoPadding() {
    for v in [0.0, -0.0, 1.0, -2.0, 0.5, 100.0, 1e20, 1e-5,
              0.8660254037844387, 0.25881904510252074, -0.5] {
        let s = spelledMultiplier(v)
        #expect(s.filter { $0 == "." }.count == 1, "\(v) was spelled \(s)")
        let frac = s.split(separator: ".").count > 1
            ? String(s.split(separator: ".")[1]) : ""
        #expect(!frac.isEmpty, "\(v) was spelled \(s) with an empty fraction")
        #expect(frac == "0" || !frac.hasSuffix("0"),
                "\(v) was spelled \(s) with an unstripped trailing zero")
    }
}

/// Clause 4: negative zero keeps its sign -- a naive spelling gives `-0`, and
/// the 4dp `fmt` gives `-0`; the rule gives `-0.0`, and it must still READ
/// BACK as negative zero.
@Test func matrixEntrySpellingPreservesNegativeZero() {
    #expect(spelledMultiplier(0.0) == "0.0")
    #expect(spelledMultiplier(-0.0) == "-0.0")
    #expect(Double(spelledMultiplier(-0.0))!.sign == .minus, "a reopened -0.0 lost its sign")
    #expect(Double(spelledMultiplier(0.0))!.sign == .plus)
}

/// The reason the whole rule exists: what is printed reads back as the same
/// Double, BIT FOR BIT. Fuzzed over raw bit patterns rather than a pretty
/// range, because the hard cases are the ones nobody would think to type --
/// subnormals, values near a binade edge, 17-digit mantissas. A fixed
/// `%.17f` fails this, mis-rounding by one ulp.
///
/// Same xorshift64 and same pi seed as the Rust twin, so the two ports walk
/// the SAME 200k values: a spelling that diverges between the ports on some
/// exotic bit pattern is then a difference the two suites can be diffed on,
/// not one that waits for an artist to find it.
@Test func matrixEntrySpellingRoundTripsBitExactly() {
    var state: UInt64 = 0x243F_6A88_85A3_08D3
    let fixed: [Double] = [
        0.0, -0.0, 1.0, -1.0, 0.8660254037844387, 0.5,
        1.0 / 3.0, Double.leastNormalMagnitude, 5e-324,
        Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
    ]
    var checked = 0
    for i in 0..<200_000 {
        var v: Double
        if i < fixed.count {
            v = fixed[i]
        } else {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            v = Double(bitPattern: state)
        }
        guard v.isFinite else { continue }
        let s = fmtMatrixEntry(v)
        guard let back = Double(s) else {
            Issue.record("\(v) was spelled \(s), which does not parse as a Double")
            continue
        }
        if back.bitPattern != v.bitPattern {
            Issue.record("\(v) was spelled \(s), which reads back as \(back)")
            break
        }
        checked += 1
    }
    #expect(checked > 190_000, "the fuzz checked only \(checked) finite values")
}

/// Positions do NOT ride the rule: `e`/`f` are translations in px and keep
/// the writer's 4dp `fmt`, exactly as `x`, `y`, `rx` and the path data do.
/// The surface of the spelling rule is deliberately narrow -- making
/// byte-level float formatting a cross-language contract corpus-wide would
/// put it in the layer that exists to DETECT contract breaks.
@Test func matrixTranslationKeepsTheFourDecimalSpelling() {
    // 36pt -> 48px, 18pt -> 24px: integral, and written without a `.0`.
    #expect(emittedMatrixArgs(Transform(e: 36, f: 18)) == "1.0,0.0,0.0,1.0,48,24")
    // A non-representable translation is still rounded to 4dp, not spelled
    // out: (1/3)pt -> 0.4444444444444444px -> "0.4444".
    let args = emittedMatrixArgs(Transform(e: 1.0 / 3.0, f: 0))
    #expect(args == "1.0,0.0,0.0,1.0,0.4444,0", "got '\(args)'")
}

/// The instance transform (SYMBOLS.md §4 / Fork F2) rides the same rule --
/// it is the same matrix format written by a second function, and a rule
/// applied to only one of the two writers is a divergence waiting to happen.
@Test func instanceTransformRidesTheMatrixSpellingRule() {
    let doc = Document(layers: [Layer(children: [
        .rect(Rect(x: 0, y: 0, width: 36, height: 36, id: "r1")),
        .live(.reference(ReferenceElem(target: ElementRef("r1"), name: nil, id: "i1",
                                       instanceTransform: Transform.rotate(30)))),
    ])])
    let svg = documentToSvg(doc)
    #expect(svg.contains("data-jas-instance-transform=\"matrix(0.8660254037844387,0.49999999999999994,-0.49999999999999994,0.8660254037844387,0,0)\""),
            "instance transform not spelled at full multiplier precision:\n\(svg)")
}

// MARK: - BRUSHSAVE: the save format must not drop the stroke profile

/// Twin of Rust's `roundtrip_path_keeps_its_stroke_brush_and_width_profile`.
/// SVG *is* the save format, so anything the writer omits is artwork the artist
/// loses on save — the same hole ARROWTRIM found for arrowheads.
@Test func roundtripPathKeepsItsStrokeBrushAndWidthProfile() {
    let path = Element.path(Path(
        d: [.moveTo(0, 0), .lineTo(30, 40)],
        stroke: Stroke(color: .black, width: 2.0),
        widthPoints: [
            StrokeWidthPoint(t: 0.25, widthLeft: 3.5, widthRight: 1.25),
            StrokeWidthPoint(t: 0.75, widthLeft: 2.0, widthRight: 2.0),
        ],
        strokeBrush: "default_brushes/flat_10",
        strokeBrushOverrides: "{\"size\":4}",
        fillRule: .nonzero))
    let doc = Document(layers: [Layer(name: "L0", children: [path])])

    let svg = documentToSvg(doc)
    let doc2 = svgToDocument(svg)
    guard case .path(let p) = doc2.layers[0].children[0] else {
        Issue.record("expected a Path back")
        return
    }
    #expect(p.strokeBrush == "default_brushes/flat_10",
            "a brushed stroke must survive save-and-reopen")
    #expect(p.strokeBrushOverrides == "{\"size\":4}",
            "and its per-instance overrides with it")
    #expect(p.widthPoints.count == 2,
            "a variable-width profile must survive save-and-reopen")
    #expect(p.widthPoints[0].t == 0.25)
    #expect(p.widthPoints[0].widthLeft == 3.5)
    #expect(p.widthPoints[0].widthRight == 1.25)
    #expect(p.widthPoints[1].widthLeft == 2.0)
}

// MARK: - PAGESAVE: artboards must survive a save in this port too

/// Swift READS `<inkscape:page>` (`parseArtboards`, "Mirrors Rust
/// `parse_artboards`") and never WROTE it — the writer's own comment said
/// "Artboards aren't yet persisted in this port's SVG (separate cross-port
/// follow-up)". So the loss is ONE-DIRECTIONAL and easy to miss: a Rust-saved
/// file keeps its artboards when opened in Swift, and a Swift-saved one loses
/// every one of them. Rust has round-tripped pages all along.
@Test func artboardsSurviveASaveInSwift() {
    let doc = Document(
        layers: [Layer(name: "L0", children: [
            .rect(Rect(x: 10, y: 10, width: 40, height: 30)),
        ])],
        artboards: [
            Artboard(id: "ab1", name: "Artboard 1", x: 0, y: 0, width: 600, height: 400),
            Artboard(id: "ab2", name: "Second Board", x: 700, y: 0, width: 300, height: 200),
        ])

    let svg = documentToSvg(doc)
    let back = svgToDocument(svg)

    #expect(back.artboards.count == 2,
            "both artboards must survive save-and-reopen; before this fix the writer emitted no page at all and every artboard was silently dropped")
    #expect(back.artboards.first?.name == "Artboard 1")
    #expect(back.artboards.first?.width == 600)
    #expect(back.artboards.last?.id == "ab2")
    // 700pt round-trips as 699.999975, NOT 700 — the ruled four-decimal floor
    // on a POSITION (2026-08-05: positions and radii stay at 4dp; only the
    // transform matrix went to full precision). Measured identical in Rust:
    // `700pt -> "933.3333" -> 699.999975`, so this is the shared, ruled floor
    // and not a divergence. Asserted as a tolerance rather than loosened to
    // `>0`, so a REAL drift still reds.
    #expect(abs((back.artboards.last?.x ?? 0) - 700) < 1e-4,
            "an artboard position must survive within the ruled 4dp floor")
}

// MARK: - OPENBOARD: opening an SVG must leave the document with an artboard

/// JYH, first thirty seconds of the first smoke in weeks: "although there is no
/// artboard" (2026-08-05).
///
/// `svgToDocument` leaves `artboards` empty BY DESIGN — both ports' parsers say
/// so, and the at-least-one-artboard repair belongs at the OPEN layer, where
/// session restore already does it. Rust's `open_file_dialog` calls
/// `ensure_artboards_invariant` immediately after its parse. **This port's
/// `openFile` never did**, so a document opened in JasSwift had no canvas to
/// zoom against and Fit-to-artboard had nothing to fit.
///
/// A parse and an OPEN are different acts, which is why this is tested at
/// `documentForOpen` and not by loosening the parser: 59 of the 70 corpus setup
/// SVGs carry a viewBox and no page, so moving this into the parser would have
/// added an artboard to 237 expected goldens for a behaviour that is not a
/// parse fact.
@Test func openingAnSvgLeavesTheDocumentWithAnArtboard() {
    let svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 400" width="600" height="400">
      <rect x="10" y="10" width="40" height="30" fill="rgb(0,0,0)"/>
    </svg>
    """
    // The PARSE still yields none — that contract is unchanged and load-bearing
    // for the corpus.
    #expect(svgToDocument(svg).artboards.isEmpty,
            "the parser must keep leaving artboards empty; 237 goldens depend on it")

    // The OPEN repairs it, as Rust's open path does.
    let opened = documentForOpen(svg)
    #expect(!opened.artboards.isEmpty,
            "opening an SVG must leave at least one artboard, or Fit-to-artboard has nothing to fit and the canvas has nothing to zoom against")
    #expect(opened.layers.first?.children.count == 1,
            "and the repair must not disturb the artwork")
}
