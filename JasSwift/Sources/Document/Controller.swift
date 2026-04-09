import Foundation

/// Document controller (MVC pattern).
///
/// The Controller provides mutation operations on the Model's document.
/// Since Document is immutable (a struct), mutations produce a new
/// Document that replaces the old one in the Model.

public class Controller {
    public let model: Model

    public init(model: Model = Model()) {
        self.model = model
    }

    public var document: Document {
        model.document
    }

    public func setDocument(_ document: Document) {
        model.document = document
    }

    public func setFilename(_ filename: String) {
        model.filename = filename
    }

    public func addLayer(_ layer: Layer) {
        model.document = Document(layers: model.document.layers + [layer])
    }

    public func removeLayer(at index: Int) {
        var layers = model.document.layers
        layers.remove(at: index)
        model.document = Document(layers: layers)
    }

    public func addElement(_ element: Element) {
        let doc = model.document
        let idx = doc.selectedLayer
        let target = doc.layers[idx]
        let childIdx = target.children.count
        let newLayer = Layer(name: target.name, children: target.children + [element],
                                opacity: target.opacity, transform: target.transform)
        var layers = doc.layers
        layers[idx] = newLayer
        let es = ElementSelection.all([idx, childIdx])
        model.document = Document(layers: layers, selectedLayer: idx,
                                     selection: [es])
    }

    /// XOR two selections per element. See the Rust port for the semantic
    /// table; mixed `.all` / `.partial` cases collapse to `.all`.
    private func toggleSelection(_ current: Selection, _ newSel: Selection) -> Selection {
        let currentByPath = Dictionary(current.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let newByPath = Dictionary(newSel.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var result: Selection = []
        // Elements only in current
        for (path, es) in currentByPath where newByPath[path] == nil {
            result.insert(es)
        }
        // Elements only in new
        for (path, es) in newByPath where currentByPath[path] == nil {
            result.insert(es)
        }
        // Elements in both: XOR.
        for (path, curEs) in currentByPath {
            guard let newEs = newByPath[path] else { continue }
            switch (curEs.kind, newEs.kind) {
            case (.all, .all):
                // Cancel out — element drops out of selection.
                continue
            case (.partial(let a), .partial(let b)):
                // Keep the element even when the XOR is empty — it
                // stays selected as `.partial([])` ("element
                // selected, no CPs highlighted"). `.all` XOR `.all`
                // still drops above; that is the element-level
                // deselect gesture.
                let xor = a.symmetricDifference(b)
                result.insert(ElementSelection(path: path, kind: .partial(xor)))
            default:
                // Mixed `.all` / `.partial` — keep `.all` to preserve
                // pre-refactor behavior for this rare case.
                result.insert(ElementSelection.all(path))
            }
        }
        return result
    }

    public func selectRect(x: Double, y: Double, width: Double, height: Double, extend: Bool = false) {
        let doc = model.document
        var selection: Selection = []
        for (li, layer) in doc.layers.enumerated() {
            let layerVis = layer.visibility
            if layerVis == .invisible { continue }
            for (ci, child) in layer.children.enumerated() {
                if child.isLocked { continue }
                let childVis = min(layerVis, child.visibility)
                if childVis == .invisible { continue }
                if case .group(let g) = child {
                    let anyHit = g.children.contains { elementIntersectsRect($0, x, y, width, height) }
                    if anyHit {
                        selection.insert(ElementSelection.all([li, ci]))
                        for gi in 0..<g.children.count {
                            selection.insert(ElementSelection.all([li, ci, gi]))
                        }
                    }
                } else {
                    if elementIntersectsRect(child, x, y, width, height) {
                        selection.insert(ElementSelection.all([li, ci]))
                    }
                }
            }
        }
        let finalSel = extend ? toggleSelection(doc.selection, selection) : selection
        model.document = Document(layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: finalSel)
    }

    public func selectPolygon(polygon: [(Double, Double)], extend: Bool = false) {
        let doc = model.document
        var selection: Selection = []
        for (li, layer) in doc.layers.enumerated() {
            let layerVis = layer.visibility
            if layerVis == .invisible { continue }
            for (ci, child) in layer.children.enumerated() {
                if child.isLocked { continue }
                let childVis = min(layerVis, child.visibility)
                if childVis == .invisible { continue }
                if case .group(let g) = child {
                    let anyHit = g.children.contains { elementIntersectsPolygon($0, polygon) }
                    if anyHit {
                        selection.insert(ElementSelection.all([li, ci]))
                        for gi in 0..<g.children.count {
                            selection.insert(ElementSelection.all([li, ci, gi]))
                        }
                    }
                } else {
                    if elementIntersectsPolygon(child, polygon) {
                        selection.insert(ElementSelection.all([li, ci]))
                    }
                }
            }
        }
        let finalSel = extend ? toggleSelection(doc.selection, selection) : selection
        model.document = Document(layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: finalSel)
    }

    public func groupSelectRect(x: Double, y: Double, width: Double, height: Double, extend: Bool = false) {
        let doc = model.document
        var selection: Selection = []

        func check(_ path: [Int], _ elem: Element, _ ancestorVis: Visibility) {
            if elem.isLocked { return }
            let effective = min(ancestorVis, elem.visibility)
            if effective == .invisible { return }
            switch elem {
            case .layer(let v):
                for (i, child) in v.children.enumerated() { check(path + [i], child, effective) }
            case .group(let v):
                for (i, child) in v.children.enumerated() { check(path + [i], child, effective) }
            default:
                if elementIntersectsRect(elem, x, y, width, height) {
                    selection.insert(ElementSelection.all(path))
                }
            }
        }

        for (li, layer) in doc.layers.enumerated() {
            check([li], .layer(layer), .preview)
        }
        let finalSel = extend ? toggleSelection(doc.selection, selection) : selection
        model.document = Document(layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: finalSel)
    }

    public func directSelectRect(x: Double, y: Double, width: Double, height: Double, extend: Bool = false) {
        let doc = model.document
        var selection: Selection = []

        func check(_ path: [Int], _ elem: Element, _ ancestorVis: Visibility) {
            if elem.isLocked { return }
            let effective = min(ancestorVis, elem.visibility)
            if effective == .invisible { return }
            switch elem {
            case .layer(let v):
                for (i, child) in v.children.enumerated() { check(path + [i], child, effective) }
            case .group(let v):
                for (i, child) in v.children.enumerated() { check(path + [i], child, effective) }
            default:
                let cps = elem.controlPointPositions
                let hitCPs: [Int] = cps.enumerated().compactMap { (i, pt) in
                    pointInRect(pt.0, pt.1, x, y, width, height) ? i : nil
                }
                if !hitCPs.isEmpty {
                    selection.insert(ElementSelection.partial(path, hitCPs))
                } else if elementIntersectsRect(elem, x, y, width, height) {
                    // Marquee covers the body but no CPs. Select the
                    // element with an empty CP set — the Direct
                    // Selection tool must not promote "body
                    // intersects" to "every CP selected" (which is
                    // what `.all` would mean).
                    selection.insert(ElementSelection.partial(path, []))
                }
            }
        }

        for (li, layer) in doc.layers.enumerated() {
            check([li], .layer(layer), .preview)
        }
        let finalSel = extend ? toggleSelection(doc.selection, selection) : selection
        model.document = Document(layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: finalSel)
    }

    public func setSelection(_ selection: Selection) {
        let doc = model.document
        model.document = Document(layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: selection)
    }

    public func selectElement(_ path: ElementPath) {
        guard !path.isEmpty else { fatalError("Path must be non-empty") }
        let doc = model.document
        let elem = doc.getElement(path)
        if elem.isLocked { return }
        if doc.effectiveVisibility(path) == .invisible { return }
        if path.count >= 2 {
            let parentPath = Array(path.dropLast())
            let parent = doc.getElement(parentPath)
            if case .group(let g) = parent {
                var selection: Selection = [ElementSelection.all(parentPath)]
                for i in 0..<g.children.count {
                    selection.insert(ElementSelection.all(parentPath + [i]))
                }
                model.document = Document(layers: doc.layers,
                                             selectedLayer: doc.selectedLayer, selection: selection)
                return
            }
        }
        let _ = elem
        model.document = Document(layers: doc.layers,
                                     selectedLayer: doc.selectedLayer,
                                     selection: [ElementSelection.all(path)])
    }

    public func selectControlPoint(path: ElementPath, index: Int) {
        guard !path.isEmpty else { fatalError("Path must be non-empty") }
        let doc = model.document
        let es = ElementSelection.partial(path, [index])
        model.document = Document(layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: [es])
    }

    public func movePathHandle(_ path: ElementPath, anchorIdx: Int,
                              handleType: String, dx: Double, dy: Double) {
        var doc = model.document
        let elem = doc.getElement(path)
        if case .path(let v) = elem {
            let newD = JasLib.movePathHandle(v.d, anchorIdx: anchorIdx, handleType: handleType, dx: dx, dy: dy)
            let newElem = Element.path(Path(d: newD, fill: v.fill, stroke: v.stroke,
                                               opacity: v.opacity, transform: v.transform,
                                               locked: v.locked))
            doc = doc.replaceElement(path, with: newElem)
            model.document = doc
        }
    }

    public func moveSelection(dx: Double, dy: Double) {
        var doc = model.document
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = elem.moveControlPoints(es.kind, dx: dx, dy: dy)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        model.document = doc
    }

    public func lockSelection() {
        func lockRecursive(_ elem: Element) -> Element {
            switch elem {
            case .group(let g):
                return .group(Group(children: g.children.map { lockRecursive($0) },
                                    opacity: g.opacity, transform: g.transform, locked: true,
                                    visibility: g.visibility))
            default:
                return elem.withLocked(true)
            }
        }
        var doc = model.document
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            doc = doc.replaceElement(es.path, with: lockRecursive(elem))
        }
        model.document = Document(layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: [])
    }

    public func unlockAll() {
        let doc = model.document
        var lockedPaths: [ElementPath] = []

        func collectLocked(_ path: ElementPath, _ elem: Element) {
            switch elem {
            case .group(let g):
                if g.locked { lockedPaths.append(path) }
                for (i, child) in g.children.enumerated() {
                    collectLocked(path + [i], child)
                }
            case .layer(let l):
                for (i, child) in l.children.enumerated() {
                    collectLocked(path + [i], child)
                }
            default:
                if elem.isLocked { lockedPaths.append(path) }
            }
        }
        for (li, layer) in doc.layers.enumerated() {
            for (ci, child) in layer.children.enumerated() {
                collectLocked([li, ci], child)
            }
        }

        func unlockChildren(_ elements: [Element]) -> [Element] {
            elements.map { elem in
                switch elem {
                case .group(let g):
                    let children = unlockChildren(g.children)
                    return Element.group(Group(children: children, opacity: g.opacity,
                                              transform: g.transform, locked: false,
                                              visibility: g.visibility))
                case .layer(let l):
                    let children = unlockChildren(l.children)
                    return Element.layer(Layer(name: l.name, children: children,
                                              opacity: l.opacity, transform: l.transform, locked: false,
                                              visibility: l.visibility))
                default:
                    return elem.isLocked ? elem.withLocked(false) : elem
                }
            }
        }
        let newLayers = doc.layers.map { layer in
            let children = unlockChildren(layer.children)
            return Layer(name: layer.name, children: children,
                         opacity: layer.opacity, transform: layer.transform, locked: false,
                         visibility: layer.visibility)
        }
        let newDoc = Document(layers: newLayers, selectedLayer: doc.selectedLayer, selection: [])
        var newSelection: Selection = []
        for path in lockedPaths {
            let _ = newDoc.getElement(path)
            newSelection.insert(ElementSelection.all(path))
        }
        model.document = Document(layers: newLayers,
                                     selectedLayer: doc.selectedLayer, selection: newSelection)
    }

    /// Set every element in the current selection to
    /// `Visibility.invisible` and clear the selection.
    ///
    /// If an element is a Group or Layer, only the container's own
    /// flag is set — a parent's `.invisible` caps every descendant,
    /// so the effect reaches the whole subtree without rewriting
    /// every node.
    public func hideSelection() {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            doc = doc.replaceElement(es.path, with: elem.withVisibility(.invisible))
        }
        model.document = Document(layers: doc.layers,
                                  selectedLayer: doc.selectedLayer, selection: [])
    }

    /// Traverse the document, set every element whose own visibility
    /// is `Visibility.invisible` back to `Visibility.preview`, and
    /// replace the current selection with exactly the paths that were
    /// shown. Elements that are effectively invisible only because an
    /// ancestor is invisible are *not* individually modified — it is
    /// the ancestor whose own flag is unset, and that cascades.
    public func showAll() {
        let doc = model.document
        var shownPaths: [ElementPath] = []

        func showIn(_ elem: Element, _ path: ElementPath) -> Element {
            var newElem = elem
            if elem.visibility == .invisible {
                newElem = elem.withVisibility(.preview)
                shownPaths.append(path)
            }
            switch newElem {
            case .group(let g):
                let newChildren = g.children.enumerated().map { (i, c) in
                    showIn(c, path + [i])
                }
                return .group(Group(children: newChildren, opacity: g.opacity,
                                    transform: g.transform, locked: g.locked,
                                    visibility: g.visibility))
            case .layer(let l):
                let newChildren = l.children.enumerated().map { (i, c) in
                    showIn(c, path + [i])
                }
                return .layer(Layer(name: l.name, children: newChildren,
                                    opacity: l.opacity, transform: l.transform, locked: l.locked,
                                    visibility: l.visibility))
            default:
                return newElem
            }
        }

        let newLayers: [Layer] = doc.layers.enumerated().map { (li, layer) in
            let shown = showIn(.layer(layer), [li])
            guard case .layer(let l) = shown else { fatalError("unreachable") }
            return l
        }
        var newSelection: Selection = []
        for path in shownPaths {
            newSelection.insert(ElementSelection.all(path))
        }
        model.document = Document(layers: newLayers,
                                  selectedLayer: doc.selectedLayer, selection: newSelection)
    }

    public func copySelection(dx: Double, dy: Double) {
        var doc = model.document
        var newSelection: Selection = []
        // Sort paths in reverse so insertions don't shift earlier paths
        let sortedSels = doc.selection.sorted { $0.path.lexicographicallyPrecedes($1.path) }.reversed()
        for es in sortedSels {
            let elem = doc.getElement(es.path)
            let copied = elem.moveControlPoints(es.kind, dx: dx, dy: dy)
            doc = doc.insertElementAfter(es.path, element: copied)
            var copyPath = es.path
            copyPath[copyPath.count - 1] += 1
            // Copying always selects the new element as a whole.
            newSelection.insert(ElementSelection.all(copyPath))
        }
        model.document = Document(layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: newSelection)
    }
}
