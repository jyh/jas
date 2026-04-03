import Testing
@testable import JasLib

@Test func pxIdentity() {
    let m = Measure(100, .px)
    #expect(m.toPx() == 100)
}

@Test func ptToPx() {
    let m = Measure(72, .pt)
    #expect(abs(m.toPx() - 96.0) < 1e-10)
}

@Test func pcToPx() {
    let m = Measure(1, .pc)
    #expect(abs(m.toPx() - 16.0) < 1e-10)
}

@Test func inToPx() {
    let m = Measure(1, .in)
    #expect(abs(m.toPx() - 96.0) < 1e-10)
}

@Test func cmToPx() {
    let m = Measure(2.54, .cm)
    #expect(abs(m.toPx() - 96.0) < 1e-10)
}

@Test func mmToPx() {
    let m = Measure(25.4, .mm)
    #expect(abs(m.toPx() - 96.0) < 1e-10)
}

@Test func emToPx() {
    let m = Measure(2, .em)
    #expect(abs(m.toPx() - 32.0) < 1e-10)
}

@Test func emCustomFontSize() {
    let m = Measure(2, .em)
    #expect(abs(m.toPx(fontSize: 24.0) - 48.0) < 1e-10)
}

@Test func remToPx() {
    let m = Measure(1.5, .rem)
    #expect(abs(m.toPx() - 24.0) < 1e-10)
}

@Test func defaultUnitIsPx() {
    let m = Measure(10)
    #expect(m.unit == .px)
    #expect(m.toPx() == 10)
}

@Test func shorthandPx() {
    let m = px(50)
    #expect(m.value == 50 && m.unit == .px)
}

@Test func shorthandPt() {
    let m = pt(72)
    #expect(m.value == 72 && m.unit == .pt)
}
