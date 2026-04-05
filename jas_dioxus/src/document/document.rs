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
            common: CommonProps::default(),
        })
    }

    fn make_layer(name: &str, children: Vec<Element>) -> Element {
        Element::Layer(LayerElem {
            name: name.to_string(), children, common: CommonProps::default(),
        })
    }

    fn make_group(children: Vec<Element>) -> Element {
        Element::Group(GroupElem { children, common: CommonProps::default() })
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
        let doc = Document { layers: vec![], selected_layer: 0, selection: vec![] };
        assert_eq!(doc.bounds(), (0.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn single_layer_bounds() {
        let layer = make_layer("L1", vec![make_rect(0.0, 0.0, 10.0, 10.0)]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
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
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
        let elem = doc.get_element(&vec![0, 0]).unwrap();
        assert!(matches!(elem, Element::Rect(_)));
    }

    #[test]
    fn get_element_nested() {
        let group = make_group(vec![make_line(0.0, 0.0, 1.0, 1.0)]);
        let layer = make_layer("L", vec![group]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
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
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
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
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
        let doc2 = doc.replace_element(&vec![0, 0], make_rect(99.0, 99.0, 1.0, 1.0));
        assert!(matches!(doc2.get_element(&vec![0, 1]).unwrap(), Element::Line(_)));
    }

    #[test]
    fn delete_element() {
        let layer = make_layer("L", vec![
            make_rect(0.0, 0.0, 10.0, 10.0),
            make_line(0.0, 0.0, 5.0, 5.0),
        ]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
        let doc2 = doc.delete_element(&vec![0, 0]);
        if let Element::Layer(l) = &doc2.layers[0] {
            assert_eq!(l.children.len(), 1);
            assert!(matches!(&l.children[0], Element::Line(_)));
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
        let sel = vec![ElementSelection { path: vec![0, 0], control_points: HashSet::new() }];
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: sel };
        let doc2 = doc.delete_selection();
        assert!(doc2.selection.is_empty());
        if let Element::Layer(l) = &doc2.layers[0] {
            assert_eq!(l.children.len(), 1);
        }
    }

    #[test]
    fn insert_element_after() {
        let layer = make_layer("L", vec![make_rect(0.0, 0.0, 10.0, 10.0)]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
        let doc2 = doc.insert_element_after(&vec![0, 0], make_line(0.0, 0.0, 5.0, 5.0));
        if let Element::Layer(l) = &doc2.layers[0] {
            assert_eq!(l.children.len(), 2);
            assert!(matches!(&l.children[1], Element::Line(_)));
        }
    }

    #[test]
    fn insert_element_at() {
        let layer = make_layer("L", vec![make_line(0.0, 0.0, 5.0, 5.0)]);
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
        let doc2 = doc.insert_element_at(&vec![0, 0], make_rect(0.0, 0.0, 10.0, 10.0));
        if let Element::Layer(l) = &doc2.layers[0] {
            assert_eq!(l.children.len(), 2);
            assert!(matches!(&l.children[0], Element::Rect(_)));
            assert!(matches!(&l.children[1], Element::Line(_)));
        }
    }
}
