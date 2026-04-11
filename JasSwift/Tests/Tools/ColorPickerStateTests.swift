import Testing
@testable import JasLib

// MARK: - ColorPickerState creation

@Test func colorPickerNewFromBlack() {
    let cp = ColorPickerState(color: .black, forFill: true)
    #expect(cp.rgbU8() == (0, 0, 0))
    #expect(cp.hexStr() == "000000")
    #expect(cp.forFill == true)
}

@Test func colorPickerNewFromRed() {
    let cp = ColorPickerState(color: Color(r: 1.0, g: 0.0, b: 0.0), forFill: false)
    #expect(cp.rgbU8() == (255, 0, 0))
    #expect(cp.hexStr() == "ff0000")
    #expect(cp.forFill == false)
}

@Test func colorPickerNewFromWhite() {
    let cp = ColorPickerState(color: .white, forFill: true)
    #expect(cp.rgbU8() == (255, 255, 255))
    #expect(cp.hexStr() == "ffffff")
}

// MARK: - setRgb

@Test func colorPickerSetRgb() {
    let cp = ColorPickerState(color: .black, forFill: true)
    cp.setRgb(128, 64, 32)
    #expect(cp.rgbU8() == (128, 64, 32))
}

// MARK: - setHsb

@Test func colorPickerSetHsbPureRed() {
    let cp = ColorPickerState(color: .black, forFill: true)
    cp.setHsb(0.0, 100.0, 100.0)
    #expect(cp.rgbU8() == (255, 0, 0))
}

@Test func colorPickerSetHsbPureGreen() {
    let cp = ColorPickerState(color: .black, forFill: true)
    cp.setHsb(120.0, 100.0, 100.0)
    #expect(cp.rgbU8() == (0, 255, 0))
}

// MARK: - setCmyk

@Test func colorPickerSetCmykWhite() {
    let cp = ColorPickerState(color: .black, forFill: true)
    cp.setCmyk(0.0, 0.0, 0.0, 0.0)
    #expect(cp.rgbU8() == (255, 255, 255))
}

@Test func colorPickerSetCmykBlack() {
    let cp = ColorPickerState(color: .white, forFill: true)
    cp.setCmyk(0.0, 0.0, 0.0, 100.0)
    #expect(cp.rgbU8() == (0, 0, 0))
}

// MARK: - setHex

@Test func colorPickerSetHex() {
    let cp = ColorPickerState(color: .black, forFill: true)
    cp.setHex("ff8000")
    #expect(cp.rgbU8() == (255, 128, 0))
}

@Test func colorPickerSetHexInvalid() {
    let cp = ColorPickerState(color: .black, forFill: true)
    cp.setHex("xyz")
    // Should remain unchanged
    #expect(cp.rgbU8() == (0, 0, 0))
}

// MARK: - hsbVals

@Test func colorPickerHsbValsRed() {
    let cp = ColorPickerState(color: Color(r: 1.0, g: 0.0, b: 0.0), forFill: true)
    let (h, s, b) = cp.hsbVals()
    #expect(abs(h - 0.0) < 1.0)
    #expect(abs(s - 100.0) < 1.0)
    #expect(abs(b - 100.0) < 1.0)
}

// MARK: - cmykVals

@Test func colorPickerCmykValsWhite() {
    let cp = ColorPickerState(color: .white, forFill: true)
    let (c, m, y, k) = cp.cmykVals()
    #expect(abs(c) < 1.0)
    #expect(abs(m) < 1.0)
    #expect(abs(y) < 1.0)
    #expect(abs(k) < 1.0)
}

// MARK: - Web snap

@Test func snapWebValues() {
    #expect(snapWeb(0.0) == 0.0)
    #expect(snapWeb(1.0) == 1.0)
    #expect(snapWeb(0.19) == 0.2)
    #expect(snapWeb(0.5) == 0.4) // equidistant, snaps to 0.4
}

@Test func colorPickerWebOnlySnaps() {
    let cp = ColorPickerState(color: .black, forFill: true)
    cp.webOnly = true
    cp.setRgb(100, 150, 200)
    let (r, g, b) = cp.rgbU8()
    let webVals: [UInt8] = [0, 51, 102, 153, 204, 255]
    #expect(webVals.contains(r))
    #expect(webVals.contains(g))
    #expect(webVals.contains(b))
}

// MARK: - Colorbar position

@Test func colorPickerColorbarPosHue() {
    let cp = ColorPickerState(color: Color.hsb(h: 180.0, s: 0.5, b: 0.8, a: 1.0), forFill: true)
    cp.radio = .h
    let pos = cp.colorbarPos()
    #expect(abs(pos - 0.5) < 0.01) // 180/360 = 0.5
}

// MARK: - Gradient position

@Test func colorPickerGradientPosHue() {
    let cp = ColorPickerState(color: Color.hsb(h: 120.0, s: 0.7, b: 0.9, a: 1.0), forFill: true)
    cp.radio = .h
    let (x, y) = cp.gradientPos()
    #expect(abs(x - 0.7) < 0.01) // S
    #expect(abs(y - 0.1) < 0.01) // 1-B = 1-0.9
}

// MARK: - Radio channel

@Test func radioChannelAllCases() {
    #expect(RadioChannel.allCases.count == 6)
    #expect(RadioChannel.allCases.contains(.h))
    #expect(RadioChannel.allCases.contains(.s))
    #expect(RadioChannel.allCases.contains(.b))
    #expect(RadioChannel.allCases.contains(.r))
    #expect(RadioChannel.allCases.contains(.g))
    #expect(RadioChannel.allCases.contains(.blue))
}

// MARK: - Color roundtrip

@Test func colorPickerColorRoundtrip() {
    let original = Color(r: 0.5, g: 0.3, b: 0.8)
    let cp = ColorPickerState(color: original, forFill: true)
    let result = cp.color()
    let (r1, g1, b1, _) = original.toRgba()
    let (r2, g2, b2, _) = result.toRgba()
    #expect(abs(r1 - r2) < 0.001)
    #expect(abs(g1 - g2) < 0.001)
    #expect(abs(b1 - b2) < 0.001)
}

// MARK: - Preserved hue/sat

@Test func colorPickerPreservedHueAtBlack() {
    let cp = ColorPickerState(color: Color.hsb(h: 200.0, s: 0.8, b: 1.0, a: 1.0), forFill: true)
    // Set to black (brightness=0), hue should be preserved
    cp.setHsb(200.0, 80.0, 0.0)
    let (h, _, _) = cp.hsbVals()
    #expect(abs(h - 200.0) < 1.0)
}
