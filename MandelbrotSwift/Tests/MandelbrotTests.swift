import Testing
import MetalKit
@testable import MandelbrotLib

func makeRenderer() -> MandelbrotRenderer? {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let mtkView = MTKView()
    mtkView.device = device
    mtkView.colorPixelFormat = .bgra8Unorm
    return MandelbrotRenderer(mtkView: mtkView)
}

// MARK: - splitDouble tests

@Test func splitDoubleReconstructsValue() throws {
    let renderer = try #require(makeRenderer())
    let values: [Double] = [0.0, 1.0, -1.0, 3.14159265358979, -0.75, 1e-10, 1234.5678]
    for value in values {
        let (hi, lo) = renderer.splitDouble(value)
        let reconstructed = Double(hi) + Double(lo)
        // hi+lo reconstruction is limited by Float mantissa (~7 decimal digits)
        // so tolerance scales with magnitude
        let tol = max(1e-15, Double(abs(Float(value))) * 1e-7)
        #expect(abs(reconstructed - value) < tol,
                "splitDouble failed for \(value): got \(reconstructed)")
    }
}

@Test func splitDoubleHiIsFloatPrecision() throws {
    let renderer = try #require(makeRenderer())
    let value = 3.14159265358979
    let (hi, _) = renderer.splitDouble(value)
    #expect(hi == Float(value))
}

@Test func splitDoubleZero() throws {
    let renderer = try #require(makeRenderer())
    let (hi, lo) = renderer.splitDouble(0.0)
    #expect(hi == 0.0)
    #expect(lo == 0.0)
}

// MARK: - Reference orbit tests

@Test func orbitStartsAtOrigin() throws {
    let renderer = try #require(makeRenderer())
    let (orbit, len) = renderer.computeReferenceOrbit()
    #expect(len > 0)
    #expect(orbit[0].x == 0.0)
    #expect(orbit[0].y == 0.0)
}

@Test func orbitLengthBoundedByMaxIter() throws {
    let renderer = try #require(makeRenderer())
    renderer.maxIter = 50
    let (orbit, len) = renderer.computeReferenceOrbit()
    #expect(Int(len) <= 51) // maxIter + 1 (includes Z_0)
    #expect(orbit.count == Int(len))
}

@Test func orbitForPointInSet() throws {
    let renderer = try #require(makeRenderer())
    // c = (0, 0) is in the set; z stays at origin
    renderer.centerX = 0.0
    renderer.centerY = 0.0
    renderer.maxIter = 100
    let (orbit, len) = renderer.computeReferenceOrbit()
    #expect(Int(len) == 101)
    for point in orbit {
        #expect(point.x == 0.0)
        #expect(point.y == 0.0)
    }
}

@Test func orbitForPointOutsideSet() throws {
    let renderer = try #require(makeRenderer())
    // c = (2, 0) escapes immediately
    renderer.centerX = 2.0
    renderer.centerY = 0.0
    renderer.maxIter = 100
    let (_, len) = renderer.computeReferenceOrbit()
    #expect(Int(len) < 20)
}

@Test func orbitFollowsMandelbrotIteration() throws {
    let renderer = try #require(makeRenderer())
    // c = (-1, 0): z_0=0, z_1=-1, z_2=0, z_3=-1, ...
    renderer.centerX = -1.0
    renderer.centerY = 0.0
    renderer.maxIter = 10
    let (orbit, len) = renderer.computeReferenceOrbit()
    #expect(Int(len) == 11) // Should not escape
    for i in 0..<Int(len) {
        if i % 2 == 0 {
            #expect(abs(orbit[i].x) < 1e-6, "orbit[\(i)].x should be 0")
        } else {
            #expect(abs(orbit[i].x - (-1.0)) < 1e-6, "orbit[\(i)].x should be -1")
        }
        #expect(abs(orbit[i].y) < 1e-6, "orbit[\(i)].y should be 0")
    }
}

// MARK: - MandelbrotUniforms tests

@Test func uniformsFieldValues() {
    let uniforms = MandelbrotUniforms(
        centerX_hi: 1.0, centerX_lo: 2.0,
        centerY_hi: 3.0, centerY_lo: 4.0,
        scale_hi: 5.0, scale_lo: 6.0,
        maxIter: 200, width: 800, height: 600, refOrbitLen: 100
    )
    #expect(uniforms.centerX_hi == 1.0)
    #expect(uniforms.centerX_lo == 2.0)
    #expect(uniforms.centerY_hi == 3.0)
    #expect(uniforms.centerY_lo == 4.0)
    #expect(uniforms.scale_hi == 5.0)
    #expect(uniforms.scale_lo == 6.0)
    #expect(uniforms.maxIter == 200)
    #expect(uniforms.width == 800)
    #expect(uniforms.height == 600)
    #expect(uniforms.refOrbitLen == 100)
}

@Test func uniformsSize() {
    // 6 floats (4 bytes each) + 4 int32s (4 bytes each) = 40 bytes
    #expect(MemoryLayout<MandelbrotUniforms>.size == 40)
}

// MARK: - Renderer init tests

@Test func rendererInitSucceeds() {
    let renderer = makeRenderer()
    #expect(renderer != nil)
}

@Test func rendererDefaultValues() throws {
    let renderer = try #require(makeRenderer())
    #expect(renderer.centerX == -0.75)
    #expect(renderer.centerY == 0.0)
    #expect(renderer.scale == 3.5)
    #expect(renderer.maxIter == 200)
}

@Test func rendererInitFailsWithoutDevice() {
    let mtkView = MTKView()
    let renderer = MandelbrotRenderer(mtkView: mtkView)
    #expect(renderer == nil)
}
