import Foundation

/// A path identifies an element by its position in the document tree.
/// Each integer is a child index at that level.
/// `[0]` → layers[0] (a Layer).
/// `[0, 2]` → layers[0].children[2].
/// `[0, 2, 1]` → layers[0].children[2] (a group), child 1.
public typealias ElementPath = [Int]

/// Per-element selection state: which element, whether it is selected,
/// and which of its control points are selected.
public struct ElementSelection: Equatable, Hashable {
    public let path: ElementPath
    public let selected: Bool
    public let controlPoints: Set<Int>

    public init(path: ElementPath, selected: Bool = true, controlPoints: Set<Int> = []) {
        self.path = path; self.selected = selected; self.controlPoints = controlPoints
    }

    // Hash/equality by path only so Selection behaves as a path-keyed collection
    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    public static func == (lhs: ElementSelection, rhs: ElementSelection) -> Bool {
        lhs.path == rhs.path
    }

    /// Full equality including flags (for tests).
    public func exactlyEquals(_ other: ElementSelection) -> Bool {
        path == other.path && selected == other.selected && controlPoints == other.controlPoints
    }
}

/// A selection is a set of ElementSelection entries (unique by path).
public typealias Selection = Set<ElementSelection>

/// A document consisting of a title, an ordered list of layers, and a selection.
public struct JasDocument: Equatable {
    public let title: String
    public let layers: [JasLayer]
    public let selectedLayer: Int
    public let selection: Selection

    public init(
        title: String = "Untitled",
        layers: [JasLayer] = [JasLayer(children: [])],
        selectedLayer: Int = 0,
        selection: Selection = []
    ) {
        self.title = title
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
        precondition(!path.isEmpty, "Path must be non-empty")
        var node: Element = .layer(layers[path[0]])
        for idx in path.dropFirst() {
            node = childrenOf(node)[idx]
        }
        return node
    }

    /// Return a new document with the element at path replaced by newElem.
    public func replaceElement(_ path: ElementPath, with newElem: Element) -> JasDocument {
        precondition(!path.isEmpty, "Path must be non-empty")
        var newLayers = layers
        if path.count == 1 {
            guard case .layer(let l) = newElem else {
                preconditionFailure("Replacing a layer requires a .layer element")
            }
            newLayers[path[0]] = l
        } else {
            let layerElem = replaceInGroup(.layer(layers[path[0]]), Array(path.dropFirst()), newElem)
            guard case .layer(let l) = layerElem else { fatalError("unreachable") }
            newLayers[path[0]] = l
        }
        return JasDocument(title: title, layers: newLayers, selectedLayer: selectedLayer, selection: selection)
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
        return .group(JasGroup(children: newChildren, opacity: g.opacity, transform: g.transform))
    case .layer(let l):
        return .layer(JasLayer(name: l.name, children: newChildren, opacity: l.opacity, transform: l.transform))
    default:
        fatalError("Element has no children")
    }
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
