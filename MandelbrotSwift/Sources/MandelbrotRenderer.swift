import Foundation
import Metal
import MetalKit

public struct MandelbrotUniforms {
    var centerX_hi: Float
    var centerX_lo: Float
    var centerY_hi: Float
    var centerY_lo: Float
    var scale_hi: Float
    var scale_lo: Float
    var maxIter: Int32
    var width: Int32
    var height: Int32
    var refOrbitLen: Int32
}

struct ColorUniforms {
    var width: Int32
    var height: Int32
    var lutSize: Int32
    var maxIter: Float
}

private let viridisControlPoints: [SIMD3<Float>] = [
    SIMD3(0.267004, 0.004874, 0.329415),
    SIMD3(0.282327, 0.040461, 0.380014),
    SIMD3(0.282884, 0.085159, 0.419549),
    SIMD3(0.271895, 0.128898, 0.449241),
    SIMD3(0.253935, 0.170689, 0.470894),
    SIMD3(0.233603, 0.210636, 0.485966),
    SIMD3(0.213939, 0.248543, 0.495647),
    SIMD3(0.196141, 0.284286, 0.501135),
    SIMD3(0.179996, 0.318290, 0.503586),
    SIMD3(0.165101, 0.350925, 0.503582),
    SIMD3(0.151918, 0.382340, 0.501464),
    SIMD3(0.140956, 0.412543, 0.497403),
    SIMD3(0.133217, 0.441702, 0.491354),
    SIMD3(0.129151, 0.469888, 0.483397),
    SIMD3(0.130021, 0.497064, 0.473322),
    SIMD3(0.136866, 0.523159, 0.461040),
    SIMD3(0.152519, 0.548157, 0.446523),
    SIMD3(0.178606, 0.571949, 0.429869),
    SIMD3(0.214298, 0.594296, 0.411374),
    SIMD3(0.258780, 0.614882, 0.391129),
    SIMD3(0.310382, 0.633498, 0.369330),
    SIMD3(0.366529, 0.649870, 0.346353),
    SIMD3(0.424505, 0.663891, 0.322654),
    SIMD3(0.483397, 0.675568, 0.298455),
    SIMD3(0.543049, 0.684934, 0.273780),
    SIMD3(0.603264, 0.692064, 0.248564),
    SIMD3(0.663569, 0.697045, 0.222878),
    SIMD3(0.723457, 0.700050, 0.196640),
    SIMD3(0.782349, 0.701379, 0.169525),
    SIMD3(0.839489, 0.701554, 0.141590),
    SIMD3(0.894305, 0.701355, 0.112529),
    SIMD3(0.993248, 0.906157, 0.143936),
]

private func viridisColor(_ t: Float) -> SIMD4<Float> {
    let n = viridisControlPoints.count
    let pos = t * Float(n - 1)
    let i = min(Int(pos), n - 2)
    let f = pos - Float(i)
    let c = viridisControlPoints[i] * (1 - f) + viridisControlPoints[i + 1] * f
    return SIMD4(c.x, c.y, c.z, 1.0)
}

public class MandelbrotRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let iterPipeline: MTLComputePipelineState
    let colorizePipeline: MTLComputePipelineState

    public var centerX: Double = -0.75
    public var centerY: Double = 0.0
    public var scale: Double = 3.5
    public var maxIter: Int32 = 200

    private var refOrbitBuffer: MTLBuffer?
    private var iterTexture: MTLTexture?
    private var iterTextureWidth: Int = 0
    private var iterTextureHeight: Int = 0

    /// Split a Double into two Floats: hi + lo ≈ value
    public func splitDouble(_ value: Double) -> (Float, Float) {
        let hi = Float(value)
        let lo = Float(value - Double(hi))
        return (hi, lo)
    }

    /// Compute reference orbit at center using Double precision
    public func computeReferenceOrbit() -> ([SIMD2<Float>], Int32) {
        var zx: Double = 0.0
        var zy: Double = 0.0
        let cx = centerX
        let cy = centerY
        let maxN = Int(maxIter)

        var orbit = [SIMD2<Float>]()
        orbit.reserveCapacity(maxN + 1)

        // Store Z_0 = (0, 0)
        orbit.append(SIMD2<Float>(0, 0))

        for _ in 0..<maxN {
            let zx2 = zx * zx
            let zy2 = zy * zy
            if zx2 + zy2 > 256.0 { break }  // large bailout for reference stability
            let newZx = zx2 - zy2 + cx
            let newZy = 2.0 * zx * zy + cy
            zx = newZx
            zy = newZy
            orbit.append(SIMD2<Float>(Float(zx), Float(zy)))
        }

        return (orbit, Int32(orbit.count))
    }

    public init?(mtkView: MTKView) {
        guard let device = mtkView.device,
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue

        do {
            let library = try device.makeLibrary(source: metalShaderSource, options: nil)
            guard let iterFunc = library.makeFunction(name: "mandelbrot_iterations"),
                  let colorFunc = library.makeFunction(name: "mandelbrot_colorize") else {
                print("Failed to find shader functions")
                return nil
            }
            self.iterPipeline = try device.makeComputePipelineState(function: iterFunc)
            self.colorizePipeline = try device.makeComputePipelineState(function: colorFunc)
        } catch {
            print("Failed to compile Metal shader: \(error)")
            return nil
        }

        super.init()
    }

    private func ensureIterTexture(width: Int, height: Int) {
        if iterTextureWidth == width && iterTextureHeight == height && iterTexture != nil {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        iterTexture = device.makeTexture(descriptor: desc)
        iterTextureWidth = width
        iterTextureHeight = height
    }

    static let lutSize = 4096
    private var smoothedCDF = [Float](repeating: 0, count: 4096)
    private var cdfInitialized = false

    /// Read back iteration texture, build histogram, compute CDF, and map to
    /// viridis colors. Returns a LUT indexed by `int(smoothIter/maxIter * lutSize)`.
    private func buildColorLUT(width: Int, height: Int) -> [SIMD4<Float>] {
        let lutSize = MandelbrotRenderer.lutSize
        guard let tex = iterTexture else {
            return [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: lutSize)
        }

        // Read back smooth iteration values
        let pixelCount = width * height
        var iterValues = [Float](repeating: 0, count: pixelCount)
        tex.getBytes(
            &iterValues,
            bytesPerRow: width * MemoryLayout<Float>.size,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        // Histogram: count escaped pixels in each LUT bin
        var histogram = [Int](repeating: 0, count: lutSize)
        let scale = Float(lutSize) / Float(maxIter)
        var escapedCount = 0
        for v in iterValues where v >= 0 {
            let bin = min(Int(v * scale), lutSize - 1)
            histogram[bin] += 1
            escapedCount += 1
        }

        // CDF: cumulative sum normalized to [0, 1]
        var cdf = [Float](repeating: 0, count: lutSize)
        var cumulative = 0
        for i in 0..<lutSize {
            cumulative += histogram[i]
            cdf[i] = escapedCount > 0 ? Float(cumulative) / Float(escapedCount) : Float(i) / Float(lutSize - 1)
        }

        // Temporally smooth the CDF to prevent jarring color changes during panning.
        // On the first frame, initialize directly; afterwards blend toward the new CDF.
        let alpha: Float = cdfInitialized ? 0.25 : 1.0
        for i in 0..<lutSize {
            smoothedCDF[i] = alpha * cdf[i] + (1.0 - alpha) * smoothedCDF[i]
        }
        cdfInitialized = true

        // Map each LUT bin to a viridis color via the inverted CDF:
        // high-iteration (boundary) pixels → dark purple, low-iteration → bright yellow.
        // This ensures a smooth dark transition into the black interior.
        return smoothedCDF.map { viridisColor($0) }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let texture = drawable.texture
        let w = texture.width
        let h = texture.height

        ensureIterTexture(width: w, height: h)

        // Compute reference orbit on CPU
        let (orbit, refLen) = computeReferenceOrbit()
        let orbitByteLen = orbit.count * MemoryLayout<SIMD2<Float>>.stride
        refOrbitBuffer = device.makeBuffer(bytes: orbit, length: orbitByteLen, options: .storageModeShared)

        let (cxHi, cxLo) = splitDouble(centerX)
        let (cyHi, cyLo) = splitDouble(centerY)
        let (sHi, sLo) = splitDouble(scale)

        var uniforms = MandelbrotUniforms(
            centerX_hi: cxHi,
            centerX_lo: cxLo,
            centerY_hi: cyHi,
            centerY_lo: cyLo,
            scale_hi: sHi,
            scale_lo: sLo,
            maxIter: maxIter,
            width: Int32(w),
            height: Int32(h),
            refOrbitLen: refLen
        )

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (w + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (h + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        // Pass 1: Compute iteration counts
        guard let encoder1 = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder1.setComputePipelineState(iterPipeline)
        encoder1.setTexture(iterTexture, index: 0)
        encoder1.setBytes(&uniforms, length: MemoryLayout<MandelbrotUniforms>.size, index: 0)
        encoder1.setBuffer(refOrbitBuffer, offset: 0, index: 1)
        encoder1.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder1.endEncoding()

        // Wait for pass 1 to complete so we can read back on CPU
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Build color LUT on CPU from histogram CDF + viridis
        let lutSize = MandelbrotRenderer.lutSize
        var colorLUT = buildColorLUT(width: w, height: h)

        guard let commandBuffer2 = commandQueue.makeCommandBuffer(),
              let encoder2 = commandBuffer2.makeComputeCommandEncoder() else { return }

        var colorUniforms = ColorUniforms(
            width: Int32(w),
            height: Int32(h),
            lutSize: Int32(lutSize),
            maxIter: Float(maxIter)
        )

        let lutBuffer = device.makeBuffer(
            bytes: &colorLUT,
            length: lutSize * MemoryLayout<SIMD4<Float>>.size,
            options: .storageModeShared
        )

        // Pass 2: Colorize using LUT
        encoder2.setComputePipelineState(colorizePipeline)
        encoder2.setTexture(iterTexture, index: 0)
        encoder2.setTexture(texture, index: 1)
        encoder2.setBytes(&colorUniforms, length: MemoryLayout<ColorUniforms>.size, index: 0)
        encoder2.setBuffer(lutBuffer, offset: 0, index: 1)
        encoder2.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder2.endEncoding()

        commandBuffer2.present(drawable)
        commandBuffer2.commit()
    }
}
