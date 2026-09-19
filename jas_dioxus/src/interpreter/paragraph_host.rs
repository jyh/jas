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

/// The engine's entry point: apply the panel the store now holds, for a write
/// to `key`. A key that owns no document attribute is refused — the panel's
/// two derived predicates must not push an undo step that changes nothing.
///
/// ⚠️ Note the asymmetry with [`super::character_host::apply_field`]: there
/// the key selects the group to write, here it only decides *whether* to
/// write, because the paragraph apply is whole-panel.
pub fn apply_field(
    model: &mut crate::document::model::Model,
    store: &crate::interpreter::state_store::StateStore,
    key: &str,
) -> bool {
    if !is_field_key(key) { return false; }
    apply_to_selection(model, &ParagraphPanelState::from_store(store))
}
