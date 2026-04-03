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

public class MandelbrotRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLComputePipelineState

    public var centerX: Double = -0.75
    public var centerY: Double = 0.0
    public var scale: Double = 3.5
    public var maxIter: Int32 = 200

    private var refOrbitBuffer: MTLBuffer?

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
            guard let function = library.makeFunction(name: "mandelbrot") else {
                print("Failed to find mandelbrot function in shader")
                return nil
            }
            self.pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("Failed to compile Metal shader: \(error)")
            return nil
        }

        super.init()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        let texture = drawable.texture
        let w = texture.width
        let h = texture.height

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

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<MandelbrotUniforms>.size, index: 0)
        encoder.setBuffer(refOrbitBuffer, offset: 0, index: 1)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (w + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (h + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
