//! Immutable document model.
//!
// Public API surface — several methods are exposed for the editor
// shell that hasn't been wired in yet.
#![allow(dead_code)]
//!
//! # Immutability contract
//!
//! A [`Document`] is treated as an immutable value: every mutation produces a
//! new `Document` via `clone()` + in-place update rather than modifying the
//! original.  This enables the undo/redo stack in [`Model`] to hold cheap
//! snapshots (each snapshot is a previous `Document` value).
//!
//! Rust does not have a built-in "frozen" qualifier, so the contract is
//! enforced by convention:
//!
//! - **Controller methods** receive a `&Model` (shared reference) and return a
//!   new `Document`; they never hold a `&mut Document` to the live copy.
//! - **Model** stores the canonical `Document` and only exposes `&Document`.
//!   Callers obtain a mutated copy from the controller and hand it back via
//!   [`Model::set_document`].
//!
//! The fields are `pub` for ergonomic construction, but production code should
//! treat a `Document` as read-only once created.
//!
//! # Element addressing
//!
//! Elements within the document are identified by their *path*: a vector of
//! integer indices tracing the route from the document's layer list to the
//! element (e.g. `[0, 2, 1]` means layer 0 → child 2 → child 1).

use std::collections::HashSet;
use std::rc::Rc;

use crate::document::artboard::{
    ensure_artboards_invariant, generate_artboard_id, Artboard, ArtboardOptions,
};
use crate::document::document_setup::DocumentSetup;
use crate::document::print_preferences::PrintPreferences;
use crate::geometry::element::{Element, LayerElem, CommonProps};

/// A path identifies an element by its position in the document tree.
/// Each integer is a child index at that level of the tree.
pub type ElementPath = Vec<usize>;

/// Sorted, de-duplicated collection of control-point indices.
///
/// Invariant: the backing vector is sorted ascending and contains no
/// duplicates. All constructors and mutators preserve it, so callers
/// can rely on deterministic iteration order and cheap membership
/// checks via binary search. `u16` is wide enough for any realistic
/// anchor count and keeps the common case (a handful of CPs) small.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct SortedCps(Vec<u16>);

impl SortedCps {
    pub fn new() -> Self { Self(Vec::new()) }

    /// Build a sorted-unique `SortedCps` from any iterator of `usize` CP indices.
    pub fn from_iter(iter: impl IntoIterator<Item = usize>) -> Self {
        let mut v: Vec<u16> = iter.into_iter().map(|i| i as u16).collect();
        v.sort_unstable();
        v.dedup();
        Self(v)
    }

    pub fn single(i: usize) -> Self { Self(vec![i as u16]) }

    pub fn contains(&self, i: usize) -> bool {
        let i = i as u16;
        self.0.binary_search(&i).is_ok()
    }

    pub fn len(&self) -> usize { self.0.len() }
    pub fn is_empty(&self) -> bool { self.0.is_empty() }

    /// Iterate CP indices in ascending order.
    pub fn iter(&self) -> impl Iterator<Item = usize> + '_ {
        self.0.iter().map(|&i| i as usize)
    }

    /// Insert `i`; no-op if already present.
    pub fn insert(&mut self, i: usize) {
        let i = i as u16;
        if let Err(pos) = self.0.binary_search(&i) {
            self.0.insert(pos, i);
        }
    }

    /// Symmetric difference (XOR) of two sorted sets.
    pub fn symmetric_difference(&self, other: &Self) -> Self {
        let mut out: Vec<u16> = Vec::with_capacity(self.0.len() + other.0.len());
        let (mut a, mut b) = (0usize, 0usize);
        while a < self.0.len() && b < other.0.len() {
            match self.0[a].cmp(&other.0[b]) {
                std::cmp::Ordering::Less    => { out.push(self.0[a]); a += 1; }
                std::cmp::Ordering::Greater => { out.push(other.0[b]); b += 1; }
                std::cmp::Ordering::Equal   => { a += 1; b += 1; }
            }
        }
        out.extend_from_slice(&self.0[a..]);
        out.extend_from_slice(&other.0[b..]);
        Self(out)
    }
}

/// Per-element selection state: either the element is fully selected
/// (bounding-box selection) or only a subset of its control points are
/// selected (Partial Selection).
///
/// Collapsing "fully selected" into an explicit `All` variant removes
/// the old convention where an empty or full CP set meant "selected
/// element", which was ambiguous with "no CPs hit by the marquee".
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SelectionKind {
    /// The element as a whole is selected. Drag-move translates the
    /// element; its bounding-box handles are shown.
    All,
    /// Only the listed CPs are selected (Partial Selection). Drag-move
    /// moves just those CPs and may convert the element to a polygon.
    Partial(SortedCps),
}

impl SelectionKind {
    /// True if control-point index `i` is selected. `All` contains every
    /// index; `Partial(s)` checks against the sorted vector.
    pub fn contains(&self, i: usize) -> bool {
        match self {
            SelectionKind::All => true,
            SelectionKind::Partial(s) => s.contains(i),
        }
    }

    /// Number of selected CPs. Callers supply `total` so `All` can
    /// answer without knowing it at construction time.
    pub fn count(&self, total: usize) -> usize {
        match self {
            SelectionKind::All => total,
            SelectionKind::Partial(s) => s.len(),
        }
    }

    /// True when every CP of an element with `total` CPs is selected.
    pub fn is_all(&self, total: usize) -> bool {
        match self {
            SelectionKind::All => true,
            SelectionKind::Partial(s) => s.len() == total,
        }
    }

    /// Return an explicit set of selected CPs for an element with
    /// `total` CPs. Useful at API boundaries that still want a listing.
    pub fn to_sorted(&self, total: usize) -> SortedCps {
        match self {
            SelectionKind::All => SortedCps::from_iter(0..total),
            SelectionKind::Partial(s) => s.clone(),
        }
    }
}

/// Per-element selection entry: which element, and how it is selected.
///
/// Equality and hashing are by **path only**, so two `ElementSelection`
/// values with the same path but different `kind`s are considered
/// equal. This matches the other three ports (map keyed by path).
#[derive(Debug, Clone)]
pub struct ElementSelection {
    pub path: ElementPath,
    pub kind: SelectionKind,
}

impl ElementSelection {
    /// Convenience: build an `All` selection entry for `path`.
    pub fn all(path: ElementPath) -> Self {
        Self { path, kind: SelectionKind::All }
    }

    /// Convenience: build a `Partial` selection entry for `path` from
    /// any iterator of CP indices.
    pub fn partial(path: ElementPath, cps: impl IntoIterator<Item = usize>) -> Self {
        Self { path, kind: SelectionKind::Partial(SortedCps::from_iter(cps)) }
    }
}

impl PartialEq for ElementSelection {
    fn eq(&self, other: &Self) -> bool {
        self.path == other.path
    }
}

impl Eq for ElementSelection {}

impl std::hash::Hash for ElementSelection {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.path.hash(state);
    }
}

/// A selection is an ordered collection of [`ElementSelection`] entries,
/// unique by path.
///
/// A `Vec` is used rather than `HashSet` to preserve insertion order (which
/// determines the visual stacking order of selection handles and the order
/// of operations like group/paste).  Uniqueness by path is maintained by
/// the controller's selection helpers (e.g. `toggle_selection`,
/// `select_all`, `set_selection`).
pub type Selection = Vec<ElementSelection>;

/// The immutable document value (see [module-level docs](self) for the
/// immutability contract).
#[derive(Debug, Clone)]
pub struct Document {
    pub layers: Vec<Element>,
    /// Off-canvas master store for Symbols (SYMBOLS.md §2, Fork S1). Each
    /// master is a plain `Element` keyed by its `common.id`; instances are
    /// `ReferenceElem`s targeting a master id. AUTHORITATIVE document data
    /// (unlike the derived dependency index), so it IS part of Clone/PartialEq
    /// and every codec. It is NOT in `layers`, so render and hit-test never
    /// touch it (masters are never painted). Storage order is unconstrained,
    /// but it MUST be emitted sorted-by-id at every order-dependent site
    /// (codecs, resolver, index) per §2 "deterministic order".
    pub symbols: Vec<Element>,
    pub selected_layer: usize,
    pub selection: Selection,
    /// Artboards — print-page regions. The at-least-one invariant
    /// (ARTBOARDS.md) guarantees this is never empty at observable
    /// state. See `document/artboard.rs`.
    pub artboards: Vec<Artboard>,
    /// Document-wide artboard display toggles (fade outside,
    /// update while dragging).
    pub artboard_options: ArtboardOptions,
    /// Per-document Document Setup state: bleed, image outline display,
    /// substituted-glyph highlight (PRINT.md §Phase 1A).
    pub document_setup: DocumentSetup,
    /// Per-document Print dialog last-used state (PRINT.md §Phase 1B).
    /// Phase 1B populates the General tab; later phases extend with
    /// sub-records for marks, output, graphics, color management,
    /// advanced.
    pub print_preferences: PrintPreferences,
}

impl Default for Document {
    fn default() -> Self {
        let mut artboards = Vec::new();
        // `None` uses platform entropy. Tests that need deterministic
        // ids construct Document directly via struct literal.
        ensure_artboards_invariant(&mut artboards, None);
        Self {
            layers: vec![Element::Layer(LayerElem {
                children: Vec::new(),
                common: CommonProps {
                    name: Some("Layer".to_string()),
                    ..Default::default()
                },
                isolated_blending: false,
                knockout_group: false,
            })],
            symbols: Vec::new(),
            selected_layer: 0,
            selection: Vec::new(),
            artboards,
            artboard_options: ArtboardOptions::default(),
            document_setup: DocumentSetup::default(),
            print_preferences: PrintPreferences::default(),
        }
    }
}

impl Document {
    /// Return the ElementSelection for the given path, or None.
    pub fn get_element_selection(&self, path: &ElementPath) -> Option<&ElementSelection> {
        self.selection.iter().find(|es| &es.path == path)
    }

    /// Return the set of all element paths in the selection.
    pub fn selected_paths(&self) -> HashSet<ElementPath> {
        self.selection.iter().map(|es| es.path.clone()).collect()
    }

    /// Every `common.id` present in this document: the whole layer forest
    /// (recursing into groups and nested layers, and into the operands a live
    /// compound shape OWNS) plus the off-canvas symbol masters. Id-less
    /// elements contribute nothing.
    ///
    /// This is the avoid-set for [`crate::document::artboard::mint_unique_ids`]
    /// at every element-id mint. Masters ARE included: a master's id is a real
    /// element id that instances target by name, so a canvas element must not
    /// be minted onto it. Swift's `Document.elementIds` is the twin.
    ///
    /// `Element::children()` deliberately does NOT report a compound's
    /// operands — they are not path-addressable tree children — so the walk
    /// matches the live payloads itself. Of the four `LiveVariant` arms only
    /// `CompoundShape` owns child `Element`s; `Reference`, `Recorded` and
    /// `Generated` name their inputs by id and own none. The match is
    /// exhaustive so a future payload that gains owned children forces this
    /// decision to be made again rather than silently going unwalked.
    ///
    /// Deliberately UNLIKE [`crate::document::id_index::rebuild_id_index`],
    /// which is operands-opaque on purpose (an operand is not a reference
    /// resolution target). The two walks answer different questions: "what may
    /// a reference name?" vs "what id is already taken?". Uniqueness spans the
    /// whole document (REFERENCE_GRAPH.md §2.5), so this one must be wider.
    pub fn element_ids(&self) -> HashSet<String> {
        fn walk(elem: &Element, out: &mut HashSet<String>) {
            if let Some(id) = elem.common().id.as_deref() {
                out.insert(id.to_string());
            }
            if let Some(children) = elem.children() {
                for c in children {
                    walk(c, out);
                }
            }
            if let Element::Live(variant) = elem {
                match variant {
                    crate::geometry::live::LiveVariant::CompoundShape(cs) => {
                        for operand in &cs.operands {
                            walk(operand, out);
                        }
                    }
                    crate::geometry::live::LiveVariant::Reference(_)
                    | crate::geometry::live::LiveVariant::Recorded(_)
                    | crate::geometry::live::LiveVariant::Generated(_) => {}
                }
            }
        }
        let mut out = HashSet::new();
        for layer in &self.layers {
            walk(layer, &mut out);
        }
        for master in &self.symbols {
            walk(master, &mut out);
        }
        out
    }

    /// Return the bounding box of all layers combined — what `Fit in Window`
    /// frames.
    ///
    /// RESOLVED, because a symbol instance measures its TARGET's geometry: the
    /// resolver-less `Element::bounds` answers `(0,0,0,0)` for reference,
    /// recorded and generated kinds, so a document whose artwork is instances
    /// used to fold a phantom point at the origin into the frame (and a
    /// document of nothing BUT instances framed a zero box there). An element
    /// that resolves to nothing — a dangling reference — now contributes
    /// nothing rather than the origin.
    pub fn bounds(&self) -> (f64, f64, f64, f64) {
        let index = crate::document::id_index::rebuild_id_index(self);
        let resolver = crate::document::id_index::IndexResolver(&index);
        let mut acc: Option<(f64, f64, f64, f64)> = None;
        for layer in &self.layers {
            let Some((x, y, w, h)) = crate::geometry::element::resolved_bounds_with(
                layer,
                &resolver,
                Element::bounds,
            ) else {
                continue;
            };
            acc = Some(match acc {
                None => (x, y, w, h),
                Some((ax, ay, aw, ah)) => {
                    let min_x = ax.min(x);
                    let min_y = ay.min(y);
                    let max_x = (ax + aw).max(x + w);
                    let max_y = (ay + ah).max(y + h);
                    (min_x, min_y, max_x - min_x, max_y - min_y)
                }
            });
        }
        acc.unwrap_or((0.0, 0.0, 0.0, 0.0))
    }

    /// Return a reference to the element at the given path.
    pub fn get_element(&self, path: &ElementPath) -> Option<&Element> {
        if path.is_empty() {
            return None;
        }
        let mut node = self.layers.get(path[0])?;
        for &idx in &path[1..] {
            node = node.children()?.get(idx)?;
        }
        Some(node)
    }

    /// Return a mutable reference to the element at `path`.
    pub fn get_element_mut(&mut self, path: &ElementPath) -> Option<&mut Element> {
        if path.is_empty() {
            return None;
        }
        let mut node: &mut Element = self.layers.get_mut(path[0])?;
        for &idx in &path[1..] {
            let children = node.children_mut()?;
            node = Rc::make_mut(children.get_mut(idx)?);
        }
        Some(node)
    }

    /// Return the effective visibility of the element at `path`,
    /// computed as the minimum of the visibilities of every element
    /// along the path from the root layer down to the target. A
    /// Group or Layer's visibility caps the visibility of everything
    /// it contains: if any ancestor is `Invisible`, the result is
    /// `Invisible` even when the target itself is `Preview`.
    pub fn effective_visibility(&self, path: &ElementPath) -> crate::geometry::element::Visibility {
        use crate::geometry::element::Visibility;
        if path.is_empty() {
            return Visibility::Preview;
        }
        let mut node = match self.layers.get(path[0]) {
            Some(n) => n,
            None => return Visibility::Preview,
        };
        let mut effective = node.visibility();
        for &idx in &path[1..] {
            node = match node.children().and_then(|c| c.get(idx)) {
                Some(n) => n,
                None => return effective,
            };
            effective = std::cmp::min(effective, node.visibility());
        }
        effective
    }

    /// Return the effective LOCK of the element at `path`: the OR of the
    /// `locked` flags of every element along the path from the root layer
    /// down to the target. A Group or Layer's lock locks everything it
    /// contains, at every depth.
    ///
    /// RULED by JYH 2026-07-28 (transcripts/LAYER_STRUCTURE.md §13): lock is
    /// INHERITED, not materialized. The repealed design wrote `locked = true`
    /// onto a container's direct children and kept a restore table; this one
    /// stores nothing and reads down the path, exactly as
    /// [`Self::effective_visibility`] does. Because the fold is an OR, a child
    /// CANNOT be unlocked inside a locked parent — JYH ruled that
    /// expressiveness loss explicitly, so there is deliberately no escape
    /// hatch here.
    ///
    /// An empty or unresolvable path is NOT locked: nothing is protected by an
    /// address that names no artwork, and a caller that cannot find its element
    /// must not be told the missing thing is locked.
    ///
    /// The twin is JasSwift `Document.effectiveLocked(_:)`.
    pub fn effective_locked(&self, path: &ElementPath) -> bool {
        if path.is_empty() {
            return false;
        }
        let mut node = match self.layers.get(path[0]) {
            Some(n) => n,
            None => return false,
        };
        let mut locked = node.locked();
        for &idx in &path[1..] {
            node = match node.children().and_then(|c| c.get(idx)) {
                Some(n) => n,
                None => return locked,
            };
            locked = locked || node.locked();
        }
        locked
    }

    /// Is the ACTIVE layer — the one plain Paste targets — effectively locked?
    ///
    /// RULED by JYH 2026-07-28 (transcripts/LAYER_STRUCTURE.md §15): plain Paste
    /// REFUSES into a locked active layer, because the artist picked that layer
    /// explicitly and landing artwork elsewhere would silently override an
    /// explicit choice.
    ///
    /// **THIS IS ONE DEFINITION SERVING TWO CONSUMERS, deliberately.** The
    /// ENFORCEMENT reads it (`op_apply::active_paste_target`) and so does the
    /// AFFORDANCE — it is the `active_document.active_layer_locked` menu
    /// predicate that greys `paste` and `paste_in_place` out
    /// (`workspace::menu_bar::build_menu_ctx`). A menu that greyed an item out
    /// on one rule while the code refused on another would be worse than either
    /// alone, and there is no second rule here to drift to.
    ///
    /// A document with NO LAYERS is not locked: there is nothing to protect, and
    /// paste's own empty-document no-op is a different refusal with a different
    /// cause. The out-of-range clamp mirrors `paste_fragment_into`'s.
    ///
    /// The twin is JasSwift `Document.activeLayerLocked`.
    pub fn active_layer_locked(&self) -> bool {
        if self.layers.is_empty() {
            return false;
        }
        let active = self.selected_layer.min(self.layers.len() - 1);
        self.effective_locked(&vec![active])
    }

    /// Element-level behavior of the Layers tree LOCK button. Pure: takes a
    /// Document, returns a Document. The twin of `cycle_element_visibility_at`
    /// (still in the web-gated `interpreter::renderer`, where this lived until
    /// LOCKINHERIT; it moved here because it is document logic with no UI in
    /// it, `op_apply` must reach it in a `--no-default-features` build, and
    /// JasSwift's twin `Document.togglingElementLock(at:)` was already a
    /// Document method — so the move is toward parity, not away. The
    /// VISIBILITY half is still on the wrong side of that line; banked).
    ///
    /// Two things happen, in this order:
    ///   1. the element's own `locked` flips — and ONLY the element's own, at
    ///      any depth. A container's lock reaches its contents by INHERITANCE
    ///      ([`Self::effective_locked`]), never by being written onto them;
    ///   2. locking removes the element AND its descendants from the selection,
    ///      exactly as `cycle_element_visibility_at` does on Invisible.
    ///
    /// Step 2 is not cosmetic: nothing downstream refuses to move or delete a
    /// selected-but-locked element, so a lock that leaves the selection alone
    /// leaves locked content draggable.
    ///
    /// The MATERIALIZATION that used to sit between the two — writing
    /// `locked = true` onto every direct child and restoring a caller-owned
    /// table of prior states on unlock — was REPEALED by
    /// transcripts/LAYER_STRUCTURE.md §13 (RULED 2026-07-28). It cannot coexist
    /// with inheritance: kept together they double-apply, and the children end
    /// up carrying flags an artist never set, which then survive into the saved
    /// file. The `saved_to_restore` parameter went with it, and so did
    /// `AppState.layers_saved_lock_states` and JasSwift's `savedLockStates`.
    pub fn toggling_element_lock(&self, path: &ElementPath) -> Self {
        let Some(elem) = self.get_element(path) else {
            return self.clone();
        };
        let was_unlocked = !elem.locked();

        let mut new_doc = self.clone();
        if let Some(elem) = new_doc.get_element_mut(path) {
            elem.common_mut().locked = was_unlocked;
        }
        // Locking an element removes it and its descendants from the selection.
        if was_unlocked {
            new_doc
                .selection
                .retain(|es| !(es.path == *path || es.path.starts_with(path.as_slice())));
        }
        new_doc
    }

    /// Return a new Document with the element at path replaced.
    pub fn replace_element(&self, path: &ElementPath, new_elem: Element) -> Self {
        let mut doc = self.clone();
        if path.is_empty() {
            return doc;
        }
        if path.len() == 1 {
            doc.layers[path[0]] = new_elem;
        } else {
            replace_in_children(&mut doc.layers[path[0]], &path[1..], new_elem);
        }
        doc
    }

    /// Return a new Document with new_elem inserted after path.
    pub fn insert_element_after(&self, path: &ElementPath, new_elem: Element) -> Self {
        let mut doc = self.clone();
        if path.is_empty() {
            return doc;
        }
        if path.len() == 1 {
            doc.layers.insert(path[0] + 1, new_elem);
        } else {
            insert_after_in_children(&mut doc.layers[path[0]], &path[1..], new_elem);
        }
        doc
    }

    /// Return a new Document with new_elem inserted at the given path index.
    pub fn insert_element_at(&self, path: &ElementPath, new_elem: Element) -> Self {
        let mut doc = self.clone();
        if path.is_empty() {
            return doc;
        }
        if path.len() == 1 {
            doc.layers.insert(path[0], new_elem);
        } else {
            insert_at_in_children(&mut doc.layers[path[0]], &path[1..], new_elem);
        }
        doc
    }

    /// Return a new Document with the element at path removed.
    pub fn delete_element(&self, path: &ElementPath) -> Self {
        let mut doc = self.clone();
        if path.is_empty() {
            return doc;
        }
        if path.len() == 1 {
            doc.layers.remove(path[0]);
        } else {
            remove_from_children(&mut doc.layers[path[0]], &path[1..]);
        }
        doc
    }

    /// Return a new Document with all selected elements removed.
    pub fn delete_selection(&self) -> Self {
        let mut doc = self.clone();
        let mut paths: Vec<ElementPath> = doc.selection.iter().map(|es| es.path.clone()).collect();
        paths.sort();
        paths.reverse();
        for path in paths {
            doc = doc.delete_element(&path);
        }
        doc.selection.clear();
        doc
    }
}

fn replace_in_children(node: &mut Element, rest: &[usize], new_elem: Element) {
    if let Some(children) = node.children_mut() {
        if rest.len() == 1 {
            children[rest[0]] = Rc::new(new_elem);
        } else {
            replace_in_children(Rc::make_mut(&mut children[rest[0]]), &rest[1..], new_elem);
        }
    }
}

fn insert_at_in_children(node: &mut Element, rest: &[usize], new_elem: Element) {
    if let Some(children) = node.children_mut() {
        if rest.len() == 1 {
            children.insert(rest[0], Rc::new(new_elem));
        } else {
            insert_at_in_children(Rc::make_mut(&mut children[rest[0]]), &rest[1..], new_elem);
        }
    }
}

fn insert_after_in_children(node: &mut Element, rest: &[usize], new_elem: Element) {
    if let Some(children) = node.children_mut() {
        if rest.len() == 1 {
            children.insert(rest[0] + 1, Rc::new(new_elem));
        } else {
            insert_after_in_children(Rc::make_mut(&mut children[rest[0]]), &rest[1..], new_elem);
        }
    }
}

fn remove_from_children(node: &mut Element, rest: &[usize]) {
    if let Some(children) = node.children_mut() {
        if rest.len() == 1 {
            children.remove(rest[0]);
        } else {
            remove_from_children(Rc::make_mut(&mut children[rest[0]]), &rest[1..]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::*;

    fn make_rect(x: f64, y: f64, w: f64, h: f64) -> Element {
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn make_line(x1: f64, y1: f64, x2: f64, y2: f64) -> Element {
        Element::Line(LineElem {
            x1, y1, x2, y2,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: vec![],
            common: CommonProps::default(),
                    stroke_gradient: None,
        })
    }

    fn make_layer(name: &str, children: Vec<Element>) -> Element {
        Element::Layer(LayerElem {
            children: children.into_iter().map(Rc::new).collect(),
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps {
                name: Some(name.to_string()),
                ..Default::default()
            },
        })
    }

    fn make_group(children: Vec<Element>) -> Element {
        Element::Group(GroupElem {
            children: children.into_iter().map(Rc::new).collect(),
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        })
    }

    #[test]
    fn default_document_has_one_layer() {
        let doc = Document::default();
        assert_eq!(doc.layers.len(), 1);
        assert!(matches!(&doc.layers[0], Element::Layer(_)));
    }

    #[test]
    fn default_selection_empty() {
        let doc = Document::default();
        assert!(doc.selection.is_empty());
    }

    #[test]
    fn empty_document_bounds() {
        let doc = Document { layers: vec![], selected_layer: 0, selection: vec![], ..Document::default() };
        assert_eq!(doc.bounds(), (0.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn single_layer_bounds() {
        let layer = make_layer("L1", vec![make_rect(0.0, 0.0, 10.0, 10.0)]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        assert_eq!(doc.bounds(), (0.0, 0.0, 10.0, 10.0));
    }

    #[test]
    fn get_element_layer() {
        let doc = Document::default();
        assert!(doc.get_element(&vec![0]).is_some());
    }

    #[test]
    fn get_element_child() {
        let layer = make_layer("L", vec![make_rect(0.0, 0.0, 10.0, 10.0)]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        let elem = doc.get_element(&vec![0, 0]).unwrap();
        assert!(matches!(elem, Element::Rect(_)));
    }

    #[test]
    fn get_element_nested() {
        let group = make_group(vec![make_line(0.0, 0.0, 1.0, 1.0)]);
        let layer = make_layer("L", vec![group]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        let elem = doc.get_element(&vec![0, 0, 0]).unwrap();
        assert!(matches!(elem, Element::Line(_)));
    }

    #[test]
    fn get_element_empty_path() {
        let doc = Document::default();
        assert!(doc.get_element(&vec![]).is_none());
    }

    #[test]
    fn replace_element_child() {
        let layer = make_layer("L", vec![make_rect(0.0, 0.0, 10.0, 10.0)]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        let new_rect = make_rect(5.0, 5.0, 20.0, 20.0);
        let doc2 = doc.replace_element(&vec![0, 0], new_rect.clone());
        assert_eq!(doc2.get_element(&vec![0, 0]).unwrap(), &new_rect);
        // Original unchanged
        if let Element::Rect(r) = doc.get_element(&vec![0, 0]).unwrap() {
            assert_eq!(r.x, 0.0);
        }
    }

    #[test]
    fn replace_element_preserves_other_children() {
        let layer = make_layer("L", vec![
            make_rect(0.0, 0.0, 10.0, 10.0),
            make_line(0.0, 0.0, 5.0, 5.0),
        ]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        let doc2 = doc.replace_element(&vec![0, 0], make_rect(99.0, 99.0, 1.0, 1.0));
        assert!(matches!(doc2.get_element(&vec![0, 1]).unwrap(), Element::Line(_)));
    }

    #[test]
    fn delete_element() {
        let layer = make_layer("L", vec![
            make_rect(0.0, 0.0, 10.0, 10.0),
            make_line(0.0, 0.0, 5.0, 5.0),
        ]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        let doc2 = doc.delete_element(&vec![0, 0]);
        if let Element::Layer(l) = &doc2.layers[0] {
            assert_eq!(l.children.len(), 1);
            assert!(matches!(&*l.children[0], Element::Line(_)));
        } else {
            panic!("expected layer");
        }
    }

    #[test]
    fn delete_selection() {
        let layer = make_layer("L", vec![
            make_rect(0.0, 0.0, 10.0, 10.0),
            make_line(0.0, 0.0, 5.0, 5.0),
        ]);
        let sel = vec![ElementSelection::all(vec![0, 0])];
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: sel, ..Document::default() };
        let doc2 = doc.delete_selection();
        assert!(doc2.selection.is_empty());
        if let Element::Layer(l) = &doc2.layers[0] {
            assert_eq!(l.children.len(), 1);
        }
    }

    #[test]
    fn insert_element_after() {
        let layer = make_layer("L", vec![make_rect(0.0, 0.0, 10.0, 10.0)]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        let doc2 = doc.insert_element_after(&vec![0, 0], make_line(0.0, 0.0, 5.0, 5.0));
        if let Element::Layer(l) = &doc2.layers[0] {
            assert_eq!(l.children.len(), 2);
            assert!(matches!(&*l.children[1], Element::Line(_)));
        }
    }

    #[test]
    fn insert_element_at() {
        let layer = make_layer("L", vec![make_line(0.0, 0.0, 5.0, 5.0)]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![], ..Document::default() };
        let doc2 = doc.insert_element_at(&vec![0, 0], make_rect(0.0, 0.0, 10.0, 10.0));
        if let Element::Layer(l) = &doc2.layers[0] {
            assert_eq!(l.children.len(), 2);
            assert!(matches!(&*l.children[0], Element::Rect(_)));
            assert!(matches!(&*l.children[1], Element::Line(_)));
        }
    }

    // ---- SortedCps / SelectionKind invariants ----

    #[test]
    fn sorted_cps_dedupes_and_sorts_on_construction() {
        let s = SortedCps::from_iter([3usize, 1, 4, 1, 5, 9, 2, 6, 5, 3]);
        let v: Vec<usize> = s.iter().collect();
        assert_eq!(v, vec![1, 2, 3, 4, 5, 6, 9]);
        assert_eq!(s.len(), 7);
    }

    #[test]
    fn sorted_cps_insert_is_idempotent() {
        let mut s = SortedCps::from_iter([1usize, 3, 5]);
        s.insert(3);
        s.insert(2);
        s.insert(2);
        let v: Vec<usize> = s.iter().collect();
        assert_eq!(v, vec![1, 2, 3, 5]);
    }

    #[test]
    fn sorted_cps_contains_uses_binary_search() {
        let s = SortedCps::from_iter([0usize, 2, 4, 6, 8]);
        for &i in &[0, 2, 4, 6, 8] {
            assert!(s.contains(i));
        }
        for &i in &[1, 3, 5, 7, 9] {
            assert!(!s.contains(i));
        }
    }

    #[test]
    fn sorted_cps_xor_is_set_symmetric_difference() {
        let a = SortedCps::from_iter([1usize, 2, 3, 4]);
        let b = SortedCps::from_iter([3usize, 4, 5, 6]);
        let xor: Vec<usize> = a.symmetric_difference(&b).iter().collect();
        assert_eq!(xor, vec![1, 2, 5, 6]);
    }

    #[test]
    fn selection_kind_all_contains_every_index() {
        let k = SelectionKind::All;
        for i in 0..1000 {
            assert!(k.contains(i));
        }
        assert_eq!(k.count(7), 7);
        assert!(k.is_all(7));
    }

    #[test]
    fn selection_kind_partial_full_is_all_for_count() {
        let k = SelectionKind::Partial(SortedCps::from_iter(0usize..4));
        assert!(k.is_all(4));
        assert!(!k.is_all(5));
        assert_eq!(k.count(99), 4);
    }

    /// `element_ids` is the avoid-set every id mint is checked against, so it
    /// must see NESTED elements and the off-canvas symbol masters, not just
    /// top-level layer children. Swift's `Document.elementIds` is the twin.
    #[test]
    fn element_ids_walks_nesting_and_symbol_masters() {
        let with_id = |elem: Element, id: &str| -> Element {
            let mut e = elem;
            e.common_mut().id = Some(id.to_string());
            e
        };
        let inner = with_id(make_rect(0.0, 0.0, 1.0, 1.0), "inner");
        let group = with_id(make_group(vec![inner]), "grp");
        let layer = with_id(make_layer("L", vec![group]), "lyr");
        let mut doc = Document {
            layers: vec![layer],
            ..Document::default()
        };
        doc.symbols
            .push(with_id(make_rect(0.0, 0.0, 2.0, 2.0), "master"));
        // An id-less sibling contributes nothing (and must not panic).
        if let Some(children) = doc.layers[0].children_mut() {
            children.push(Rc::new(make_line(0.0, 0.0, 1.0, 1.0)));
        }
        let ids = doc.element_ids();
        let mut sorted: Vec<&str> = ids.iter().map(|s| s.as_str()).collect();
        sorted.sort();
        assert_eq!(sorted, vec!["grp", "inner", "lyr", "master"]);
    }

    /// A compound shape OWNS its operands (`CompoundShape.operands` is a
    /// `Vec<Rc<Element>>`), and each operand is a real element carrying its
    /// own `common.id`. Those ids are part of the document's id space
    /// (REFERENCE_GRAPH.md §2.5 uniqueness), so the mint avoid-set must see
    /// them — otherwise a fresh mint can land on an operand id. The walk
    /// must also keep recursing THROUGH an operand subtree (an operand that
    /// is itself a group). Swift's `elementIdsSeesIdsInsideLiveElements` is
    /// the twin.
    #[test]
    fn element_ids_sees_ids_inside_live_elements() {
        use crate::geometry::live::{
            CompoundOperation, CompoundShape, ElementRef, GeneratedElem, LiveVariant,
            RecordedElem, ReferenceElem,
        };
        let with_id = |elem: Element, id: &str| -> Element {
            let mut e = elem;
            e.common_mut().id = Some(id.to_string());
            e
        };
        let id_common = |id: &str| CommonProps {
            id: Some(id.to_string()),
            ..Default::default()
        };

        // Operand 1 is a plain rect; operand 2 is a GROUP whose child also
        // carries an id, so the walk has to descend past the operand itself.
        let operand_a = with_id(make_rect(0.0, 0.0, 1.0, 1.0), "op-a");
        let nested = with_id(make_rect(2.0, 2.0, 1.0, 1.0), "op-b-inner");
        let operand_b = with_id(make_group(vec![nested]), "op-b");
        // An id-less operand contributes nothing (and must not trip the walk).
        let operand_c = make_line(0.0, 0.0, 1.0, 1.0);
        let compound = Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation: CompoundOperation::Union,
            operands: vec![
                Rc::new(operand_a),
                Rc::new(operand_b),
                Rc::new(operand_c),
            ],
            fill: None,
            stroke: None,
            common: id_common("cmp"),
        }));

        // The other three LiveVariant payloads own NO child elements — they
        // name their inputs by id — so each contributes exactly its own id.
        let reference = Element::Live(LiveVariant::Reference(ReferenceElem::new(
            ElementRef("op-a".to_string()),
            id_common("ref"),
        )));
        let recorded = Element::Live(LiveVariant::Recorded(RecordedElem::new(
            vec![],
            vec![ElementRef("op-a".to_string())],
            id_common("rec"),
        )));
        let generated = Element::Live(LiveVariant::Generated(GeneratedElem::new(
            "concept".to_string(),
            serde_json::json!({}),
            id_common("gen"),
        )));

        let layer = with_id(
            make_layer("L", vec![compound, reference, recorded, generated]),
            "lyr",
        );
        let doc = Document {
            layers: vec![layer],
            ..Document::default()
        };
        let ids = doc.element_ids();
        let mut sorted: Vec<&str> = ids.iter().map(|s| s.as_str()).collect();
        sorted.sort();
        assert_eq!(
            sorted,
            vec!["cmp", "gen", "lyr", "op-a", "op-b", "op-b-inner", "rec", "ref"]
        );
    }

    #[test]
    fn selection_kind_to_sorted_round_trips() {
        let all = SelectionKind::All;
        let v: Vec<usize> = all.to_sorted(5).iter().collect();
        assert_eq!(v, vec![0, 1, 2, 3, 4]);
        let part = SelectionKind::Partial(SortedCps::from_iter([2usize, 0]));
        let v2: Vec<usize> = part.to_sorted(99).iter().collect();
        assert_eq!(v2, vec![0, 2]);
    }

    // ── D5a: the Layers LOCK button prunes the selection ──────────
    //
    // SCOPE-effective-locked.md §3, D5a. jas_dioxus dropped the locked
    // element and its descendants from the selection; JasSwift's closure had
    // no equivalent, so a locked layer stayed selected there -- and nothing
    // downstream refuses to move or delete a selected element for being
    // locked, so that is not cosmetic.
    //
    // PER-PORT: the Layers panel is reached through GUI event handlers that
    // no shared corpus drives, and no shared fixture can seed a locked
    // document anyway (the SVG codec drops `locked`). The mirror is
    // JasSwift/Tests/Document/DocumentTests.swift.
    //
    // These are REGRESSION PINS for this port -- the red was in Swift.

    /// One layer named "L" holding two rects, with `selection` seeded to
    /// the whole tree: the layer, and both of its children.
    fn lock_toggle_doc() -> Document {
        let rect = |x: f64| Element::Rect(RectElem {
            x, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(rect(0.0)), Rc::new(rect(20.0))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { name: Some("L".into()), ..Default::default() },
        });
        Document {
            layers: vec![layer],
            selected_layer: 0,
            selection: vec![
                ElementSelection::all(vec![0]),
                ElementSelection::all(vec![0, 0]),
                ElementSelection::all(vec![0, 1]),
            ],
            ..Document::default()
        }
    }

    #[test]
    fn toggling_element_lock_locks_and_prunes_the_selection() {
        let doc = lock_toggle_doc();
        assert_eq!(doc.selection.len(), 3, "control: everything starts selected");
        let out = doc.toggling_element_lock(&vec![0usize]);
        assert!(out.get_element(&vec![0usize]).unwrap().locked(),
            "the layer itself is locked");
        assert!(out.selection.is_empty(),
            "the layer AND both descendants leave the selection");
    }

    /// Locking a CHILD must prune that child only -- if the prune were
    /// written as a whole-clear, or matched on the wrong end of the path,
    /// this is the case that notices.
    #[test]
    fn toggling_element_lock_prunes_only_the_locked_subtree() {
        let doc = lock_toggle_doc();
        let out = doc.toggling_element_lock(&vec![0usize, 0usize]);
        let mut paths: Vec<Vec<usize>> =
            out.selection.iter().map(|es| es.path.clone()).collect();
        paths.sort();
        assert_eq!(paths, vec![vec![0], vec![0, 1]]);
    }

    /// UNlocking must not touch the selection at all -- the prune is keyed
    /// on the direction of the toggle, not on the button being pressed.
    #[test]
    fn toggling_element_lock_unlock_leaves_the_selection_alone() {
        let doc = lock_toggle_doc();
        let locked = doc.toggling_element_lock(&vec![0usize]);
        assert!(locked.selection.is_empty());
        // Re-select the layer, then unlock it.
        let mut relocked = locked;
        relocked.selection =
            vec![ElementSelection::all(vec![0usize])];
        let out = relocked.toggling_element_lock(&vec![0usize]);
        assert!(!out.get_element(&vec![0usize]).unwrap().locked());
        assert_eq!(out.selection.len(), 1, "unlock keeps the selection");
    }

    /// MATERIALIZATION IS REPEALED (transcripts/LAYER_STRUCTURE.md §13, RULED
    /// 2026-07-28). Locking a CONTAINER writes the container's own flag and
    /// nothing else -- the contents are protected by
    /// `Document::effective_locked` reading down the path, not by flags an
    /// artist never set. The shared corpus family
    /// `test_fixtures/operations/lock_toggle_no_materialization.json` is the
    /// cross-language gate; this is the same fact at the pure function.
    #[test]
    fn toggling_element_lock_does_not_materialize_onto_children() {
        let out = lock_toggle_doc().toggling_element_lock(&vec![0usize]);
        assert!(out.get_element(&vec![0usize]).unwrap().locked());
        assert!(!out.get_element(&vec![0usize, 0usize]).unwrap().locked());
        assert!(!out.get_element(&vec![0usize, 1usize]).unwrap().locked());
        // ...and the children are protected anyway, by inheritance.
        assert!(out.effective_locked(&vec![0usize, 0usize]));
        assert!(out.effective_locked(&vec![0usize, 1usize]));
    }

    /// A round trip through the lock button leaves the document where it
    /// started. Before the repeal it was LOSSY: the lock wrote `locked = true`
    /// onto both children and the unlock -- with no restore table to consult --
    /// left them locked while the container itself opened.
    #[test]
    fn toggling_element_lock_round_trip_leaves_children_untouched() {
        let once = lock_toggle_doc().toggling_element_lock(&vec![0usize]);
        let out = once.toggling_element_lock(&vec![0usize]);
        assert!(!out.get_element(&vec![0usize]).unwrap().locked());
        assert!(!out.get_element(&vec![0usize, 0usize]).unwrap().locked());
        assert!(!out.get_element(&vec![0usize, 1usize]).unwrap().locked());
    }

    /// `Document::effective_locked` ORs down the path, mirroring
    /// `Document::effective_visibility`. A child CANNOT be unlocked inside a
    /// locked parent -- JYH ruled that expressiveness loss explicitly
    /// (transcripts/LAYER_STRUCTURE.md §13), so there is no escape hatch to
    /// test for; what IS tested is that the OR is total and that an
    /// unresolvable path is not reported as locked.
    #[test]
    fn effective_locked_ors_down_the_path() {
        let doc = lock_toggle_doc();
        assert!(!doc.effective_locked(&vec![0usize]));
        assert!(!doc.effective_locked(&vec![0usize, 0usize]));
        // Own flag on the LEAF.
        let leaf_locked = doc.toggling_element_lock(&vec![0usize, 1usize]);
        assert!(!leaf_locked.effective_locked(&vec![0usize, 0usize]));
        assert!(leaf_locked.effective_locked(&vec![0usize, 1usize]));
        assert!(!leaf_locked.effective_locked(&vec![0usize]));
        // Own flag on the CONTAINER reaches both children.
        let layer_locked = doc.toggling_element_lock(&vec![0usize]);
        assert!(layer_locked.effective_locked(&vec![0usize]));
        assert!(layer_locked.effective_locked(&vec![0usize, 0usize]));
        assert!(layer_locked.effective_locked(&vec![0usize, 1usize]));
        // Addresses that name no artwork are not locked.
        assert!(!doc.effective_locked(&vec![]));
        assert!(!layer_locked.effective_locked(&vec![7usize]));
        assert!(
            layer_locked.effective_locked(&vec![0usize, 9usize]),
            "an out-of-range CHILD index still inherits what the walk already saw"
        );
    }
}
