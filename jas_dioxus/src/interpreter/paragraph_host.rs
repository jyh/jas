//! **W2b-7 — the Paragraph panel's apply law, out from behind `feature = "web"`.**
//!
//! Companion to [`super::character_host`] (W2b-6) and built to the same
//! boundary: **the DOCUMENT write moves into this ungated host; the PANEL
//! DISPLAY write stays web-side.** Before this module the whole law lived in
//! `#[cfg(feature = "web")] workspace::app_state`, so the engine could not
//! reach any of it — `workspace/mod.rs` and `interpreter/mod.rs` both gate
//! their halves. Nothing here is new behaviour; every rule was already
//! implemented web-side and is moved, not re-authored.
//!
//! ## ⛔ Paragraph is NOT character, in two ways that decide this file's shape
//!
//! 1. **There is no reference law to port.** `character_law.py` states the
//!    Character law and both ports obey it, so W2b-6 was purely about
//!    reachability. **The reference interpreter implements no paragraph law at
//!    all** — `paragraph` does not occur anywhere under `workspace_interpreter/`
//!    in any case, and the apparent hits on its field names are a different
//!    subject wearing the same word (`test_align_panel.py` is the *Align
//!    objects* panel, whose `align_left_button` is unrelated to this panel's
//!    `pg_align_left`) plus arbitrary store-key fixtures in `test_effects.py`.
//!    ⇒ **The only two implementations are Rust and Swift**
//!    (`JasSwift/Sources/Interpreter/ParagraphPanelSync.swift`), which is
//!    exactly the pair that carries this campaign's divergence base rate: both
//!    confirmed `RO`-class divergences were Rust ↔ Swift. There is no third
//!    voice to arbitrate, so equivalence here is a claim about two, not three.
//!
//! 2. **The apply is WHOLE-PANEL, not field-scoped.** Character's edited field
//!    selects a group and only that group's attributes are written, which is
//!    what its clobber guard exists to pin. A paragraph edit writes *every*
//!    wrapper attribute from panel state on every call — so there is no group
//!    table, no per-key restriction, and [`apply_to_selection`] takes no
//!    `edited` key. The mutual exclusions live in [`ParagraphPanelState::set_field`]
//!    (the alignment radio, and bullets ↔ numbered-list), upstream of the write.

use crate::geometry::tspan::Tspan;

/// The Paragraph panel's id: the store scope its keys live in.
/// `workspace/panels/paragraph.yaml`'s own top-level `id`.
pub const PARAGRAPH_PANEL: &str = "paragraph_panel_content";

/// Every panel field whose write reaches the DOCUMENT, spelled as
/// `workspace/panels/paragraph.yaml` declares it.
///
/// ⚠️ **This is 16, while the panel has 15 body inputs.** The sixteenth,
/// `hanging_punctuation`, is reachable only through the panel MENU
/// (`paragraph.yaml`'s `menu:` → `action: toggle_hanging_punctuation`), not
/// through a widget in the panel body. A key list derived from body widgets
/// alone reads 15 and would agree with a host that had dropped it — which is
/// why [`tests::field_keys_partition_the_declared_yaml_state`] partitions the
/// YAML's `state:` block instead of counting widgets.
pub const FIELDS: [&str; 16] = [
    "align_left", "align_center", "align_right",
    "justify_left", "justify_center", "justify_right", "justify_all",
    "bullets", "numbered_list",
    "left_indent", "right_indent", "first_line_indent",
    "space_before", "space_after",
    "hyphenate", "hanging_punctuation",
];

/// True when a write to the Paragraph panel's `key` reaches the selection.
///
/// The panel's `state:` block declares two further keys — `text_selected` and
/// `area_text_selected` — which are DERIVED read-only predicates driving the
/// controls' `disabled:` bindings. They answer false: a write to one must not
/// push an undo step that changes nothing. (They are this panel's analogue of
/// Character's seven `snap_*` flags.)
pub fn is_field_key(key: &str) -> bool {
    FIELDS.contains(&key)
}

/// Paragraph panel state — the sixteen writable fields declared in
/// `workspace/panels/paragraph.yaml`. Written to by the renderer when the user
/// edits a control; read by [`apply_to_selection`] to push the attributes onto
/// the paragraph wrapper tspan(s) inside the selected Text / TextPath element.
#[derive(Debug, Clone)]
pub struct ParagraphPanelState {
    /// Alignment radio group — exactly one of these seven is true.
    pub align_left: bool,
    pub align_center: bool,
    pub align_right: bool,
    pub justify_left: bool,
    pub justify_center: bool,
    pub justify_right: bool,
    pub justify_all: bool,
    /// Single-attr-shared dropdowns; mutually exclusive at write time.
    /// Empty string ⇒ no marker / clears the attribute.
    pub bullets: String,
    pub numbered_list: String,
    pub left_indent: f64,
    pub right_indent: f64,
    /// Signed; negative ⇒ hanging indent.
    pub first_line_indent: f64,
    pub space_before: f64,
    pub space_after: f64,
    pub hyphenate: bool,
    pub hanging_punctuation: bool,
}

impl Default for ParagraphPanelState {
    fn default() -> Self {
        Self {
            align_left: true,
            align_center: false,
            align_right: false,
            justify_left: false,
            justify_center: false,
            justify_right: false,
            justify_all: false,
            bullets: String::new(),
            numbered_list: String::new(),
            left_indent: 0.0,
            right_indent: 0.0,
            first_line_indent: 0.0,
            space_before: 0.0,
            space_after: 0.0,
            hyphenate: false,
            hanging_punctuation: false,
        }
    }
}

impl ParagraphPanelState {
    /// Write ONE field from a YAML-interpreted value. A value of the wrong
    /// JSON type leaves the field alone, as the web renderer's setter did.
    ///
    /// **The two mutual exclusions live here, upstream of the document write.**
    /// Setting an alignment bool true clears the other six (the radio group);
    /// setting a non-empty `bullets` clears `numbered_list` and vice versa,
    /// because both spell the single `jas_list_style` attribute. ⚠️ Setting a
    /// list field to the EMPTY string does *not* clear the other one — empty
    /// means "no marker", and clearing on it would make deselecting bullets
    /// silently also deselect a numbered list.
    pub fn set_field(&mut self, key: &str, v: &serde_json::Value) {
        fn clear_aligns(pp: &mut ParagraphPanelState) {
            pp.align_left = false;
            pp.align_center = false;
            pp.align_right = false;
            pp.justify_left = false;
            pp.justify_center = false;
            pp.justify_right = false;
            pp.justify_all = false;
        }
        match key {
            "align_left"     => { if let Some(b) = v.as_bool() { if b { clear_aligns(self); self.align_left = true; } } }
            "align_center"   => { if let Some(b) = v.as_bool() { if b { clear_aligns(self); self.align_center = true; } } }
            "align_right"    => { if let Some(b) = v.as_bool() { if b { clear_aligns(self); self.align_right = true; } } }
            "justify_left"   => { if let Some(b) = v.as_bool() { if b { clear_aligns(self); self.justify_left = true; } } }
            "justify_center" => { if let Some(b) = v.as_bool() { if b { clear_aligns(self); self.justify_center = true; } } }
            "justify_right"  => { if let Some(b) = v.as_bool() { if b { clear_aligns(self); self.justify_right = true; } } }
            "justify_all"    => { if let Some(b) = v.as_bool() { if b { clear_aligns(self); self.justify_all = true; } } }
            "bullets" => {
                if let Some(s) = v.as_str() {
                    self.bullets = s.into();
                    if !s.is_empty() { self.numbered_list.clear(); }
                }
            }
            "numbered_list" => {
                if let Some(s) = v.as_str() {
                    self.numbered_list = s.into();
                    if !s.is_empty() { self.bullets.clear(); }
                }
            }
            "left_indent"         => { if let Some(n) = v.as_f64() { self.left_indent = n; } }
            "right_indent"        => { if let Some(n) = v.as_f64() { self.right_indent = n; } }
            "first_line_indent"   => { if let Some(n) = v.as_f64() { self.first_line_indent = n; } }
            "space_before"        => { if let Some(n) = v.as_f64() { self.space_before = n; } }
            "space_after"         => { if let Some(n) = v.as_f64() { self.space_after = n; } }
            "hyphenate"           => { if let Some(b) = v.as_bool() { self.hyphenate = b; } }
            "hanging_punctuation" => { if let Some(b) = v.as_bool() { self.hanging_punctuation = b; } }
            _ => {}
        }
    }

    /// The panel as the store holds it. Like Character and unlike Stroke there
    /// is **no flat global spelling to fall back to** — every Paragraph control
    /// binds `panel.<field>` only. A null or absent entry leaves the declared
    /// default, which for `align_left` is `true`.
    pub fn from_store(store: &crate::interpreter::state_store::StateStore) -> Self {
        let mut pp = Self::default();
        for f in FIELDS {
            let v = store.get_panel(PARAGRAPH_PANEL, f);
            if !v.is_null() {
                pp.set_field(f, v);
            }
        }
        pp
    }
}

/// Collapse the seven alignment radio bools to the
/// `(text-align, text-align-last)` pair per PARAGRAPH.md §Alignment.
/// `align_left` is the default and writes NOTHING, per the identity-value rule.
pub fn paragraph_align_attrs(pp: &ParagraphPanelState)
    -> (Option<String>, Option<String>) {
    if pp.align_center { (Some("center".into()), None) }
    else if pp.align_right { (Some("right".into()), None) }
    else if pp.justify_left { (Some("justify".into()), Some("left".into())) }
    else if pp.justify_center { (Some("justify".into()), Some("center".into())) }
    else if pp.justify_right { (Some("justify".into()), Some("right".into())) }
    else if pp.justify_all { (Some("justify".into()), Some("justify".into())) }
    else { (None, None) }  // align_left (default) → omit
}

/// Map the alignment radio bools to `text-anchor` for point text /
/// text-on-path per the §Alignment sub-mapping. Only the three non-justify
/// buttons map; the justify buttons fall through to the default `start`
/// (they are grayed for point text).
///
/// ⚠️ **NOT CALLED BY [`apply_to_selection`], and that is not an omission.**
/// `Element::Text` has no `text_anchor` field today, so the web-side apply
/// computed this value and immediately discarded it (`let _ = text_anchor;`)
/// against a Phase 5 rendering follow-up. Moving that discard would have moved
/// a dead call; the function is kept because it states half of the alignment
/// law and its inverse lives beside it, and it is wired the day the element
/// gains the field.
pub fn paragraph_text_anchor(pp: &ParagraphPanelState) -> Option<String> {
    if pp.align_center { Some("middle".into()) }
    else if pp.align_right { Some("end".into()) }
    else { None }  // align_left → start (default; omit)
}

/// Inverse of [`paragraph_align_attrs`]: set the radio bool a
/// `(text_align, text_align_last)` pair denotes. Used when reading wrappers
/// back into the panel. Kept beside its inverse deliberately — the two are one
/// law, and a law split across a feature gate is the second-copy hazard this
/// whole node exists to avoid.
pub fn apply_align_radio(pp: &mut ParagraphPanelState, ta: &str, tal: &str) {
    pp.align_left = false;
    pp.align_center = false;
    pp.align_right = false;
    pp.justify_left = false;
    pp.justify_center = false;
    pp.justify_right = false;
    pp.justify_all = false;
    match (ta, tal) {
        ("center", _) => pp.align_center = true,
        ("right", _) => pp.align_right = true,
        ("justify", "left") => pp.justify_left = true,
        ("justify", "center") => pp.justify_center = true,
        ("justify", "right") => pp.justify_right = true,
        ("justify", "justify") => pp.justify_all = true,
        _ => pp.align_left = true,
    }
}

/// The paragraph attributes a wrapper tspan carries, cleared together.
/// Named once here so the demote arm below and the write arm cannot drift.
macro_rules! clear_paragraph_attrs {
    ($t:expr) => {{
        let t = $t;
        t.jas_role = None;
        t.text_align = None;
        t.text_align_last = None;
        t.text_indent = None;
        t.jas_left_indent = None;
        t.jas_right_indent = None;
        t.jas_space_before = None;
        t.jas_space_after = None;
        t.jas_hyphenate = None;
        t.jas_hanging_punctuation = None;
        t.jas_list_style = None;
        t.jas_word_spacing_min = None;
        t.jas_word_spacing_desired = None;
        t.jas_word_spacing_max = None;
        t.jas_letter_spacing_min = None;
        t.jas_letter_spacing_desired = None;
        t.jas_letter_spacing_max = None;
        t.jas_glyph_scaling_min = None;
        t.jas_glyph_scaling_desired = None;
        t.jas_glyph_scaling_max = None;
        t.jas_auto_leading = None;
        t.jas_single_word_justify = None;
        t.jas_hyphenate_min_word = None;
        t.jas_hyphenate_min_before = None;
        t.jas_hyphenate_min_after = None;
        t.jas_hyphenate_limit = None;
        t.jas_hyphenate_zone = None;
        t.jas_hyphenate_bias = None;
        t.jas_hyphenate_capitalized = None;
    }};
}

/// Find the paragraph wrapper tspan(s), repairing a corrupted one first, and
/// return their indices. The wrapper is the tspan whose `jas_role` is
/// `"paragraph"`; it carries the paragraph attributes and holds no content.
///
/// **Repair:** a wrapper with non-empty content is demoted to a body tspan
/// (keeping its content and per-character overrides, losing the role and the
/// paragraph attributes) and a fresh empty wrapper inheriting those attributes
/// is prepended in its place. **If no wrapper exists anywhere, an empty one is
/// prepended** and its index returned, so the apply always has a target.
pub fn ensure_paragraph_wrapper(tspans: &mut Vec<Tspan>) -> Vec<usize> {
    let bad: Vec<usize> = tspans.iter().enumerate()
        .filter_map(|(i, t)|
            if t.jas_role.as_deref() == Some("paragraph") && !t.content.is_empty() {
                Some(i)
            } else { None })
        .collect();
    for &i in bad.iter().rev() {
        let src = &tspans[i];
        let new_wrapper = Tspan {
            jas_role: Some("paragraph".into()),
            text_align: src.text_align.clone(),
            text_align_last: src.text_align_last.clone(),
            text_indent: src.text_indent,
            jas_left_indent: src.jas_left_indent,
            jas_right_indent: src.jas_right_indent,
            jas_space_before: src.jas_space_before,
            jas_space_after: src.jas_space_after,
            jas_hyphenate: src.jas_hyphenate,
            jas_hanging_punctuation: src.jas_hanging_punctuation,
            jas_list_style: src.jas_list_style.clone(),
            jas_word_spacing_min: src.jas_word_spacing_min,
            jas_word_spacing_desired: src.jas_word_spacing_desired,
            jas_word_spacing_max: src.jas_word_spacing_max,
            jas_letter_spacing_min: src.jas_letter_spacing_min,
            jas_letter_spacing_desired: src.jas_letter_spacing_desired,
            jas_letter_spacing_max: src.jas_letter_spacing_max,
            jas_glyph_scaling_min: src.jas_glyph_scaling_min,
            jas_glyph_scaling_desired: src.jas_glyph_scaling_desired,
            jas_glyph_scaling_max: src.jas_glyph_scaling_max,
            jas_auto_leading: src.jas_auto_leading,
            jas_single_word_justify: src.jas_single_word_justify.clone(),
            jas_hyphenate_min_word: src.jas_hyphenate_min_word,
            jas_hyphenate_min_before: src.jas_hyphenate_min_before,
            jas_hyphenate_min_after: src.jas_hyphenate_min_after,
            jas_hyphenate_limit: src.jas_hyphenate_limit,
            jas_hyphenate_zone: src.jas_hyphenate_zone,
            jas_hyphenate_bias: src.jas_hyphenate_bias,
            jas_hyphenate_capitalized: src.jas_hyphenate_capitalized,
            ..Tspan::default_tspan()
        };
        clear_paragraph_attrs!(&mut tspans[i]);
        tspans.insert(i, new_wrapper);
    }
    let existing: Vec<usize> = tspans.iter().enumerate()
        .filter_map(|(i, t)|
            if t.jas_role.as_deref() == Some("paragraph") { Some(i) } else { None })
        .collect();
    if !existing.is_empty() { return existing; }
    let wrapper = Tspan {
        jas_role: Some("paragraph".into()),
        ..Tspan::default_tspan()
    };
    tspans.insert(0, wrapper);
    vec![0]
}

/// **Push the Paragraph panel onto every Text / TextPath in the selection.**
/// Returns whether the document changed.
///
/// This is the one route the engine has, and unlike Character's it is NOT
/// field-scoped: every wrapper attribute is written from panel state on every
/// call, which is what the web app has always done. Per the identity-value
/// rule an attribute equal to its default is *omitted* (written as `None`)
/// rather than written, so a default panel clears the wrapper.
///
/// One `edit_document` for the whole selection, so a multi-element paragraph
/// change is ONE undo step (OP_LOG.md Increment 1).
pub fn apply_to_selection(
    model: &mut crate::document::model::Model, pp: &ParagraphPanelState,
) -> bool {
    use crate::geometry::element::Element;
    let (text_align, text_align_last) = paragraph_align_attrs(pp);
    let list_style = if !pp.bullets.is_empty() {
        Some(pp.bullets.clone())
    } else if !pp.numbered_list.is_empty() {
        Some(pp.numbered_list.clone())
    } else {
        None
    };
    let opt_f = |v: f64| if v == 0.0 { None } else { Some(v) };
    let opt_b = |v: bool| if !v { None } else { Some(true) };
    let left_indent = opt_f(pp.left_indent);
    let right_indent = opt_f(pp.right_indent);
    let first_line_indent = opt_f(pp.first_line_indent);
    let space_before = opt_f(pp.space_before);
    let space_after = opt_f(pp.space_after);
    let hyph = opt_b(pp.hyphenate);
    let hang_punct = opt_b(pp.hanging_punctuation);

    let mut doc = model.document().clone();
    let paths: Vec<Vec<usize>> = doc.selection.iter()
        .filter(|es| matches!(doc.get_element(&es.path),
                              Some(Element::Text(_)) | Some(Element::TextPath(_))))
        .map(|es| es.path.clone())
        .collect();
    let mut changed = false;
    for path in paths {
        let mut write = |tspans: &Vec<Tspan>| -> Vec<Tspan> {
            let mut tspans = tspans.clone();
            for i in ensure_paragraph_wrapper(&mut tspans) {
                let w = &mut tspans[i];
                w.text_align = text_align.clone();
                w.text_align_last = text_align_last.clone();
                w.text_indent = first_line_indent;
                w.jas_left_indent = left_indent;
                w.jas_right_indent = right_indent;
                w.jas_space_before = space_before;
                w.jas_space_after = space_after;
                w.jas_hyphenate = hyph;
                w.jas_hanging_punctuation = hang_punct;
                w.jas_list_style = list_style.clone();
            }
            tspans
        };
        let new_elem = match doc.get_element(&path) {
            Some(Element::Text(t)) => {
                let mut nt = t.clone();
                nt.tspans = write(&t.tspans);
                Some(Element::Text(nt))
            }
            Some(Element::TextPath(tp)) => {
                let mut ntp = tp.clone();
                ntp.tspans = write(&tp.tspans);
                Some(Element::TextPath(ntp))
            }
            _ => None,
        };
        if let Some(e) = new_elem {
            doc = doc.replace_element(&path, e);
            changed = true;
        }
    }
    if changed {
        model.edit_document(doc);
    }
    changed
}

/// Every paragraph wrapper tspan of every selected Text / TextPath, in
/// selection order. The wrapper is the tspan whose `jas_role` is
/// `"paragraph"`; a selection may hold several.
pub fn selected_wrappers(doc: &crate::document::document::Document) -> Vec<Tspan> {
    use crate::geometry::element::Element;
    let mut out: Vec<Tspan> = Vec::new();
    for es in doc.selection.iter() {
        let tspans: Option<&[Tspan]> = match doc.get_element(&es.path) {
            Some(Element::Text(t)) => Some(&t.tspans[..]),
            Some(Element::TextPath(tp)) => Some(&tp.tspans[..]),
            _ => None,
        };
        if let Some(tspans) = tspans {
            out.extend(tspans.iter()
                       .filter(|ts| ts.jas_role.as_deref() == Some("paragraph"))
                       .cloned());
        }
    }
    out
}

/// **Read the selection's wrappers back into panel state**, taking a value
/// only where EVERY wrapper agrees — a mixed selection leaves the field as it
/// was, which is how a panel shows "no single value".
///
/// ⛔ **THIS IS NOT DISPLAY-ONLY, AND IT IS THE ONE PLACE PARAGRAPH'S BOUNDARY
/// DIFFERS FROM CHARACTER'S.** The web app calls it immediately before every
/// paragraph write, and its own comment says why: *"Sync first so untouched
/// fields hold the selection's current values, not stale panel state, before
/// the new field is set and the whole panel is re-applied."* Because the apply
/// is WHOLE-PANEL, the pre-write sync is what stops an edit to one field from
/// stamping stale values over the other fifteen. The engine needs it for the
/// same reason, so it lives here and not beside `character_panel_post_write`.
pub fn sync_from_wrappers(pp: &mut ParagraphPanelState, wrappers: &[Tspan]) {
    if wrappers.is_empty() { return; }
    fn agree<T: PartialEq + Clone>(values: &[T]) -> Option<T> {
        let first = values.first()?.clone();
        if values.iter().all(|v| *v == first) { Some(first) } else { None }
    }
    let lefts: Vec<f64> = wrappers.iter().map(|w| w.jas_left_indent.unwrap_or(0.0)).collect();
    if let Some(v) = agree(&lefts) { pp.left_indent = v; }
    let rights: Vec<f64> = wrappers.iter().map(|w| w.jas_right_indent.unwrap_or(0.0)).collect();
    if let Some(v) = agree(&rights) { pp.right_indent = v; }
    let firsts: Vec<f64> = wrappers.iter().map(|w| w.text_indent.unwrap_or(0.0)).collect();
    if let Some(v) = agree(&firsts) { pp.first_line_indent = v; }
    let sb: Vec<f64> = wrappers.iter().map(|w| w.jas_space_before.unwrap_or(0.0)).collect();
    if let Some(v) = agree(&sb) { pp.space_before = v; }
    let sa: Vec<f64> = wrappers.iter().map(|w| w.jas_space_after.unwrap_or(0.0)).collect();
    if let Some(v) = agree(&sa) { pp.space_after = v; }
    let hy: Vec<bool> = wrappers.iter().map(|w| w.jas_hyphenate.unwrap_or(false)).collect();
    if let Some(v) = agree(&hy) { pp.hyphenate = v; }
    let hp: Vec<bool> = wrappers.iter()
        .map(|w| w.jas_hanging_punctuation.unwrap_or(false)).collect();
    if let Some(v) = agree(&hp) { pp.hanging_punctuation = v; }
    let styles: Vec<String> = wrappers.iter()
        .map(|w| w.jas_list_style.clone().unwrap_or_default()).collect();
    if let Some(ls) = agree(&styles) {
        if ls.starts_with("bullet-") { pp.bullets = ls; pp.numbered_list.clear(); }
        else if ls.starts_with("num-") { pp.numbered_list = ls; pp.bullets.clear(); }
        else { pp.bullets.clear(); pp.numbered_list.clear(); }
    }
    let tas: Vec<String> = wrappers.iter()
        .map(|w| w.text_align.clone().unwrap_or_else(|| "left".into())).collect();
    let tals: Vec<String> = wrappers.iter()
        .map(|w| w.text_align_last.clone().unwrap_or_default()).collect();
    if let (Some(ta), Some(tal)) = (agree(&tas), agree(&tals)) {
        apply_align_radio(pp, &ta, &tal);
    }
}

/// The panel as the DOCUMENT says it is — the engine's base for a write.
pub fn panel_from_document(doc: &crate::document::document::Document)
    -> ParagraphPanelState {
    let mut pp = ParagraphPanelState::default();
    sync_from_wrappers(&mut pp, &selected_wrappers(doc));
    pp
}

/// **The sixteen fields as the SELECTION holds them**, for the engine's panel
/// scope — the role `properties_host::live_values` plays for Properties.
///
/// ⛔ **WITHOUT THIS, THE PANEL'S SCOPE IS WHATEVER THE STORE LAST HAPPENED TO
/// HOLD, AND A BOOLEAN WIDGET READS IT TO DECIDE WHAT A PRESS MEANS.** The
/// seven alignment controls are checkboxes bound to `panel.align_*`, and a
/// press writes the NEGATION of the bound expression. `bind_write` writes the
/// one bool pressed and never clears its siblings, so a store-backed scope
/// still reads `align_left = true` after the user has moved to centre — and
/// the next press on Left evaluates `not true`, writes FALSE, and selects
/// nothing. Derived from the document the same press evaluates `not false`
/// and selects Left, which is what the web app achieves by syncing first.
pub fn live_values(doc: &crate::document::document::Document)
    -> serde_json::Map<String, serde_json::Value> {
    use serde_json::json;
    let pp = panel_from_document(doc);
    let mut m = serde_json::Map::new();
    m.insert("align_left".into(), json!(pp.align_left));
    m.insert("align_center".into(), json!(pp.align_center));
    m.insert("align_right".into(), json!(pp.align_right));
    m.insert("justify_left".into(), json!(pp.justify_left));
    m.insert("justify_center".into(), json!(pp.justify_center));
    m.insert("justify_right".into(), json!(pp.justify_right));
    m.insert("justify_all".into(), json!(pp.justify_all));
    m.insert("bullets".into(), json!(pp.bullets));
    m.insert("numbered_list".into(), json!(pp.numbered_list));
    m.insert("left_indent".into(), json!(pp.left_indent));
    m.insert("right_indent".into(), json!(pp.right_indent));
    m.insert("first_line_indent".into(), json!(pp.first_line_indent));
    m.insert("space_before".into(), json!(pp.space_before));
    m.insert("space_after".into(), json!(pp.space_after));
    m.insert("hyphenate".into(), json!(pp.hyphenate));
    m.insert("hanging_punctuation".into(), json!(pp.hanging_punctuation));
    debug_assert_eq!(m.len(), FIELDS.len(),
                     "live_values must expose every field the panel declares");
    // The two DERIVED PREDICATES. They reach no attribute — `is_field_key`
    // answers false for both — but they drive every control's `disabled:`
    // binding, and the panel's own YAML states the obligation: *"Native apps
    // overwrite on selection change; flask demo keeps the default."* Both
    // default to TRUE, so an engine that does not overwrite them reports every
    // control enabled on an empty selection. Swift computes them in
    // `paragraphPanelLiveOverrides`; this is the same law.
    let (any_text, all_area) = text_selection_facts(doc);
    m.insert("text_selected".into(), json!(any_text));
    m.insert("area_text_selected".into(), json!(any_text && all_area));
    m
}

/// `(any text selected, every selected text element is AREA text)`.
///
/// Area text is a wrapping frame — `width > 0 && height > 0`. A TextPath is
/// never area text, which is why it clears `all_area` while still counting as
/// text: the JUSTIFY_* controls, the indents and hyphenation are area-only.
fn text_selection_facts(doc: &crate::document::document::Document) -> (bool, bool) {
    use crate::geometry::element::Element;
    let mut any_text = false;
    let mut all_area = true;
    for es in doc.selection.iter() {
        match doc.get_element(&es.path) {
            Some(Element::Text(t)) => {
                any_text = true;
                if !(t.width > 0.0 && t.height > 0.0) { all_area = false; }
            }
            Some(Element::TextPath(_)) => {
                any_text = true;
                all_area = false;
            }
            _ => {}
        }
    }
    (any_text, all_area)
}

/// **The engine's entry point: apply a write to `key`.** A key that owns no
/// document attribute is refused — the panel's two derived predicates must not
/// push an undo step that changes nothing.
///
/// ⛔ **THE BASE IS THE SELECTION, NOT THE STORE**, and this is the whole
/// reason [`sync_from_wrappers`] is in this file. The apply is WHOLE-PANEL, so
/// every field not being edited is written from the base — and the store's
/// copy of those fields can be arbitrarily stale (it is only ever written by
/// `bind_write`, one key per press, with no sibling ever cleared). Basing on
/// the store would let one edit stamp stale values over the other fifteen, and
/// would resolve the alignment radio by `FIELDS` array order rather than by
/// what the user pressed. The web app avoids both by syncing first; this is
/// the same act.
///
/// ⚠️ Note the asymmetry with [`super::character_host::apply_field`]: there
/// the key selects the GROUP to write, here it only decides *whether* to
/// write, because the paragraph apply is whole-panel.
pub fn apply_field(
    model: &mut crate::document::model::Model,
    store: &crate::interpreter::state_store::StateStore,
    key: &str,
) -> bool {
    if !is_field_key(key) { return false; }
    let mut pp = panel_from_document(model.document());
    // The edited key LAST, so its mutual exclusions are applied over a base
    // that already agrees with the document.
    pp.set_field(key, store.get_panel(PARAGRAPH_PANEL, key));
    apply_to_selection(model, &pp)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ⛔ **EVERY ARM IN THIS MODULE RUNS IN A BUILD WITH NO WEB FEATURE, AND
    /// THAT IS THE WHOLE POINT OF W2b-7.** Before this move the paragraph law
    /// lived inside `#[cfg(feature = "web")] app_state`, so not one of these
    /// tests could be written — the types they name did not exist in a
    /// web-free build. They are the reachability receipt, not extra coverage.
    ///
    /// ⚠️ **THE COMMAND MATTERS AND THE OBVIOUS ONE IS WRONG.** This crate
    /// declares `default = ["web"]`, so `cargo test --lib` *and*
    /// `cargo test --lib --features ffi` both build WITH web and would pass
    /// these arms with the gate still in place. The web-free set is
    /// `cargo test --lib --no-default-features --features ffi`, which is what
    /// CI runs.
    ///
    /// Every `panel.<key>` the Paragraph panel's YAML declares, read from the
    /// artifact — a key list typed into a test is a claim about the panel that
    /// nothing re-checks when the panel changes.
    fn declared_panel_keys() -> Vec<String> {
        let src = std::fs::read_to_string(
            concat!(env!("CARGO_MANIFEST_DIR"), "/../workspace/panels/paragraph.yaml"))
            .expect("paragraph.yaml is readable");
        let mut out: Vec<String> = Vec::new();
        let mut rest = src.as_str();
        while let Some(i) = rest.find("panel.") {
            rest = &rest[i + 6..];
            let k: String = rest.chars()
                .take_while(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '_')
                .collect();
            if !k.is_empty() && !out.contains(&k) {
                out.push(k);
            }
        }
        assert!(out.len() > 12, "read only {} keys — the YAML's shape changed", out.len());
        out
    }

    /// **THE KEY TABLE, PARTITIONED AGAINST THE PANEL'S OWN YAML.** The panel
    /// declares N keys; each either reaches the document or is a derived
    /// read-only predicate, and the split must be exactly sixteen against the
    /// two. Drift in EITHER direction reds.
    ///
    /// ⚠️ **SIXTEEN, NOT THE FIFTEEN THE PANEL HAS BODY INPUTS FOR.** The
    /// sixteenth, `hanging_punctuation`, is reachable only through the panel
    /// MENU (`action: toggle_hanging_punctuation`). A key list derived from
    /// body widgets reads 15 and would agree with a host that had dropped it —
    /// which is why this partitions `panel.<key>` occurrences, a population
    /// that includes the menu's `checked:` binding.
    #[test]
    fn the_yaml_keys_partition_into_sixteen_fields_and_two_predicates() {
        let declared = declared_panel_keys();
        let (owns, derived): (Vec<&String>, Vec<&String>) =
            declared.iter().partition(|k| is_field_key(k));
        assert_eq!(owns.len(), 16,
                   "the panel declares {} document-writing keys, not 16: {:?}",
                   owns.len(), owns);
        let mut preds: Vec<&str> = derived.iter().map(|s| s.as_str()).collect();
        preds.sort_unstable();
        assert_eq!(preds, ["area_text_selected", "text_selected"],
                   "a declared key reaches no attribute and is not one of the \
                    two derived predicates");
        // Anti-vacuity: the partition covers the WHOLE declared set, so
        // neither side can be right by being empty.
        assert_eq!(owns.len() + preds.len(), declared.len());
    }

    /// The two derived predicates drive `disabled:` bindings and own no
    /// attribute; a write to one must not push an undo step that changes
    /// nothing.
    #[test]
    fn derived_predicates_are_not_field_keys() {
        for k in ["text_selected", "area_text_selected", "not_a_field", ""] {
            assert!(!is_field_key(k), "{k}");
        }
        // Anti-vacuity: the same predicate says YES to a real field, so the
        // four NOs above are a reading and not a function that always refuses.
        assert!(is_field_key("align_left"));
        assert!(is_field_key("hanging_punctuation"));
    }

    fn with_align(which: &str) -> ParagraphPanelState {
        let mut pp = ParagraphPanelState::default();
        pp.set_field(which, &serde_json::json!(true));
        pp
    }

    const ALIGN_KEYS: [&str; 7] = [
        "align_left", "align_center", "align_right",
        "justify_left", "justify_center", "justify_right", "justify_all",
    ];

    /// **THE SEVEN ALIGNMENT STATES MUST READ PAIRWISE DISTINCT, AND EVERY
    /// PAIR IS ASSERTED.** A table's power is in its probes, not its row count:
    /// two rows collapsing to the same `(text-align, text-align-last)` pair
    /// would make the mapping untested for both, and the rows being
    /// semantically distinct is not evidence that their readings are.
    #[test]
    fn the_seven_alignment_states_read_pairwise_distinct() {
        let pairs: Vec<(Option<String>, Option<String>)> =
            ALIGN_KEYS.iter().map(|k| paragraph_align_attrs(&with_align(k))).collect();
        assert_eq!(pairs.len(), 7);
        for i in 0..pairs.len() {
            for j in (i + 1)..pairs.len() {
                assert_ne!(pairs[i], pairs[j],
                           "{} and {} both read {:?} — the mapping is untested \
                            for both", ALIGN_KEYS[i], ALIGN_KEYS[j], pairs[i]);
            }
        }
        // align_left is the default and writes NOTHING (identity-value rule).
        assert_eq!(pairs[0], (None, None), "align_left must omit both attributes");
    }

    /// `apply_align_radio` is the inverse of `paragraph_align_attrs`, and a
    /// round trip through the attribute pair must return the same state. The
    /// two are one law; this is what keeps them from drifting apart.
    #[test]
    fn every_alignment_state_round_trips_through_its_attributes() {
        for k in ALIGN_KEYS {
            let pp = with_align(k);
            let (ta, tal) = paragraph_align_attrs(&pp);
            let mut back = ParagraphPanelState::default();
            apply_align_radio(&mut back,
                              ta.as_deref().unwrap_or(""),
                              tal.as_deref().unwrap_or(""));
            assert_eq!(flags_of(&back), flags_of(&pp),
                       "{k} did not survive a round trip through {:?}/{:?}", ta, tal);
        }
    }

    fn flags_of(pp: &ParagraphPanelState) -> [bool; 7] {
        [pp.align_left, pp.align_center, pp.align_right,
         pp.justify_left, pp.justify_center, pp.justify_right, pp.justify_all]
    }

    /// The radio law: setting one alignment true clears the other six, so
    /// exactly one is ever set.
    #[test]
    fn setting_an_alignment_clears_the_other_six() {
        for k in ALIGN_KEYS {
            let pp = with_align(k);
            assert_eq!(flags_of(&pp).iter().filter(|b| **b).count(), 1,
                       "{k} left {:?}", flags_of(&pp));
        }
    }

    /// Bullets and numbered-list both spell the single `jas_list_style`
    /// attribute, so a non-empty write to one clears the other.
    #[test]
    fn bullets_and_numbered_list_are_mutually_exclusive() {
        let mut pp = ParagraphPanelState::default();
        pp.set_field("bullets", &serde_json::json!("disc"));
        assert_eq!(pp.bullets, "disc");
        pp.set_field("numbered_list", &serde_json::json!("decimal"));
        assert_eq!(pp.numbered_list, "decimal");
        assert_eq!(pp.bullets, "", "a numbered list must clear the bullets");
        pp.set_field("bullets", &serde_json::json!("circle"));
        assert_eq!(pp.numbered_list, "", "bullets must clear the numbered list");
    }

    /// ⚠️ **THE EMPTY STRING IS "no marker", NOT "clear the other one".**
    /// Clearing on empty would make deselecting bullets silently deselect a
    /// numbered list too.
    #[test]
    fn an_empty_list_string_does_not_clear_the_other() {
        let mut pp = ParagraphPanelState::default();
        pp.set_field("numbered_list", &serde_json::json!("decimal"));
        pp.set_field("bullets", &serde_json::json!(""));
        assert_eq!(pp.numbered_list, "decimal",
                   "an empty bullets write cleared the numbered list");
    }

    /// A value of the wrong JSON type leaves the field alone, as the web
    /// renderer's setter did.
    #[test]
    fn a_wrong_typed_value_leaves_the_field_alone() {
        let mut pp = ParagraphPanelState::default();
        pp.set_field("left_indent", &serde_json::json!("not a number"));
        assert_eq!(pp.left_indent, 0.0);
        pp.set_field("hyphenate", &serde_json::json!(12));
        assert!(!pp.hyphenate);
        pp.set_field("bullets", &serde_json::json!(true));
        assert_eq!(pp.bullets, "");
    }

    /// A null or absent store entry leaves the declared default — and the
    /// default that matters is `align_left = true`, because it is the one
    /// state that writes no attribute at all.
    #[test]
    fn from_store_on_an_empty_store_is_the_declared_default() {
        let store = crate::interpreter::state_store::StateStore::new();
        let pp = ParagraphPanelState::from_store(&store);
        assert!(pp.align_left, "the default alignment was lost");
        assert_eq!(flags_of(&pp).iter().filter(|b| **b).count(), 1);
        assert_eq!(paragraph_align_attrs(&pp), (None, None));
    }

    fn body(content: &str) -> Tspan {
        Tspan { content: content.into(), ..Tspan::default_tspan() }
    }

    fn wrapper() -> Tspan {
        Tspan { jas_role: Some("paragraph".into()), ..Tspan::default_tspan() }
    }

    /// With no wrapper anywhere, one is prepended so the apply always has a
    /// target — and it is prepended, not appended, because the wrapper carries
    /// the paragraph attributes for the content that follows it.
    #[test]
    fn a_wrapper_is_prepended_when_none_exists() {
        let mut tspans = vec![body("hello"), body("world")];
        let idx = ensure_paragraph_wrapper(&mut tspans);
        assert_eq!(idx, vec![0]);
        assert_eq!(tspans.len(), 3);
        assert_eq!(tspans[0].jas_role.as_deref(), Some("paragraph"));
        assert!(tspans[0].content.is_empty(), "the wrapper must hold no content");
        assert_eq!(tspans[1].content, "hello", "the body tspans must survive in order");
        assert_eq!(tspans[2].content, "world");
    }

    /// **THE REPAIR ARM.** A wrapper carrying content is corrupt: it is demoted
    /// to a body tspan and a fresh empty wrapper INHERITING its paragraph
    /// attributes takes its place. The content must survive and the attributes
    /// must move — asserting only one of those passes if the other is dropped.
    #[test]
    fn a_wrapper_with_content_is_demoted_and_its_attributes_are_inherited() {
        let mut bad = wrapper();
        bad.content = "trapped".into();
        bad.text_align = Some("center".into());
        bad.jas_left_indent = Some(12.0);
        let mut tspans = vec![bad];

        let idx = ensure_paragraph_wrapper(&mut tspans);

        assert_eq!(idx, vec![0], "the fresh wrapper is the target");
        assert_eq!(tspans.len(), 2);
        // The new wrapper inherited the paragraph attributes...
        assert_eq!(tspans[0].jas_role.as_deref(), Some("paragraph"));
        assert_eq!(tspans[0].text_align.as_deref(), Some("center"));
        assert_eq!(tspans[0].jas_left_indent, Some(12.0));
        assert!(tspans[0].content.is_empty());
        // ...and the demoted tspan kept its CONTENT and lost the role and the
        // attributes, so the pair cannot both claim to be the wrapper.
        assert_eq!(tspans[1].content, "trapped", "the content was lost");
        assert_eq!(tspans[1].jas_role, None, "the demoted tspan is still a wrapper");
        assert_eq!(tspans[1].text_align, None, "the demoted tspan kept an attribute");
        assert_eq!(tspans[1].jas_left_indent, None);
    }

    /// An existing empty wrapper is used as-is — no repair, no second wrapper.
    #[test]
    fn an_existing_empty_wrapper_is_reused() {
        let mut tspans = vec![wrapper(), body("hello")];
        let idx = ensure_paragraph_wrapper(&mut tspans);
        assert_eq!(idx, vec![0]);
        assert_eq!(tspans.len(), 2, "a second wrapper was inserted");
    }

    // ---- the document write, in a build with no web feature ----------------

    fn text_doc() -> crate::document::document::Document {
        use crate::geometry::element::{CommonProps, Element, TextElem};
        use crate::document::document::{Document, ElementSelection};
        let elem = Element::Text(TextElem::from_string(
            0.0, 16.0, "hello", "sans-serif", 16.0, "normal", "normal", "none",
            0.0, 0.0, None, None, CommonProps::default()));
        let mut doc = Document::default();
        doc.layers = vec![elem];
        doc.selection = vec![ElementSelection::all(vec![0])];
        doc
    }

    fn wrapper_of(model: &crate::document::model::Model) -> Tspan {
        use crate::geometry::element::Element;
        let doc = model.document();
        match doc.get_element(&vec![0]) {
            Some(Element::Text(t)) => t.tspans.iter()
                .find(|s| s.jas_role.as_deref() == Some("paragraph"))
                .expect("no paragraph wrapper on the element").clone(),
            other => panic!("expected a Text element, got {:?}", other.map(|_| "other")),
        }
    }

    /// **THE REACHABILITY ARM: the engine's own route writes the document, in
    /// a build with no web feature.** Until this move the paragraph apply was
    /// behind `feature = "web"` and this could not be written at all.
    #[test]
    fn apply_to_selection_writes_the_wrapper_web_free() {
        let mut model = crate::document::model::Model::new(text_doc(), None);
        let mut pp = ParagraphPanelState::default();
        pp.set_field("align_center", &serde_json::json!(true));
        pp.set_field("left_indent", &serde_json::json!(12.0));
        pp.set_field("hyphenate", &serde_json::json!(true));

        assert!(apply_to_selection(&mut model, &pp), "the apply reported no change");

        let w = wrapper_of(&model);
        assert_eq!(w.text_align.as_deref(), Some("center"));
        assert_eq!(w.jas_left_indent, Some(12.0));
        assert_eq!(w.jas_hyphenate, Some(true));
    }

    /// **THE IDENTITY-VALUE RULE: a field at its default is OMITTED, not
    /// written.** This is what makes a default panel clear the wrapper rather
    /// than stamp zeros onto it, and it is the half a "did it write?" arm
    /// cannot see.
    #[test]
    fn a_default_panel_omits_every_attribute() {
        let mut model = crate::document::model::Model::new(text_doc(), None);
        // First put values on, so the omission below is a READING and not the
        // trivial truth that nothing was ever there.
        let mut pp = ParagraphPanelState::default();
        pp.set_field("align_right", &serde_json::json!(true));
        pp.set_field("left_indent", &serde_json::json!(12.0));
        pp.set_field("space_before", &serde_json::json!(4.0));
        pp.set_field("hyphenate", &serde_json::json!(true));
        pp.set_field("bullets", &serde_json::json!("disc"));
        apply_to_selection(&mut model, &pp);
        let before = wrapper_of(&model);
        assert_eq!(before.text_align.as_deref(), Some("right"));
        assert_eq!(before.jas_left_indent, Some(12.0));
        assert_eq!(before.jas_list_style.as_deref(), Some("disc"));

        // Now the default panel, which must clear all of it.
        apply_to_selection(&mut model, &ParagraphPanelState::default());
        let w = wrapper_of(&model);
        assert_eq!(w.text_align, None, "align_left must omit text-align");
        assert_eq!(w.text_align_last, None);
        assert_eq!(w.jas_left_indent, None, "a zero indent must be omitted");
        assert_eq!(w.jas_right_indent, None);
        assert_eq!(w.text_indent, None);
        assert_eq!(w.jas_space_before, None);
        assert_eq!(w.jas_space_after, None);
        assert_eq!(w.jas_hyphenate, None, "a false flag must be omitted, not written false");
        assert_eq!(w.jas_hanging_punctuation, None);
        assert_eq!(w.jas_list_style, None);
    }

    /// **THE TWO DERIVED PREDICATES, WHICH THE PANEL'S OWN YAML MAKES AN
    /// OBLIGATION:** *"Native apps overwrite on selection change; flask demo
    /// keeps the default."* Both default to TRUE, so an engine that does not
    /// overwrite them reports every control enabled on an EMPTY selection —
    /// a green that is wrong in the permissive direction.
    #[test]
    fn live_values_derives_the_two_predicates_from_the_selection() {
        use crate::document::document::Document;
        let v = |d: &Document, k: &str| live_values(d).get(k).and_then(|x| x.as_bool());

        // Empty selection: neither holds, against a YAML default of true.
        let empty = Document::default();
        assert_eq!(v(&empty, "text_selected"), Some(false),
                   "an empty selection reported text selected");
        assert_eq!(v(&empty, "area_text_selected"), Some(false));

        // A point-text element (width/height 0) is text but NOT area text,
        // which is what gates the JUSTIFY_* controls and the indents.
        let point = text_doc();
        assert_eq!(v(&point, "text_selected"), Some(true));
        assert_eq!(v(&point, "area_text_selected"), Some(false),
                   "point text was reported as area text");

        // And every field key is present beside them, so the scope a widget
        // binds against is complete rather than partly store-backed.
        let m = live_values(&point);
        for f in FIELDS {
            assert!(m.contains_key(f), "live_values omits the declared field {f}");
        }
        assert_eq!(m.len(), FIELDS.len() + 2,
                   "live_values exposes something the panel does not declare");
    }

    /// A negative first-line indent is a HANGING indent and is a real value —
    /// it must survive the identity-value rule, which keys on zero and not on
    /// sign.
    #[test]
    fn a_negative_first_line_indent_is_written() {
        let mut model = crate::document::model::Model::new(text_doc(), None);
        let mut pp = ParagraphPanelState::default();
        pp.set_field("first_line_indent", &serde_json::json!(-8.0));
        apply_to_selection(&mut model, &pp);
        assert_eq!(wrapper_of(&model).text_indent, Some(-8.0));
    }

    /// **THE SCOPING LAW, AND IT IS THIS NODE'S CLOBBER GUARD.** The apply is
    /// whole-panel, so it is tempting to read it as "the wrapper is rebuilt
    /// from panel state" — it is NOT. It writes the TEN attributes the panel
    /// owns and must leave the rest of the wrapper alone; the justification
    /// and hyphenation detail (`jas_word_spacing_*`, `jas_glyph_scaling_*`,
    /// `jas_hyphenate_limit` …) belongs to the Justification and Hyphenation
    /// dialogs, and an alignment click that cleared them would be a silent
    /// data loss with no panel showing it.
    ///
    /// ⚠️ The arm does NOT restate which ten the panel owns — that list IS
    /// `apply_to_selection`, and an arm repeating it would agree with it by
    /// construction and survive any change to it. It asserts the COMPLEMENT:
    /// these attributes are not the panel's, so they must be exactly what the
    /// element had.
    #[test]
    fn an_alignment_edit_leaves_the_justification_detail_alone() {
        use crate::geometry::element::Element;
        let mut doc = text_doc();
        // Seed a wrapper carrying dialog-owned detail the panel cannot express.
        let mut w = wrapper();
        w.jas_word_spacing_min = Some(0.8);
        w.jas_word_spacing_desired = Some(1.0);
        w.jas_word_spacing_max = Some(1.33);
        w.jas_glyph_scaling_min = Some(0.97);
        w.jas_hyphenate_limit = Some(2.0);
        w.jas_hyphenate_zone = Some(36.0);
        w.jas_single_word_justify = Some("full_justify".into());
        if let Some(Element::Text(t)) = doc.get_element(&vec![0]) {
            let mut nt = t.clone();
            nt.tspans = vec![w, body("hello")];
            doc = doc.replace_element(&vec![0], Element::Text(nt));
        } else {
            panic!("fixture is not a Text element");
        }
        let mut model = crate::document::model::Model::new(doc, None);

        let mut pp = ParagraphPanelState::default();
        pp.set_field("align_center", &serde_json::json!(true));
        assert!(apply_to_selection(&mut model, &pp));

        let w = wrapper_of(&model);
        // The edit landed...
        assert_eq!(w.text_align.as_deref(), Some("center"), "the edit did not land");
        // ...and nothing the panel does not own was touched.
        assert_eq!(w.jas_word_spacing_min, Some(0.8), "justification was clobbered");
        assert_eq!(w.jas_word_spacing_desired, Some(1.0));
        assert_eq!(w.jas_word_spacing_max, Some(1.33));
        assert_eq!(w.jas_glyph_scaling_min, Some(0.97));
        assert_eq!(w.jas_hyphenate_limit, Some(2.0));
        assert_eq!(w.jas_hyphenate_zone, Some(36.0));
        assert_eq!(w.jas_single_word_justify.as_deref(), Some("full_justify"));
    }

    /// **A KEY THAT OWNS NO ATTRIBUTE MUST NOT REACH THE DOCUMENT**, and the
    /// refusal is asserted by its return value rather than by "the document
    /// did not change" — which would also pass if the apply were dead.
    #[test]
    fn apply_field_refuses_a_derived_predicate() {
        let mut model = crate::document::model::Model::new(text_doc(), None);
        let store = crate::interpreter::state_store::StateStore::new();
        assert!(!apply_field(&mut model, &store, "text_selected"));
        assert!(!apply_field(&mut model, &store, "area_text_selected"));
        assert!(!apply_field(&mut model, &store, "not_a_field"));
        // Anti-vacuity: a REAL key through the same door does write, so the
        // three refusals above are the guard and not a dead function.
        assert!(apply_field(&mut model, &store, "align_left"));
    }
}
