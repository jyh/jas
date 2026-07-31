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

/// What a `lp_filter_button` item DOES when clicked, read from its declared
/// `type` and never inferred from the fields it happens to carry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuRowKind {
    /// `type: toggle` — a type token that goes in or out of the CHECKED set.
    Toggle,
    /// `type: action` — a named behaviour, carried verbatim from the item's
    /// `action` key and routed by `checked_after_action`.
    Action(String),
}

/// One rendered row of the Layers filter menu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MenuRow {
    pub label: String,
    pub value: String,
    pub kind: MenuRowKind,
}

/// The menu rows a `lp_filter_button`-shaped `items` list declares, in
/// declaration order.
///
/// WHY THIS FUNCTION EXISTS, and it is not tidiness. Until 2026-07-30
/// `render_layers_filter_dropdown` built its rows by collecting every item that
/// carried a `label` and a `value` — and the menu's FIRST item is not a type:
///
/// ```yaml
/// - { label: "All", value: __all__, type: action, action: clear_layers_type_filter }
/// ```
///
/// so `All` rendered as a checkbox. Clicking it CHECKED the token `__all__`,
/// nothing answers `__all__`, and under CHECKED semantics the hidden set is the
/// complement of the checked set over the menu — the whole vocabulary. The one
/// row whose entire purpose is *show me everything again* was the row that
/// showed nothing. JasSwift's `renderDropdown` dispatched on the declared type
/// from the day both were written; this brings this port to it.
///
/// AN UNRECOGNISED OR ABSENT `type` YIELDS NO ROW. Treating the presence of
/// `label` + `value` as licence to render a checkbox is the defect itself, so a
/// kind this port does not know is dropped rather than guessed at. The failure
/// that produces — an item missing from the menu — is loud and local; the one it
/// replaces was a blank tree three layers away. A shipping item that lost its
/// `type: toggle` would also fall under `check_layers_type_filter.py`'s exact
/// floor of twelve menu values, so the drop cannot pass unseen.
///
/// Twin: `layersFilterMenuRows` in
/// JasSwift/Sources/Interpreter/YamlPanelBodyView.swift. Both answer the `menu`
/// block of `test_fixtures/view_state/layers_type_filter.json`.
pub fn menu_rows(items: &[serde_json::Value]) -> Vec<MenuRow> {
    items
        .iter()
        .filter_map(|item| {
            let label = item.get("label").and_then(|v| v.as_str())?;
            let value = item.get("value").and_then(|v| v.as_str())?;
            let kind = match item.get("type").and_then(|v| v.as_str()) {
                Some("toggle") => MenuRowKind::Toggle,
                Some("action") => MenuRowKind::Action(
                    item.get("action").and_then(|v| v.as_str())?.to_string(),
                ),
                _ => return None,
            };
            Some(MenuRow { label: label.to_string(), value: value.to_string(), kind })
        })
        .collect()
}

/// The CHECKED set after invoking a declared menu action, or `None` when the
/// action is not one this port knows.
///
/// `None` RATHER THAN A FALLBACK, deliberately. An unknown action answered with
/// the empty set would turn every future typo into *show everything*, and an
/// unknown action answered with the unchanged set would make a real action
/// silently inert. Refusing lets the caller render the row without pretending it
/// works — and guessing a meaning for a token nobody defined is the exact move
/// that made `__all__` a type.
///
/// `checked` is unused today because the single declared action, `All`, does not
/// read the current set. It is a parameter because the next one will: solo,
/// invert, and *check every type* are all stated in `layers.yaml`'s vocabulary
/// as functions of what is already checked.
pub fn checked_after_action(action: &str, checked: &HashSet<String>) -> Option<HashSet<String>> {
    let _ = checked;
    match action {
        // `layers.yaml`: "The 'All' item at the top restores the default in one
        // click." The default is the empty set, which under the ruled semantics
        // means everything is listed.
        "clear_layers_type_filter" => Some(HashSet::new()),
        _ => None,
    }
}

/// Whether an action's effect is ALREADY IN FORCE — what the tick on an action
/// row means, as against a toggle's tick, which means "this type is checked".
///
/// Stated as *invoking it would change nothing* rather than as a hand-written
/// per-action predicate, so a new action cannot arrive with a tick rule that
/// contradicts what its own invocation does. An unknown action is never in
/// force: it is inert, not satisfied.
pub fn action_is_in_force(action: &str, checked: &HashSet<String>) -> bool {
    checked_after_action(action, checked).as_ref() == Some(checked)
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
