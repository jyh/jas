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

    public init(document: JasDocument = JasDocument()) {
        self.document = document
    }

    public func onDocumentChanged(_ callback: @escaping (JasDocument) -> Void) {
        listeners.append(callback)
    }

    private func notify() {
        for listener in listeners {
            listener(document)
        }
    }
}
