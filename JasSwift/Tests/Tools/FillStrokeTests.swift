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

@Test func swapFillStrokeColors() {
    let model = Model()
    model.defaultFill = Fill(color: Color(r: 1.0, g: 0.0, b: 0.0))
    model.defaultStroke = Stroke(color: Color(r: 0.0, g: 0.0, b: 1.0))

    // Swap
    let oldFill = model.defaultFill
    let oldStroke = model.defaultStroke
    if let s = oldStroke {
        model.defaultFill = Fill(color: s.color)
    } else {
        model.defaultFill = nil
    }
    if let f = oldFill {
        model.defaultStroke = Stroke(color: f.color)
    } else {
        model.defaultStroke = nil
    }

    #expect(model.defaultFill?.color == Color(r: 0.0, g: 0.0, b: 1.0))
    #expect(model.defaultStroke?.color == Color(r: 1.0, g: 0.0, b: 0.0))
}

@Test func swapFillStrokeWithNilFill() {
    let model = Model()
    model.defaultFill = nil
    model.defaultStroke = Stroke(color: Color(r: 0.0, g: 1.0, b: 0.0))

    let oldFill = model.defaultFill
    let oldStroke = model.defaultStroke
    if let s = oldStroke {
        model.defaultFill = Fill(color: s.color)
    } else {
        model.defaultFill = nil
    }
    if let f = oldFill {
        model.defaultStroke = Stroke(color: f.color)
    } else {
        model.defaultStroke = nil
    }

    #expect(model.defaultFill?.color == Color(r: 0.0, g: 1.0, b: 0.0))
    #expect(model.defaultStroke == nil)
}

@Test func swapFillStrokeWithNilStroke() {
    let model = Model()
    model.defaultFill = Fill(color: Color(r: 1.0, g: 0.5, b: 0.0))
    model.defaultStroke = nil

    let oldFill = model.defaultFill
    let oldStroke = model.defaultStroke
    if let s = oldStroke {
        model.defaultFill = Fill(color: s.color)
    } else {
        model.defaultFill = nil
    }
    if let f = oldFill {
        model.defaultStroke = Stroke(color: f.color)
    } else {
        model.defaultStroke = nil
    }

    #expect(model.defaultFill == nil)
    #expect(model.defaultStroke?.color == Color(r: 1.0, g: 0.5, b: 0.0))
}

@Test func swapFillStrokeBothNil() {
    let model = Model()
    model.defaultFill = nil
    model.defaultStroke = nil

    let oldFill = model.defaultFill
    let oldStroke = model.defaultStroke
    if let s = oldStroke {
        model.defaultFill = Fill(color: s.color)
    } else {
        model.defaultFill = nil
    }
    if let f = oldFill {
        model.defaultStroke = Stroke(color: f.color)
    } else {
        model.defaultStroke = nil
    }

    #expect(model.defaultFill == nil)
    #expect(model.defaultStroke == nil)
}
