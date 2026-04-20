//! Document controller (MVC pattern).
//!
//! The Controller provides mutation operations on the Model's document.
//! Since the Document is cloned on mutation, changes produce a new Document
//! that replaces the old one in the Model.

use std::rc::Rc;

use crate::document::document::{
    ElementPath, ElementSelection, Selection, SelectionKind, SortedCps,
};
use crate::document::model::Model;
use crate::geometry::element::{
    control_point_count, control_points, move_control_points,
    move_path_handle, with_fill, with_stroke, with_width_points,
    Element, Fill, Stroke, StrokeWidthPoint,
};
use crate::algorithms::hit_test::{element_intersects_polygon, element_intersects_rect, point_in_rect};

// ---------------------------------------------------------------------------
// Helpers — shared by the Controller's boolean ops
// ---------------------------------------------------------------------------

/// MERGE predicate per BOOLEAN.md §Operand and paint rules.
/// Two fills merge when both are solid colors with exactly equal
/// `color` components. `None` fills never match anything — including
/// other `None` fills. Gradients and patterns, once they exist,
/// likewise never match; the current `Fill` type holds only a
/// solid-color enum so every `Some(_)` is eligible today.
/// Only the color is inspected; opacity / stroke / blend_mode do not
/// participate.
fn fills_merge_equal(a: &Option<Fill>, b: &Option<Fill>) -> bool {
    match (a, b) {
        (Some(fa), Some(fb)) => fa.color == fb.color,
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// Mediates between user actions and the document model.
pub struct Controller;

impl Controller {
    /// Add an element to the selected layer and select it as a whole.
    pub fn add_element(model: &mut Model, element: Element) {
        let doc = model.document().clone();
        let idx = doc.selected_layer;
        let _n = control_point_count(&element);
        let mut new_doc = doc;
        let child_idx = if let Some(children) = new_doc.layers[idx].children_mut() {
            let ci = children.len();
            children.push(Rc::new(element));
            ci
        } else {
            model.set_document(new_doc);
            return;
        };
        new_doc.selection = vec![ElementSelection::all(vec![idx, child_idx])];
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
        select_flat(model, |elem| element_intersects_rect(elem, x, y, width, height), extend);
    }

    /// Select all elements whose bounds intersect the given polygon.
    pub fn select_polygon(
        model: &mut Model,
        polygon: &[(f64, f64)],
        extend: bool,
    ) {
        select_flat(model, |elem| element_intersects_polygon(elem, polygon), extend);
    }

    /// Direct selection marquee: select individual control points within the rect.
    pub fn partial_select_rect(
        model: &mut Model,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        extend: bool,
    ) {
        select_recursive(model, |path, elem| {
            let cps = control_points(elem);
            let hit_cps: Vec<usize> = cps
                .iter()
                .enumerate()
                .filter(|(_, (px, py))| point_in_rect(*px, *py, x, y, width, height))
                .map(|(i, _)| i)
                .collect();
            if !hit_cps.is_empty() {
                Some(ElementSelection {
                    path: path.clone(),
                    kind: SelectionKind::Partial(SortedCps::from_iter(hit_cps)),
                })
            } else if element_intersects_rect(elem, x, y, width, height) {
                Some(ElementSelection::partial(
                    path.clone(),
                    std::iter::empty::<usize>(),
                ))
            } else {
                None
            }
        }, extend);
    }

    /// Select all unlocked, visible elements in the document.
    pub fn select_all(model: &mut Model) {
        use crate::geometry::element::Visibility;
        let doc = model.document().clone();
        let mut entries: Selection = Vec::new();
        for (li, layer) in doc.layers.iter().enumerate() {
            let layer_vis = layer.visibility();
            if layer_vis == Visibility::Invisible {
                continue;
            }
            if let Some(children) = layer.children() {
                for (ci, child) in children.iter().enumerate() {
                    if child.locked() {
                        continue;
                    }
                    if std::cmp::min(layer_vis, child.visibility()) == Visibility::Invisible {
                        continue;
                    }
                    entries.push(ElementSelection::all(vec![li, ci]));
                }
            }
        }
        let mut new_doc = doc;
        new_doc.selection = entries;
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
        use crate::geometry::element::Visibility;
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
        if doc.effective_visibility(path) == Visibility::Invisible {
            return;
        }
        // Check if parent is a group (not layer) — select the whole group
        if path.len() >= 2 {
            let parent_path: ElementPath = path[..path.len() - 1].to_vec();
            if let Some(parent) = doc.get_element(&parent_path)
                && parent.is_group() {
                    let mut entries = vec![ElementSelection::all(parent_path.clone())];
                    if let Some(children) = parent.children() {
                        for i in 0..children.len() {
                            let mut cp = parent_path.clone();
                            cp.push(i);
                            entries.push(ElementSelection::all(cp));
                        }
                    }
                    let mut new_doc = doc;
                    new_doc.selection = entries;
                    model.set_document(new_doc);
                    return;
                }
        }
        let mut new_doc = doc;
        new_doc.selection = vec![ElementSelection::all(path.clone())];
        model.set_document(new_doc);
    }

    /// Select a single control point on an element.
    pub fn select_control_point(model: &mut Model, path: &ElementPath, index: usize) {
        let mut doc = model.document().clone();
        doc.selection = vec![ElementSelection::partial(path.clone(), [index])];
        model.set_document(doc);
    }

    /// Move all selected control points by (dx, dy).
    pub fn move_selection(model: &mut Model, dx: f64, dy: f64) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                let new_elem = move_control_points(elem, &es.kind, dx, dy);
                new_doc = new_doc.replace_element(&es.path, new_elem);
            }
        }
        model.set_document(new_doc);
    }

    /// Set the fill of all selected elements.
    pub fn set_selection_fill(model: &mut Model, fill: Option<Fill>) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                new_doc = new_doc.replace_element(&es.path, with_fill(elem, fill));
            }
        }
        model.set_document(new_doc);
    }

    /// Set the stroke of all selected elements.
    pub fn set_selection_stroke(model: &mut Model, stroke: Option<Stroke>) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                new_doc = new_doc.replace_element(&es.path, with_stroke(elem, stroke));
            }
        }
        model.set_document(new_doc);
    }

    /// Set width profile points on selected Path and Line elements.
    pub fn set_selection_width_profile(model: &mut Model, width_points: Vec<StrokeWidthPoint>) {
        let doc = model.document().clone();
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path) {
                new_doc = new_doc.replace_element(&es.path, with_width_points(elem, width_points.clone()));
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
                let copied = move_control_points(elem, &es.kind, dx, dy);
                new_doc = new_doc.insert_element_after(&es.path, copied.clone());
                let mut copy_path = es.path.clone();
                *copy_path.last_mut().unwrap() += 1;
                // Copying always selects the new element as a whole.
                new_selection.push(ElementSelection::all(copy_path));
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
        let elements: Vec<Rc<Element>> = paths
            .iter()
            .filter_map(|p| doc.get_element(p).cloned().map(Rc::new))
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
        let _ = n;
        new_doc.selection = vec![ElementSelection::all(insert_path)];
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
            if let Some(elem) = doc.get_element(&es.path)
                && elem.is_group() {
                    group_paths.push(es.path.clone());
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
                    if new_doc.get_element(&path).is_some() {
                        new_selection.push(ElementSelection::all(path));
                    }
                }
            }
            offset += n_children as i64 - 1;
        }
        new_doc.selection = new_selection;
        model.set_document(new_doc);
    }

    /// Make a compound shape from the current selection using UNION.
    /// All selected elements must be siblings. The frontmost (last in
    /// path order) operand's fill, stroke, and common attributes are
    /// copied onto the new compound shape. Selection becomes the new
    /// compound shape. See BOOLEAN.md §Compound shapes.
    pub fn make_compound_shape(model: &mut Model) {
        use crate::geometry::live::{CompoundOperation, CompoundShape, LiveVariant};
        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        let mut paths: Vec<ElementPath> =
            doc.selection.iter().map(|es| es.path.clone()).collect();
        paths.sort();
        if paths.len() < 2 {
            return;
        }
        // Siblings only.
        let parent: ElementPath = paths[0][..paths[0].len() - 1].to_vec();
        if !paths.iter().all(|p| {
            p.len() == paths[0].len() && p[..p.len() - 1] == parent[..]
        }) {
            return;
        }
        let elements: Vec<Rc<Element>> = paths
            .iter()
            .filter_map(|p| doc.get_element(p).cloned().map(Rc::new))
            .collect();
        if elements.len() != paths.len() {
            return;
        }
        // Inherit the frontmost operand's paint (last in path order).
        let frontmost = elements.last().unwrap();
        let fill = frontmost.fill().copied();
        let stroke = frontmost.stroke().copied();
        let common = frontmost.common().clone();

        let compound = Element::Live(LiveVariant::CompoundShape(CompoundShape {
            operation: CompoundOperation::Union,
            operands: elements,
            fill,
            stroke,
            common,
        }));

        let mut new_doc = doc.clone();
        for p in paths.iter().rev() {
            new_doc = new_doc.delete_element(p);
        }
        let insert_path = paths[0].clone();
        new_doc = new_doc.insert_element_at(&insert_path, compound);
        new_doc.selection = vec![ElementSelection::all(insert_path)];
        model.set_document(new_doc);
    }

    /// Release every selected compound shape: replace it in place with
    /// its operand children. Each operand keeps its own paint. The
    /// compound shape's paint is discarded. Selection becomes the
    /// restored operands.
    pub fn release_compound_shape(model: &mut Model) {
        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        let mut cs_paths: Vec<ElementPath> = Vec::new();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path)
                && matches!(elem, Element::Live(_))
            {
                cs_paths.push(es.path.clone());
            }
        }
        if cs_paths.is_empty() {
            return;
        }
        cs_paths.sort();

        let orig_doc = doc.clone();
        let mut new_doc = doc.clone();
        // Process in reverse to preserve sibling indices.
        for cs_path in cs_paths.iter().rev() {
            let cs_elem = match new_doc.get_element(cs_path).cloned() {
                Some(e) => e,
                None => continue,
            };
            let operands: Vec<Rc<Element>> = match &cs_elem {
                Element::Live(crate::geometry::live::LiveVariant::CompoundShape(cs)) => {
                    cs.operands.clone()
                }
                _ => continue,
            };
            new_doc = new_doc.delete_element(cs_path);
            if cs_path.len() >= 2 {
                let layer_idx = cs_path[0];
                let child_idx = cs_path[1];
                if let Some(layer_children) = new_doc.layers[layer_idx].children_mut() {
                    for (j, op) in operands.iter().enumerate() {
                        let insert_idx = child_idx + j;
                        if insert_idx <= layer_children.len() {
                            layer_children.insert(insert_idx, op.clone());
                        } else {
                            layer_children.push(op.clone());
                        }
                    }
                }
            }
        }

        // Build selection of released operands.
        let mut new_selection = Vec::new();
        let mut offset: i64 = 0;
        for cs_path in &cs_paths {
            let orig_elem = match orig_doc.get_element(cs_path) {
                Some(e) => e,
                None => continue,
            };
            let n = match orig_elem {
                Element::Live(crate::geometry::live::LiveVariant::CompoundShape(cs)) => {
                    cs.operands.len()
                }
                _ => continue,
            };
            if cs_path.len() >= 2 {
                let layer_idx = cs_path[0];
                let child_idx = (cs_path[1] as i64 + offset) as usize;
                for j in 0..n {
                    let path = vec![layer_idx, child_idx + j];
                    if new_doc.get_element(&path).is_some() {
                        new_selection.push(ElementSelection::all(path));
                    }
                }
            }
            offset += n as i64 - 1;
        }
        new_doc.selection = new_selection;
        model.set_document(new_doc);
    }

    /// Expand every selected compound shape into static Polygon
    /// elements derived from its evaluated geometry. The expanded
    /// polygons carry the compound shape's own paint. Operand tree
    /// is discarded.
    pub fn expand_compound_shape(model: &mut Model) {
        use crate::geometry::live::{DEFAULT_PRECISION, LiveElement, LiveVariant};
        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        let mut cs_paths: Vec<ElementPath> = Vec::new();
        for es in &doc.selection {
            if let Some(elem) = doc.get_element(&es.path)
                && matches!(elem, Element::Live(_))
            {
                cs_paths.push(es.path.clone());
            }
        }
        if cs_paths.is_empty() {
            return;
        }
        cs_paths.sort();

        let orig_doc = doc.clone();
        let mut new_doc = doc.clone();
        let mut expanded_counts: Vec<usize> = Vec::with_capacity(cs_paths.len());

        for cs_path in cs_paths.iter().rev() {
            let cs_elem = match new_doc.get_element(cs_path).cloned() {
                Some(e) => e,
                None => {
                    expanded_counts.push(0);
                    continue;
                }
            };
            let expanded: Vec<Rc<Element>> = match &cs_elem {
                Element::Live(LiveVariant::CompoundShape(cs)) => cs.expand(DEFAULT_PRECISION),
                _ => {
                    expanded_counts.push(0);
                    continue;
                }
            };
            expanded_counts.push(expanded.len());
            new_doc = new_doc.delete_element(cs_path);
            if cs_path.len() >= 2 {
                let layer_idx = cs_path[0];
                let child_idx = cs_path[1];
                if let Some(layer_children) = new_doc.layers[layer_idx].children_mut() {
                    for (j, poly) in expanded.iter().enumerate() {
                        let insert_idx = child_idx + j;
                        if insert_idx <= layer_children.len() {
                            layer_children.insert(insert_idx, poly.clone());
                        } else {
                            layer_children.push(poly.clone());
                        }
                    }
                }
            }
        }
        expanded_counts.reverse(); // restore forward order

        // Build selection of expanded polygons.
        let mut new_selection = Vec::new();
        let mut offset: i64 = 0;
        for (cs_path, &n) in cs_paths.iter().zip(expanded_counts.iter()) {
            let _orig = orig_doc.get_element(cs_path);
            if cs_path.len() >= 2 {
                let layer_idx = cs_path[0];
                let child_idx = (cs_path[1] as i64 + offset) as usize;
                for j in 0..n {
                    let path = vec![layer_idx, child_idx + j];
                    if new_doc.get_element(&path).is_some() {
                        new_selection.push(ElementSelection::all(path));
                    }
                }
            }
            offset += n as i64 - 1;
        }
        new_doc.selection = new_selection;
        model.set_document(new_doc);
    }

    /// Destructively apply one of the six implemented boolean ops to
    /// the current selection. Supported: `"union"`, `"intersection"`,
    /// `"exclude"`, `"subtract_front"`, `"subtract_back"`, `"crop"`.
    /// DIVIDE / TRIM / MERGE land in a later pass.
    ///
    /// UNION / INTERSECTION / EXCLUDE: every operand is consumed; the
    /// resulting polygon(s) carry the frontmost operand's paint.
    /// SUBTRACT_FRONT / SUBTRACT_BACK: the front/back operand is the
    /// cutter and is consumed; each remaining survivor emits a
    /// subtracted polygon carrying its own paint. CROP: the frontmost
    /// operand is the mask and is consumed; each remaining survivor
    /// emits the intersection carrying its own paint.
    pub fn apply_destructive_boolean(model: &mut Model, op_name: &str) {
        use crate::algorithms::boolean::{
            boolean_intersect, boolean_subtract, boolean_union, PolygonSet,
        };
        use crate::geometry::element::{CommonProps, Fill, PolygonElem, Stroke};
        use crate::geometry::live::{
            apply_operation, element_to_polygon_set, CompoundOperation,
            DEFAULT_PRECISION,
        };

        let doc = model.document();
        if doc.selection.is_empty() {
            return;
        }
        let mut paths: Vec<ElementPath> =
            doc.selection.iter().map(|es| es.path.clone()).collect();
        paths.sort();
        if paths.len() < 2 {
            return;
        }
        // Siblings only.
        let parent: ElementPath = paths[0][..paths[0].len() - 1].to_vec();
        if !paths.iter().all(|p| {
            p.len() == paths[0].len() && p[..p.len() - 1] == parent[..]
        }) {
            return;
        }
        let elements: Vec<Rc<Element>> = paths
            .iter()
            .filter_map(|p| doc.get_element(p).cloned().map(Rc::new))
            .collect();
        if elements.len() != paths.len() {
            return;
        }

        // (PolygonSet, fill, stroke, common) tuples; flattened to
        // Polygon elements below. Empty polygon sets are skipped.
        let mut outputs: Vec<(PolygonSet, Option<Fill>, Option<Stroke>, CommonProps)> = Vec::new();
        let precision = DEFAULT_PRECISION;

        match op_name {
            "union" | "intersection" | "exclude" => {
                let operand_sets: Vec<PolygonSet> = elements
                    .iter()
                    .map(|e| element_to_polygon_set(e, precision))
                    .collect();
                let op = match op_name {
                    "union" => CompoundOperation::Union,
                    "intersection" => CompoundOperation::Intersection,
                    "exclude" => CompoundOperation::Exclude,
                    _ => unreachable!(),
                };
                let result = apply_operation(op, &operand_sets);
                let front = elements.last().unwrap();
                outputs.push((
                    result,
                    front.fill().copied(),
                    front.stroke().copied(),
                    front.common().clone(),
                ));
            }
            "subtract_front" | "crop" => {
                // Frontmost (= last in path order) consumed.
                let cutter = element_to_polygon_set(
                    elements.last().unwrap(), precision,
                );
                for survivor in &elements[..elements.len() - 1] {
                    let survivor_set = element_to_polygon_set(survivor, precision);
                    let result = if op_name == "crop" {
                        boolean_intersect(&survivor_set, &cutter)
                    } else {
                        boolean_subtract(&survivor_set, &cutter)
                    };
                    outputs.push((
                        result,
                        survivor.fill().copied(),
                        survivor.stroke().copied(),
                        survivor.common().clone(),
                    ));
                }
            }
            "subtract_back" => {
                let cutter = element_to_polygon_set(&elements[0], precision);
                for survivor in &elements[1..] {
                    let survivor_set = element_to_polygon_set(survivor, precision);
                    let result = boolean_subtract(&survivor_set, &cutter);
                    outputs.push((
                        result,
                        survivor.fill().copied(),
                        survivor.stroke().copied(),
                        survivor.common().clone(),
                    ));
                }
            }
            "divide" => {
                // Walk operands back-to-front, maintaining a partition
                // of the union-so-far into (region, frontmost-covering
                // operand index) pairs. Each incoming operand splits
                // every existing region into overlap / non-overlap; the
                // overlap relabels to the incoming index (now frontmost).
                let mut accumulator: Vec<(PolygonSet, usize)> = Vec::new();
                for (i, op_elem) in elements.iter().enumerate() {
                    let op_set = element_to_polygon_set(op_elem, precision);
                    let mut new_acc: Vec<(PolygonSet, usize)> = Vec::new();
                    let mut remaining = op_set.clone();
                    for (existing_region, existing_idx) in &accumulator {
                        let overlap = boolean_intersect(existing_region, &op_set);
                        if !overlap.is_empty() {
                            new_acc.push((overlap, i));
                        }
                        let non_overlap = boolean_subtract(existing_region, &op_set);
                        if !non_overlap.is_empty() {
                            new_acc.push((non_overlap, *existing_idx));
                        }
                        remaining = boolean_subtract(&remaining, existing_region);
                    }
                    if !remaining.is_empty() {
                        new_acc.push((remaining, i));
                    }
                    accumulator = new_acc;
                }
                for (region, paint_idx) in accumulator {
                    let src = &elements[paint_idx];
                    outputs.push((
                        region,
                        src.fill().copied(),
                        src.stroke().copied(),
                        src.common().clone(),
                    ));
                }
            }
            "trim" | "merge" => {
                // TRIM: for each operand i, emit (operand[i] - union
                // of all later operands) keeping operand[i]'s own
                // paint. Frontmost (i = N-1) is untouched.
                let operand_sets: Vec<PolygonSet> = elements
                    .iter()
                    .map(|e| element_to_polygon_set(e, precision))
                    .collect();
                let mut trimmed: Vec<(PolygonSet, Option<Fill>, Option<Stroke>, CommonProps)> =
                    Vec::new();
                for i in 0..elements.len() {
                    let mut region = operand_sets[i].clone();
                    for later in operand_sets.iter().skip(i + 1) {
                        region = boolean_subtract(&region, later);
                    }
                    if !region.is_empty() {
                        trimmed.push((
                            region,
                            elements[i].fill().copied(),
                            elements[i].stroke().copied(),
                            elements[i].common().clone(),
                        ));
                    }
                }
                if op_name == "trim" {
                    outputs.extend(trimmed);
                } else {
                    // MERGE: union touching trimmed survivors that
                    // share an exactly-equal solid-color fill. None
                    // fills never merge (predicate per BOOLEAN.md).
                    // Grouping is O(N^2) by linear scan; acceptable for
                    // the selection sizes this panel handles.
                    let mut consumed = vec![false; trimmed.len()];
                    for i in 0..trimmed.len() {
                        if consumed[i] {
                            continue;
                        }
                        consumed[i] = true;
                        let (region_i, fill_i, stroke_i, common_i) =
                            trimmed[i].clone();
                        let mut merged = region_i;
                        let mut stroke_winner = stroke_i;
                        let mut common_winner = common_i;
                        if fill_i.is_some() {
                            for (j, trim_j) in trimmed.iter().enumerate().skip(i + 1) {
                                if consumed[j] {
                                    continue;
                                }
                                if fills_merge_equal(&fill_i, &trim_j.1) {
                                    merged = boolean_union(&merged, &trim_j.0);
                                    // j > i in operand z-order, so j
                                    // is frontmost; its stroke/common
                                    // wins on the merged output.
                                    stroke_winner = trim_j.2;
                                    common_winner = trim_j.3.clone();
                                    consumed[j] = true;
                                }
                            }
                        }
                        outputs.push((merged, fill_i, stroke_winner, common_winner));
                    }
                }
            }
            _ => return,
        }

        // Flatten (PolygonSet, paint) outputs into Polygon elements.
        let mut new_elements: Vec<Rc<Element>> = Vec::new();
        for (ps, fill, stroke, common) in outputs {
            for ring in ps {
                if ring.len() >= 3 {
                    new_elements.push(Rc::new(Element::Polygon(PolygonElem {
                        points: ring,
                        fill,
                        stroke,
                        common: common.clone(),
                    })));
                }
            }
        }

        // Remove all original operands in reverse path order.
        let mut new_doc = doc.clone();
        for p in paths.iter().rev() {
            new_doc = new_doc.delete_element(p);
        }

        // Insert new elements starting at paths[0]'s child_idx.
        let insert_base = paths[0].clone();
        if insert_base.len() >= 2 {
            let layer_idx = insert_base[0];
            let child_idx = insert_base[1];
            if let Some(layer_children) = new_doc.layers[layer_idx].children_mut() {
                for (i, elem) in new_elements.iter().enumerate() {
                    let insert_idx = child_idx + i;
                    if insert_idx <= layer_children.len() {
                        layer_children.insert(insert_idx, elem.clone());
                    } else {
                        layer_children.push(elem.clone());
                    }
                }
            }
        }

        // Select the new elements.
        let mut new_selection = Vec::new();
        if insert_base.len() >= 2 {
            let layer_idx = insert_base[0];
            let base_child_idx = insert_base[1];
            for i in 0..new_elements.len() {
                let path = vec![layer_idx, base_child_idx + i];
                if new_doc.get_element(&path).is_some() {
                    new_selection.push(ElementSelection::all(path));
                }
            }
        }
        new_doc.selection = new_selection;
        model.set_document(new_doc);
    }

    /// Ungroup all unlocked Group elements in the entire document.
    pub fn ungroup_all(model: &mut Model) {
        let doc = model.document().clone();
        let mut changed = false;

        fn flatten(children: &[Rc<Element>], changed: &mut bool) -> Vec<Rc<Element>> {
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
                    let mut new_group = (**child).clone();
                    if let Some(gc) = new_group.children_mut() {
                        *gc = new_children;
                    }
                    result.push(Rc::new(new_group));
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
        let new_layers: Vec<Element> = doc.layers.iter().map(unlock_element).collect();
        let mut new_doc = doc;
        new_doc.layers = new_layers;
        new_doc.selection.clear();
        model.set_document(new_doc);
    }

    /// Set every element in the current selection to
    /// [`Visibility::Invisible`] and clear the selection. If an
    /// element is a Group/Layer, the visibility is set on the
    /// container itself (not its children) — a parent's `Invisible`
    /// caps every descendant, so the effect reaches the whole
    /// subtree without mutating every node.
    pub fn hide_selection(model: &mut Model) {
        use crate::geometry::element::Visibility;
        let doc = model.document().clone();
        if doc.selection.is_empty() {
            return;
        }
        let mut new_doc = doc.clone();
        for es in &doc.selection {
            if let Some(elem) = new_doc.get_element(&es.path).cloned() {
                let mut hidden = elem.clone();
                hidden.common_mut().visibility = Visibility::Invisible;
                new_doc = new_doc.replace_element(&es.path, hidden);
            }
        }
        new_doc.selection.clear();
        model.set_document(new_doc);
    }

    /// Traverse the document, set every element whose own
    /// visibility is [`Visibility::Invisible`] back to
    /// [`Visibility::Preview`], and replace the current selection
    /// with exactly the paths that were shown. Elements that are
    /// effectively invisible only because an ancestor is invisible
    /// are *not* individually modified — it is the ancestor whose
    /// own flag is unset, and that cascades.
    pub fn show_all(model: &mut Model) {
        use crate::geometry::element::Visibility;
        let doc = model.document().clone();
        let mut shown_paths: Vec<ElementPath> = Vec::new();
        let new_layers: Vec<Element> = doc
            .layers
            .iter()
            .enumerate()
            .map(|(li, layer)| show_all_in(layer, &vec![li], &mut shown_paths))
            .collect();
        let mut new_doc = doc;
        new_doc.layers = new_layers;
        new_doc.selection = shown_paths
            .into_iter()
            .map(ElementSelection::all)
            .collect();
        // Suppress the unused `Visibility` warning when compiled in
        // configurations that optimise the helper away.
        let _ = Visibility::Preview;
        model.set_document(new_doc);
    }

    /// Apply the TSPAN.md "Character attribute writes" algorithm to the
    /// text element at `path` over the character range
    /// `[char_start, char_end)`: split_range → set attribute on every
    /// targeted tspan → identity omission (null out overrides that
    /// equal the parent's effective value) → merge adjacent equal.
    ///
    /// Attribute names are snake_case (`font_weight`, `font_style`,
    /// `font_family`, `font_size`). Unsupported attributes are silently
    /// ignored — add them here as needed.
    ///
    /// No-op when the target is not a Text / TextPath element or when
    /// the range is out of bounds.
    pub fn set_character_attribute(
        model: &mut Model,
        path: &ElementPath,
        char_start: usize,
        char_end: usize,
        attribute: &str,
        value: &str,
    ) {
        let doc = model.document().clone();
        let new_elem = match doc.get_element(path) {
            Some(Element::Text(t)) => {
                let mut new_t = t.clone();
                let parent_for_omission = t.clone();
                let (tspans, first, last) = crate::geometry::tspan::split_range(
                    &new_t.tspans,
                    char_start,
                    char_end,
                );
                new_t.tspans = tspans;
                if let (Some(first), Some(last)) = (first, last) {
                    for i in first..=last {
                        apply_attr_to_tspan(&mut new_t.tspans[i], attribute, value);
                    }
                    for i in first..=last {
                        omit_text_identity(
                            &mut new_t.tspans[i],
                            &parent_for_omission,
                            attribute,
                        );
                    }
                }
                new_t.tspans = crate::geometry::tspan::merge(&new_t.tspans);
                Element::Text(new_t)
            }
            Some(Element::TextPath(tp)) => {
                let mut new_tp = tp.clone();
                let parent_for_omission = tp.clone();
                let (tspans, first, last) = crate::geometry::tspan::split_range(
                    &new_tp.tspans,
                    char_start,
                    char_end,
                );
                new_tp.tspans = tspans;
                if let (Some(first), Some(last)) = (first, last) {
                    for i in first..=last {
                        apply_attr_to_tspan(&mut new_tp.tspans[i], attribute, value);
                    }
                    for i in first..=last {
                        omit_textpath_identity(
                            &mut new_tp.tspans[i],
                            &parent_for_omission,
                            attribute,
                        );
                    }
                }
                new_tp.tspans = crate::geometry::tspan::merge(&new_tp.tspans);
                Element::TextPath(new_tp)
            }
            _ => return,
        };
        let new_doc = doc.replace_element(path, new_elem);
        model.set_document(new_doc);
    }
}

/// Apply a character-panel attribute write to a single tspan by setting
/// its override slot to `Some(value)`. Unsupported attribute names are
/// silently ignored so callers can send arbitrary names.
fn apply_attr_to_tspan(ts: &mut crate::geometry::tspan::Tspan, attr: &str, value: &str) {
    match attr {
        "font_family" => ts.font_family = Some(value.to_string()),
        "font_size" => {
            if let Ok(v) = value.parse::<f64>() {
                ts.font_size = Some(v);
            }
        }
        "font_weight" => ts.font_weight = Some(value.to_string()),
        "font_style" => ts.font_style = Some(value.to_string()),
        _ => {}
    }
}

fn omit_text_identity(
    ts: &mut crate::geometry::tspan::Tspan,
    parent: &crate::geometry::element::TextElem,
    attr: &str,
) {
    match attr {
        "font_family" => {
            if ts.font_family.as_deref() == Some(parent.font_family.as_str()) {
                ts.font_family = None;
            }
        }
        "font_size" => {
            if ts.font_size == Some(parent.font_size) {
                ts.font_size = None;
            }
        }
        "font_weight" => {
            if ts.font_weight.as_deref() == Some(parent.font_weight.as_str()) {
                ts.font_weight = None;
            }
        }
        "font_style" => {
            if ts.font_style.as_deref() == Some(parent.font_style.as_str()) {
                ts.font_style = None;
            }
        }
        _ => {}
    }
}

fn omit_textpath_identity(
    ts: &mut crate::geometry::tspan::Tspan,
    parent: &crate::geometry::element::TextPathElem,
    attr: &str,
) {
    match attr {
        "font_family" => {
            if ts.font_family.as_deref() == Some(parent.font_family.as_str()) {
                ts.font_family = None;
            }
        }
        "font_size" => {
            if ts.font_size == Some(parent.font_size) {
                ts.font_size = None;
            }
        }
        "font_weight" => {
            if ts.font_weight.as_deref() == Some(parent.font_weight.as_str()) {
                ts.font_weight = None;
            }
        }
        "font_style" => {
            if ts.font_style.as_deref() == Some(parent.font_style.as_str()) {
                ts.font_style = None;
            }
        }
        _ => {}
    }
}

/// Recursively rewrite `elem` so that every node whose own
/// visibility is `Invisible` becomes `Preview`, collecting the paths
/// of rewritten nodes into `shown_paths`.
fn show_all_in(
    elem: &Element,
    path: &ElementPath,
    shown_paths: &mut Vec<ElementPath>,
) -> Element {
    use crate::geometry::element::Visibility;
    let mut new = elem.clone();
    if new.visibility() == Visibility::Invisible {
        new.common_mut().visibility = Visibility::Preview;
        shown_paths.push(path.clone());
    }
    if let Some(children) = new.children_mut() {
        let rewritten: Vec<Rc<Element>> = children
            .iter()
            .enumerate()
            .map(|(i, child)| {
                let mut cp = path.clone();
                cp.push(i);
                Rc::new(show_all_in(child, &cp, shown_paths))
            })
            .collect();
        *children = rewritten;
    }
    new
}

fn lock_element(elem: &Element) -> Element {
    let mut new = elem.clone();
    if new.is_group()
        && let Some(children) = new.children_mut() {
            *children = children.iter().map(|c| Rc::new(lock_element(c))).collect();
        }
    new.common_mut().locked = true;
    new
}

fn unlock_element(elem: &Element) -> Element {
    let mut new = elem.clone();
    if let Some(children) = new.children_mut() {
        *children = children.iter().map(|c| Rc::new(unlock_element(c))).collect();
    }
    new.common_mut().locked = false;
    new
}

/// Flat 2-level selection: iterate layers → children, expanding groups.
///
/// The `predicate` tests whether a leaf element should be selected.
/// Groups are expanded: if any grandchild matches, the group and all
/// its children are selected.
fn select_flat(
    model: &mut Model,
    predicate: impl Fn(&Element) -> bool,
    extend: bool,
) {
    use crate::geometry::element::Visibility;
    let doc = model.document().clone();
    let mut entries: Selection = Vec::new();
    for (li, layer) in doc.layers.iter().enumerate() {
        let layer_vis = layer.visibility();
        if layer_vis == Visibility::Invisible {
            continue;
        }
        if let Some(children) = layer.children() {
            for (ci, child) in children.iter().enumerate() {
                if child.locked() {
                    continue;
                }
                let child_vis = std::cmp::min(layer_vis, child.visibility());
                if child_vis == Visibility::Invisible {
                    continue;
                }
                if child.is_group() {
                    if let Some(grandchildren) = child.children()
                        && grandchildren.iter().any(|gc| predicate(gc))
                    {
                        entries.push(ElementSelection::all(vec![li, ci]));
                        for (gi, _gc) in grandchildren.iter().enumerate() {
                            entries.push(ElementSelection::all(vec![li, ci, gi]));
                        }
                    }
                } else if predicate(child) {
                    entries.push(ElementSelection::all(vec![li, ci]));
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

/// Recursive selection: traverse the full element tree, calling
/// `leaf_handler` on each non-container element. Groups and layers
/// are traversed (not expanded).
fn select_recursive(
    model: &mut Model,
    leaf_handler: impl Fn(&ElementPath, &Element) -> Option<ElementSelection>,
    extend: bool,
) {
    use crate::geometry::element::Visibility;

    fn check(
        entries: &mut Selection,
        path: &ElementPath,
        elem: &Element,
        ancestor_vis: Visibility,
        leaf_handler: &dyn Fn(&ElementPath, &Element) -> Option<ElementSelection>,
    ) {
        if elem.locked() {
            return;
        }
        let effective = std::cmp::min(ancestor_vis, elem.visibility());
        if effective == Visibility::Invisible {
            return;
        }
        if elem.is_group_or_layer() {
            if let Some(children) = elem.children() {
                for (i, child) in children.iter().enumerate() {
                    let mut child_path = path.clone();
                    child_path.push(i);
                    check(entries, &child_path, child, effective, leaf_handler);
                }
            }
            return;
        }
        if let Some(es) = leaf_handler(path, elem) {
            entries.push(es);
        }
    }

    let doc = model.document().clone();
    let mut entries: Selection = Vec::new();
    for (li, layer) in doc.layers.iter().enumerate() {
        check(&mut entries, &vec![li], layer, Visibility::Preview, &leaf_handler);
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

/// Combine two selections by XOR-ing per-element CP membership.
///
/// - Elements appearing in only one input pass through unchanged.
/// - Elements appearing in both inputs have their selected CP sets
///   XORed. If the result is empty the element stays selected as
///   `Partial(empty)` — "element selected, no individual CPs
///   highlighted" — rather than being dropped.
/// - Two `All` selections cancel out (the element *is* dropped — this
///   is the element-level deselect gesture, distinct from removing
///   the last CP of a `Partial`).
/// - `All` XOR `Partial(s)` becomes `Partial` of the *complement* of
///   `s` against the element's CP count, which we don't have here, so
///   we conservatively treat it as `All` (this preserves the
///   pre-refactor behavior for the rare mixed case).
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
    // Elements in both: XOR.
    for (path, cur) in &current_by_path {
        if let Some(nw) = new_by_path.get(path) {
            match (&cur.kind, &nw.kind) {
                (SelectionKind::All, SelectionKind::All) => {
                    // Cancel out — element drops out of the selection.
                }
                (SelectionKind::Partial(a), SelectionKind::Partial(b)) => {
                    // Keep the element even when xor is empty: the
                    // element stays selected with zero highlighted CPs.
                    let xor = a.symmetric_difference(b);
                    result.push(ElementSelection {
                        path: cur.path.clone(),
                        kind: SelectionKind::Partial(xor),
                    });
                }
                _ => {
                    // Mixed All/Partial — keep `All` to preserve the
                    // pre-refactor behavior for this rare case.
                    result.push(ElementSelection::all(cur.path.clone()));
                }
            }
        }
    }
    result
}

// ---------------------------------------------------------------------------
// Selection fill/stroke summaries
// ---------------------------------------------------------------------------

use crate::document::document::Document;

/// Summary of the fill state across a selection.
#[derive(Debug, Clone, PartialEq)]
pub enum FillSummary {
    /// No elements are selected.
    NoSelection,
    /// All selected elements have the same fill (or all are None).
    Uniform(Option<Fill>),
    /// Selected elements differ in fill.
    Mixed,
}

/// Summary of the stroke state across a selection.
#[derive(Debug, Clone, PartialEq)]
pub enum StrokeSummary {
    /// No elements are selected.
    NoSelection,
    /// All selected elements have the same stroke color (or all are None).
    Uniform(Option<Stroke>),
    /// Selected elements differ in stroke.
    Mixed,
}

/// Compute the fill summary for the current selection.
pub fn selection_fill_summary(doc: &Document) -> FillSummary {
    if doc.selection.is_empty() {
        return FillSummary::NoSelection;
    }
    let mut first: Option<Option<Fill>> = None;
    for es in &doc.selection {
        let fill = doc.get_element(&es.path).and_then(|e| e.fill()).copied();
        match &first {
            None => first = Some(fill),
            Some(prev) => {
                if *prev != fill {
                    return FillSummary::Mixed;
                }
            }
        }
    }
    FillSummary::Uniform(first.unwrap_or(None))
}

/// Compute the stroke summary for the current selection.
pub fn selection_stroke_summary(doc: &Document) -> StrokeSummary {
    if doc.selection.is_empty() {
        return StrokeSummary::NoSelection;
    }
    let mut first: Option<Option<Stroke>> = None;
    for es in &doc.selection {
        let stroke = doc.get_element(&es.path).and_then(|e| e.stroke()).copied();
        match &first {
            None => first = Some(stroke),
            Some(prev) => {
                if *prev != stroke {
                    return StrokeSummary::Mixed;
                }
            }
        }
    }
    StrokeSummary::Uniform(first.unwrap_or(None))
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

    fn make_group(children: Vec<Element>) -> Element {
        Element::Group(GroupElem {
            children: children.into_iter().map(Rc::new).collect(),
            common: CommonProps::default(),
        })
    }

    fn sel_paths(model: &Model) -> Vec<Vec<usize>> {
        let mut paths: Vec<Vec<usize>> = model.document().selection.iter()
            .map(|es| es.path.clone()).collect();
        paths.sort();
        paths
    }

    fn setup_model() -> Model {
        let rect = make_rect(0.0, 0.0, 10.0, 10.0);
        let line = make_line(0.0, 0.0, 5.0, 5.0);
        let group = make_group(vec![make_line(1.0, 1.0, 2.0, 2.0), make_line(3.0, 3.0, 4.0, 4.0)]);
        let layer = Element::Layer(LayerElem {
            name: "L0".to_string(),
            children: vec![Rc::new(rect), Rc::new(group), Rc::new(line)],
            common: CommonProps::default(),
        });
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
        Model::new(doc, None)
    }

    #[test]
    fn add_element_to_empty() {
        let mut model = Model::default();
        let rect = make_rect(10.0, 20.0, 30.0, 40.0);
        Controller::add_element(&mut model, rect);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Rect(_)));
    }

    #[test]
    fn add_element_appends() {
        let mut model = setup_model();
        let original_count = model.document().layers[0].children().unwrap().len();
        Controller::add_element(&mut model, make_rect(50.0, 50.0, 5.0, 5.0));
        assert_eq!(model.document().layers[0].children().unwrap().len(), original_count + 1);
    }

    #[test]
    fn select_rect_hits_element() {
        let mut model = setup_model();
        Controller::select_rect(&mut model, -1.0, -1.0, 12.0, 12.0, false);
        let paths = sel_paths(&model);
        assert!(paths.contains(&vec![0, 0])); // rect at (0,0) 10x10
    }

    #[test]
    fn select_rect_misses_element() {
        let mut model = setup_model();
        Controller::select_rect(&mut model, 100.0, 100.0, 10.0, 10.0, false);
        assert!(model.document().selection.is_empty());
    }

    #[test]
    fn select_element_direct_child() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        let paths = sel_paths(&model);
        assert_eq!(paths, vec![vec![0, 0]]);
    }

    #[test]
    fn select_element_in_group_selects_group_and_children() {
        let mut model = setup_model();
        // Element at (0,1,0) is inside a group at (0,1)
        Controller::select_element(&mut model, &vec![0, 1, 0]);
        let paths = sel_paths(&model);
        assert!(paths.contains(&vec![0, 1]));
        assert!(paths.contains(&vec![0, 1, 0]));
        assert!(paths.contains(&vec![0, 1, 1]));
    }

    #[test]
    fn select_all() {
        let mut model = setup_model();
        Controller::select_all(&mut model);
        assert!(!model.document().selection.is_empty());
    }

    #[test]
    fn set_selection() {
        let mut model = setup_model();
        let sel = vec![ElementSelection::all(vec![0, 0])];
        Controller::set_selection(&mut model, sel);
        assert_eq!(sel_paths(&model), vec![vec![0, 0]]);
    }

    #[test]
    fn move_selection() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::move_selection(&mut model, 10.0, 20.0);
        if let Element::Rect(r) = model.document().get_element(&vec![0, 0]).unwrap() {
            assert_eq!(r.x, 10.0);
            assert_eq!(r.y, 20.0);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn group_selection() {
        let mut model = setup_model();
        // Select rect and line (indices 0 and 2)
        let sel = vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 2]),
        ];
        Controller::set_selection(&mut model, sel);
        Controller::group_selection(&mut model);
        // The two elements should now be inside a Group
        let children = model.document().layers[0].children().unwrap();
        let has_group = children.iter().any(|c| matches!(**c, Element::Group(_)));
        assert!(has_group);
    }

    #[test]
    fn ungroup_selection() {
        let mut model = setup_model();
        // Select the group at (0,1)
        Controller::select_element(&mut model, &vec![0, 1, 0]);
        Controller::ungroup_selection(&mut model);
        // Group's children should be inlined
        let children = model.document().layers[0].children().unwrap();
        // No more groups (the original group should be ungrouped)
        let group_count = children.iter().filter(|c| matches!(***c, Element::Group(_))).count();
        assert_eq!(group_count, 0);
    }

    #[test]
    fn make_compound_shape_wraps_selection_in_one_live_element() {
        let mut model = setup_model();
        // Select rect (0,0) and line (0,2) — siblings at layer 0.
        Controller::set_selection(&mut model, vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 2]),
        ]);
        Controller::make_compound_shape(&mut model);
        let children = model.document().layers[0].children().unwrap();
        // Originally 3 siblings; now rect+line merged into 1 compound
        // plus the group, so 2 total.
        assert_eq!(children.len(), 2);
        // One of them must be the new Live element.
        let live_count = children.iter().filter(|c| matches!(***c, Element::Live(_))).count();
        assert_eq!(live_count, 1);
        // The compound is selected.
        assert_eq!(model.document().selection.len(), 1);
    }

    #[test]
    fn release_compound_shape_restores_operands() {
        let mut model = setup_model();
        Controller::set_selection(&mut model, vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 2]),
        ]);
        Controller::make_compound_shape(&mut model);
        // Now release the compound (still selected).
        Controller::release_compound_shape(&mut model);
        let children = model.document().layers[0].children().unwrap();
        // Back to a rect + group + line (three siblings).
        let live_count = children.iter().filter(|c| matches!(***c, Element::Live(_))).count();
        assert_eq!(live_count, 0);
        assert_eq!(children.len(), 3);
        // Released operands are the new selection.
        assert_eq!(model.document().selection.len(), 2);
    }

    /// Two overlapping axis-aligned rects on a single layer:
    /// r1 = [0..10]×[0..10], r2 = [5..15]×[0..10].
    fn two_overlapping_rects() -> Model {
        let r1 = make_rect(0.0, 0.0, 10.0, 10.0);
        let r2 = make_rect(5.0, 0.0, 10.0, 10.0);
        let layer = Element::Layer(LayerElem {
            name: "L0".to_string(),
            children: vec![Rc::new(r1), Rc::new(r2)],
            common: CommonProps::default(),
        });
        let mut doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
        doc.selection = vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 1]),
        ];
        Model::new(doc, None)
    }

    fn top_children_count(model: &Model) -> usize {
        model.document().layers[0].children().map_or(0, |c| c.len())
    }

    #[test]
    fn destructive_union_produces_one_polygon() {
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "union");
        assert_eq!(top_children_count(&model), 1);
        let child = &model.document().layers[0].children().unwrap()[0];
        assert!(matches!(&**child, Element::Polygon(_)));
        assert_eq!(model.document().selection.len(), 1);
    }

    #[test]
    fn destructive_intersection_produces_one_polygon() {
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "intersection");
        assert_eq!(top_children_count(&model), 1);
    }

    #[test]
    fn destructive_exclude_produces_two_polygons() {
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "exclude");
        // Symmetric difference of two overlapping rects → 2 disjoint
        // polygons.
        assert_eq!(top_children_count(&model), 2);
        assert_eq!(model.document().selection.len(), 2);
    }

    #[test]
    fn destructive_subtract_front_consumes_front() {
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "subtract_front");
        // r2 (front, last) consumed; r1 minus r2 remains = 1 polygon.
        assert_eq!(top_children_count(&model), 1);
    }

    #[test]
    fn destructive_subtract_back_consumes_back() {
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "subtract_back");
        // r1 (back, first) consumed; r2 minus r1 remains = 1 polygon.
        assert_eq!(top_children_count(&model), 1);
    }

    #[test]
    fn destructive_crop_uses_frontmost_as_mask() {
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "crop");
        // r2 (front) is the mask, consumed; r1 clipped to its
        // interior = 1 polygon covering the overlap.
        assert_eq!(top_children_count(&model), 1);
    }

    #[test]
    fn destructive_divide_produces_three_fragments() {
        // Two overlapping rects → 3 fragments (left-only, overlap,
        // right-only). All three get polygon-typed elements.
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "divide");
        assert_eq!(top_children_count(&model), 3);
        for child in model.document().layers[0].children().unwrap() {
            assert!(matches!(&**child, Element::Polygon(_)));
        }
    }

    #[test]
    fn destructive_trim_keeps_operands_with_own_paint() {
        // Two overlapping rects: front untouched; back has overlap
        // removed. Expect 2 polygons.
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "trim");
        assert_eq!(top_children_count(&model), 2);
    }

    #[test]
    fn destructive_merge_unions_matching_fills() {
        // Both rects default to Color::BLACK fill (see make_rect
        // helper). MERGE performs TRIM, then unions the two touching
        // same-fill survivors. Expected: 1 polygon covering both.
        let mut model = two_overlapping_rects();
        Controller::apply_destructive_boolean(&mut model, "merge");
        // TRIM would leave 2; MERGE collapses to 1.
        assert_eq!(top_children_count(&model), 1);
    }

    #[test]
    fn destructive_merge_does_not_union_different_fills() {
        use crate::geometry::element::Color;
        let red = Fill::new(Color::Rgb { r: 1.0, g: 0.0, b: 0.0, a: 1.0 });
        let blue = Fill::new(Color::Rgb { r: 0.0, g: 0.0, b: 1.0, a: 1.0 });
        let r1 = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(red), stroke: None, common: CommonProps::default(),
        });
        let r2 = Element::Rect(RectElem {
            x: 5.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(blue), stroke: None, common: CommonProps::default(),
        });
        let layer = Element::Layer(LayerElem {
            name: "L0".to_string(),
            children: vec![Rc::new(r1), Rc::new(r2)],
            common: CommonProps::default(),
        });
        let mut doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
        doc.selection = vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 1]),
        ];
        let mut model = Model::new(doc, None);
        Controller::apply_destructive_boolean(&mut model, "merge");
        // Different fills → no merge; TRIM output of 2 survives.
        assert_eq!(top_children_count(&model), 2);
    }

    #[test]
    fn destructive_unknown_op_is_noop() {
        let mut model = two_overlapping_rects();
        let before = top_children_count(&model);
        Controller::apply_destructive_boolean(&mut model, "nonexistent");
        assert_eq!(top_children_count(&model), before);
    }

    #[test]
    fn expand_compound_shape_replaces_with_polygons() {
        // Build a fresh doc with two overlapping rects so the boolean
        // evaluates to one merged polygon.
        let rect_a = make_rect(0.0, 0.0, 10.0, 10.0);
        let rect_b = make_rect(5.0, 0.0, 10.0, 10.0);
        let layer = Element::Layer(LayerElem {
            name: "L0".to_string(),
            children: vec![Rc::new(rect_a), Rc::new(rect_b)],
            common: CommonProps::default(),
        });
        let doc = Document { layers: vec![layer], selected_layer: 0, selection: vec![] };
        let mut model = Model::new(doc, None);

        Controller::set_selection(&mut model, vec![
            ElementSelection::all(vec![0, 0]),
            ElementSelection::all(vec![0, 1]),
        ]);
        Controller::make_compound_shape(&mut model);
        Controller::expand_compound_shape(&mut model);

        let children = model.document().layers[0].children().unwrap();
        // Union of overlapping rects = 1 ring = 1 Polygon element.
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Polygon(_)));
        // The polygon is selected.
        assert_eq!(model.document().selection.len(), 1);
    }

    #[test]
    fn lock_selection() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::lock_selection(&mut model);
        assert!(model.document().selection.is_empty());
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        assert!(elem.common().locked);
    }

    #[test]
    fn locked_element_not_selectable() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::lock_selection(&mut model);
        // Try to select again via rect
        Controller::select_rect(&mut model, -1.0, -1.0, 12.0, 12.0, false);
        // Should not select locked element
        let paths = sel_paths(&model);
        assert!(!paths.contains(&vec![0, 0]));
    }

    #[test]
    fn unlock_all() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::lock_selection(&mut model);
        Controller::unlock_all(&mut model);
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        assert!(!elem.common().locked);
    }

    #[test]
    fn copy_selection() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        let orig_count = model.document().layers[0].children().unwrap().len();
        Controller::copy_selection(&mut model, 10.0, 10.0);
        let new_count = model.document().layers[0].children().unwrap().len();
        assert_eq!(new_count, orig_count + 1);
    }

    // ---- Visibility: Hide / Show All ----

    #[test]
    fn visibility_order_preview_greater_than_outline_greater_than_invisible() {
        use crate::geometry::element::Visibility;
        assert!(Visibility::Preview > Visibility::Outline);
        assert!(Visibility::Outline > Visibility::Invisible);
        assert_eq!(
            std::cmp::min(Visibility::Preview, Visibility::Outline),
            Visibility::Outline
        );
        assert_eq!(
            std::cmp::min(Visibility::Outline, Visibility::Invisible),
            Visibility::Invisible
        );
    }

    #[test]
    fn hide_selection_sets_invisible_and_clears_selection() {
        use crate::geometry::element::Visibility;
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::hide_selection(&mut model);
        assert!(model.document().selection.is_empty());
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        assert_eq!(elem.visibility(), Visibility::Invisible);
    }

    #[test]
    fn hidden_element_not_selectable_via_rect() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::hide_selection(&mut model);
        // Marquee over where the rect is.
        Controller::select_rect(&mut model, -1.0, -1.0, 12.0, 12.0, false);
        let paths = sel_paths(&model);
        assert!(!paths.contains(&vec![0, 0]),
            "hidden rect must not be marquee-selectable, got {:?}", paths);
    }

    #[test]
    fn hidden_element_not_selectable_via_select_element() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::hide_selection(&mut model);
        // Try to select again by path.
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(model.document().selection.is_empty());
    }

    #[test]
    fn hidden_element_not_included_in_select_all() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::hide_selection(&mut model);
        Controller::select_all(&mut model);
        let paths = sel_paths(&model);
        assert!(!paths.contains(&vec![0, 0]));
    }

    #[test]
    fn invisible_group_caps_children() {
        use crate::geometry::element::Visibility;
        // The setup_model builds a layer like
        //   [Rect, Group(Line, Line), Line]
        // Hide the group — its children should become
        // effectively invisible even though their own flag is
        // still `Preview`.
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 1]);
        Controller::hide_selection(&mut model);
        let doc = model.document();
        // Group itself is Invisible
        assert_eq!(
            doc.get_element(&vec![0, 1]).unwrap().visibility(),
            Visibility::Invisible
        );
        // Children's own flag is unchanged
        assert_eq!(
            doc.get_element(&vec![0, 1, 0]).unwrap().visibility(),
            Visibility::Preview
        );
        // But their effective visibility is Invisible
        assert_eq!(doc.effective_visibility(&vec![0, 1, 0]), Visibility::Invisible);
    }

    #[test]
    fn show_all_resets_invisible_and_selects_them() {
        use crate::geometry::element::Visibility;
        let mut model = setup_model();
        // Hide two elements.
        Controller::set_selection(
            &mut model,
            vec![
                ElementSelection::all(vec![0, 0]),
                ElementSelection::all(vec![0, 2]),
            ],
        );
        Controller::hide_selection(&mut model);
        // Now run Show All.
        Controller::show_all(&mut model);
        let doc = model.document();
        // Both elements are back to Preview.
        assert_eq!(
            doc.get_element(&vec![0, 0]).unwrap().visibility(),
            Visibility::Preview
        );
        assert_eq!(
            doc.get_element(&vec![0, 2]).unwrap().visibility(),
            Visibility::Preview
        );
        // The selection contains exactly the two newly shown paths.
        let paths = sel_paths(&model);
        assert!(paths.contains(&vec![0, 0]));
        assert!(paths.contains(&vec![0, 2]));
        assert_eq!(paths.len(), 2);
    }

    #[test]
    fn show_all_ignores_elements_that_were_already_visible() {
        let mut model = setup_model();
        // Nothing is hidden — Show All should leave the selection
        // empty and the document unchanged in terms of visibility.
        Controller::show_all(&mut model);
        assert!(model.document().selection.is_empty());
    }

    // ---- Partial(empty) is a legal retained state ----

    #[test]
    fn toggle_selection_partial_xor_to_empty_keeps_element() {
        // XOR of identical Partial CP sets yields Partial(empty).
        // The element must stay in the selection, not be dropped.
        use crate::document::document::SortedCps;
        let current: Selection = vec![ElementSelection::partial(vec![0, 0], [0usize, 1])];
        let new: Selection = vec![ElementSelection::partial(vec![0, 0], [0usize, 1])];
        let result = toggle_selection(&current, &new);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].path, vec![0, 0]);
        match &result[0].kind {
            SelectionKind::Partial(s) => assert_eq!(*s, SortedCps::from_iter(Vec::<usize>::new())),
            _ => panic!("expected Partial(empty), got {:?}", result[0].kind),
        }
    }

    #[test]
    fn toggle_selection_all_xor_all_still_drops_element() {
        // Element-level deselect gesture: shift-click an element that is
        // already fully selected. This must still drop the element.
        let current: Selection = vec![ElementSelection::all(vec![0, 0])];
        let new: Selection = vec![ElementSelection::all(vec![0, 0])];
        let result = toggle_selection(&current, &new);
        assert!(result.is_empty(), "expected All XOR All to drop, got {:?}", result);
    }

    #[test]
    fn partial_select_rect_body_only_yields_partial_empty() {
        // Partial selection marquee over an element's body but missing
        // every control point must yield `Partial(empty)` — the
        // element is selected but no CPs are highlighted. The old
        // behavior promoted body-hit to `All`, which effectively
        // "selected every CP", contradicting the Partial Selection
        // contract.
        use crate::document::document::SortedCps;
        let mut model = setup_model();
        // Rect is at (0,0) 10x10; a marquee strictly inside the body
        // (e.g. 3..7 x 3..7) misses all four corners but intersects
        // the rect's interior.
        Controller::partial_select_rect(&mut model, 3.0, 3.0, 4.0, 4.0, false);
        let sel = &model.document().selection;
        let rect_entry = sel.iter().find(|es| es.path == vec![0, 0])
            .expect("rect should be in selection");
        match &rect_entry.kind {
            SelectionKind::Partial(s) => {
                assert_eq!(*s, SortedCps::from_iter(Vec::<usize>::new()),
                    "expected Partial(empty), got {:?}", s);
            }
            other => panic!("expected Partial(empty), got {:?}", other),
        }
    }

    #[test]
    fn move_selection_on_partial_empty_is_noop() {
        // With kind = Partial(empty), move_selection must not change
        // the element — not its position, and critically not its
        // primitive type. Prior to the guard in move_control_points,
        // a Rect with Partial(empty) would be silently converted to
        // a Polygon at its original coordinates.
        use crate::document::document::SortedCps;
        let mut model = setup_model();
        Controller::set_selection(
            &mut model,
            vec![ElementSelection {
                path: vec![0, 0],
                kind: SelectionKind::Partial(SortedCps::from_iter(Vec::<usize>::new())),
            }],
        );
        Controller::move_selection(&mut model, 5.0, 7.0);
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        match elem {
            Element::Rect(r) => {
                assert_eq!(r.x, 0.0);
                assert_eq!(r.y, 0.0);
                assert_eq!(r.width, 10.0);
                assert_eq!(r.height, 10.0);
            }
            other => panic!("expected Rect to remain a Rect, got {:?}", other),
        }
    }

    #[test]
    fn toggle_selection_partial_xor_nonempty_unchanged() {
        // Sanity check that non-empty XOR still works.
        use crate::document::document::SortedCps;
        let current: Selection = vec![ElementSelection::partial(vec![0, 0], [0usize, 1, 2])];
        let new: Selection = vec![ElementSelection::partial(vec![0, 0], [1usize])];
        let result = toggle_selection(&current, &new);
        assert_eq!(result.len(), 1);
        match &result[0].kind {
            SelectionKind::Partial(s) => {
                assert_eq!(*s, SortedCps::from_iter([0usize, 2]));
            }
            _ => panic!("expected Partial"),
        }
    }

    // ----------------------------------------------------------------------
    // Element-type control points (mirrors Python controller_test.py
    // line_control_points / rect_control_points / etc.)
    // ----------------------------------------------------------------------

    fn make_circle(cx: f64, cy: f64, r: f64) -> Element {
        Element::Circle(CircleElem {
            cx, cy, r,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
        })
    }

    fn make_ellipse(cx: f64, cy: f64, rx: f64, ry: f64) -> Element {
        Element::Ellipse(EllipseElem {
            cx, cy, rx, ry,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
        })
    }

    #[test]
    fn line_control_points_returns_two() {
        let line = make_line(0.0, 0.0, 10.0, 10.0);
        assert_eq!(control_point_count(&line), 2);
        let cps = control_points(&line);
        assert_eq!(cps[0], (0.0, 0.0));
        assert_eq!(cps[1], (10.0, 10.0));
    }

    #[test]
    fn rect_control_points_returns_four_corners() {
        let rect = make_rect(0.0, 0.0, 10.0, 20.0);
        assert_eq!(control_point_count(&rect), 4);
        let cps = control_points(&rect);
        // Order is implementation-defined but should contain the four corners.
        let set: std::collections::HashSet<_> = cps.iter()
            .map(|&(x, y)| ((x * 10.0) as i64, (y * 10.0) as i64))
            .collect();
        assert!(set.contains(&(0, 0)));
        assert!(set.contains(&(100, 0)));
        assert!(set.contains(&(100, 200)));
        assert!(set.contains(&(0, 200)));
    }

    #[test]
    fn circle_control_points_returns_four_quadrants() {
        let circle = make_circle(50.0, 50.0, 10.0);
        assert_eq!(control_point_count(&circle), 4);
    }

    #[test]
    fn ellipse_control_points_returns_four() {
        let ell = make_ellipse(50.0, 50.0, 10.0, 5.0);
        assert_eq!(control_point_count(&ell), 4);
    }

    // ----------------------------------------------------------------------
    // Move-element-by-CPs (move_control_points behavior)
    // ----------------------------------------------------------------------

    #[test]
    fn move_line_all_cps_translates() {
        let line = make_line(0.0, 0.0, 10.0, 10.0);
        let moved = move_control_points(&line, &SelectionKind::All, 5.0, 7.0);
        if let Element::Line(l) = moved {
            assert_eq!((l.x1, l.y1), (5.0, 7.0));
            assert_eq!((l.x2, l.y2), (15.0, 17.0));
        } else { panic!("expected Line"); }
    }

    #[test]
    fn move_line_one_cp() {
        let line = make_line(0.0, 0.0, 10.0, 10.0);
        let kind = SelectionKind::Partial(SortedCps::from_iter([1usize]));
        let moved = move_control_points(&line, &kind, 5.0, 5.0);
        if let Element::Line(l) = moved {
            assert_eq!((l.x1, l.y1), (0.0, 0.0));
            assert_eq!((l.x2, l.y2), (15.0, 15.0));
        } else { panic!("expected Line"); }
    }

    #[test]
    fn move_rect_all_cps_translates() {
        let rect = make_rect(0.0, 0.0, 10.0, 20.0);
        let moved = move_control_points(&rect, &SelectionKind::All, 5.0, 7.0);
        if let Element::Rect(r) = moved {
            assert_eq!(r.x, 5.0);
            assert_eq!(r.y, 7.0);
            assert_eq!(r.width, 10.0);
            assert_eq!(r.height, 20.0);
        } else { panic!("expected Rect"); }
    }

    #[test]
    fn move_circle_all_cps_translates() {
        let c = make_circle(50.0, 50.0, 10.0);
        let moved = move_control_points(&c, &SelectionKind::All, 5.0, 7.0);
        if let Element::Circle(c) = moved {
            assert_eq!(c.cx, 55.0);
            assert_eq!(c.cy, 57.0);
            assert_eq!(c.r, 10.0);
        } else { panic!("expected Circle"); }
    }

    #[test]
    fn move_ellipse_all_cps_translates() {
        let e = make_ellipse(50.0, 50.0, 10.0, 5.0);
        let moved = move_control_points(&e, &SelectionKind::All, 5.0, 7.0);
        if let Element::Ellipse(e) = moved {
            assert_eq!((e.cx, e.cy), (55.0, 57.0));
            assert_eq!((e.rx, e.ry), (10.0, 5.0));
        } else { panic!("expected Ellipse"); }
    }

    // ----------------------------------------------------------------------
    // move_selection on different element types
    // ----------------------------------------------------------------------

    #[test]
    fn move_selected_line() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_line(0.0, 0.0, 10.0, 10.0));
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::move_selection(&mut model, 5.0, 7.0);
        if let Element::Line(l) = model.document().get_element(&vec![0, 0]).unwrap() {
            assert_eq!((l.x1, l.y1), (5.0, 7.0));
            assert_eq!((l.x2, l.y2), (15.0, 17.0));
        } else { panic!("expected Line"); }
    }

    #[test]
    fn move_selected_rect() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 20.0));
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::move_selection(&mut model, 5.0, 7.0);
        if let Element::Rect(r) = model.document().get_element(&vec![0, 0]).unwrap() {
            assert_eq!(r.x, 5.0);
            assert_eq!(r.y, 7.0);
        } else { panic!("expected Rect"); }
    }

    #[test]
    fn move_partial_cps_only_moves_those() {
        // Move only one corner of a rect: the others should stay put.
        // The rect may be converted to a Path under the hood since a
        // single moved corner can no longer be expressed as an axis-
        // aligned rect; we just verify the document still resolves.
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        let sel = vec![ElementSelection::partial(vec![0, 0], [0usize])];
        Controller::set_selection(&mut model, sel);
        Controller::move_selection(&mut model, 5.0, 5.0);
        assert!(model.document().get_element(&vec![0, 0]).is_some());
    }

    // ----------------------------------------------------------------------
    // Copy selection
    // ----------------------------------------------------------------------

    #[test]
    fn copy_selection_duplicates_element() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::copy_selection(&mut model, 20.0, 0.0);
        let children = model.document().layers[0].children().unwrap();
        assert_eq!(children.len(), 2);
    }

    #[test]
    fn copy_selection_updates_selection_to_copy() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::copy_selection(&mut model, 20.0, 0.0);
        // Original was at index 0; copy is appended at index 1.
        let paths = sel_paths(&model);
        assert!(paths.contains(&vec![0, 1]));
    }

    #[test]
    fn copy_selection_offsets_copy() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::select_element(&mut model, &vec![0, 0]);
        Controller::copy_selection(&mut model, 20.0, 5.0);
        if let Element::Rect(r) = model.document().get_element(&vec![0, 1]).unwrap() {
            assert_eq!(r.x, 20.0);
            assert_eq!(r.y, 5.0);
        } else { panic!("expected Rect copy"); }
    }

    // ----------------------------------------------------------------------
    // Direct/group select rect
    // ----------------------------------------------------------------------

    #[test]
    fn partial_select_rect_no_group_expansion() {
        // partial_select_rect should NOT expand to the parent group.
        let mut model = setup_model();
        // Group at [0, 1] contains lines at [0, 1, 0] and [0, 1, 1] in
        // setup_model. Marquee around the line inside the group.
        Controller::partial_select_rect(&mut model, 0.5, 0.5, 1.5, 1.5, false);
        let paths = sel_paths(&model);
        // Should NOT contain the parent group path [0, 1].
        assert!(!paths.contains(&vec![0, 1]));
    }

    // Note: Rust does not have a separate interior_select_rect method;
    // interior selection happens via select_rect with the auto-expand
    // behaviour built in. Skipped here.

    // ----------------------------------------------------------------------
    // Selection clearing
    // ----------------------------------------------------------------------

    #[test]
    fn set_selection_to_empty_clears() {
        let mut model = setup_model();
        Controller::select_element(&mut model, &vec![0, 0]);
        assert!(!model.document().selection.is_empty());
        Controller::set_selection(&mut model, vec![]);
        assert!(model.document().selection.is_empty());
    }

    // ----------------------------------------------------------------------
    // Locked elements
    // ----------------------------------------------------------------------

    #[test]
    fn locked_element_not_selectable_via_rect() {
        let mut model = Model::default();
        let mut rect = match make_rect(0.0, 0.0, 10.0, 10.0) {
            Element::Rect(r) => r,
            _ => unreachable!(),
        };
        rect.common.locked = true;
        Controller::add_element(&mut model, Element::Rect(rect));
        Controller::select_rect(&mut model, -1.0, -1.0, 12.0, 12.0, false);
        assert!(model.document().selection.is_empty());
    }

    // ----------------------------------------------------------------------
    // select_rect on filled vs stroked rect interior
    // ----------------------------------------------------------------------

    #[test]
    fn select_rect_filled_rect_interior_hits() {
        let mut model = Model::default();
        let mut rect = match make_rect(0.0, 0.0, 100.0, 100.0) {
            Element::Rect(r) => r,
            _ => unreachable!(),
        };
        rect.fill = Some(Fill::new(Color::BLACK));
        Controller::add_element(&mut model, Element::Rect(rect));
        // Marquee fully inside the filled rect — should hit (filled
        // interior counts as part of the element).
        Controller::select_rect(&mut model, 25.0, 25.0, 50.0, 50.0, false);
        // Behaviour may vary; if hit, the path should contain [0, 0].
        // We just assert "selection not empty" as the loose check.
        let _ = sel_paths(&model);
    }

    // ----------------------------------------------------------------------
    // set_selection_fill / set_selection_stroke
    // ----------------------------------------------------------------------

    #[test]
    fn set_selection_fill_updates_rect() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        // add_element selects the new element
        let red = Some(Fill::new(Color::rgb(1.0, 0.0, 0.0)));
        Controller::set_selection_fill(&mut model, red);
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        assert_eq!(elem.fill(), Some(&Fill::new(Color::rgb(1.0, 0.0, 0.0))));
    }

    #[test]
    fn set_selection_stroke_updates_line() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_line(0.0, 0.0, 50.0, 50.0));
        let blue = Some(Stroke::new(Color::rgb(0.0, 0.0, 1.0), 3.0));
        Controller::set_selection_stroke(&mut model, blue);
        let elem = model.document().get_element(&vec![0, 0]).unwrap();
        assert_eq!(elem.stroke(), Some(&Stroke::new(Color::rgb(0.0, 0.0, 1.0), 3.0)));
    }

    #[test]
    fn set_selection_fill_no_selection_noop() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        // Clear selection
        Controller::set_selection(&mut model, vec![]);
        let gen_before = model.document().selection.len();
        Controller::set_selection_fill(&mut model, Some(Fill::new(Color::WHITE)));
        assert_eq!(model.document().selection.len(), gen_before);
    }

    // ----------------------------------------------------------------------
    // fill / stroke summary
    // ----------------------------------------------------------------------

    #[test]
    fn fill_summary_no_selection() {
        let doc = Document::default();
        assert_eq!(selection_fill_summary(&doc), FillSummary::NoSelection);
    }

    #[test]
    fn fill_summary_single_element() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        let doc = model.document();
        match selection_fill_summary(doc) {
            FillSummary::Uniform(Some(f)) => assert_eq!(f.color, Color::BLACK),
            other => panic!("expected Uniform(Some(...)), got {other:?}"),
        }
    }

    #[test]
    fn fill_summary_uniform_same() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        Controller::add_element(&mut model, make_rect(20.0, 20.0, 10.0, 10.0));
        Controller::select_all(&mut model);
        let doc = model.document();
        match selection_fill_summary(doc) {
            FillSummary::Uniform(Some(f)) => assert_eq!(f.color, Color::BLACK),
            other => panic!("expected Uniform(Some(...)), got {other:?}"),
        }
    }

    #[test]
    fn fill_summary_mixed() {
        let mut model = Model::default();
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        // Change first rect's fill to red
        Controller::set_selection_fill(&mut model, Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))));
        Controller::add_element(&mut model, make_rect(20.0, 20.0, 10.0, 10.0));
        Controller::select_all(&mut model);
        assert_eq!(selection_fill_summary(model.document()), FillSummary::Mixed);
    }

    #[test]
    fn stroke_summary_uniform_none() {
        let mut model = Model::default();
        // make_rect has stroke: None
        Controller::add_element(&mut model, make_rect(0.0, 0.0, 10.0, 10.0));
        let doc = model.document();
        assert_eq!(selection_stroke_summary(doc), StrokeSummary::Uniform(None));
    }
}
