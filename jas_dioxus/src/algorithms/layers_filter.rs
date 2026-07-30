//! The Layers-panel type filter: which tree rows survive a set of hidden
//! element types.
//!
//! WHY THIS IS AN ALGORITHM AND NOT PART OF THE RENDERER. It lived inline in
//! `interpreter::renderer`, which is `#[cfg(feature = "web")]`, so the shared
//! corpus reader could not import it in a native build and
//! `check_native_core_tests.py` red immediately. That gate's advice is the right
//! advice — *prefer moving the web-free helper it needs into a non-gated module*
//! — and it applies twice over here: this is a pure function of paths and type
//! tokens with no frontend in it, and port six (a native Windows frontend over
//! the Rust core) needs the Layers filter without ever linking the web renderer.
//!
//! The twin is `layersTypeValue` / `layersTypeFilterKeep` in
//! JasSwift/Sources/Interpreter/YamlPanelBodyView.swift, and the shared
//! definition both ports answer to is
//! `test_fixtures/view_state/layers_type_filter.json`.

use crate::geometry::element::Element;
use std::collections::HashSet;

/// The token the Layers type filter matches an element against, in the spelling
/// `workspace/panels/layers.yaml`'s `lp_filter_button` uses for its `items`
/// values.
///
/// DERIVED FROM THE ELEMENT, NEVER FROM ITS DISPLAY NAME. Until 2026-07-29 the
/// filter recovered this by parsing the row label: `<Rectangle>` was matched
/// apart, and anything else fell through to `""`. That worked by construction
/// while only Layers could carry a name — and the commit that let EVERY element
/// carry one ("Tree row reads common.name; drop the is_layer rename gate")
/// silently made every NAMED element unfilterable, because its label is then
/// "roof" rather than `<Rectangle>` and `""` matches nothing hidden. The gate
/// that could have caught it was deferred in `transcripts/LAYERS_TESTS.md`
/// (LYR-091) for the exact reason that naming a non-layer was impossible at the
/// time; nobody revisited it when it became possible.
///
/// The general shape, worth more than the instance: a display name is a
/// PRESENTATION of an element and its type is a FACT about it, so reading the
/// fact back out of the presentation is lossy the moment presentation gains a
/// second form. `layers.yaml` is precise about this where it means names —
/// search matches "whose name (or auto-generated type name like `<Path>`)" —
/// and the filter clause says only *type*, and *all*.
///
/// JasSwift's `layersTypeValue` has always matched on the element; this brings
/// this port to it rather than the other way round.
pub fn type_value(elem: &Element) -> &'static str {
    match elem {
        Element::Line(_) => "line",
        Element::Rect(_) => "rectangle",
        Element::Circle(_) => "circle",
        Element::Ellipse(_) => "ellipse",
        Element::Polyline(_) => "polyline",
        Element::Polygon(_) => "polygon",
        Element::Path(_) => "path",
        Element::Text(_) => "text",
        Element::TextPath(_) => "text_path",
        Element::Group(_) => "group",
        Element::Layer(_) => "layer",
        // No `items` entry offers "live", so a Live element cannot be hidden in
        // either port today. Spelled the same as JasSwift's `.live` arm so that
        // stays a SHARED gap rather than becoming a divergence the moment the
        // menu gains the option — at which point both ports already answer it.
        Element::Live(_) => "live",
    }
}

/// Paths surviving the Layers type filter, given each row as
/// `(path, type_value)`.
///
/// An ancestor of a surviving row is kept even when its own type is hidden: a
/// tree cannot draw a child without its parent row. That makes hiding a
/// CONTAINER type inoperative whenever any descendant survives, which is a
/// deliberate consequence and not obviously what `layers.yaml`'s "hides all
/// elements of that type" intends. JasSwift does the identical thing, so it is a
/// shared question for council rather than a divergence — and both readings are
/// pinned by the `council: R1` vectors in the shared fixture, so whichever way
/// it is ruled, the ruling has one place to land.
pub fn type_filter_keep<'a>(
    rows: impl IntoIterator<Item = (&'a [usize], &'a str)>,
    hidden: &HashSet<String>,
) -> HashSet<Vec<usize>> {
    let visible: HashSet<Vec<usize>> = rows
        .into_iter()
        .filter(|(_, ty)| !hidden.contains(*ty))
        .map(|(path, _)| path.to_vec())
        .collect();
    let mut keep = visible.clone();
    for p in &visible {
        for i in 1..p.len() {
            keep.insert(p[..i].to_vec());
        }
    }
    keep
}
