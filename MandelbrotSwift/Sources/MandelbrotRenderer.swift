import Foundation
import Metal
import MetalKit

struct MandelbrotUniforms {
    var centerX: Float
    var centerY: Float
    var scale: Float
    var maxIter: Int32
    var width: Int32
    var height: Int32
}

class MandelbrotRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLComputePipelineState

    var centerX: Float = -0.75
    var centerY: Float = 0.0
    var scale: Float = 3.5
    var maxIter: Int32 = 500

    init?(mtkView: MTKView) {
        guard let device = mtkView.device,
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue

        // Compile Metal shader from source at runtime
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Nothing needed; we read size each frame
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        let texture = drawable.texture
        let w = texture.width
        let h = texture.height

        var uniforms = MandelbrotUniforms(
            centerX: centerX,
            centerY: centerY,
            scale: scale,
            maxIter: maxIter,
            width: Int32(w),
            height: Int32(h)
        )

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<MandelbrotUniforms>.size, index: 0)

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
