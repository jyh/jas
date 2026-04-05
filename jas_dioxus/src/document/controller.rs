//! Document controller (MVC pattern).
//!
//! The Controller provides mutation operations on the Model's document.
//! Since the Document is cloned on mutation, changes produce a new Document
//! that replaces the old one in the Model.

use std::collections::HashSet;

use crate::document::document::{ElementPath, ElementSelection, Selection};
use crate::document::model::Model;
use crate::geometry::element::{
    control_point_count, control_points, flatten_path_commands, move_control_points,
    move_path_handle, Element, PathElem,
};

// ---------------------------------------------------------------------------
// Geometry helpers for hit-testing
// ---------------------------------------------------------------------------

fn point_in_rect(px: f64, py: f64, rx: f64, ry: f64, rw: f64, rh: f64) -> bool {
    rx <= px && px <= rx + rw && ry <= py && py <= ry + rh
}

fn cross(ox: f64, oy: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    (ax - ox) * (by - oy) - (ay - oy) * (bx - ox)
}

fn on_segment(px1: f64, py1: f64, px2: f64, py2: f64, qx: f64, qy: f64) -> bool {
    qx >= px1.min(px2) && qx <= px1.max(px2) && qy >= py1.min(py2) && qy <= py1.max(py2)
}

fn segments_intersect(
    ax1: f64, ay1: f64, ax2: f64, ay2: f64, bx1: f64, by1: f64, bx2: f64, by2: f64,
) -> bool {
    let d1 = cross(bx1, by1, bx2, by2, ax1, ay1);
    let d2 = cross(bx1, by1, bx2, by2, ax2, ay2);
    let d3 = cross(ax1, ay1, ax2, ay2, bx1, by1);
    let d4 = cross(ax1, ay1, ax2, ay2, bx2, by2);
    if ((d1 > 0.0 && d2 < 0.0) || (d1 < 0.0 && d2 > 0.0))
        && ((d3 > 0.0 && d4 < 0.0) || (d3 < 0.0 && d4 > 0.0))
    {
        return true;
    }
    let eps = 1e-10;
    if d1.abs() < eps && on_segment(bx1, by1, bx2, by2, ax1, ay1) { return true; }
    if d2.abs() < eps && on_segment(bx1, by1, bx2, by2, ax2, ay2) { return true; }
    if d3.abs() < eps && on_segment(ax1, ay1, ax2, ay2, bx1, by1) { return true; }
    if d4.abs() < eps && on_segment(ax1, ay1, ax2, ay2, bx2, by2) { return true; }
    false
}

fn segment_intersects_rect(
    x1: f64, y1: f64, x2: f64, y2: f64, rx: f64, ry: f64, rw: f64, rh: f64,
) -> bool {
    if point_in_rect(x1, y1, rx, ry, rw, rh) || point_in_rect(x2, y2, rx, ry, rw, rh) {
        return true;
    }
    let edges = [
        (rx, ry, rx + rw, ry),
        (rx + rw, ry, rx + rw, ry + rh),
        (rx + rw, ry + rh, rx, ry + rh),
        (rx, ry + rh, rx, ry),
    ];
    edges
        .iter()
        .any(|&(ex1, ey1, ex2, ey2)| segments_intersect(x1, y1, x2, y2, ex1, ey1, ex2, ey2))
}

fn rects_intersect(
    ax: f64, ay: f64, aw: f64, ah: f64, bx: f64, by: f64, bw: f64, bh: f64,
) -> bool {
    ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by
}

fn segments_of_element(elem: &Element) -> Vec<(f64, f64, f64, f64)> {
    match elem {
        Element::Line(e) => vec![(e.x1, e.y1, e.x2, e.y2)],
        Element::Rect(e) => vec![
            (e.x, e.y, e.x + e.width, e.y),
            (e.x + e.width, e.y, e.x + e.width, e.y + e.height),
            (e.x + e.width, e.y + e.height, e.x, e.y + e.height),
            (e.x, e.y + e.height, e.x, e.y),
        ],
        Element::Polyline(e) if e.points.len() >= 2 => e
            .points
            .windows(2)
            .map(|w| (w[0].0, w[0].1, w[1].0, w[1].1))
            .collect(),
        Element::Polygon(e) if e.points.len() >= 2 => {
            let mut segs: Vec<_> = e
                .points
                .windows(2)
                .map(|w| (w[0].0, w[0].1, w[1].0, w[1].1))
                .collect();
            let last = e.points.last().unwrap();
            let first = e.points.first().unwrap();
            segs.push((last.0, last.1, first.0, first.1));
            segs
        }
        Element::Path(e) => {
            let pts = flatten_path_commands(&e.d);
            if pts.len() >= 2 {
                pts.windows(2)
                    .map(|w| (w[0].0, w[0].1, w[1].0, w[1].1))
                    .collect()
            } else {
                vec![]
            }
        }
        _ => vec![],
    }
}

fn all_cps(elem: &Element) -> HashSet<usize> {
    (0..control_point_count(elem)).collect()
}

fn element_intersects_rect(elem: &Element, rx: f64, ry: f64, rw: f64, rh: f64) -> bool {
    match elem {
        Element::Line(e) => {
            segment_intersects_rect(e.x1, e.y1, e.x2, e.y2, rx, ry, rw, rh)
        }
        Element::Rect(e) => {
            if e.fill.is_some() {
                rects_intersect(e.x, e.y, e.width, e.height, rx, ry, rw, rh)
            } else {
                segments_of_element(elem)
                    .iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_rect(x1, y1, x2, y2, rx, ry, rw, rh))
            }
        }
        Element::Text(_) | Element::TextPath(_) => {
            let b = elem.bounds();
            rects_intersect(b.0, b.1, b.2, b.3, rx, ry, rw, rh)
        }
        Element::Group(_) | Element::Layer(_) => {
            let b = elem.bounds();
            rects_intersect(b.0, b.1, b.2, b.3, rx, ry, rw, rh)
        }
        _ => {
            if elem.fill().is_some() {
                let segs = segments_of_element(elem);
                let endpoints: Vec<(f64, f64)> = segs
                    .iter()
                    .flat_map(|&(x1, y1, x2, y2)| vec![(x1, y1), (x2, y2)])
                    .collect();
                if endpoints
                    .iter()
                    .any(|&(px, py)| point_in_rect(px, py, rx, ry, rw, rh))
                {
                    return true;
                }
                segs.iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_rect(x1, y1, x2, y2, rx, ry, rw, rh))
            } else {
                segments_of_element(elem)
                    .iter()
                    .any(|&(x1, y1, x2, y2)| segment_intersects_rect(x1, y1, x2, y2, rx, ry, rw, rh))
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// Mediates between user actions and the document model.
pub struct Controller;

impl Controller {
    /// Add an element to the selected layer.
    pub fn add_element(model: &mut Model, element: Element) {
        let doc = model.document().clone();
        let idx = doc.selected_layer;
        if let Some(children) = model.document().layers[idx].children() {
            let _ = children; // just checking it's a layer
        }
        let mut new_doc = doc;
        if let Some(children) = new_doc.layers[idx].children_mut() {
            children.push(element);
        }
        model.set_document(new_doc);
    }

    /// Select all elements whose bounds intersect the given rectangle.
    pub fn select_rect(
        model: &mut Model,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        extend: bool,
    ) {
        let doc = model.document().clone();
        let mut entries: Selection = Vec::new();
        for (li, layer) in doc.layers.iter().enumerate() {
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate() {
                    if child.locked() {
                        continue;
                    }
                    if child.is_group() {
                        if let Some(grandchildren) = child.children() {
                            if grandchildren
                                .iter()
                                .any(|gc| element_intersects_rect(gc, x, y, width, height))
                            {
                                entries.push(ElementSelection {
                                    path: vec![li, ci],
                                    control_points: all_cps(child),
                                });
                                for (gi, gc) in grandchildren.iter().enumerate() {
                                    entries.push(ElementSelection {
                                        path: vec![li, ci, gi],
                                        control_points: all_cps(gc),
                                    });
                                }
                            }
                        }
                    } else if element_intersects_rect(child, x, y, width, height) {
                        entries.push(ElementSelection {
                            path: vec![li, ci],
                            control_points: all_cps(child),
                        });
                    }
                }
            }
        }
        let new_sel = if extend {
            toggle_selection(&doc.selection, &entries)
        } else {
            entries
        };
        let mut new_doc = doc;
        new_doc.selection = new_sel;
        model.set_document(new_doc);
    }

    /// Direct selection marquee: select individual control points within the rect.
    pub fn direct_select_rect(
        model: &mut Model,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        extend: bool,
    ) {
        let doc = model.document().clone();
        let mut entries: Selection = Vec::new();

        fn check(
            entries: &mut Selection,
            path: &ElementPath,
            elem: &Element,
            x: f64,
            y: f64,
            width: f64,
            height: f64,
        ) {
            if elem.locked() {
                return;
            }
            if elem.is_group_or_layer() {
                if let Some(children) = elem.children() {
                    for (i, child) in children.iter().enumerate() {
                        let mut child_path = path.clone();
                        child_path.push(i);
                        check(entries, &child_path, child, x, y, width, height);
                    }
                }
                return;
            }
            let cps = control_points(elem);
            let hit_cps: HashSet<usize> = cps
                .iter()
                .enumerate()
                .filter(|(_, (px, py))| point_in_rect(*px, *py, x, y, width, height))
                .map(|(i, _)| i)
                .collect();
            if !hit_cps.is_empty() || element_intersects_rect(elem, x, y, width, height) {
                entries.push(ElementSelection {
                    path: path.clone(),
                    control_points: hit_cps,
                });
            }
        }

        for (li, layer) in doc.layers.iter().enumerate() {
            check(&mut entries, &vec![li], layer, x, y, width, height);
        }

        let new_sel = if extend {
            toggle_selection(&doc.selection, &entries)
        } else {
            entries
        };
        let mut new_doc = doc;
        new_doc.selection = new_sel;
        model.set_document(new_doc);
    }

    /// Set the document selection directly.
    pub fn set_selection(model: &mut Model, selection: Selection) {
        let mut doc = model.document().clone();
        doc.selection = selection;
        model.set_document(doc);
    }

    /// Select an element by path.
    pub fn select_element(model: &mut Model, path: &ElementPath) {
        if path.is_empty() {
            return;
        }
        let doc = model.document().clone();
        let elem = match doc.get_element(path) {
            Some(e) => e,
            None => return,
        };
        if elem.locked() {
            return;
        }
        // Check if parent is a group (not layer) — select the whole group
        if path.len() >= 2 {
            let parent_path: ElementPath = path[..path.len() - 1].to_vec();
            if let Some(parent) = doc.get_element(&parent_path) {
                if parent.is_group() {
                    let mut entries = vec![ElementSelection {
                        path: parent_path.clone(),
                        control_points: all_cps(parent),
                    }];
                    if let Some(children) = parent.children() {
                        for i in 0..children.len() {
                            let mut cp = parent_path.clone();
                            cp.push(i);
                            entries.push(ElementSelection {
                                path: cp,
                                control_points: all_cps(&children[i]),
                            });
                        }
                    }
                    let mut new_doc = doc;
                    new_doc.selection = entries;
                    model.set_document(new_doc);
                    return;
                }
            }
        }
        let cps = all_cps(elem);
        let mut new_doc = doc;
        new_doc.selection = vec![ElementSelection {
            path: path.clone(),
            control_points: cps,
        }];
        model.set_document(new_doc);
    }

    /// Select a single control point on an element.
    pub fn select_control_point(model: &mut Model, path: &ElementPath, index: usize) {
        let mut doc = model.document().clone();
        doc.selection = vec![ElementSelection {
            path: path.clone(),
            control_points: [index].into_iter().collect(),
        }];
        model.set_document(doc);
    }

    /// Move all selected control points by (dx, dy).
    pub fn move_selection(model: &mut Model, dx: f64, dy: f64) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                let new_elem = move_control_points(elem, &es.control_points, dx, dy);
                new_doc = new_doc.replace_element(&es.path, new_elem);
            }
        }
        model.set_document(new_doc);
    }

    /// Duplicate selected elements, offset by (dx, dy).
    pub fn copy_selection(model: &mut Model, dx: f64, dy: f64) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        let mut new_selection: Selection = Vec::new();
        let mut sorted_sels: Vec<_> = doc.selection.clone();
        sorted_sels.sort_by(|a, b| b.path.cmp(&a.path));
        for es in &sorted_sels {
            if let Some(elem) = doc.get_element(&es.path) {
                let copied = move_control_points(elem, &es.control_points, dx, dy);
                new_doc = new_doc.insert_element_after(&es.path, copied.clone());
                let mut copy_path = es.path.clone();
                *copy_path.last_mut().unwrap() += 1;
                new_selection.push(ElementSelection {
                    path: copy_path,
                    control_points: all_cps(&copied),
                });
            }
        }
        new_doc.selection = new_selection;
        model.set_document(new_doc);
    }

    /// Group selected elements into a single Group.
    pub fn group_selection(model: &mut Model) {
        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        let mut paths: Vec<ElementPath> = doc.selection.iter().map(|es| es.path.clone()).collect();
        paths.sort();
        if paths.len() < 2 {
            return;
        }
        // All selected elements must be siblings (same parent prefix)
        let parent: ElementPath = paths[0][..paths[0].len() - 1].to_vec();
        if !paths.iter().all(|p| p.len() == paths[0].len() && p[..p.len() - 1] == parent[..]) {
            return;
        }
        // Gather elements in order
        let elements: Vec<Element> = paths
            .iter()
            .filter_map(|p| doc.get_element(p).cloned())
            .collect();
        if elements.len() != paths.len() {
            return;
        }
        // Delete selected elements in reverse order
        let mut new_doc = doc.clone();
        for p in paths.iter().rev() {
            new_doc = new_doc.delete_element(p);
        }
        // Create group and insert at first selected position
        let group = Element::Group(crate::geometry::element::GroupElem {
            children: elements,
            common: crate::geometry::element::CommonProps::default(),
        });
        let insert_path = paths[0].clone();
        new_doc = new_doc.insert_element_at(&insert_path, group.clone());
        // Select the new group
        let n = control_point_count(&group);
        new_doc.selection = vec![ElementSelection {
            path: insert_path,
            control_points: (0..n).collect(),
        }];
        model.set_document(new_doc);
    }

    /// Ungroup all selected Group elements, replacing each with its children.
    pub fn ungroup_selection(model: &mut Model) {
        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        // Find selected groups
        let mut group_paths: Vec<ElementPath> = Vec::new();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                if elem.is_group() {
                    group_paths.push(es.path.clone());
                }
            }
        }
        if group_paths.is_empty() {
            return;
        }
        group_paths.sort();

        let orig_doc = doc.clone();
        let mut new_doc = doc.clone();

        // Process in reverse order to preserve indices
        for gpath in group_paths.iter().rev() {
            let group_elem = match new_doc.get_element(gpath).cloned() {
                Some(e) => e,
                None => continue,
            };
            let children = match group_elem.children() {
                Some(c) => c.to_vec(),
                None => continue,
            };
            // Delete the group
            new_doc = new_doc.delete_element(gpath);
            // Insert children at the group's position
            if gpath.len() >= 2 {
                let layer_idx = gpath[0];
                let child_idx = gpath[1];
                if let Some(layer_children) = new_doc.layers[layer_idx].children_mut() {
                    for (j, child) in children.into_iter().enumerate() {
                        layer_children.insert(child_idx + j, child);
                    }
                }
            }
        }

        // Build selection for ungrouped children
        let mut new_selection = Vec::new();
        let mut offset: i64 = 0;
        for gpath in &group_paths {
            let orig_group = match orig_doc.get_element(gpath) {
                Some(e) => e,
                None => continue,
            };
            let n_children = orig_group.children().map_or(0, |c| c.len());
            if gpath.len() >= 2 {
                let layer_idx = gpath[0];
                let child_idx = (gpath[1] as i64 + offset) as usize;
                for j in 0..n_children {
                    let path = vec![layer_idx, child_idx + j];
                    if let Some(elem) = new_doc.get_element(&path) {
                        let n = control_point_count(elem);
                        new_selection.push(ElementSelection {
                            path,
                            control_points: (0..n).collect(),
                        });
                    }
                }
            }
            offset += n_children as i64 - 1;
        }
        new_doc.selection = new_selection;
        model.set_document(new_doc);
    }

    /// Ungroup all unlocked Group elements in the entire document.
    pub fn ungroup_all(model: &mut Model) {
        let doc = model.document().clone();
        let mut changed = false;

        fn flatten(children: &[Element], changed: &mut bool) -> Vec<Element> {
            let mut result = Vec::new();
            for child in children {
                if child.is_group() && !child.locked() {
                    *changed = true;
                    let inner = child.children().unwrap_or(&[]);
                    result.extend(flatten(inner, changed));
                } else if child.is_group() {
                    // Locked group: recurse into children but keep the group
                    let inner = child.children().unwrap_or(&[]);
                    let new_children = flatten(inner, changed);
                    let mut new_group = child.clone();
                    if let Some(gc) = new_group.children_mut() {
                        *gc = new_children;
                    }
                    result.push(new_group);
                } else {
                    result.push(child.clone());
                }
            }
            result
        }

        let new_layers: Vec<Element> = doc
            .layers
            .iter()
            .map(|layer| {
                let children = layer.children().unwrap_or(&[]);
                let new_children = flatten(children, &mut changed);
                let mut new_layer = layer.clone();
                if let Some(lc) = new_layer.children_mut() {
                    *lc = new_children;
                }
                new_layer
            })
            .collect();

        if !changed {
            return;
        }
        let mut new_doc = doc;
        new_doc.layers = new_layers;
        new_doc.selection.clear();
        model.set_document(new_doc);
    }

    /// Lock all selected elements.
    pub fn lock_selection(model: &mut Model) {
        let doc = model.document().clone();
        if doc.selection.is_empty() {
            return;
        }
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = new_doc.get_element(&es.path).cloned() {
                let locked = lock_element(&elem);
                new_doc = new_doc.replace_element(&es.path, locked);
            }
        }
        new_doc.selection.clear();
        model.set_document(new_doc);
    }

    /// Move a Bezier handle of a path element.
    pub fn move_path_handle(
        model: &mut Model,
        path: &ElementPath,
        anchor_idx: usize,
        handle_type: &str,
        dx: f64,
        dy: f64,
    ) {
        let doc = model.document().clone();
        if let Some(Element::Path(pe)) = doc.get_element(path) {
            let new_pe = move_path_handle(pe, anchor_idx, handle_type, dx, dy);
            let new_doc = doc.replace_element(path, Element::Path(new_pe));
            model.set_document(new_doc);
        }
    }

    /// Unlock all locked elements.
    pub fn unlock_all(model: &mut Model) {
        let doc = model.document().clone();
        let new_layers: Vec<Element> = doc.layers.iter().map(|l| unlock_element(l)).collect();
        let mut new_doc = doc;
        new_doc.layers = new_layers;
        new_doc.selection.clear();
        model.set_document(new_doc);
    }
}

fn lock_element(elem: &Element) -> Element {
    let mut new = elem.clone();
    if new.is_group() {
        if let Some(children) = new.children_mut() {
            *children = children.iter().map(|c| lock_element(c)).collect();
        }
    }
    new.common_mut().locked = true;
    new
}

fn unlock_element(elem: &Element) -> Element {
    let mut new = elem.clone();
    if let Some(children) = new.children_mut() {
        *children = children.iter().map(|c| unlock_element(c)).collect();
    }
    new.common_mut().locked = false;
    new
}

fn toggle_selection(current: &Selection, new: &Selection) -> Selection {
    let current_by_path: std::collections::HashMap<&Vec<usize>, &ElementSelection> =
        current.iter().map(|es| (&es.path, es)).collect();
    let new_by_path: std::collections::HashMap<&Vec<usize>, &ElementSelection> =
        new.iter().map(|es| (&es.path, es)).collect();

    let mut result: Selection = Vec::new();
    // Elements only in current
    for (path, es) in &current_by_path {
        if !new_by_path.contains_key(path) {
            result.push((*es).clone());
        }
    }
    // Elements only in new
    for (path, es) in &new_by_path {
        if !current_by_path.contains_key(path) {
            result.push((*es).clone());
        }
    }
    // Elements in both: toggle CPs
    for (path, cur) in &current_by_path {
        if let Some(nw) = new_by_path.get(path) {
            let toggled: HashSet<usize> = cur
                .control_points
                .symmetric_difference(&nw.control_points)
                .copied()
                .collect();
            if !toggled.is_empty() {
                result.push(ElementSelection {
                    path: cur.path.clone(),
                    control_points: toggled,
                });
            }
        }
    }
    result
}
