import SwiftUI
import AppKit

/// The main drawing canvas rendered as a white NSView.
public struct CanvasView: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The main content view with a dark workspace background.
/// A floating canvas subwindow is opened on appear.
public struct ContentView: View {
    public init() {}

    public var body: some View {
        Color(nsColor: NSColor(white: 0.235, alpha: 1.0))
            .frame(minWidth: 640, minHeight: 480)
            .onAppear {
                openCanvasWindow()
            }
    }

    private func openCanvasWindow() {
        let canvas = NSHostingView(rootView: CanvasView())

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Untitled"
        window.contentView = canvas
        window.isFloatingPanel = true
        window.center()
        window.orderFront(nil)
    }
}
