import Foundation

/// Document controller (MVC pattern).
///
/// The Controller provides mutation operations on the Model's document.
/// Since Document is immutable (a struct), mutations produce a new
/// Document that replaces the old one in the Model.
public class Controller {
    public let model: JasModel

    public init(model: JasModel = JasModel()) {
        self.model = model
    }

    public var document: JasDocument {
        model.document
    }

    public func setDocument(_ document: JasDocument) {
        model.document = document
    }

    public func setTitle(_ title: String) {
        model.document = JasDocument(title: title, layers: model.document.layers)
    }

    public func addLayer(_ layer: JasLayer) {
        model.document = JasDocument(title: model.document.title, layers: model.document.layers + [layer])
    }

    public func removeLayer(at index: Int) {
        var layers = model.document.layers
        layers.remove(at: index)
        model.document = JasDocument(title: model.document.title, layers: layers)
    }
}
