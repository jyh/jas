import Foundation
import Combine

/// Observable model that holds the current document.
///
/// Views register callbacks via onDocumentChanged to be notified
/// whenever the document is replaced.
public class JasModel: ObservableObject {
    @Published public var document: JasDocument {
        didSet { notify() }
    }
    private var listeners: [(JasDocument) -> Void] = []
    private var undoStack: [JasDocument] = []
    private var redoStack: [JasDocument] = []
    private let maxUndo = 100

    public init(document: JasDocument = JasDocument()) {
        self.document = document
    }

    public func onDocumentChanged(_ callback: @escaping (JasDocument) -> Void) {
        listeners.append(callback)
    }

    public func snapshot() {
        undoStack.append(document)
        if undoStack.count > maxUndo {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    public func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(document)
        document = prev
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private func notify() {
        for listener in listeners {
            listener(document)
        }
    }
}
