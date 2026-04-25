import Testing
@testable import JasLib
import Foundation

private func approxEq(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) < 1e-9
}

private func pointApprox(_ p: (Double, Double),
                         _ expected: (Double, Double)) {
    #expect(approxEq(p.0, expected.0) && approxEq(p.1, expected.1),
            "got (\(p.0), \(p.1)), expected (\(expected.0), \(expected.1))")
}

// MARK: - Scale matrix

@Test func scaleIdentityAtUnitFactors() {
    let m = TransformApply.scaleMatrix(sx: 1, sy: 1, rx: 50, ry: 50)
    pointApprox(m.applyPoint(10, 20), (10, 20))
    pointApprox(m.applyPoint(0, 0), (0, 0))
}

@Test func scaleUniformAroundOrigin() {
    let m = TransformApply.scaleMatrix(sx: 2, sy: 2, rx: 0, ry: 0)
    pointApprox(m.applyPoint(3, 5), (6, 10))
}

@Test func scaleUniformAroundRefPoint() {
    let m = TransformApply.scaleMatrix(sx: 2, sy: 2, rx: 100, ry: 100)
    pointApprox(m.applyPoint(100, 100), (100, 100))
    pointApprox(m.applyPoint(110, 100), (120, 100))
    pointApprox(m.applyPoint(100, 90), (100, 80))
}

@Test func scaleNonUniform() {
    let m = TransformApply.scaleMatrix(sx: 2, sy: 0.5, rx: 0, ry: 0)
    pointApprox(m.applyPoint(4, 4), (8, 2))
}

@Test func scaleNegativeFlips() {
    let m = TransformApply.scaleMatrix(sx: -1, sy: 1, rx: 0, ry: 0)
    pointApprox(m.applyPoint(5, 7), (-5, 7))
}

// MARK: - Rotate matrix

@Test func rotateZeroIsIdentity() {
    let m = TransformApply.rotateMatrix(thetaDeg: 0, rx: 50, ry: 50)
    pointApprox(m.applyPoint(10, 20), (10, 20))
}

@Test func rotateNinetyAroundOrigin() {
    let m = TransformApply.rotateMatrix(thetaDeg: 90, rx: 0, ry: 0)
    pointApprox(m.applyPoint(1, 0), (0, 1))
}

@Test func rotate180AroundRefPoint() {
    let m = TransformApply.rotateMatrix(thetaDeg: 180, rx: 50, ry: 50)
    pointApprox(m.applyPoint(50, 50), (50, 50))
    pointApprox(m.applyPoint(60, 50), (40, 50))
    pointApprox(m.applyPoint(50, 60), (50, 40))
}

// MARK: - Shear matrix

@Test func shearZeroAngleIsIdentity() {
    let m = TransformApply.shearMatrix(
        angleDeg: 0, axis: "horizontal", axisAngleDeg: 0, rx: 50, ry: 50)
    pointApprox(m.applyPoint(10, 20), (10, 20))
}

@Test func shearHorizontalAt45AroundOrigin() {
    let m = TransformApply.shearMatrix(
        angleDeg: 45, axis: "horizontal", axisAngleDeg: 0, rx: 0, ry: 0)
    pointApprox(m.applyPoint(0, 10), (10, 10))
    pointApprox(m.applyPoint(5, 0), (5, 0))
}

@Test func shearVerticalAt45AroundOrigin() {
    let m = TransformApply.shearMatrix(
        angleDeg: 45, axis: "vertical", axisAngleDeg: 0, rx: 0, ry: 0)
    pointApprox(m.applyPoint(10, 0), (10, 10))
    pointApprox(m.applyPoint(0, 5), (0, 5))
}

@Test func shearHorizontalAroundRefPoint() {
    let m = TransformApply.shearMatrix(
        angleDeg: 45, axis: "horizontal", axisAngleDeg: 0, rx: 50, ry: 50)
    pointApprox(m.applyPoint(50, 50), (50, 50))
    pointApprox(m.applyPoint(50, 49), (49, 49))
}

@Test func shearCustomAxisAtZeroMatchesHorizontal() {
    let custom = TransformApply.shearMatrix(
        angleDeg: 30, axis: "custom", axisAngleDeg: 0, rx: 0, ry: 0)
    let horizontal = TransformApply.shearMatrix(
        angleDeg: 30, axis: "horizontal", axisAngleDeg: 0, rx: 0, ry: 0)
    pointApprox(custom.applyPoint(7, 11), horizontal.applyPoint(7, 11))
}

@Test func shearUnknownAxisReturnsIdentity() {
    let m = TransformApply.shearMatrix(
        angleDeg: 45, axis: "diagonal", axisAngleDeg: 0, rx: 0, ry: 0)
    pointApprox(m.applyPoint(10, 20), (10, 20))
}

// MARK: - Stroke width factor

@Test func strokeFactorUniform() {
    #expect(approxEq(TransformApply.strokeWidthFactor(sx: 2, sy: 2), 2.0))
    #expect(approxEq(TransformApply.strokeWidthFactor(sx: 0.5, sy: 0.5), 0.5))
}

@Test func strokeFactorGeometricMean() {
    #expect(approxEq(TransformApply.strokeWidthFactor(sx: 2, sy: 8), 4.0))
}

@Test func strokeFactorNegativeFactorsUseAbs() {
    let expected = sqrt(6.0)
    #expect(approxEq(TransformApply.strokeWidthFactor(sx: -2, sy: 3), expected))
}

// MARK: - Transform composition

@Test func aroundPointTranslateNoOpAtOrigin() {
    let t = Transform.translate(5, 7)
    let m = t.aroundPoint(0, 0)
    pointApprox(m.applyPoint(0, 0), (5, 7))
}

@Test func multiplyAssociativeBasicCase() {
    let a = Transform.translate(10, 0)
    let b = Transform.scale(2, 2)
    let c = Transform.translate(0, 5)
    let left = a.multiply(b).multiply(c)
    let right = a.multiply(b.multiply(c))
    pointApprox(left.applyPoint(3, 4), right.applyPoint(3, 4))
}
