import Foundation
import Combine

private var nextUntitled = 1

private func freshFilename() -> String {
    let name = "Untitled-\(nextUntitled)"
    nextUntitled += 1
    return name
}

/// Observable model that holds the current document.
///
/// Views register callbacks via onDocumentChanged to be notified
/// whenever the document is replaced.
public class Model: ObservableObject {
    @Published public var document: Document {
        didSet { notify() }
    }
    @Published public var filename: String
    public private(set) var savedDocument: Document
    private var listeners: [(Document) -> Void] = []
    private var undoStack: [Document] = []
    private var redoStack: [Document] = []
    private let maxUndo = 100

    public var isModified: Bool { document != savedDocument }

    public init(document: Document = Document(), filename: String? = nil) {
        self.document = document
        self.savedDocument = document
        self.filename = filename ?? freshFilename()
    }

    public func markSaved() {
        savedDocument = document
        objectWillChange.send()
    }

    public func onDocumentChanged(_ callback: @escaping (Document) -> Void) {
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
