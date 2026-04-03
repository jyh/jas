import SwiftUI
import MetalKit

struct MetalView: NSViewRepresentable {
    @Binding var centerX: Double
    @Binding var centerY: Double
    @Binding var scale: Double
    @Binding var maxIter: Int32

    class Coordinator: NSObject {
        var renderer: MandelbrotRenderer?
        var parent: MetalView
        var isDragging = false
        var lastDragLocation: NSPoint = .zero

        init(parent: MetalView) {
            self.parent = parent
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = DraggableMTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true

        if let renderer = MandelbrotRenderer(mtkView: mtkView) {
            renderer.centerX = centerX
            renderer.centerY = centerY
            renderer.scale = scale
            renderer.maxIter = maxIter
            mtkView.delegate = renderer
            context.coordinator.renderer = renderer
        }

        mtkView.coordinator = context.coordinator

        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.centerX = centerX
        renderer.centerY = centerY
        renderer.scale = scale
        renderer.maxIter = maxIter
        mtkView.setNeedsDisplay(mtkView.bounds)
    }
}

/// Custom MTKView subclass to handle mouse events
class DraggableMTKView: MTKView {
    weak var coordinator: MetalView.Coordinator?
    private var lastDragLocation: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let coordinator = coordinator else { return }
        let location = convert(event.locationInWindow, from: nil)
        let dx = location.x - lastDragLocation.x
        let dy = location.y - lastDragLocation.y
        lastDragLocation = location

        let w = Double(bounds.width)
        let h = Double(bounds.height)

        coordinator.parent.centerX -= dx / w * coordinator.parent.scale
        coordinator.parent.centerY += dy / h * (coordinator.parent.scale * (h / w))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let coordinator = coordinator else { return }
        let delta = Double(event.scrollingDeltaY)
        let angle: Double
        if event.hasPreciseScrollingDeltas {
            angle = delta / 30.0
        } else {
            angle = delta / 3.0
        }

        let factor = pow(0.85, angle)

        let location = convert(event.locationInWindow, from: nil)
        let w = Double(bounds.width)
        let h = Double(bounds.height)

        // Mouse position in fractal coordinates
        let mx = (Double(location.x) / w - 0.5) * coordinator.parent.scale + coordinator.parent.centerX
        let my = (0.5 - Double(location.y) / h) * (coordinator.parent.scale * (h / w)) + coordinator.parent.centerY

        coordinator.parent.scale *= factor
        coordinator.parent.centerX = mx + (coordinator.parent.centerX - mx) * factor
        coordinator.parent.centerY = my + (coordinator.parent.centerY - my) * factor

        // Adjust max iterations on zoom
        let iterAdjust = 1.0 + abs(angle) * 0.12
        var newIter = Int32(Double(coordinator.parent.maxIter) * iterAdjust)
        newIter = max(100, min(10000, newIter))
        coordinator.parent.maxIter = newIter
    }
}
