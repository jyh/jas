import Foundation

/// Document controller (MVC pattern).
///
/// The Controller provides mutation operations on the Model's document.
/// Since Document is immutable (a struct), mutations produce a new
/// Document that replaces the old one in the Model.
private func boundsIntersect(_ a: BBox, _ b: (Double, Double, Double, Double)) -> Bool {
    a.x < b.0 + b.2 && a.x + a.width > b.0 && a.y < b.1 + b.3 && a.y + a.height > b.1
}

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

    public func addElement(_ element: Element) {
        let doc = model.document
        let idx = doc.selectedLayer
        let target = doc.layers[idx]
        let newLayer = JasLayer(name: target.name, children: target.children + [element],
                                opacity: target.opacity, transform: target.transform)
        var layers = doc.layers
        layers[idx] = newLayer
        model.document = JasDocument(title: doc.title, layers: layers, selectedLayer: idx,
                                     selection: doc.selection)
    }

    public func selectRect(x: Double, y: Double, width: Double, height: Double) {
        let doc = model.document
        let selRect = (x, y, width, height)
        var selection: Selection = []
        for (li, layer) in doc.layers.enumerated() {
            for (ci, child) in layer.children.enumerated() {
                if case .group(let g) = child {
                    let anyHit = g.children.contains { boundsIntersect($0.bounds, selRect) }
                    if anyHit {
                        for gi in 0..<g.children.count {
                            selection.insert([li, ci, gi])
                        }
                    }
                } else {
                    if boundsIntersect(child.bounds, selRect) {
                        selection.insert([li, ci])
                    }
                }
            }
        }
        model.document = JasDocument(title: doc.title, layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: selection)
    }

    public func setSelection(_ selection: Selection) {
        let doc = model.document
        model.document = JasDocument(title: doc.title, layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: selection)
    }

    public func selectElement(_ path: ElementPath) {
        precondition(!path.isEmpty, "Path must be non-empty")
        let doc = model.document
        if path.count >= 2 {
            let parentPath = Array(path.dropLast())
            let parent = doc.getElement(parentPath)
            if case .group(let g) = parent {
                let selection: Selection = Set((0..<g.children.count).map { parentPath + [$0] })
                model.document = JasDocument(title: doc.title, layers: doc.layers,
                                             selectedLayer: doc.selectedLayer, selection: selection)
                return
            }
        }
        model.document = JasDocument(title: doc.title, layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: [path])
    }
}
