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
        let old = model.document
        model.document = Document(
            layers: old.layers + [layer],
            selectedLayer: old.selectedLayer,
            selection: old.selection,
            artboards: old.artboards,
            artboardOptions: old.artboardOptions
        )
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

    // MARK: - Selection helpers

    /// Flat 2-level selection with group expansion. Used by `selectRect`
    /// and `selectPolygon` — the only difference between them is the
    /// hit-test predicate.
    private func selectFlat(_ model: Model, predicate: (Element) -> Bool, extend: Bool) {
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
                    let anyHit = g.children.contains { predicate($0) }
                    if anyHit {
                        selection.insert(ElementSelection.all([li, ci]))
                        for gi in 0..<g.children.count {
                            selection.insert(ElementSelection.all([li, ci, gi]))
                        }
                    }
                } else {
                    if predicate(child) {
                        selection.insert(ElementSelection.all([li, ci]))
                    }
                }
            }
        }
        let finalSel = extend ? toggleSelection(doc.selection, selection) : selection
        model.document = Document(layers: doc.layers,
                                     selectedLayer: doc.selectedLayer, selection: finalSel)
    }

    /// Recursive selection with customizable leaf handling. Used by
    /// `groupSelectRect` and `directSelectRect` — they differ only in
    /// what happens when a leaf element is reached.
    private func selectRecursive(_ model: Model,
                                 leafHandler: ([Int], Element) -> ElementSelection?,
                                 extend: Bool) {
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
                if let es = leafHandler(path, elem) {
                    selection.insert(es)
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

    // MARK: - Public selection methods

    public func selectRect(x: Double, y: Double, width: Double, height: Double, extend: Bool = false) {
        selectFlat(model, predicate: { elementIntersectsRect($0, x, y, width, height) }, extend: extend)
    }

    public func selectPolygon(polygon: [(Double, Double)], extend: Bool = false) {
        selectFlat(model, predicate: { elementIntersectsPolygon($0, polygon) }, extend: extend)
    }

    public func groupSelectRect(x: Double, y: Double, width: Double, height: Double, extend: Bool = false) {
        selectRecursive(model, leafHandler: { path, elem in
            elementIntersectsRect(elem, x, y, width, height)
                ? ElementSelection.all(path) : nil
        }, extend: extend)
    }

    public func directSelectRect(x: Double, y: Double, width: Double, height: Double, extend: Bool = false) {
        selectRecursive(model, leafHandler: { path, elem in
            let cps = elem.controlPointPositions
            let hitCPs: [Int] = cps.enumerated().compactMap { (i, pt) in
                pointInRect(pt.0, pt.1, x, y, width, height) ? i : nil
            }
            if !hitCPs.isEmpty {
                return ElementSelection.partial(path, hitCPs)
            } else if elementIntersectsRect(elem, x, y, width, height) {
                // Marquee covers the body but no CPs. Select the
                // element with an empty CP set — the Direct
                // Selection tool must not promote "body
                // intersects" to "every CP selected" (which is
                // what `.all` would mean).
                return ElementSelection.partial(path, [])
            }
            return nil
        }, extend: extend)
    }

    /// Select all unlocked, visible elements in the active layer.
    public func selectAll() {
        selectFlat(model, predicate: { _ in true }, extend: false)
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
                                               widthPoints: v.widthPoints,
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
            // showIn preserves the Element variant: a .layer input always produces a .layer output.
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

    /// Group the currently selected sibling elements into a new Group.
    /// Requires at least 2 selected elements that share the same parent.
    /// After grouping, the selection contains only the new group.
    public func groupSelection() {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let paths = doc.selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }
        guard paths.count >= 2 else { return }
        // All selected elements must be siblings (same parent prefix)
        let parent = Array(paths[0].dropLast())
        guard paths.allSatisfy({ Array($0.dropLast()) == parent }) else { return }
        // Gather elements in order
        let elements = paths.map { doc.getElement($0) }
        // Delete in reverse order
        var newDoc = doc
        for path in paths.reversed() {
            newDoc = newDoc.deleteElement(path)
        }
        // Create group and insert at position of first element
        let group = Element.group(Group(children: elements))
        let insertPath = paths[0]
        let layerIdx = insertPath[0]
        let childIdx = insertPath.count > 1 ? insertPath[1] : 0
        let layer = newDoc.layers[layerIdx]
        var newChildren = layer.children
        newChildren.insert(group, at: childIdx)
        let newLayer = Layer(name: layer.name, children: newChildren,
                            opacity: layer.opacity, transform: layer.transform)
        var newLayers = newDoc.layers
        newLayers[layerIdx] = newLayer
        let newSelection: Selection = [ElementSelection.all(insertPath)]
        model.document = Document(layers: newLayers,
                                  selectedLayer: newDoc.selectedLayer,
                                  selection: newSelection)
    }

    /// Ungroup all selected Group elements, replacing each with its children.
    /// After ungrouping, the selection contains the formerly-grouped children.
    public func ungroupSelection() {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        // Collect selected paths that are Groups
        var groupPaths: [ElementPath] = []
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            if case .group = elem {
                groupPaths.append(es.path)
            }
        }
        guard !groupPaths.isEmpty else { return }
        groupPaths.sort { $0.lexicographicallyPrecedes($1) }
        // Process in reverse order to preserve indices
        var newDoc = doc
        for gpath in groupPaths.reversed() {
            let groupElem = newDoc.getElement(gpath)
            guard case .group(let g) = groupElem else { continue }
            let children = g.children
            // Delete the group
            newDoc = newDoc.deleteElement(gpath)
            let layerIdx = gpath[0]
            let childIdx = gpath.count > 1 ? gpath[1] : 0
            let layer = newDoc.layers[layerIdx]
            var newChildren = layer.children
            newChildren.insert(contentsOf: children, at: childIdx)
            let newLayer = Layer(name: layer.name, children: newChildren,
                                opacity: layer.opacity, transform: layer.transform)
            var newLayers = newDoc.layers
            newLayers[layerIdx] = newLayer
            newDoc = Document(layers: newLayers, selectedLayer: newDoc.selectedLayer,
                              selection: [])
        }
        // Build selection for all unpacked children
        var newSelection: Selection = []
        var offset = 0
        for gpath in groupPaths {
            let groupElem = doc.getElement(gpath)
            guard case .group(let g) = groupElem else { continue }
            let nChildren = g.children.count
            let layerIdx = gpath[0]
            let childIdx = (gpath.count > 1 ? gpath[1] : 0) + offset
            for j in 0..<nChildren {
                let path: ElementPath = [layerIdx, childIdx + j]
                newSelection.insert(ElementSelection.all(path))
            }
            offset += nChildren - 1
        }
        model.document = Document(layers: newDoc.layers,
                                  selectedLayer: newDoc.selectedLayer,
                                  selection: newSelection)
    }

    /// Make a compound shape from the current selection using UNION.
    /// Thin wrapper around makeCompoundShape(operation:).
    public func makeCompoundShape() {
        makeCompoundShape(operation: .union)
    }

    /// Make a compound shape from the current selection using the
    /// given [operation]. All selected elements must be siblings;
    /// at least 2 required. Paint inherits from the frontmost
    /// (last-in-path-order) operand. The new compound replaces its
    /// operands in place and becomes the selection. See BOOLEAN.md
    /// §Compound shapes.
    public func makeCompoundShape(operation: CompoundOperation) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let paths = doc.selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }
        guard paths.count >= 2 else { return }
        let parent = Array(paths[0].dropLast())
        guard paths.allSatisfy({ Array($0.dropLast()) == parent }) else { return }
        let elements = paths.map { doc.getElement($0) }
        let frontmost = elements.last!
        let cs = CompoundShape(
            operation: operation,
            operands: elements,
            fill: frontmost.fill,
            stroke: frontmost.stroke,
            opacity: 1.0,
            transform: frontmost.transform,
            locked: false,
            visibility: frontmost.visibility
        )
        let compound = Element.live(.compoundShape(cs))
        var newDoc = doc
        for path in paths.reversed() {
            newDoc = newDoc.deleteElement(path)
        }
        let insertPath = paths[0]
        let layerIdx = insertPath[0]
        let childIdx = insertPath.count > 1 ? insertPath[1] : 0
        let layer = newDoc.layers[layerIdx]
        var newChildren = layer.children
        newChildren.insert(compound, at: childIdx)
        let newLayer = Layer(name: layer.name, children: newChildren,
                            opacity: layer.opacity, transform: layer.transform)
        var newLayers = newDoc.layers
        newLayers[layerIdx] = newLayer
        let newSelection: Selection = [ElementSelection.all(insertPath)]
        model.document = Document(layers: newLayers,
                                  selectedLayer: newDoc.selectedLayer,
                                  selection: newSelection)
    }

    /// Alt/Option+click on the four Shape Mode buttons. Creates a
    /// live compound shape with the chosen [opName] (union,
    /// subtract_front, intersection, exclude) instead of applying
    /// the destructive variant. Unknown op names are no-ops.
    public func applyCompoundCreation(_ opName: String) {
        let op: CompoundOperation
        switch opName {
        case "union": op = .union
        case "subtract_front": op = .subtractFront
        case "intersection": op = .intersection
        case "exclude": op = .exclude
        default: return
        }
        makeCompoundShape(operation: op)
    }

    /// Release every selected compound shape. Each is replaced with
    /// its operand children; operands keep their own paint. Released
    /// operands become the new selection.
    public func releaseCompoundShape() {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        var csPaths: [ElementPath] = []
        for es in doc.selection {
            if case .live = doc.getElement(es.path) {
                csPaths.append(es.path)
            }
        }
        guard !csPaths.isEmpty else { return }
        csPaths.sort { $0.lexicographicallyPrecedes($1) }
        var newDoc = doc
        for csPath in csPaths.reversed() {
            guard case .live(.compoundShape(let cs)) = newDoc.getElement(csPath) else { continue }
            newDoc = newDoc.deleteElement(csPath)
            let layerIdx = csPath[0]
            let childIdx = csPath.count > 1 ? csPath[1] : 0
            let layer = newDoc.layers[layerIdx]
            var newChildren = layer.children
            newChildren.insert(contentsOf: cs.operands, at: childIdx)
            let newLayer = Layer(name: layer.name, children: newChildren,
                                opacity: layer.opacity, transform: layer.transform)
            var newLayers = newDoc.layers
            newLayers[layerIdx] = newLayer
            newDoc = Document(layers: newLayers, selectedLayer: newDoc.selectedLayer,
                              selection: [])
        }
        var newSelection: Selection = []
        var offset = 0
        for csPath in csPaths {
            guard case .live(.compoundShape(let cs)) = doc.getElement(csPath) else { continue }
            let n = cs.operands.count
            let layerIdx = csPath[0]
            let childIdx = (csPath.count > 1 ? csPath[1] : 0) + offset
            for j in 0..<n {
                newSelection.insert(ElementSelection.all([layerIdx, childIdx + j]))
            }
            offset += n - 1
        }
        model.document = Document(layers: newDoc.layers,
                                  selectedLayer: newDoc.selectedLayer,
                                  selection: newSelection)
    }

    /// Expand every selected compound shape into static Polygon
    /// elements derived from its evaluated geometry. Expanded
    /// polygons become the new selection.
    public func expandCompoundShape() {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        var csPaths: [ElementPath] = []
        for es in doc.selection {
            if case .live = doc.getElement(es.path) {
                csPaths.append(es.path)
            }
        }
        guard !csPaths.isEmpty else { return }
        csPaths.sort { $0.lexicographicallyPrecedes($1) }
        var expandedCounts: [Int] = []
        var newDoc = doc
        for csPath in csPaths.reversed() {
            guard case .live(.compoundShape(let cs)) = newDoc.getElement(csPath) else {
                expandedCounts.append(0)
                continue
            }
            let expanded = cs.expand(precision: DEFAULT_PRECISION)
            expandedCounts.append(expanded.count)
            newDoc = newDoc.deleteElement(csPath)
            let layerIdx = csPath[0]
            let childIdx = csPath.count > 1 ? csPath[1] : 0
            let layer = newDoc.layers[layerIdx]
            var newChildren = layer.children
            newChildren.insert(contentsOf: expanded, at: childIdx)
            let newLayer = Layer(name: layer.name, children: newChildren,
                                opacity: layer.opacity, transform: layer.transform)
            var newLayers = newDoc.layers
            newLayers[layerIdx] = newLayer
            newDoc = Document(layers: newLayers, selectedLayer: newDoc.selectedLayer,
                              selection: [])
        }
        expandedCounts.reverse()
        var newSelection: Selection = []
        var offset = 0
        for (csPath, n) in zip(csPaths, expandedCounts) {
            let layerIdx = csPath[0]
            let childIdx = (csPath.count > 1 ? csPath[1] : 0) + offset
            for j in 0..<n {
                newSelection.insert(ElementSelection.all([layerIdx, childIdx + j]))
            }
            offset += n - 1
        }
        model.document = Document(layers: newDoc.layers,
                                  selectedLayer: newDoc.selectedLayer,
                                  selection: newSelection)
    }

    /// Destructively apply one of the nine boolean ops to the
    /// current selection. Supported: "union", "intersection",
    /// "exclude", "subtract_front", "subtract_back", "crop",
    /// "divide", "trim", "merge".
    ///
    /// [options] carries the document-scoped Boolean Options
    /// settings (precision / remove_redundant_points /
    /// divide_remove_unpainted) per BOOLEAN.md §Boolean Options
    /// dialog. Defaults are applied when not provided.
    ///
    /// Semantics per BOOLEAN.md §Operand and paint rules:
    /// - UNION / INTERSECTION / EXCLUDE: all operands consumed;
    ///   result carries the frontmost operand's paint.
    /// - SUBTRACT_FRONT: frontmost is consumed as cutter; each
    ///   survivor keeps its own paint.
    /// - SUBTRACT_BACK: backmost is consumed as cutter.
    /// - CROP: frontmost is consumed as mask; survivors clipped to
    ///   its interior.
    /// - DIVIDE: cut the union apart so no two fragments overlap;
    ///   each fragment inherits the frontmost covering operand's
    ///   paint.
    /// - TRIM: each operand minus the union of all later operands;
    ///   frontmost is untouched.
    /// - MERGE: TRIM, then union touching survivors whose solid-
    ///   color fills are exactly equal.
    public func applyDestructiveBoolean(
        _ opName: String, options: BooleanOptions = BooleanOptions()
    ) {
        let doc = model.document
        guard !doc.selection.isEmpty else { return }
        let paths = doc.selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }
        guard paths.count >= 2 else { return }
        let parent = Array(paths[0].dropLast())
        guard paths.allSatisfy({ Array($0.dropLast()) == parent }) else { return }
        let elements = paths.map { doc.getElement($0) }
        let precision = options.precision

        // outputs: one (polygonSet, element-for-paint) pair per fragment.
        var outputs: [(BoolPolygonSet, Element)] = []
        switch opName {
        case "union", "intersection", "exclude":
            let sets = elements.map { elementToPolygonSet($0, precision: precision) }
            let op: CompoundOperation = opName == "union" ? .union
                : opName == "intersection" ? .intersection : .exclude
            outputs.append((applyOperation(op, sets), elements.last!))
        case "subtract_front", "crop":
            let cutter = elementToPolygonSet(elements.last!, precision: precision)
            for survivor in elements.dropLast() {
                let sSet = elementToPolygonSet(survivor, precision: precision)
                let res = opName == "crop"
                    ? booleanIntersect(sSet, cutter)
                    : booleanSubtract(sSet, cutter)
                outputs.append((res, survivor))
            }
        case "subtract_back":
            let cutter = elementToPolygonSet(elements.first!, precision: precision)
            for survivor in elements.dropFirst() {
                let sSet = elementToPolygonSet(survivor, precision: precision)
                outputs.append((booleanSubtract(sSet, cutter), survivor))
            }
        case "divide":
            // Walk operands back-to-front, maintaining a partition
            // of the union-so-far as (region, frontmost-covering
            // operand index) pairs. Each incoming operand splits
            // every existing region into overlap / non-overlap;
            // overlap relabels to the incoming index (now frontmost).
            let operandSets = elements.map { elementToPolygonSet($0, precision: precision) }
            var accumulator: [(BoolPolygonSet, Int)] = []
            for (i, opSet) in operandSets.enumerated() {
                var newAcc: [(BoolPolygonSet, Int)] = []
                var remaining = opSet
                for (existingRegion, existingIdx) in accumulator {
                    let overlap = booleanIntersect(existingRegion, opSet)
                    if !overlap.isEmpty { newAcc.append((overlap, i)) }
                    let nonOverlap = booleanSubtract(existingRegion, opSet)
                    if !nonOverlap.isEmpty { newAcc.append((nonOverlap, existingIdx)) }
                    remaining = booleanSubtract(remaining, existingRegion)
                }
                if !remaining.isEmpty { newAcc.append((remaining, i)) }
                accumulator = newAcc
            }
            for (region, paintIdx) in accumulator {
                outputs.append((region, elements[paintIdx]))
            }
        case "trim", "merge":
            let operandSets = elements.map { elementToPolygonSet($0, precision: precision) }
            var trimmed: [(BoolPolygonSet, Element)] = []
            for i in 0..<elements.count {
                var region = operandSets[i]
                for later in operandSets[(i + 1)...] {
                    region = booleanSubtract(region, later)
                }
                if !region.isEmpty {
                    trimmed.append((region, elements[i]))
                }
            }
            if opName == "trim" {
                outputs.append(contentsOf: trimmed)
            } else {
                // MERGE: unify touching same-fill survivors. O(N^2)
                // pass; acceptable for panel-sized selections. The
                // frontmost contributor wins stroke / common props
                // on the merged output.
                var consumed = [Bool](repeating: false, count: trimmed.count)
                for i in 0..<trimmed.count {
                    if consumed[i] { continue }
                    consumed[i] = true
                    var merged = trimmed[i].0
                    var paintSrc = trimmed[i].1
                    if let fillI = paintSrc.fill {
                        for j in (i + 1)..<trimmed.count {
                            if consumed[j] { continue }
                            if let fillJ = trimmed[j].1.fill,
                               fillI.color == fillJ.color {
                                merged = booleanUnion(merged, trimmed[j].0)
                                paintSrc = trimmed[j].1
                                consumed[j] = true
                            }
                        }
                    }
                    outputs.append((merged, paintSrc))
                }
            }
        default:
            return
        }

        // Flatten to Polygon elements; drop rings with < 3 points.
        // Optional per BooleanOptions:
        // - divide_remove_unpainted: drop unpainted DIVIDE fragments
        // - remove_redundant_points: collapse near-collinear points
        var newElements: [Element] = []
        for (ps, paintSrc) in outputs {
            if opName == "divide" && options.divideRemoveUnpainted
               && paintSrc.fill == nil && paintSrc.stroke == nil {
                continue
            }
            for ring in ps {
                let r = options.removeRedundantPoints
                    ? collapseCollinearPoints(ring, tolerance: options.precision)
                    : ring
                guard r.count >= 3 else { continue }
                newElements.append(.polygon(Polygon(
                    points: r,
                    fill: paintSrc.fill,
                    stroke: paintSrc.stroke,
                    opacity: 1.0,
                    transform: paintSrc.transform,
                    locked: false,
                    visibility: paintSrc.visibility
                )))
            }
        }

        var newDoc = doc
        for path in paths.reversed() {
            newDoc = newDoc.deleteElement(path)
        }
        let insertPath = paths[0]
        let layerIdx = insertPath[0]
        let childIdx = insertPath.count > 1 ? insertPath[1] : 0
        let layer = newDoc.layers[layerIdx]
        var newChildren = layer.children
        newChildren.insert(contentsOf: newElements, at: childIdx)
        let newLayer = Layer(name: layer.name, children: newChildren,
                            opacity: layer.opacity, transform: layer.transform)
        var newLayers = newDoc.layers
        newLayers[layerIdx] = newLayer
        var newSelection: Selection = []
        for i in 0..<newElements.count {
            newSelection.insert(ElementSelection.all([layerIdx, childIdx + i]))
        }
        model.document = Document(layers: newLayers,
                                  selectedLayer: newDoc.selectedLayer,
                                  selection: newSelection)
    }

    /// Re-apply the last destructive or compound-creating boolean op
    /// to the current selection. [lastOp] is the 13-value enum from
    /// BOOLEAN.md §Repeat state: op names ending in _compound route
    /// to applyCompoundCreation; all others route to
    /// applyDestructiveBoolean. No-op when [lastOp] is nil or empty.
    public func applyRepeatBooleanOperation(
        _ lastOp: String?, options: BooleanOptions = BooleanOptions()
    ) {
        guard let op = lastOp, !op.isEmpty else { return }
        let suffix = "_compound"
        if op.hasSuffix(suffix) {
            let base = String(op.dropLast(suffix.count))
            applyCompoundCreation(base)
        } else {
            applyDestructiveBoolean(op, options: options)
        }
    }

    /// Set the fill of every element in the current selection.
    public func setSelectionFill(_ fill: Fill?) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withFill(elem, fill: fill)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        model.document = doc
    }

    /// Set the stroke of every element in the current selection.
    public func setSelectionStroke(_ stroke: Stroke?) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withStroke(elem, stroke: stroke)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        model.document = doc
    }

    // ── Opacity mask lifecycle (OPACITY.md § States) ───────────

    /// Create an opacity mask on every selected element that does not
    /// already have one. The subtree starts as an empty ``Group``;
    /// users populate it via the MASK_PREVIEW click (Phase 4).
    /// ``clip`` and ``invert`` come from the document preferences
    /// ``new_masks_clipping`` / ``new_masks_inverted``.
    public func makeMaskOnSelection(clip: Bool, invert: Bool) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            if elem.mask != nil { continue }
            let m = Mask(
                subtreeElement: .group(Group(children: [])),
                clip: clip,
                invert: invert,
                disabled: false,
                linked: true,
                unlinkTransform: nil
            )
            doc = doc.replaceElement(es.path, with: withMask(elem, mask: m))
        }
        model.document = doc
    }

    /// Remove the opacity mask from every selected element.
    public func releaseMaskOnSelection() {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            if elem.mask == nil { continue }
            doc = doc.replaceElement(es.path, with: withMask(elem, mask: nil))
        }
        model.document = doc
    }

    /// Set `mask.clip` on every selected element that has a mask.
    public func setMaskClipOnSelection(_ clip: Bool) {
        updateMaskOnSelection { old in
            Mask(subtreeElement: old.subtreeElement,
                 clip: clip, invert: old.invert,
                 disabled: old.disabled, linked: old.linked,
                 unlinkTransform: old.unlinkTransform)
        }
    }

    /// Set `mask.invert` on every selected element that has a mask.
    public func setMaskInvertOnSelection(_ invert: Bool) {
        updateMaskOnSelection { old in
            Mask(subtreeElement: old.subtreeElement,
                 clip: old.clip, invert: invert,
                 disabled: old.disabled, linked: old.linked,
                 unlinkTransform: old.unlinkTransform)
        }
    }

    /// Toggle `mask.disabled` on every selected mask, driven by the
    /// first selected element's current state.
    public func toggleMaskDisabledOnSelection() {
        guard let current = firstMask(model.document)?.disabled else { return }
        let newState = !current
        updateMaskOnSelection { old in
            Mask(subtreeElement: old.subtreeElement,
                 clip: old.clip, invert: old.invert,
                 disabled: newState, linked: old.linked,
                 unlinkTransform: old.unlinkTransform)
        }
    }

    /// Toggle `mask.linked` on every selected mask. On unlink, captures
    /// each element's current transform into `unlink_transform`. On
    /// relink, clears `unlink_transform`.
    public func toggleMaskLinkedOnSelection() {
        guard let currentLinked = firstMask(model.document)?.linked else { return }
        let newLinked = !currentLinked
        var doc = model.document
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            guard let old = elem.mask else { continue }
            let newMask = Mask(
                subtreeElement: old.subtreeElement,
                clip: old.clip, invert: old.invert,
                disabled: old.disabled,
                linked: newLinked,
                unlinkTransform: newLinked ? nil : elem.transform
            )
            doc = doc.replaceElement(es.path, with: withMask(elem, mask: newMask))
        }
        model.document = doc
    }

    /// Internal helper: apply `transform` to every selected element's
    /// mask. Elements without a mask are skipped.
    private func updateMaskOnSelection(_ transform: (Mask) -> Mask) {
        var doc = model.document
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            guard let old = elem.mask else { continue }
            doc = doc.replaceElement(es.path, with: withMask(elem, mask: transform(old)))
        }
        model.document = doc
    }

    /// Write Character-panel text attributes to every `Text` /
    /// `TextPath` element in the current selection. Non-text elements
    /// in the selection are left alone. Fields not present in `attrs`
    /// preserve their current value on each element. Mirrors the Rust
    /// `apply_character_panel_to_selection` pipeline.
    ///
    /// Recognised keys (mostly string): `font_family`, `font_size`
    /// (number), `font_weight`, `font_style`, `text_decoration`,
    /// `text_transform`, `font_variant`, `baseline_shift`,
    /// `line_height`, `letter_spacing`, `xml_lang`, `aa_mode`,
    /// `rotate`, `horizontal_scale`, `vertical_scale`, `kerning`.
    /// Unknown keys are silently ignored.
    public func setSelectionTextAttributes(_ attrs: [String: Any]) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem: Element
            switch elem {
            case .text(let t):
                newElem = .text(Self.applyTextAttrs(t, attrs: attrs))
            case .textPath(let tp):
                newElem = .textPath(Self.applyTextPathAttrs(tp, attrs: attrs))
            default:
                continue
            }
            doc = doc.replaceElement(es.path, with: newElem)
        }
        model.document = doc
    }

    /// Apply a character-attribute dict onto a single `Text`, returning
    /// a new value with only the overlapping keys replaced.
    private static func applyTextAttrs(_ t: Text, attrs: [String: Any]) -> Text {
        let ff = (attrs["font_family"] as? String) ?? t.fontFamily
        let fs = (attrs["font_size"] as? NSNumber)?.doubleValue ?? t.fontSize
        let fw = (attrs["font_weight"] as? String) ?? t.fontWeight
        let fst = (attrs["font_style"] as? String) ?? t.fontStyle
        let td = (attrs["text_decoration"] as? String) ?? t.textDecoration
        let tt = (attrs["text_transform"] as? String) ?? t.textTransform
        let fv = (attrs["font_variant"] as? String) ?? t.fontVariant
        let bs = (attrs["baseline_shift"] as? String) ?? t.baselineShift
        let lh = (attrs["line_height"] as? String) ?? t.lineHeight
        let ls = (attrs["letter_spacing"] as? String) ?? t.letterSpacing
        let lang = (attrs["xml_lang"] as? String) ?? t.xmlLang
        let aa = (attrs["aa_mode"] as? String) ?? t.aaMode
        let rotate = (attrs["rotate"] as? String) ?? t.rotate
        let hscale = (attrs["horizontal_scale"] as? String) ?? t.horizontalScale
        let vscale = (attrs["vertical_scale"] as? String) ?? t.verticalScale
        let kern = (attrs["kerning"] as? String) ?? t.kerning
        return Text(x: t.x, y: t.y, tspans: t.tspans,
                    fontFamily: ff, fontSize: fs,
                    fontWeight: fw, fontStyle: fst, textDecoration: td,
                    textTransform: tt, fontVariant: fv,
                    baselineShift: bs, lineHeight: lh,
                    letterSpacing: ls, xmlLang: lang,
                    aaMode: aa, rotate: rotate,
                    horizontalScale: hscale, verticalScale: vscale,
                    kerning: kern,
                    width: t.width, height: t.height,
                    fill: t.fill, stroke: t.stroke,
                    opacity: t.opacity, transform: t.transform,
                    locked: t.locked, visibility: t.visibility)
    }

    /// Apply a character-attribute dict onto a single `TextPath`,
    /// returning a new value with overlapping keys replaced.
    private static func applyTextPathAttrs(_ tp: TextPath, attrs: [String: Any]) -> TextPath {
        let ff = (attrs["font_family"] as? String) ?? tp.fontFamily
        let fs = (attrs["font_size"] as? NSNumber)?.doubleValue ?? tp.fontSize
        let fw = (attrs["font_weight"] as? String) ?? tp.fontWeight
        let fst = (attrs["font_style"] as? String) ?? tp.fontStyle
        let td = (attrs["text_decoration"] as? String) ?? tp.textDecoration
        let tt = (attrs["text_transform"] as? String) ?? tp.textTransform
        let fv = (attrs["font_variant"] as? String) ?? tp.fontVariant
        let bs = (attrs["baseline_shift"] as? String) ?? tp.baselineShift
        let lh = (attrs["line_height"] as? String) ?? tp.lineHeight
        let ls = (attrs["letter_spacing"] as? String) ?? tp.letterSpacing
        let lang = (attrs["xml_lang"] as? String) ?? tp.xmlLang
        let aa = (attrs["aa_mode"] as? String) ?? tp.aaMode
        let rotate = (attrs["rotate"] as? String) ?? tp.rotate
        let hscale = (attrs["horizontal_scale"] as? String) ?? tp.horizontalScale
        let vscale = (attrs["vertical_scale"] as? String) ?? tp.verticalScale
        let kern = (attrs["kerning"] as? String) ?? tp.kerning
        return TextPath(d: tp.d, tspans: tp.tspans,
                        startOffset: tp.startOffset,
                        fontFamily: ff, fontSize: fs,
                        fontWeight: fw, fontStyle: fst, textDecoration: td,
                        textTransform: tt, fontVariant: fv,
                        baselineShift: bs, lineHeight: lh,
                        letterSpacing: ls, xmlLang: lang,
                        aaMode: aa, rotate: rotate,
                        horizontalScale: hscale, verticalScale: vscale,
                        kerning: kern,
                        fill: tp.fill, stroke: tp.stroke,
                        opacity: tp.opacity, transform: tp.transform,
                        locked: tp.locked, visibility: tp.visibility)
    }

    public func setSelectionWidthProfile(_ widthPoints: [StrokeWidthPoint]) {
        var doc = model.document
        if doc.selection.isEmpty { return }
        for es in doc.selection {
            let elem = doc.getElement(es.path)
            let newElem = withWidthPoints(elem, widthPoints: widthPoints)
            doc = doc.replaceElement(es.path, with: newElem)
        }
        model.document = doc
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

// MARK: - Fill / Stroke summary

public enum FillSummary: Equatable {
    case noSelection
    case uniform(Fill?)
    case mixed
}

public enum StrokeSummary: Equatable {
    case noSelection
    case uniform(Stroke?)
    case mixed
}

/// Summarize the fill of all selected elements.
public func selectionFillSummary(_ doc: Document) -> FillSummary {
    let sel = doc.selection
    guard !sel.isEmpty else { return .noSelection }
    var first = true
    var value: Fill? = nil
    for es in sel {
        let elem = doc.getElement(es.path)
        // Skip groups/layers -- they have no fill.
        if case .group = elem { continue }
        if case .layer = elem { continue }
        let f = elem.fill
        if first {
            value = f
            first = false
        } else if f != value {
            return .mixed
        }
    }
    if first { return .noSelection }
    return .uniform(value)
}

/// Summarize the stroke of all selected elements.
public func selectionStrokeSummary(_ doc: Document) -> StrokeSummary {
    let sel = doc.selection
    guard !sel.isEmpty else { return .noSelection }
    var first = true
    var value: Stroke? = nil
    for es in sel {
        let elem = doc.getElement(es.path)
        if case .group = elem { continue }
        if case .layer = elem { continue }
        let s = elem.stroke
        if first {
            value = s
            first = false
        } else if s != value {
            return .mixed
        }
    }
    if first { return .noSelection }
    return .uniform(value)
}
