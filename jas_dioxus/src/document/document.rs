//! Immutable document model.
//!
//! A Document is an ordered list of Layers. Elements within the document are
//! identified by their path: a vector of integer indices tracing the route
//! from the document's layer list to the element.

use std::collections::HashSet;

use crate::geometry::element::{Element, LayerElem, CommonProps};

/// A path identifies an element by its position in the document tree.
/// Each integer is a child index at that level of the tree.
pub type ElementPath = Vec<usize>;

/// Per-element selection state: which element and which of its control points
/// are selected.
#[derive(Debug, Clone)]
pub struct ElementSelection {
    pub path: ElementPath,
    pub control_points: HashSet<usize>,
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

/// A selection is a collection of ElementSelection entries (unique by path).
pub type Selection = Vec<ElementSelection>;

/// The immutable document.
#[derive(Debug, Clone)]
pub struct Document {
    pub layers: Vec<Element>,
    pub selected_layer: usize,
    pub selection: Selection,
}

impl Default for Document {
    fn default() -> Self {
        Self {
            layers: vec![Element::Layer(LayerElem {
                name: "Layer".to_string(),
                children: Vec::new(),
                common: CommonProps::default(),
            })],
            selected_layer: 0,
            selection: Vec::new(),
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
            children[rest[0]] = new_elem;
        } else {
            replace_in_children(&mut children[rest[0]], &rest[1..], new_elem);
        }
    }
}

fn insert_at_in_children(node: &mut Element, rest: &[usize], new_elem: Element) {
    if let Some(children) = node.children_mut() {
        if rest.len() == 1 {
            children.insert(rest[0], new_elem);
        } else {
            insert_at_in_children(&mut children[rest[0]], &rest[1..], new_elem);
        }
    }
}

fn insert_after_in_children(node: &mut Element, rest: &[usize], new_elem: Element) {
    if let Some(children) = node.children_mut() {
        if rest.len() == 1 {
            children.insert(rest[0] + 1, new_elem);
        } else {
            insert_after_in_children(&mut children[rest[0]], &rest[1..], new_elem);
        }
    }
}

fn remove_from_children(node: &mut Element, rest: &[usize]) {
    if let Some(children) = node.children_mut() {
        if rest.len() == 1 {
            children.remove(rest[0]);
        } else {
            remove_from_children(&mut children[rest[0]], &rest[1..]);
        }
    }
}
