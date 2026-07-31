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
        // ONE ROUND KIND, so `circle` is DERIVED (JYH, 2026-07-30). Before
        // that the token was whichever SVG tag the element arrived as, which
        // is PROVENANCE: `apply_scale` composes a matrix onto common.transform
        // and never touches radii, so a `circle` stayed typed `circle` while
        // being drawn as an egg. The Circle checkbox answered "which tag was
        // this" -- a question no artist asks.
        //
        // AS AUTHORED, DELIBERATELY: common.transform is not consulted. No
        // other token accounts for transforms either -- a sheared rect is
        // still `rectangle`, a rotated text still `text` -- and making this the
        // one token that reads the matrix would be a second rule nobody could
        // predict from the first.
        Element::Ellipse(e) if e.rx == e.ry => "circle",
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

/// Every type token the filter menu can offer, in `layers.yaml` order.
///
/// The CHECKED set is what the artist manipulates and what
/// `panel.type_filter` stores; the keep-computation below wants the
/// complement. This list is the universe that complement is taken against, so
/// it must match `lp_filter_button.items` exactly —
/// `scripts/check_layers_type_filter.py` asserts that against the shipping YAML
/// and against both ports, in the same run.
pub const ALL_TYPE_TOKENS: [&str; 12] = [
    "layer", "group", "path", "rectangle", "circle", "ellipse",
    "polyline", "polygon", "text", "text_path", "line", "live",
];

/// The hidden-type set implied by a CHECKED set.
///
/// JYH's ruling, council 2026-07-30: *a checked type lists all its elements,
/// plus their ancestors; nothing checked — the default — is the same as
/// checking everything.*
///
/// Stated that way the ancestor rule stops being an awkward exception and
/// becomes half the definition. And the algorithm did not have to move: checked
/// and unchecked are COMPLEMENTS over the menu, so the shipping keep-set was
/// already computing the ruled rule. The implementation was never wrong — the
/// spec sentence was, and it is rewritten.
///
/// The empty case is the exception and it is load-bearing: an empty filter must
/// mean EVERYTHING, not nothing. Without it, unticking the last box would blank
/// the panel, and `type_filter`'s declared default of `[]` would render an empty
/// tree on first open.
pub fn hidden_from_checked(checked: &HashSet<String>) -> HashSet<String> {
    if checked.is_empty() {
        return HashSet::new();
    }
    ALL_TYPE_TOKENS
        .iter()
        .filter(|t| !checked.contains(**t))
        .map(|t| t.to_string())
        .collect()
}

#[cfg(test)]
mod checked_semantics_tests {
    use super::*;

    fn set(v: &[&str]) -> HashSet<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    /// THE EXCEPTION, and the reason it exists. `type_filter` defaults to `[]`,
    /// so without this the panel would open with an empty tree.
    #[test]
    fn nothing_checked_hides_nothing() {
        assert!(hidden_from_checked(&HashSet::new()).is_empty());
    }

    /// Checking one type hides the other eleven.
    #[test]
    fn checking_one_type_hides_the_rest() {
        let hidden = hidden_from_checked(&set(&["circle"]));
        assert_eq!(hidden.len(), ALL_TYPE_TOKENS.len() - 1);
        assert!(!hidden.contains("circle"));
        assert!(hidden.contains("rectangle"));
        // `live` is in the universe now (council Q1.2). Before the Compound
        // Shape menu entry landed it was not, so a live element could never be
        // checked and would have vanished under ANY filter.
        assert!(hidden.contains("live"));
    }

    /// Checking everything is the same as checking nothing, observably.
    #[test]
    fn checking_every_type_hides_nothing() {
        let all = set(&ALL_TYPE_TOKENS);
        assert!(hidden_from_checked(&all).is_empty());
    }
}
