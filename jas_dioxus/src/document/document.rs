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
    pub selected_layer: usize,
    pub selection: Selection,
    /// Artboards — print-page regions. The at-least-one invariant
    /// (ARTBOARDS.md) guarantees this is never empty at observable
    /// state. See `document/artboard.rs`.
    pub artboards: Vec<Artboard>,
    /// Document-wide artboard display toggles (fade outside,
    /// update while dragging).
    pub artboard_options: ArtboardOptions,
}

impl Default for Document {
    fn default() -> Self {
        let mut artboards = Vec::new();
        // `None` uses platform entropy. Tests that need deterministic
        // ids construct Document directly via struct literal.
        ensure_artboards_invariant(&mut artboards, None);
        Self {
            layers: vec![Element::Layer(LayerElem {
                name: "Layer".to_string(),
                children: Vec::new(),
                common: CommonProps::default(),
                isolated_blending: false,
                knockout_group: false,
            })],
            selected_layer: 0,
            selection: Vec::new(),
            artboards,
            artboard_options: ArtboardOptions::default(),
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

    /// Return the bounding box of all layers combined.
    pub fn bounds(&self) -> (f64, f64, f64, f64) {
        if self.layers.is_empty() {
            return (0.0, 0.0, 0.0, 0.0);
        }
        let all: Vec<_> = self.layers.iter().map(|l| l.bounds()).collect();
        let min_x = all.iter().map(|b| b.0).fold(f64::INFINITY, f64::min);
        let min_y = all.iter().map(|b| b.1).fold(f64::INFINITY, f64::min);
        let max_x = all
            .iter()
            .map(|b| b.0 + b.2)
            .fold(f64::NEG_INFINITY, f64::max);
        let max_y = all
            .iter()
            .map(|b| b.1 + b.3)
            .fold(f64::NEG_INFINITY, f64::max);
        (min_x, min_y, max_x - min_x, max_y - min_y)
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
        })
    }

    fn make_line(x1: f64, y1: f64, x2: f64, y2: f64) -> Element {
        Element::Line(LineElem {
            x1, y1, x2, y2,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: vec![],
            common: CommonProps::default(),
        })
    }

    fn make_layer(name: &str, children: Vec<Element>) -> Element {
        Element::Layer(LayerElem {
            name: name.to_string(),
            children: children.into_iter().map(Rc::new).collect(),
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
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

    #[test]
    fn selection_kind_to_sorted_round_trips() {
        let all = SelectionKind::All;
        let v: Vec<usize> = all.to_sorted(5).iter().collect();
        assert_eq!(v, vec![0, 1, 2, 3, 4]);
        let part = SelectionKind::Partial(SortedCps::from_iter([2usize, 0]));
        let v2: Vec<usize> = part.to_sorted(99).iter().collect();
        assert_eq!(v2, vec![0, 2]);
    }
}
