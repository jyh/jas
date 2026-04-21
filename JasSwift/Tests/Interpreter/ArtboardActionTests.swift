import Testing
@testable import JasLib

/// Integration tests for the artboard YAML action dispatch.
///
/// Each test runs a full action via LayersPanel.dispatchYamlAction
/// (which reads workspace/actions.yaml compiled into workspace.json
/// at build time) and verifies the document-model side effects.

@Test func newArtboardActionAppendsOne() {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [Artboard.defaultWithId("aaa00001")]
    ))
    LayersPanel.dispatchYamlAction("new_artboard", model: model)
    #expect(model.document.artboards.count == 2)
    #expect(model.document.artboards[1].name == "Artboard 2")
    #expect(model.document.artboards[0].id != model.document.artboards[1].id)
}

@Test func deleteArtboardsActionRemovesSelection() {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [
            Artboard.defaultWithId("aaa"),
            Artboard.defaultWithId("bbb"),
            Artboard.defaultWithId("ccc"),
        ]
    ))
    LayersPanel.dispatchYamlAction(
        "delete_artboards",
        model: model,
        artboardsPanelSelection: ["bbb"]
    )
    let ids = model.document.artboards.map(\.id)
    #expect(ids == ["aaa", "ccc"])
}

@Test func duplicateArtboardsActionWithFreshNameAndOffset() {
    let source = Artboard.defaultWithId("aaa").with(x: 50, y: 80)
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [source]
    ))
    LayersPanel.dispatchYamlAction(
        "duplicate_artboards",
        model: model,
        artboardsPanelSelection: ["aaa"]
    )
    #expect(model.document.artboards.count == 2)
    let dup = model.document.artboards[1]
    #expect(dup.id != "aaa")
    #expect(dup.name == "Artboard 2")
    #expect(dup.x == 70)   // 50 + 20
    #expect(dup.y == 100)  // 80 + 20
}

@Test func moveArtboardUpActionSwapRule() {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [
            Artboard.defaultWithId("aaa"),
            Artboard.defaultWithId("bbb"),
            Artboard.defaultWithId("ccc"),
        ]
    ))
    LayersPanel.dispatchYamlAction(
        "move_artboard_up",
        model: model,
        artboardsPanelSelection: ["bbb"]
    )
    #expect(model.document.artboards.map(\.id) == ["bbb", "aaa", "ccc"])
}

@Test func moveArtboardUpDiscontiguous_1_3_5() {
    // ART-103 canonical example: {1, 3, 5} → [1, 3, 2, 5, 4].
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: ["a1", "a2", "a3", "a4", "a5"].map(Artboard.defaultWithId)
    ))
    LayersPanel.dispatchYamlAction(
        "move_artboard_up",
        model: model,
        artboardsPanelSelection: ["a1", "a3", "a5"]
    )
    #expect(model.document.artboards.map(\.id) == ["a1", "a3", "a2", "a5", "a4"])
}

@Test func confirmArtboardRenameWritesName() {
    let model = Model(document: Document(
        layers: [Layer(children: [])],
        artboards: [Artboard.defaultWithId("aaa")]
    ))
    LayersPanel.dispatchYamlAction(
        "confirm_artboard_rename",
        model: model,
        params: [
            "artboard_id": "aaa",
            "new_name": "Cover",
        ]
    )
    #expect(model.document.artboards[0].name == "Cover")
}

@Test func nextArtboardNameFillsGap() {
    let abs = [
        Artboard.defaultWithId("a").with(name: "Artboard 1"),
        Artboard.defaultWithId("b").with(name: "Artboard 3"),
    ]
    #expect(nextArtboardName(abs) == "Artboard 2")
}

@Test func ensureArtboardsInvariantSeedsDefault() {
    let (abs, repaired) = ensureArtboardsInvariant([]) { "seedfeed" }
    #expect(repaired == true)
    #expect(abs.count == 1)
    #expect(abs[0].name == "Artboard 1")
    #expect(abs[0].id == "seedfeed")
}

@Test func artboardFillCanonicalRoundTrip() {
    #expect(ArtboardFill.transparent.asCanonical == "transparent")
    #expect(ArtboardFill.color("#ff0000").asCanonical == "#ff0000")
    #expect(ArtboardFill.fromCanonical("transparent") == .transparent)
    #expect(ArtboardFill.fromCanonical("#ff0000") == .color("#ff0000"))
}

@Test func documentToTestJsonOmitsDefaults() {
    // Legacy-compat: empty artboards + default options produce no
    // artboard-related keys in the canonical JSON.
    let doc = Document(layers: [Layer(children: [])])
    let json = documentToTestJson(doc)
    #expect(!json.contains("\"artboards\""))
    #expect(!json.contains("\"artboard_options\""))
}

@Test func documentToTestJsonEmitsArtboardsWhenPresent() {
    let doc = Document(
        layers: [Layer(children: [])],
        artboards: [Artboard.defaultWithId("idaaaaaa")]
    )
    let json = documentToTestJson(doc)
    #expect(json.contains("\"artboards\":["))
    #expect(json.contains("\"id\":\"idaaaaaa\""))
    #expect(json.contains("\"fill\":\"transparent\""))
}

@Test func artboardsRoundtripPreservesIds() {
    let doc = Document(
        layers: [Layer(children: [])],
        artboards: [
            Artboard.defaultWithId("aaa00001"),
            Artboard.defaultWithId("bbb00002").with(name: "Cover"),
        ]
    )
    let json1 = documentToTestJson(doc)
    let doc2 = testJsonToDocument(json1)
    #expect(doc2.artboards.count == 2)
    #expect(doc2.artboards[0].id == "aaa00001")
    #expect(doc2.artboards[1].name == "Cover")
    let json2 = documentToTestJson(doc2)
    #expect(json1 == json2)
}
