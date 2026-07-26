import Testing
@testable import JasLib

// MARK: - Model fillOnTop property

@Test func modelFillOnTopDefault() {
    let model = Model()
    #expect(model.fillOnTop == true)
}

@Test func modelFillOnTopToggle() {
    let model = Model()
    model.fillOnTop.toggle()
    #expect(model.fillOnTop == false)
    model.fillOnTop.toggle()
    #expect(model.fillOnTop == true)
}

// MARK: - Default fill/stroke values

@Test func modelDefaultFillIsNil() {
    let model = Model()
    #expect(model.defaultFill == nil)
}

@Test func modelDefaultStrokeIsBlack() {
    let model = Model()
    #expect(model.defaultStroke != nil)
    #expect(model.defaultStroke?.color == .black)
}

// MARK: - Reset defaults (d/D shortcut logic)

@Test func resetFillStrokeDefaults() {
    let model = Model()
    model.defaultFill = Fill(color: .white)
    model.defaultStroke = Stroke(color: Color(r: 1.0, g: 0.0, b: 0.0))
    // Reset
    model.defaultFill = nil
    model.defaultStroke = Stroke(color: .black)
    #expect(model.defaultFill == nil)
    #expect(model.defaultStroke?.color == .black)
}

// MARK: - Swap fill/stroke (X shortcut logic)
//
// These drive `Controller.swapFillStrokeColors` — the ONE statement of the
// law (workspace/actions.yaml `swap_fill_stroke`, mirroring Rust's
// app_state.rs), which both Shift+X and the fill/stroke widget arrow call.
// They used to re-implement the swap inline, so they could not have caught a
// regression in the code that ships.

@Test func swapFillStrokeColors() {
    let model = Model()
    model.defaultFill = Fill(color: Color(r: 1.0, g: 0.0, b: 0.0))
    model.defaultStroke = Stroke(color: Color(r: 0.0, g: 0.0, b: 1.0))

    Controller(model: model).swapFillStrokeColors()

    #expect(model.defaultFill?.color == Color(r: 0.0, g: 0.0, b: 1.0))
    #expect(model.defaultStroke?.color == Color(r: 1.0, g: 0.0, b: 0.0))
}

@Test func swapFillStrokeWithNilFill() {
    let model = Model()
    model.defaultFill = nil
    model.defaultStroke = Stroke(color: Color(r: 0.0, g: 1.0, b: 0.0))

    Controller(model: model).swapFillStrokeColors()

    #expect(model.defaultFill?.color == Color(r: 0.0, g: 1.0, b: 0.0))
    #expect(model.defaultStroke == nil, "no fill swaps in as no stroke")
}

@Test func swapFillStrokeWithNilStroke() {
    let model = Model()
    model.defaultFill = Fill(color: Color(r: 1.0, g: 0.5, b: 0.0))
    model.defaultStroke = nil

    Controller(model: model).swapFillStrokeColors()

    #expect(model.defaultFill == nil, "no stroke swaps in as no fill")
    #expect(model.defaultStroke?.color == Color(r: 1.0, g: 0.5, b: 0.0))
}

@Test func swapFillStrokeBothNil() {
    let model = Model()
    model.defaultFill = nil
    model.defaultStroke = nil

    Controller(model: model).swapFillStrokeColors()

    #expect(model.defaultFill == nil)
    #expect(model.defaultStroke == nil)
}
