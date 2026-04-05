import Foundation

/// A path identifies an element by its position in the document tree.
/// Each integer is a child index at that level.
/// `[0]` → layers[0] (a Layer).
/// `[0, 2]` → layers[0].children[2].
/// `[0, 2, 1]` → layers[0].children[2] (a group), child 1.
public typealias ElementPath = [Int]

/// Per-element selection state: which element and which of its control points
/// are selected.
public struct ElementSelection: Equatable, Hashable {
    public let path: ElementPath
    public let controlPoints: Set<Int>

    public init(path: ElementPath, controlPoints: Set<Int> = []) {
        self.path = path; self.controlPoints = controlPoints
    }

    // Hash/equality by path only so Selection behaves as a path-keyed collection
    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    public static func == (lhs: ElementSelection, rhs: ElementSelection) -> Bool {
        lhs.path == rhs.path
    }

    /// Full equality including control points (for tests).
    public func exactlyEquals(_ other: ElementSelection) -> Bool {
        path == other.path && controlPoints == other.controlPoints
    }
}

/// A selection is a set of ElementSelection entries (unique by path).
public typealias Selection = Set<ElementSelection>

/// A document consisting of an ordered list of layers and a selection.
public struct Document: Equatable {
    public let layers: [Layer]
    public let selectedLayer: Int
    public let selection: Selection

    public init(
        layers: [Layer] = [Layer(children: [])],
        selectedLayer: Int = 0,
        selection: Selection = []
    ) {
        self.layers = layers
        self.selectedLayer = selectedLayer
        self.selection = selection
    }

    /// Return the ElementSelection for the given path, or nil.
    public func getElementSelection(_ path: ElementPath) -> ElementSelection? {
        selection.first { $0.path == path }
    }

    /// Return the set of all element paths in the selection.
    public var selectedPaths: Set<ElementPath> {
        Set(selection.map(\.path))
    }

    public var bounds: BBox {
        guard !layers.isEmpty else { return (0, 0, 0, 0) }
        let all = layers.map(\.bounds)
        let minX = all.map(\.x).min()!, minY = all.map(\.y).min()!
        let maxX = all.map { $0.x + $0.width }.max()!
        let maxY = all.map { $0.y + $0.height }.max()!
        return (minX, minY, maxX - minX, maxY - minY)
    }

    /// Return the element at the given path.
    public func getElement(_ path: ElementPath) -> Element {
        guard !path.isEmpty else { fatalError("Path must be non-empty") }
        var node: Element = .layer(layers[path[0]])
        for idx in path.dropFirst() {
            node = childrenOf(node)[idx]
        }
        return node
    }

    /// Return a new document with the element at path replaced by newElem.
    public func replaceElement(_ path: ElementPath, with newElem: Element) -> Document {
        guard !path.isEmpty else { fatalError("Path must be non-empty") }
        var newLayers = layers
        if path.count == 1 {
            guard case .layer(let l) = newElem else {
                fatalError("Replacing a layer requires a .layer element")
            }
            newLayers[path[0]] = l
        } else {
            let layerElem = replaceInGroup(.layer(layers[path[0]]), Array(path.dropFirst()), newElem)
            guard case .layer(let l) = layerElem else { fatalError("unreachable") }
            newLayers[path[0]] = l
        }
        return Document(layers: newLayers, selectedLayer: selectedLayer, selection: selection)
    }
    /// Return a new document with newElem inserted immediately after path.
    public func insertElementAfter(_ path: ElementPath, element newElem: Element) -> Document {
        guard !path.isEmpty else { fatalError("Path must be non-empty") }
        var newLayers = layers
        if path.count == 1 {
            guard case .layer(let l) = newElem else {
                fatalError("Inserting at layer level requires a .layer element")
            }
            newLayers.insert(l, at: path[0] + 1)
        } else {
            let layerElem = insertAfterInGroup(.layer(layers[path[0]]), Array(path.dropFirst()), newElem)
            guard case .layer(let l) = layerElem else { fatalError("unreachable") }
            newLayers[path[0]] = l
        }
        return Document(layers: newLayers, selectedLayer: selectedLayer, selection: selection)
    }

    /// Return a new document with the element at path removed.
    public func deleteElement(_ path: ElementPath) -> Document {
        guard !path.isEmpty else { fatalError("Path must be non-empty") }
        var newLayers = layers
        if path.count == 1 {
            newLayers.remove(at: path[0])
        } else {
            let layerElem = removeFromGroup(.layer(layers[path[0]]), Array(path.dropFirst()))
            guard case .layer(let l) = layerElem else { fatalError("unreachable") }
            newLayers[path[0]] = l
        }
        return Document(layers: newLayers, selectedLayer: selectedLayer, selection: selection)
    }

    /// Return a new document with all selected elements removed and selection cleared.
    public func deleteSelection() -> Document {
        let sortedPaths = selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }.reversed()
        var doc = self
        for path in sortedPaths {
            doc = doc.deleteElement(path)
        }
        return Document(layers: doc.layers,
                           selectedLayer: doc.selectedLayer, selection: [])
    }
}

// MARK: - Private helpers

private func childrenOf(_ elem: Element) -> [Element] {
    switch elem {
    case .group(let g): return g.children
    case .layer(let l): return l.children
    default: fatalError("Element has no children")
    }
}

private func withChildren(_ elem: Element, _ newChildren: [Element]) -> Element {
    switch elem {
    case .group(let g):
        return .group(Group(children: newChildren, opacity: g.opacity, transform: g.transform, locked: g.locked))
    case .layer(let l):
        return .layer(Layer(name: l.name, children: newChildren, opacity: l.opacity, transform: l.transform, locked: l.locked))
    default:
        fatalError("Element has no children")
    }
}

private func insertAfterInGroup(_ node: Element, _ rest: [Int], _ newElem: Element) -> Element {
    var children = childrenOf(node)
    if rest.count == 1 {
        children.insert(newElem, at: rest[0] + 1)
    } else {
        children[rest[0]] = insertAfterInGroup(children[rest[0]], Array(rest.dropFirst()), newElem)
    }
    return withChildren(node, children)
}

private func replaceInGroup(_ node: Element, _ rest: [Int], _ newElem: Element) -> Element {
    var children = childrenOf(node)
    if rest.count == 1 {
        children[rest[0]] = newElem
    } else {
        children[rest[0]] = replaceInGroup(children[rest[0]], Array(rest.dropFirst()), newElem)
    }
    return withChildren(node, children)
}

private func removeFromGroup(_ node: Element, _ rest: [Int]) -> Element {
    var children = childrenOf(node)
    if rest.count == 1 {
        children.remove(at: rest[0])
    } else {
        children[rest[0]] = removeFromGroup(children[rest[0]], Array(rest.dropFirst()))
    }
    return withChildren(node, children)
}
