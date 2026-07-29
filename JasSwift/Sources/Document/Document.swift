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

/// A selection is an ORDERED ARRAY of `ElementSelection` entries, unique by
/// path. RULED 2026-07-28 (transcripts/LAYER_STRUCTURE.md §10, D6).
///
/// **Ruled on determinism, not performance.** This was `Set<ElementSelection>`.
/// A `Set`'s iteration order is per-process hash order, and both copy paths
/// iterate `doc.selection` — measured: five selected elements over ten separate
/// test processes gave ten different orders and document order not once. The
/// z-order of a copied fragment is part of the artwork, so a paste that stacks
/// differently between two runs of the same build is a defect. Rust's
/// `Selection` is `Vec<ElementSelection>`; this is now the identical
/// representation.
///
/// **Deliberately NOT an ordered-set type.** `swift-collections` is already a
/// dependency (`Package.swift:12`; `TreeDictionary` is live in this file and in
/// `Model.swift`), so
/// `OrderedSet` would have been free — the ruling turns on the OTHER reason:
/// identical representation across the active ports beats the convenience.
///
/// **THE COST, and where it is actually paid.** `Set` gave free deduplication;
/// an array does not. The migration made the COMPILER enumerate every insertion
/// site — 28 in production, 23 more in the test targets — and each was answered
/// individually against its jas_dioxus counterpart rather than blanket-guarded.
///
/// The audit's result, measured: a `contains(where:)` guard at all 24 of them
/// left the whole Swift suite GREEN when removed, so 24 of those guards were
/// redundant and are NOT here. Rust reaches the same conclusion by construction
/// — it pushes plainly at every site but three, because a path enumerated from
/// `layers[li].children[ci]` cannot repeat. The guards that remain are exactly
/// the ones jas_dioxus also writes, at the two places a duplicate is genuinely
/// reachable: `Controller.addToSelection` (its whole contract is idempotence)
/// and the magic wand's "add" mode (a new match may already be selected).
///
/// The canonical-JSON selection serializer no longer sorts, so if a duplicate
/// ever does appear it is visible in every golden carrying a multi-entry
/// selection — `add_to_selection_twice_on_one_path_yields_one_entry` in
/// `test_fixtures/operations/select_all_top_level.json` is the case that reds.
public typealias Selection = [ElementSelection]

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

    /// Layers LOCK-button behaviour — the twin of
    /// ``cyclingElementVisibility(at:)``, which the eye button has had
    /// factored out (and testable) all along while the lock button's
    /// identical document work stayed inlined in a SwiftUI closure. Pure.
    /// Mirrors Rust `renderer.rs` `toggle_element_lock_at`.
    ///
    /// Two things happen, in this order:
    ///   1. the element's own `locked` flips — and ONLY the element's own, at
    ///      any depth. A container's lock reaches its contents by INHERITANCE
    ///      (``effectiveLocked(_:)``), never by being written onto them;
    ///   2. locking removes the element AND its descendants from the
    ///      selection, exactly as ``cyclingElementVisibility(at:)`` does
    ///      when an element becomes `.invisible`.
    ///
    /// Step 2 is not cosmetic: nothing downstream refuses to move or delete
    /// a selected element for being locked, so a lock that left the
    /// selection alone left locked content draggable (D5a).
    ///
    /// The MATERIALIZATION that used to sit between the two — writing
    /// `locked = true` onto every direct child and restoring a caller-owned
    /// table of prior states on unlock — was REPEALED by
    /// transcripts/LAYER_STRUCTURE.md §13 (RULED 2026-07-28). It cannot
    /// coexist with inheritance: kept together they double-apply, and the
    /// children end up carrying flags an artist never set, which then survive
    /// into the saved file. The `savedToRestore` parameter went with it, and
    /// so did `YamlPanelBodyView.savedLockStates` and jas_dioxus's
    /// `AppState.layers_saved_lock_states`.
    public func togglingElementLock(at path: ElementPath) -> Document {
        guard let e = tryGetElement(path) else { return self }
        let wasUnlocked = !e.isLocked
        let doc = replaceElement(path, with: e.withLocked(wasUnlocked))
        // Locking an element removes it and its descendants from selection.
        if wasUnlocked {
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

    /// Every element `id` present in this document: the whole layer forest
    /// (recursing into groups and nested layers, and into the operands a live
    /// compound shape OWNS) plus the off-canvas symbol masters. Id-less
    /// elements contribute nothing.
    ///
    /// This is the avoid-set for `mintUniqueIds` at every element-id mint.
    /// Masters ARE included: a master's id is a real element id that instances
    /// target by name, so a canvas element must not be minted onto it. Rust's
    /// `Document::element_ids` is the twin.
    ///
    /// A compound's operands are NOT path-addressable tree children (they are
    /// not reported by `childrenOf`), so the walk matches the live payload
    /// itself. Of the four `LiveVariant` arms only `compoundShape` owns child
    /// `Element`s; `reference`, `recorded` and `generated` name their inputs
    /// by id and own none. The inner switch is exhaustive so a future payload
    /// that gains owned children forces this decision to be made again rather
    /// than silently going unwalked.
    ///
    /// Deliberately UNLIKE `rebuildIdIndex`, which is operands-opaque on
    /// purpose (an operand is not a reference resolution target). The two
    /// walks answer different questions: "what may a reference name?" vs
    /// "what id is already taken?". Uniqueness spans the whole document
    /// (REFERENCE_GRAPH.md §2.5), so this one must be wider.
    public var elementIds: Set<String> {
        var out: Set<String> = []
        func walk(_ elem: Element) {
            if let id = elem.id { out.insert(id) }
            switch elem {
            case .group(let g): for c in g.children { walk(c) }
            case .layer(let l): for c in l.children { walk(c) }
            case .live(let variant):
                switch variant {
                case .compoundShape(let cs): for operand in cs.operands { walk(operand) }
                case .reference, .recorded, .generated: break
                }
            default: break
            }
        }
        for layer in layers { walk(.layer(layer)) }
        for master in symbols { walk(master) }
        return out
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

    /// Effective LOCK of the element at `path`: the OR of the `locked` flags
    /// of every element along the path from the root layer down to the target.
    /// A Group or Layer's lock locks everything it contains, at every depth.
    ///
    /// RULED by JYH 2026-07-28 (transcripts/LAYER_STRUCTURE.md §13): lock is
    /// INHERITED, not materialized. The repealed design wrote `locked = true`
    /// onto a container's direct children and kept a restore table; this one
    /// stores nothing and reads down the path, exactly as
    /// ``effectiveVisibility(_:)`` does. Because the fold is an OR, a child
    /// CANNOT be unlocked inside a locked parent — JYH ruled that
    /// expressiveness loss explicitly, so there is deliberately no escape
    /// hatch here.
    ///
    /// An empty or unresolvable path is NOT locked: nothing is protected by an
    /// address that names no artwork, and a caller that cannot find its element
    /// must not be told the missing thing is locked.
    ///
    /// The twin is jas_dioxus `Document::effective_locked`.
    public func effectiveLocked(_ path: ElementPath) -> Bool {
        guard !path.isEmpty else { return false }
        guard path[0] >= 0, path[0] < layers.count else { return false }
        var node: Element = .layer(layers[path[0]])
        var locked = node.isLocked
        for idx in path.dropFirst() {
            let children = childrenOf(node)
            guard idx >= 0, idx < children.count else { return locked }
            node = children[idx]
            if node.isLocked { locked = true }
        }
        return locked
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

/// Replace a container's children and change NOTHING else.
///
/// EDIT_SEMANTICS_FREEZE.md T4, the BYSTANDER CLAUSE: *an edit preserves,
/// unchanged, every element it does not name — including the containers it
/// rebuilds to reach its target.* `replaceInGroup` / `removeFromGroup` /
/// `insertAfterInGroup` rebuild every container on the path down to the element
/// the caller named, and those containers are bystanders.
///
/// This used to be a private twin that rebuilt Layer/Group from FOUR fields,
/// destroying the container's `id`, `mask`, `blendMode`, `visibility`,
/// `isolatedBlending`, `knockoutGroup` and a Group's `name` on EVERY nested
/// element edit in the port — so a hidden group un-hid itself when a shape
/// inside it moved, and every reference bound to a container's id was orphaned.
/// It now delegates to `Group.withChildren` / `Layer.withChildren`
/// (`Geometry/Element.swift`), which forward every field, so there is ONE
/// children-rebuild body per container kind and the omission is not expressible
/// twice. Rust needs no twin at all: `replace_element` rewrites the child slot
/// in place, so the parent's `common` is never reconstructed.
private func withChildren(_ elem: Element, _ newChildren: [Element]) -> Element {
    switch elem {
    case .group(let g):
        return .group(g.withChildren(newChildren))
    case .layer(let l):
        return .layer(l.withChildren(newChildren))
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
