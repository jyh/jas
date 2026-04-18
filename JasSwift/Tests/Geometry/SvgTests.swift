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
        .circle(Circle(cx: 36, cy: 36, r: 18,
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
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
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
        ], stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
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
    // translate(36pt, 18pt) -> e=48px, f=24px
    #expect(svg.contains("transform=\"matrix(1,0,0,1,48,24)\""))
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
            .circle(Circle(cx: 36, cy: 36, r: 18))
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
        .circle(Circle(cx: 36, cy: 36, r: 18,
                          fill: Fill(color: Color(r: 0, g: 0, b: 1))))
    ])])
    let doc2 = roundtrip(doc)
    if case .circle(let v) = doc2.layers[0].children[0] {
        #expect(abs(v.r - 18) < 0.1)
    } else {
        Issue.record("Expected circle")
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
                      stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
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
            .circle(Circle(cx: 36, cy: 36, r: 18))
        ]),
    ])
    let doc2 = roundtrip(doc)
    #expect(doc2.layers.count == 2)
    #expect(doc2.layers[0].name == "L1")
    #expect(doc2.layers[1].name == "L2")
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
                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
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
                   stroke: Stroke(color: Color(r: 0, g: 0, b: 0))))
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
