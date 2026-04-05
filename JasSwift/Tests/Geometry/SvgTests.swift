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
        #expect(abs(v.fill!.color.r - 1.0) < 0.1)
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
        #expect(abs(v.fill!.color.a - 0.5) < 0.1)
    } else {
        Issue.record("Expected rect")
    }
}
