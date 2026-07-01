import Foundation
import Collections

/// A path identifies an element by its position in the document tree.
/// Each integer is a child index at that level.
/// `[0]` → layers[0] (a Layer).
/// `[0, 2]` → layers[0].children[2].
/// `[0, 2, 1]` → layers[0].children[2] (a group), child 1.
public typealias ElementPath = [Int]

/// Sorted, de-duplicated collection of control-point indices.
///
/// Invariant: the backing array is sorted ascending and contains no
/// duplicates. All constructors and mutators preserve it, so callers
/// can rely on deterministic iteration order and binary-search
/// membership checks.
public struct SortedCps: Equatable, Hashable {
    private var indices: [UInt16]

    public init() { self.indices = [] }

    /// Build a sorted-unique `SortedCps` from any sequence of `Int` CP indices.
    public init<S: Sequence>(_ seq: S) where S.Element == Int {
        var v = seq.map { UInt16($0) }
        v.sort()
        // Drop adjacent duplicates.
        var dedup: [UInt16] = []
        dedup.reserveCapacity(v.count)
        for x in v {
            if dedup.last != x { dedup.append(x) }
        }
        self.indices = dedup
    }

    public static func single(_ i: Int) -> SortedCps {
        var s = SortedCps()
        s.indices = [UInt16(i)]
        return s
    }

    public func contains(_ i: Int) -> Bool {
        let v = UInt16(i)
        var lo = 0, hi = indices.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if indices[mid] < v { lo = mid + 1 }
            else if indices[mid] > v { hi = mid }
            else { return true }
        }
        return false
    }

    public var count: Int { indices.count }
    public var isEmpty: Bool { indices.isEmpty }

    /// Iterate CP indices in ascending order.
    public func toArray() -> [Int] { indices.map { Int($0) } }

    /// Insert `i`; no-op if already present.
    public mutating func insert(_ i: Int) {
        let v = UInt16(i)
        var lo = 0, hi = indices.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if indices[mid] < v { lo = mid + 1 }
            else if indices[mid] > v { hi = mid }
            else { return }
        }
        indices.insert(v, at: lo)
    }

    /// Symmetric difference (XOR) of two sorted sets.
    public func symmetricDifference(_ other: SortedCps) -> SortedCps {
        var out: [UInt16] = []
        out.reserveCapacity(indices.count + other.indices.count)
        var a = 0, b = 0
        while a < indices.count && b < other.indices.count {
            if indices[a] < other.indices[b] { out.append(indices[a]); a += 1 }
            else if indices[a] > other.indices[b] { out.append(other.indices[b]); b += 1 }
            else { a += 1; b += 1 }
        }
        out.append(contentsOf: indices[a...].dropFirst(0))
        out.append(contentsOf: other.indices[b...].dropFirst(0))
        var result = SortedCps()
        result.indices = out
        return result
    }
}

/// Per-element selection state: either the element is fully selected
/// (`all`) or only a subset of its control points are selected
/// (`partial`).
public enum SelectionKind: Equatable, Hashable {
    case all
    case partial(SortedCps)

    /// True if control-point index `i` is selected. `.all` contains
    /// every index; `.partial(s)` checks against the sorted vector.
    public func contains(_ i: Int) -> Bool {
        switch self {
        case .all: return true
        case .partial(let s): return s.contains(i)
        }
    }

    /// Number of selected CPs. The caller supplies `total` so `.all`
    /// can answer without knowing it at construction time.
    public func count(total: Int) -> Int {
        switch self {
        case .all: return total
        case .partial(let s): return s.count
        }
    }

    /// True when every CP of an element with `total` CPs is selected.
    public func isAll(total: Int) -> Bool {
        switch self {
        case .all: return true
        case .partial(let s): return s.count == total
        }
    }

    /// Return an explicit set of selected CPs for an element with
    /// `total` CPs.
    public func toSorted(total: Int) -> SortedCps {
        switch self {
        case .all: return SortedCps(0..<total)
        case .partial(let s): return s
        }
    }
}

/// Per-element selection entry: which element, and how it is selected.
///
/// Equality and hashing are by **path only**, so two `ElementSelection`
/// values with the same path but different `kind`s are considered
/// equal — `Selection` is effectively a path-keyed map.
public struct ElementSelection: Equatable, Hashable {
    public let path: ElementPath
    public let kind: SelectionKind

    public init(path: ElementPath, kind: SelectionKind = .all) {
        self.path = path
        self.kind = kind
    }

    /// Convenience: build an `.all` selection entry for `path`.
    public static func all(_ path: ElementPath) -> ElementSelection {
        ElementSelection(path: path, kind: .all)
    }

    /// Convenience: build a `.partial` selection entry for `path` from
    /// any sequence of CP indices.
    public static func partial<S: Sequence>(_ path: ElementPath, _ cps: S) -> ElementSelection
    where S.Element == Int {
        ElementSelection(path: path, kind: .partial(SortedCps(cps)))
    }

    // Hash/equality by path only so Selection behaves as a path-keyed collection
    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    public static func == (lhs: ElementSelection, rhs: ElementSelection) -> Bool {
        lhs.path == rhs.path
    }

    /// Full equality including selection kind (for tests).
    public func exactlyEquals(_ other: ElementSelection) -> Bool {
        path == other.path && kind == other.kind
    }
}

/// A selection is a set of ElementSelection entries (unique by path).
public typealias Selection = Set<ElementSelection>

/// A document consisting of an ordered list of layers, a selection,
/// and a list of artboards (with document-global options).
public struct Document: Equatable {
    public let layers: [Layer]
    /// Off-canvas master store for Symbols (SYMBOLS.md §2, Fork S1). Each
    /// master is a plain `Element` keyed by its `id`; instances are
    /// `ReferenceElem`s targeting a master id. AUTHORITATIVE document data
    /// (unlike the derived dependency index), so it IS part of Equatable and
    /// every codec. It is NOT in `layers`, so render and hit-test never touch
    /// it (masters are never painted). Storage order is unconstrained, but it
    /// MUST be emitted sorted-by-id at every order-dependent site (codecs,
    /// resolver, index) per §2 "deterministic order".
    public let symbols: [Element]
    public let selectedLayer: Int
    public let selection: Selection
    /// Print-page regions. The at-least-one-artboard invariant
    /// (ARTBOARDS.md) is enforced by the init: if `artboards` is
    /// passed empty, a default Letter artboard is seeded. Parsers
    /// that want the "empty artboards, trust load-time repair
    /// elsewhere" semantic should use `init(rawLayers:..., rawArtboards:...)`.
    public let artboards: [Artboard]
    /// Document-global artboard display toggles (fade outside,
    /// update while dragging).
    public let artboardOptions: ArtboardOptions
    /// Per-document Document Setup state: bleed, image outline display,
    /// substituted-glyph highlight (PRINT.md §Phase 1A).
    public let documentSetup: DocumentSetup
    /// Per-document Print dialog last-used state (PRINT.md §Phase 1B).
    public let printPreferences: PrintPreferences

    public init(
        layers: [Layer] = [Layer(name: "Layer", children: [])],
        symbols: [Element] = [],
        selectedLayer: Int = 0,
        selection: Selection = [],
        artboards: [Artboard] = [],
        artboardOptions: ArtboardOptions = .default,
        documentSetup: DocumentSetup = .default,
        printPreferences: PrintPreferences = .default
    ) {
        self.layers = layers
        self.symbols = symbols
        self.selectedLayer = selectedLayer
        self.selection = selection
        self.artboards = artboards
        self.artboardOptions = artboardOptions
        self.documentSetup = documentSetup
        self.printPreferences = printPreferences
    }

    /// Fresh-document initializer: seeds one default artboard via the
    /// at-least-one-artboard invariant (ARTBOARDS.md). Use this for
    /// explicit "new document" flows (File → New, workspace session
    /// restore) rather than the generic `init`. Internal rebuilds
    /// (setDocument, replaceElement, etc.) preserve the caller's
    /// current artboards, including explicit empty.
    public static func newEmptyDocument(
        idGenerator: () -> String = generateArtboardId
    ) -> Document {
        Document(
            layers: [Layer(name: "Layer", children: [])],
            artboards: ensureArtboardsInvariant([], idGenerator: idGenerator).artboards
        )
    }

    /// Parser-facing init: accepts whatever artboards the caller
    /// decoded, no invariant enforcement. Used by `testJsonToDocument`
    /// and similar legacy-fixture readers.
    public init(
        rawLayers: [Layer],
        rawSymbols: [Element] = [],
        rawSelectedLayer: Int,
        rawSelection: Selection,
        rawArtboards: [Artboard],
        rawArtboardOptions: ArtboardOptions,
        rawDocumentSetup: DocumentSetup = .default,
        rawPrintPreferences: PrintPreferences = .default
    ) {
        self.layers = rawLayers
        self.symbols = rawSymbols
        self.selectedLayer = rawSelectedLayer
        self.selection = rawSelection
        self.artboards = rawArtboards
        self.artboardOptions = rawArtboardOptions
        self.documentSetup = rawDocumentSetup
        self.printPreferences = rawPrintPreferences
    }

    /// Copy-with-changes: return a Document identical to `self` except
    /// for the fields explicitly passed. Use this instead of the
    /// designated `Document(...)` initializer for in-place edits — the
    /// designated init's empty defaults silently drop unset fields,
    /// and "drop the artboards every time the selection changes" is
    /// what made the artboard frame disappear after a selection
    /// mutation.
    public func replacing(
        layers: [Layer]? = nil,
        symbols: [Element]? = nil,
        selectedLayer: Int? = nil,
        selection: Selection? = nil,
        artboards: [Artboard]? = nil,
        artboardOptions: ArtboardOptions? = nil,
        documentSetup: DocumentSetup? = nil,
        printPreferences: PrintPreferences? = nil
    ) -> Document {
        Document(
            layers: layers ?? self.layers,
            symbols: symbols ?? self.symbols,
            selectedLayer: selectedLayer ?? self.selectedLayer,
            selection: selection ?? self.selection,
            artboards: artboards ?? self.artboards,
            artboardOptions: artboardOptions ?? self.artboardOptions,
            documentSetup: documentSetup ?? self.documentSetup,
            printPreferences: printPreferences ?? self.printPreferences
        )
    }

    /// Layers eye-button (regular click): cycle the visibility of the element
    /// at `path` Preview -> Outline -> Invisible -> Preview and, when it
    /// becomes Invisible, drop it (and its descendants) from the selection.
    /// Pure. Mirrors Rust `cycle_element_visibility_at`, OCaml
    /// `Document.cycle_element_visibility_at`, and the Python eye handler.
    public func cyclingElementVisibility(at path: ElementPath) -> Document {
        let e = getElement(path)
        let newVis = e.visibility.cycled
        let doc = replaceElement(path, with: e.withVisibility(newVis))
        if newVis == .invisible {
            let filtered = doc.selection.filter {
                !($0.path == path || $0.path.starts(with: path))
            }
            return doc.replacing(selection: filtered)
        }
        return doc
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

    /// Bounds-checked element lookup. Returns `nil` for an empty path
    /// or any index that falls outside its level (a stale selection /
    /// dangling path), instead of trapping like `getElement`. Mirrors
    /// the Rust `Document::get_element -> Option<&Element>` contract so
    /// callers that may hold paths into a since-mutated document (e.g.
    /// the active-document view derived from a stale selection) degrade
    /// gracefully rather than crash.
    public func tryGetElement(_ path: ElementPath) -> Element? {
        guard let first = path.first else { return nil }
        guard first >= 0, first < layers.count else { return nil }
        var node: Element = .layer(layers[first])
        for idx in path.dropFirst() {
            let children = childrenOf(node)
            guard idx >= 0, idx < children.count else { return nil }
            node = children[idx]
        }
        return node
    }

    /// Effective visibility of the element at `path`, computed as the
    /// minimum of the visibilities of every element along the path
    /// from the root layer down to the target. A parent Group/Layer
    /// caps the visibility of everything it contains: if any
    /// ancestor is `.invisible`, the result is `.invisible`
    /// regardless of the target's own flag.
    public func effectiveVisibility(_ path: ElementPath) -> Visibility {
        guard !path.isEmpty else { return .preview }
        guard path[0] < layers.count else { return .preview }
        var node: Element = .layer(layers[path[0]])
        var effective = node.visibility
        for idx in path.dropFirst() {
            let children = childrenOf(node)
            guard idx < children.count else { return effective }
            node = children[idx]
            if node.visibility < effective { effective = node.visibility }
        }
        return effective
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
            // replaceInGroup always returns a Group or Layer, so this branch is unreachable.
            guard case .layer(let l) = layerElem else { fatalError("unreachable") }
            newLayers[path[0]] = l
        }
        return Document(layers: newLayers, symbols: symbols, selectedLayer: selectedLayer, selection: selection, artboards: artboards, artboardOptions: artboardOptions, documentSetup: documentSetup, printPreferences: printPreferences)
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
            // insertAfterInGroup always returns a Group or Layer, so this branch is unreachable.
            guard case .layer(let l) = layerElem else { fatalError("unreachable") }
            newLayers[path[0]] = l
        }
        return Document(layers: newLayers, symbols: symbols, selectedLayer: selectedLayer, selection: selection, artboards: artboards, artboardOptions: artboardOptions, documentSetup: documentSetup, printPreferences: printPreferences)
    }

    /// Return a new document with the element at path removed.
    public func deleteElement(_ path: ElementPath) -> Document {
        guard !path.isEmpty else { fatalError("Path must be non-empty") }
        var newLayers = layers
        if path.count == 1 {
            newLayers.remove(at: path[0])
        } else {
            let layerElem = removeFromGroup(.layer(layers[path[0]]), Array(path.dropFirst()))
            // removeFromGroup always returns a Group or Layer, so this branch is unreachable.
            guard case .layer(let l) = layerElem else { fatalError("unreachable") }
            newLayers[path[0]] = l
        }
        return Document(layers: newLayers, symbols: symbols, selectedLayer: selectedLayer, selection: selection, artboards: artboards, artboardOptions: artboardOptions, documentSetup: documentSetup, printPreferences: printPreferences)
    }

    /// Return a new document with all selected elements removed and selection cleared.
    public func deleteSelection() -> Document {
        let sortedPaths = selection.map(\.path).sorted { $0.lexicographicallyPrecedes($1) }.reversed()
        var doc = self
        for path in sortedPaths {
            doc = doc.deleteElement(path)
        }
        return Document(layers: doc.layers,
                           symbols: symbols,
                           selectedLayer: doc.selectedLayer,
                           selection: [],
                           artboards: artboards,
                           artboardOptions: artboardOptions,
                           documentSetup: documentSetup,
                           printPreferences: printPreferences)
    }
}

// MARK: - id→element index (REFERENCE_GRAPH.md §2.3/§2.4)

/// The persistent id→element index (REFERENCE_GRAPH.md §2.4). A
/// `TreeDictionary` (swift-collections HAMT) gives O(log n) lookup/insert,
/// O(1) structure-sharing copy (so each undo snapshot carries the index
/// cheaply — see ``Model``), and value semantics so it can be paired with the
/// snapshot without an authoritative-state risk. It is `Equatable` because
/// `Element` is, which lets the debug-only gate compare a stored index against
/// a from-scratch rebuild by value. Mirrors Rust's `rpds::RedBlackTreeMap`
/// (`IdIndex`); §2.3 explicitly permits each app to pick its own persistent
/// map, so equivalence is pinned on `resolve()` *results*, not on the map type.
public typealias IdIndex = TreeDictionary<String, Element>

/// Build the persistent id→element index from `doc`. This is the SINGLE
/// canonical walk (REFERENCE_GRAPH.md §2.3 trust mechanism): it is both the
/// builder that populates the Model's companion index (so paint reads it
/// without rebuilding) AND the oracle the gate compares against. The walk is
/// identical to the pre-companion per-paint rebuild, so the resulting map's
/// values are bit-identical — zero behavior change.
///
/// Indexes id-bearing descendants of every layer — top-level layer ids are not
/// resolution targets (references target shapes), matching the Rust reference.
///
/// Also indexes `doc.symbols` (SYMBOLS.md §2): each master is walked with the
/// same operands-opaque discipline so a `ReferenceElem` instance can resolve a
/// master by its `id`. Unlike a top-level layer, a master's OWN id is a valid
/// target (a master is reached only through a reference), so each master is
/// indexed directly (its own id + id-bearing descendants), not skipped.
/// Masters live off-canvas (not in `layers`), so indexing them here makes them
/// resolvable WITHOUT ever making them painted — the whole point of the
/// off-canvas store. Masters are sorted by id first so a (well-formed:
/// impossible) duplicate-id master resolves deterministically (first-by-id
/// wins), matching the §2 deterministic-order rule.
public func rebuildIdIndex(_ doc: Document) -> IdIndex {
    var index = IdIndex()
    for layer in doc.layers {
        for child in layer.children {
            collectRefIds(child, into: &index)
        }
    }
    let sortedMasters = doc.symbols.sorted { ($0.id ?? "") < ($1.id ?? "") }
    for master in sortedMasters {
        collectRefIds(master, into: &index)
    }
    return index
}

/// Recursive worker for ``rebuildIdIndex``. First-occurrence wins (the
/// unique-id invariant means no collisions in practice; this just makes the
/// build deterministic), so an already-present id is never overwritten.
private func collectRefIds(_ elem: Element, into index: inout IdIndex) {
    if let id = elem.id, index[id] == nil {
        index[id] = elem
    }
    switch elem {
    case .group(let g): for c in g.children { collectRefIds(c, into: &index) }
    case .layer(let l): for c in l.children { collectRefIds(c, into: &index) }
    default: break
    }
}

/// An `ElementResolver` that reads an already-built ``IdIndex`` (the Phase-4b
/// paint seam). The canvas installs the Model's persistent index here instead
/// of rebuilding per paint; lookups are O(log n) against the structure-shared
/// map. Mirrors Rust's `RenderResolver` reading the installed `IdIndex`.
public struct IdIndexResolver: ElementResolver {
    private let index: IdIndex
    public init(index: IdIndex) { self.index = index }
    public func resolve(_ id: ElementRef) -> Element? { index[id.id] }
    public func resolveConcept(_ conceptId: String) -> ConceptDef? {
        conceptDefFromRegistry(conceptId)
    }
}

/// Resolve a concept pack from the bundled workspace registry (CONCEPTS.md 3b),
/// so a placed Generated instance evaluates its concept's geometry on the render
/// path. Mirrors Rust `RenderResolver.resolve_concept` (reads the cached
/// workspace). Concepts are static workspace data, so this is cheap.
func conceptDefFromRegistry(_ conceptId: String) -> ConceptDef? {
    guard let ws = WorkspaceData.load(),
          let c = ws.concept(conceptId),
          let generator = c["generator"] as? String else { return nil }
    let closed = (c["closed"] as? Bool) ?? true
    return ConceptDef(generator: generator, closed: closed)
}

// MARK: - RebuildResolver (REFERENCE_GRAPH.md §2.4 — rebuild-on-demand)

/// An `ElementResolver` that rebuilds the id→element index from a `Document`
/// on construction (the rebuild-on-demand strategy). Retained as the
/// convenience build-and-resolve used by the resolver/symbols fixtures and any
/// caller that lacks a precomputed index; the hot paint path reads the Model's
/// persistent companion index via ``IdIndexResolver`` instead (no per-paint
/// rebuild). Delegates to ``rebuildIdIndex`` so its `resolve()` results are
/// identical to the companion index. Mirrors Rust's `register_ref_index`.
public struct RebuildResolver: ElementResolver {
    private let inner: IdIndexResolver

    /// Build the index from `doc` (via the shared ``rebuildIdIndex`` walk) and
    /// wrap it in an ``IdIndexResolver``.
    public init(document doc: Document) {
        self.inner = IdIndexResolver(index: rebuildIdIndex(doc))
    }

    public func resolve(_ id: ElementRef) -> Element? { inner.resolve(id) }
    public func resolveConcept(_ conceptId: String) -> ConceptDef? {
        inner.resolveConcept(conceptId)
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
