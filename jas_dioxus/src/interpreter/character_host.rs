//! The Character panel's field-scoped apply law, hosted without a web
//! dependency (FB wave 2b, W2b-6).
//!
//! ⛔ **THIS MODULE IS A MOVE, NOT A REWRITE.** Every item below came out of
//! `workspace/app_state.rs` unchanged except for its visibility, and
//! `app_state` re-exports them all, so there is exactly ONE copy of the
//! character law in Rust. The wave-2b block warns that *"a half-lifted host is
//! worse than none — it is a SECOND COPY of the rules"*; a move with
//! re-exports is the shape that cannot become one.
//!
//! **WHY IT MOVED.** `workspace/mod.rs:39` carries `#[cfg(feature = "web")]`
//! on `app_state`, so the entire character law — the field → group table, the
//! sibling rules, the attribute writer — was unreachable from the engine. That
//! is the COLORTIERS shape: a law that both ports already obey, that one port
//! cannot call. Nothing here changes what the law SAYS; the 2026-09-18 census
//! measured the field → group table as identical in all three implementations
//! (reference 18 · Rust 18 · Swift 18, every pairwise difference NONE), so
//! this node is about REACHABILITY and not about behaviour.
//!
//! **WHAT DID NOT MOVE, AND THE BOUNDARY IS DELIBERATE.**
//! `AppState::apply_character_panel_to_selection` keeps its two
//! session-dependent routes (the next-typed-character override and the
//! per-range tspan write): both read the active tool's edit session, which is
//! web/UI state the engine does not have. `character_panel_post_write` also
//! stays web-side — its own docstring says it is display-only, it bumps the
//! PANEL's Leading field and never the document. Dragging either across would
//! couple this module to a struct the engine has no instance of, which is the
//! gate problem re-created one level down.
//!
//! The reference states the same table in
//! `workspace_interpreter/character_law.py`; Swift implements it in
//! `CharacterPanelSync.swift`. See `transcripts/CHARACTER.md`, "The
//! field-scoped apply law".

use crate::geometry::tspan::parse_pt;

// ── Text formatting and parsing the character law needs ───────────────
// These moved with it: they were `pub(crate)` in the web-gated `app_state`
// and are used by nothing outside this law and its panel display.
/// Format a number for CSS length/value output: integers have no
/// decimal, fractions drop trailing zeros. Matches the visual form
/// users expect in a vector illustration application's numeric fields
/// (e.g. `14.4pt`, `0.025em`, `5pt`).
pub fn fmt_num(n: f64) -> String {
    if n == n.trunc() {
        format!("{}", n as i64)
    } else {
        let s = format!("{:.4}", n);
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    }
}
/// Parse a Character-panel Style name into the `(font_weight,
/// font_style)` pair used on Text / TextPath elements. Returns `None`
/// for names the parser doesn't recognise — callers should leave the
/// existing weight/style alone in that case.
pub fn parse_style_name(name: &str) -> Option<(String, String)> {
    match name.trim() {
        "Regular" => Some(("normal".into(), "normal".into())),
        "Italic" => Some(("normal".into(), "italic".into())),
        "Bold" => Some(("bold".into(), "normal".into())),
        "Bold Italic" | "Italic Bold" => Some(("bold".into(), "italic".into())),
        _ => None,
    }
}
/// Inverse of `text_decoration_from_flags` — extract the two flags from
/// a `text-decoration` string. Whitespace-split so "underline
/// line-through", "line-through underline", and mixed-case input all
/// round-trip cleanly through the Character panel's Underline /
/// Strikethrough toggles.
pub fn text_decoration_flags(td: &str) -> (bool, bool) {
    let mut underline = false;
    let mut strikethrough = false;
    for tok in td.split_whitespace() {
        match tok {
            "underline" => underline = true,
            "line-through" => strikethrough = true,
            _ => {}
        }
    }
    (underline, strikethrough)
}

/// Build the CSS `text-decoration` value from two independent flags.
/// Combines them in a stable alphabetical order — matches what the SVG
/// serializer already emits for tspan text_decoration arrays.
pub fn text_decoration_from_flags(underline: bool, strikethrough: bool) -> String {
    match (underline, strikethrough) {
        (true, true) => "line-through underline".to_string(),
        (true, false) => "underline".to_string(),
        (false, true) => "line-through".to_string(),
        (false, false) => String::new(),
    }
}

/// Character panel state fields — mirror the panel-local state
/// declared in `workspace/panels/character.yaml`. Written to by the
/// renderer when the user edits a Character panel control; read by
/// `apply_character_panel_to_selection` to push the attributes onto
/// the selected Text / TextPath element via
/// `Controller::set_character_attribute`.
#[derive(Debug, Clone)]
pub struct CharacterPanelState {
    pub font_family: String,
    pub style_name: String,
    pub font_size: f64,
    pub leading: f64,
    /// Kerning — accepts named modes `Auto` / `Optical` / `Metrics`
    /// (stored verbatim, pass through to the element attribute), or a
    /// numeric string in 1/1000 em (e.g. `"25"`). Empty / `"0"` /
    /// `"Auto"` all round-trip to an empty element attribute, matching
    /// the identity-omission rule.
    pub kerning: String,
    pub tracking: f64,
    pub vertical_scale: f64,
    pub horizontal_scale: f64,
    pub baseline_shift: f64,
    pub character_rotation: f64,
    pub all_caps: bool,
    pub small_caps: bool,
    pub superscript: bool,
    pub subscript: bool,
    pub underline: bool,
    pub strikethrough: bool,
    pub language: String,
    pub anti_aliasing: String,
    pub snap_to_glyph_visible: bool,
    pub snap_baseline: bool,
    pub snap_x_height: bool,
    pub snap_glyph_bounds: bool,
    pub snap_proximity_guides: bool,
    pub snap_angular_guides: bool,
    pub snap_anchor_point: bool,
}
impl Default for CharacterPanelState {
    fn default() -> Self {
        Self {
            font_family: "sans-serif".into(),
            style_name: "Regular".into(),
            font_size: 12.0,
            leading: 14.4,
            // "Auto" — the workspace-declared default, not an empty string.
            // Both spell the same element attribute (`kerning_attr` maps ""
            // and "Auto" to empty alike), which is why the drift survived
            // unnoticed until `character_panel_defaults_match_the_workspace`
            // compared the struct against the bundle; the DISPLAY told them
            // apart, showing a blank Kerning combo with no selection where
            // the other two ports showed "Auto".
            kerning: "Auto".into(),
            tracking: 0.0,
            vertical_scale: 100.0,
            horizontal_scale: 100.0,
            baseline_shift: 0.0,
            character_rotation: 0.0,
            all_caps: false,
            small_caps: false,
            superscript: false,
            subscript: false,
            underline: false,
            strikethrough: false,
            language: "en".into(),
            anti_aliasing: "Sharp".into(),
            snap_to_glyph_visible: true,
            snap_baseline: false,
            snap_x_height: false,
            snap_glyph_bounds: false,
            snap_proximity_guides: false,
            snap_angular_guides: false,
            snap_anchor_point: false,
        }
    }
}

/// Which of the CASE group's two toggles the user committed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaseField {
    AllCaps,
    SmallCaps,
}
/// Which of the DECORATION group's two toggles the user committed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecorationField {
    Underline,
    Strikethrough,
}
/// Which of the BASELINE_SHIFT group's three fields the user committed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BaselineField {
    /// The numeric Baseline Shift input.
    Number,
    Superscript,
    Subscript,
}
/// The character attributes ONE Character-panel field owns.
///
/// A panel edit must write only the group it touched and preserve every
/// other attribute from the element (see
/// `AppState::apply_character_panel_to_selection`). Fields that move
/// together stay in one group, and only where that is forced:
///
/// - `Style` is one dropdown naming a `font_weight` + `font_style` PAIR;
///   there is no control that moves the weight without the style.
/// - `Case` is the All Caps / Small Caps pair, whose mutual exclusion can
///   only be expressed by writing `text_transform` and `font_variant`
///   together — turning All Caps ON must clear a small-caps variant.
/// - `Decoration` is the Underline / Strikethrough pair feeding ONE CSS
///   token list, which cannot be written a token at a time.
///
/// The three groups fed by MORE THAN ONE panel field carry which field the
/// user committed, because that is what decides where the OTHER fields of
/// the group are read from: the committed one comes from panel state, its
/// siblings from THE ELEMENT (see `character_with_group`). The remaining
/// eleven groups have one field each, so there is nothing to tag.
///
/// The two glyph scales are deliberately SEPARATE groups (as the Stroke
/// law's two arrowhead scales are), and `FontSize` owns only the size —
/// never the leading, because Auto leading is an ABSENT `line-height` and
/// preserving it keeps Auto alive across a size change.
///
/// Mirrors the reference `CHARACTER_EDIT_GROUPS` + `MULTI_FIELD_GROUPS`
/// (`workspace_interpreter/character_law.py`), which states the table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CharacterEditGroup {
    FontFamily,
    Style,
    FontSize,
    Leading,
    Kerning,
    Tracking,
    VerticalScale,
    HorizontalScale,
    BaselineShift(BaselineField),
    Rotation,
    Case(CaseField),
    Decoration(DecorationField),
    Language,
    AaMode,
}
impl CharacterEditGroup {
    /// Map a Character-panel field key to the group it owns. `None` means
    /// the key owns no element attribute, so editing it writes nothing to
    /// the selection.
    ///
    /// Unlike the Stroke panel there is no flat-global spelling to
    /// normalize: every Character control binds `panel.<field>` only
    /// (`workspace/panels/character.yaml`).
    pub fn from_field(key: &str) -> Option<Self> {
        Some(match key {
            "font_family" => Self::FontFamily,
            "style_name" => Self::Style,
            "font_size" => Self::FontSize,
            "leading" => Self::Leading,
            "kerning" => Self::Kerning,
            "tracking" => Self::Tracking,
            "vertical_scale" => Self::VerticalScale,
            "horizontal_scale" => Self::HorizontalScale,
            // Three fields, one attribute: the two the user did NOT commit
            // are read from the element, and the committed one wins any
            // conflict with them.
            "baseline_shift" => Self::BaselineShift(BaselineField::Number),
            "superscript" => Self::BaselineShift(BaselineField::Superscript),
            "subscript" => Self::BaselineShift(BaselineField::Subscript),
            "character_rotation" => Self::Rotation,
            "all_caps" => Self::Case(CaseField::AllCaps),
            "small_caps" => Self::Case(CaseField::SmallCaps),
            "underline" => Self::Decoration(DecorationField::Underline),
            "strikethrough" => Self::Decoration(DecorationField::Strikethrough),
            "language" => Self::Language,
            "anti_aliasing" => Self::AaMode,
            // The seven snap_* flags and the section-visibility flags are
            // UI-only state: toggling one must not push an undo step that
            // changes nothing.
            _ => return None,
        })
    }

    /// Whether this group has ANY tspan-level representation.
    ///
    /// `Tspan` carries no glyph scales and no kerning mode, so a per-range
    /// write of those three groups can express nothing at all. The apply
    /// returns before touching the document rather than pushing an undo step
    /// that changes nothing — the same clause the `snap_*` flags get. (A
    /// tspan-level kerning / scale is banked in CHARACTER.md's follow-ups.)
    pub fn writes_tspan_field(self) -> bool {
        use CharacterEditGroup as G;
        !matches!(self, G::Kerning | G::VerticalScale | G::HorizontalScale)
    }

    /// The tspan override fields this group writes, applied to a template
    /// tspan built by `build_panel_full_overrides`. Fields outside the
    /// group are cleared to `None` so `merge_tspan_overrides` leaves the
    /// range's existing values alone.
    ///
    /// Groups with no tspan-level field (`writes_tspan_field`) yield an
    /// override template with nothing set — a range write for those is not
    /// expressible on a Tspan, and stamping the panel's other attributes
    /// instead is exactly what this law forbids.
    pub fn restrict_tspan_overrides(self, t: &mut crate::geometry::tspan::Tspan) {
        use CharacterEditGroup as G;
        let keep_family = matches!(self, G::FontFamily);
        let keep_style = matches!(self, G::Style);
        let keep_size = matches!(self, G::FontSize);
        let keep_leading = matches!(self, G::Leading);
        let keep_tracking = matches!(self, G::Tracking);
        let keep_baseline = matches!(self, G::BaselineShift(_));
        let keep_rotation = matches!(self, G::Rotation);
        let keep_case = matches!(self, G::Case(_));
        let keep_decoration = matches!(self, G::Decoration(_));
        let keep_language = matches!(self, G::Language);
        let keep_aa = matches!(self, G::AaMode);
        if !keep_family { t.font_family = None; }
        if !keep_style { t.font_weight = None; t.font_style = None; }
        if !keep_size { t.font_size = None; }
        if !keep_leading { t.line_height = None; }
        if !keep_tracking { t.letter_spacing = None; }
        if !keep_baseline { t.baseline_shift = None; }
        if !keep_rotation { t.rotate = None; }
        if !keep_case { t.text_transform = None; t.font_variant = None; }
        if !keep_decoration { t.text_decoration = None; }
        if !keep_language { t.xml_lang = None; }
        if !keep_aa { t.jas_aa_mode = None; }
    }
}
/// The character attributes a Character-panel edit can reach, lifted out
/// of a Text / TextPath element as a flat record.
///
/// The two element types carry the same sixteen fields; this record is the
/// shared shape the field-scoped law operates on, so `character_with_group`
/// can be a pure function the conformance corpus drives directly. Names are
/// the element's own (SVG / CSS) names, not panel field names.
#[derive(Debug, Clone, PartialEq)]
pub struct CharacterAttrs {
    pub font_family: String,
    pub font_size: f64,
    pub font_weight: String,
    pub font_style: String,
    pub text_decoration: String,
    pub text_transform: String,
    pub font_variant: String,
    pub baseline_shift: String,
    pub line_height: String,
    pub letter_spacing: String,
    pub xml_lang: String,
    pub aa_mode: String,
    pub rotate: String,
    pub horizontal_scale: String,
    pub vertical_scale: String,
    pub kerning: String,
}
/// Lift / lower the sixteen character attributes for either text element
/// type. `TextElem` and `TextPathElem` declare the same field names, so
/// one macro body serves both without a trait.
macro_rules! character_attrs_for {
    ($e:expr) => {
        CharacterAttrs {
            font_family: $e.font_family.clone(),
            font_size: $e.font_size,
            font_weight: $e.font_weight.clone(),
            font_style: $e.font_style.clone(),
            text_decoration: $e.text_decoration.clone(),
            text_transform: $e.text_transform.clone(),
            font_variant: $e.font_variant.clone(),
            baseline_shift: $e.baseline_shift.clone(),
            line_height: $e.line_height.clone(),
            letter_spacing: $e.letter_spacing.clone(),
            xml_lang: $e.xml_lang.clone(),
            aa_mode: $e.aa_mode.clone(),
            rotate: $e.rotate.clone(),
            horizontal_scale: $e.horizontal_scale.clone(),
            vertical_scale: $e.vertical_scale.clone(),
            kerning: $e.kerning.clone(),
        }
    };
}
// `macro_rules!` is textual, not path-resolved: without this the macro is
// invisible to `use crate::interpreter::character_host::character_attrs_for`.
pub(crate) use character_attrs_for;

/// An element's sixteen character attributes, or `None` when it is not a
/// Text / TextPath. The function form of `character_attrs_for!`, for callers
/// that hold an `Element` rather than one of the two concrete types.
pub fn character_attrs_of(
    elem: &crate::geometry::element::Element,
) -> Option<CharacterAttrs> {
    use crate::geometry::element::Element;
    match elem {
        Element::Text(t) => Some(character_attrs_for!(t)),
        Element::TextPath(tp) => Some(character_attrs_for!(tp)),
        _ => None,
    }
}
macro_rules! set_character_attrs {
    ($e:expr, $a:expr) => {{
        $e.font_family = $a.font_family.clone();
        $e.font_size = $a.font_size;
        $e.font_weight = $a.font_weight.clone();
        $e.font_style = $a.font_style.clone();
        $e.text_decoration = $a.text_decoration.clone();
        $e.text_transform = $a.text_transform.clone();
        $e.font_variant = $a.font_variant.clone();
        $e.baseline_shift = $a.baseline_shift.clone();
        $e.line_height = $a.line_height.clone();
        $e.letter_spacing = $a.letter_spacing.clone();
        $e.xml_lang = $a.xml_lang.clone();
        $e.aa_mode = $a.aa_mode.clone();
        $e.rotate = $a.rotate.clone();
        $e.horizontal_scale = $a.horizontal_scale.clone();
        $e.vertical_scale = $a.vertical_scale.clone();
        $e.kerning = $a.kerning.clone();
    }};
}
// `macro_rules!` is textual, not path-resolved: without this the macro is
// invisible to `use crate::interpreter::character_host::set_character_attrs`.
pub(crate) use set_character_attrs;

/// The element's `kerning` attribute for a Kerning combo entry. Named
/// modes pass through verbatim; a numeric entry is 1/1000 em and
/// serialises to `"{N}em"`. Empty / `"0"` / `"Auto"` all round-trip to an
/// empty attribute, since Auto is the element default.
pub fn kerning_attr(raw: &str) -> String {
    match raw.trim() {
        "" | "0" | "Auto" => String::new(),
        "Optical" | "Metrics" => raw.trim().to_string(),
        other => match other.parse::<f64>() {
            Ok(n) if n == 0.0 => String::new(),
            Ok(n) => format!("{}em", fmt_num(n / 1000.0)),
            Err(_) => String::new(),
        },
    }
}
/// The Character panel state ONE group's write should read: the committed
/// field as the panel holds it, the group's SIBLING fields taken from
/// `base` — the element (or tspan) being edited.
///
/// The law itself reads siblings out of its `base` (`character_with_group`),
/// which covers the whole-element route. The two TSPAN routes go through
/// override BUILDERS that read panel state instead, because a tspan stores
/// these attributes in a different shape (an `Option<f64>` baseline shift, a
/// token `Vec` decoration). This is the same rule in the builders'
/// representation, so there is one rule and not two: normalise the panel
/// state ONCE, hand it to the builder, and every downstream derivation
/// agrees with the law by construction (`sibling_normalization_agrees_with_
/// the_law` pins that).
///
/// A no-op for the eleven single-field groups: nothing in them has a sibling.
pub fn cp_with_element_siblings(
    cp: &CharacterPanelState, base: &CharacterAttrs, group: CharacterEditGroup,
) -> CharacterPanelState {
    use CharacterEditGroup as G;
    let mut out = cp.clone();
    match group {
        G::Decoration(field) => {
            let (u, s) = text_decoration_flags(&base.text_decoration);
            match field {
                DecorationField::Underline => out.strikethrough = s,
                DecorationField::Strikethrough => out.underline = u,
            }
        }
        G::Case(field) => {
            let (all_caps, small_caps) =
                case_flags(&base.text_transform, &base.font_variant);
            match field {
                // The committed toggle turned ON wins the exclusion, which
                // the law expresses by ignoring the sibling in that case; in
                // this representation the sibling has to be cleared for the
                // builder to reach the same answer.
                CaseField::AllCaps => out.small_caps = small_caps && !cp.all_caps,
                CaseField::SmallCaps => out.all_caps = all_caps && !cp.small_caps,
            }
        }
        G::BaselineShift(field) => {
            let (sup, sub, num) = baseline_shift_state(&base.baseline_shift);
            match field {
                BaselineField::Superscript => {
                    out.subscript = sub && !cp.superscript;
                    out.baseline_shift = num;
                }
                BaselineField::Subscript => {
                    out.superscript = sup && !cp.subscript;
                    out.baseline_shift = num;
                }
                BaselineField::Number => {
                    // A committed 0 carries no intent, so the element's
                    // super / sub stands; an explicit shift replaces it.
                    let explicit = cp.baseline_shift != 0.0;
                    out.superscript = sup && !explicit;
                    out.subscript = sub && !explicit;
                }
            }
        }
        _ => {}
    }
    out
}
/// `(all_caps, small_caps)` implied by an element's `text-transform` /
/// `font-variant`. The element side of the CASE group's sibling rule; also
/// what the panel display mirror reads. Mirrors the reference `case_flags`.
pub fn case_flags(text_transform: &str, font_variant: &str) -> (bool, bool) {
    (text_transform == "uppercase", font_variant == "small-caps")
}
/// `(superscript, subscript, numeric_pt)` implied by an element's
/// `baseline-shift`. The three are mutually exclusive on the element: a
/// `super` / `sub` keyword carries no number and a number carries neither
/// keyword. Mirrors the reference `baseline_shift_state`.
pub fn baseline_shift_state(bs: &str) -> (bool, bool, f64) {
    match bs.trim() {
        "super" => (true, false, 0.0),
        "sub" => (false, true, 0.0),
        other => (false, false, parse_pt(other).unwrap_or(0.0)),
    }
}
/// Overwrite `base`'s `group` attributes from the Character panel state,
/// leaving every other attribute of `base` untouched.
///
/// Only the COMMITTED field is read from `cp`. Everything else comes from
/// `base`:
///
/// - every attribute outside the group, trivially — that is field scoping;
/// - the SIBLING fields of the three multi-field groups (`Case`,
///   `Decoration`, `BaselineShift`), read back out of `base`'s own
///   attributes. Panel state is NOT a picture of the selection, so reading a
///   sibling from it destroyed the element's attribute: with
///   `text-decoration: line-through` on the element and the panel's
///   strikethrough flag at its `false` default, an Underline click wrote a
///   bare `underline`. Where the committed field conflicts with an
///   element-read sibling the COMMITTED field wins — it is what the user
///   just chose;
/// - and the values a derivation needs from the element — notably the
///   `Leading` group's Auto test, which compares the panel's leading against
///   the ELEMENT's `font_size * 1.2` rather than the panel's font size. The
///   whole-rebuild law used the panel's, which was harmless only because it
///   rewrote the size in the same breath; under the field-scoped law a
///   leading edit must not consult a font-size field the user did not touch.
///
/// Mirrors the reference `character_with_field`
/// (`workspace_interpreter/character_law.py`), whose `field` parameter is
/// this port's tagged `group`.
pub fn character_with_group(
    base: CharacterAttrs, cp: &CharacterPanelState, group: CharacterEditGroup,
) -> CharacterAttrs {
    use CharacterEditGroup as G;
    let mut c = base;
    match group {
        G::FontFamily => c.font_family = cp.font_family.clone(),
        G::Style => {
            // Unknown style names leave BOTH halves of the pair alone
            // rather than guessing one.
            if let Some((fw, fst)) = parse_style_name(&cp.style_name) {
                c.font_weight = fw;
                c.font_style = fst;
            }
        }
        G::FontSize => c.font_size = cp.font_size,
        G::Leading => {
            // Auto (an ABSENT line-height) is 120% of the ELEMENT's size.
            let auto = c.font_size * 1.2;
            c.line_height = if (cp.leading - auto).abs() < 1e-6 {
                String::new()
            } else {
                format!("{}pt", fmt_num(cp.leading))
            };
        }
        G::Kerning => c.kerning = kerning_attr(&cp.kerning),
        G::Tracking => {
            c.letter_spacing = if cp.tracking == 0.0 {
                String::new()
            } else {
                format!("{}em", fmt_num(cp.tracking / 1000.0))
            };
        }
        G::VerticalScale => {
            c.vertical_scale = if cp.vertical_scale == 100.0 {
                String::new()
            } else {
                fmt_num(cp.vertical_scale)
            };
        }
        G::HorizontalScale => {
            c.horizontal_scale = if cp.horizontal_scale == 100.0 {
                String::new()
            } else {
                fmt_num(cp.horizontal_scale)
            };
        }
        G::BaselineShift(field) => {
            // THREE fields, one attribute: the two the user did not commit
            // come from the element, so a toggle turned OFF falls back to the
            // element's other keyword or its own numeric shift instead of
            // wiping the attribute with the panel's 0.
            let (mut sup, mut sub, mut num) = baseline_shift_state(&c.baseline_shift);
            match field {
                BaselineField::Superscript => {
                    sup = cp.superscript;
                    if sup { sub = false; }
                }
                BaselineField::Subscript => {
                    sub = cp.subscript;
                    if sub { sup = false; }
                }
                BaselineField::Number => {
                    num = cp.baseline_shift;
                    // An explicit shift replaces super / sub; a committed 0
                    // does not, because 0 is what the input displays while
                    // super / sub is set.
                    if num != 0.0 { sup = false; sub = false; }
                }
            }
            c.baseline_shift = if sup {
                "super".to_string()
            } else if sub {
                "sub".to_string()
            } else if num != 0.0 {
                format!("{}pt", fmt_num(num))
            } else {
                String::new()
            };
        }
        G::Rotation => {
            c.rotate = if cp.character_rotation == 0.0 {
                String::new()
            } else {
                fmt_num(cp.character_rotation)
            };
        }
        G::Case(field) => {
            // The sibling toggle comes from the element, so turning one off
            // cannot clear the other's attribute; the committed toggle turned
            // ON still wins the exclusion.
            let (mut all_caps, mut small_caps) =
                case_flags(&c.text_transform, &c.font_variant);
            match field {
                CaseField::AllCaps => all_caps = cp.all_caps,
                CaseField::SmallCaps => {
                    small_caps = cp.small_caps;
                    if small_caps { all_caps = false; }
                }
            }
            c.text_transform = if all_caps { "uppercase".into() } else { String::new() };
            c.font_variant = if small_caps && !all_caps {
                "small-caps".into()
            } else {
                String::new()
            };
        }
        G::Decoration(field) => {
            // One token list, two fields: the token the user did not commit
            // is read off the element, so underlining never un-strikes.
            let (mut underline, mut strikethrough) =
                text_decoration_flags(&c.text_decoration);
            match field {
                DecorationField::Underline => underline = cp.underline,
                DecorationField::Strikethrough => strikethrough = cp.strikethrough,
            }
            c.text_decoration = text_decoration_from_flags(underline, strikethrough);
        }
        G::Language => c.xml_lang = cp.language.clone(),
        G::AaMode => {
            c.aa_mode = if cp.anti_aliasing == "Sharp" || cp.anti_aliasing.is_empty() {
                String::new()
            } else {
                cp.anti_aliasing.clone()
            };
        }
    }
    c
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ⛔ **EVERY ARM IN THIS MODULE RUNS IN A BUILD WITH NO WEB FEATURE, AND
    /// THAT IS THE WHOLE POINT OF W2b-6.** Before this move the character law
    /// lived inside `#[cfg(feature = "web")] app_state`, so not one of these
    /// tests could be written: the types they name did not exist in a web-free
    /// build. They are the reachability receipt, not extra coverage — the
    /// behaviour they assert was already asserted web-side and still is.
    ///
    /// ⚠️ **THE COMMAND MATTERS, AND THE OBVIOUS ONE IS WRONG.** This crate
    /// declares `default = ["web"]`, so `cargo test --lib` — and even
    /// `cargo test --lib --features ffi` — BUILD WITH THE WEB FEATURE ON. The
    /// web-free set is the one CI runs at `test.yml:1488`:
    ///
    /// ```text
    /// cargo test --lib --no-default-features --features ffi
    /// ```
    ///
    /// The first draft of this comment claimed these arms prove reachability
    /// because they pass under `cargo test --lib`. They do pass there, and it
    /// proved nothing: that build has `web` on, so the arms would have passed
    /// just as well with the module still gated. Same family as the brief's
    /// `cargo test --lib` / ffi trap — **the feature set you think you are
    /// testing is not the one cargo built.**
    ///
    /// Driven, so the arms are load-bearing rather than decorative: re-gate the
    /// module in `interpreter/mod.rs` and run the web-free command above — the
    /// count falls 2715 → 2711 and all four arms disappear from the run.
    fn panel() -> CharacterPanelState {
        CharacterPanelState::default()
    }

    fn attrs() -> CharacterAttrs {
        CharacterAttrs {
            font_family: "Georgia".into(),
            font_size: 30.0,
            font_weight: "bold".into(),
            font_style: "italic".into(),
            text_decoration: "underline".into(),
            text_transform: "uppercase".into(),
            font_variant: "small-caps".into(),
            baseline_shift: "super".into(),
            line_height: "36pt".into(),
            letter_spacing: "0.05em".into(),
            xml_lang: "fr".into(),
            aa_mode: "crisp".into(),
            rotate: "15".into(),
            horizontal_scale: "110".into(),
            vertical_scale: "120".into(),
            kerning: "Optical".into(),
        }
    }

    /// Every `panel.<key>` the Character panel's YAML declares. Read from the
    /// artifact, because a key list typed into a test is a claim about the
    /// panel that nothing re-checks when the panel changes — the seat's own
    /// "no typed expectations, derive them from the artifact's bytes" rule.
    fn declared_panel_keys() -> Vec<String> {
        let src = std::fs::read_to_string(
            concat!(env!("CARGO_MANIFEST_DIR"), "/../workspace/panels/character.yaml"))
            .expect("character.yaml is readable");
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
        assert!(out.len() > 20, "read only {} keys — the YAML's shape changed", out.len());
        out
    }

    /// **THE FIELD → GROUP TABLE, PARTITIONED AGAINST THE PANEL'S OWN YAML,
    /// AND EVERY NUMBER IS DERIVED.** The panel declares N keys; each either
    /// owns an element attribute or is UI-only, and the split must be exactly
    /// the censused eighteen against the seven `snap_*` flags. Drift in EITHER
    /// direction reds: a key added to the YAML with no mapping lands in
    /// `no_group` and is not one of the seven, and a mapping dropped from the
    /// table takes the count below eighteen. Both drove.
    #[test]
    fn the_yaml_keys_partition_into_the_censused_eighteen_and_the_seven_flags() {
        let declared = declared_panel_keys();
        let (owns, no_group): (Vec<&String>, Vec<&String>) = declared.iter()
            .partition(|k| CharacterEditGroup::from_field(k).is_some());
        assert_eq!(owns.len(), 18,
                   "the censused table is 18 (reference 18 · Rust 18 · Swift 18); \
                    the YAML now maps {}: {:?}", owns.len(), owns);
        let mut flags: Vec<&str> = no_group.iter().map(|s| s.as_str()).collect();
        flags.sort_unstable();
        assert_eq!(flags, ["snap_anchor_point", "snap_angular_guides", "snap_baseline",
                           "snap_glyph_bounds", "snap_proximity_guides",
                           "snap_to_glyph_visible", "snap_x_height"],
                   "a declared key owns no group and is not one of the seven UI-only flags");
        // Anti-vacuity: the partition covers the whole declared set, so neither
        // side can be right by being empty.
        assert_eq!(owns.len() + flags.len(), declared.len());
    }

    /// A key that owns no element attribute must map to no group, or a UI-only
    /// toggle pushes an undo step that changes nothing.
    #[test]
    fn ui_only_keys_own_no_group() {
        for k in ["snap_baseline", "snap_x_height", "snap_glyph_bounds",
                  "snap_to_glyph_visible", "snap_proximity_guides",
                  "snap_angular_guides", "snap_anchor_point", "not_a_field"] {
            assert!(CharacterEditGroup::from_field(k).is_none(), "{k}");
        }
    }

    /// **THE LAW ITSELF, ENGINE-SIDE: a field edit writes its OWN group and
    /// leaves the other fifteen attributes exactly as the element had them.**
    /// This is the clobber that `transcripts/CHARACTER.md` records — a Tracking
    /// edit on a 30pt bold italic underlined Georgia run resetting it to the
    /// panel's defaults — and until this move no build without `--features web`
    /// could even ask the question.
    #[test]
    fn an_edit_writes_only_its_own_group() {
        let base = attrs();
        let mut cp = panel();
        cp.font_size = 48.0;
        let out = character_with_group(base.clone(), &cp,
                                       CharacterEditGroup::from_field("font_size").unwrap());
        assert_eq!(out.font_size, 48.0, "the edited group did not land");
        // Anti-vacuity: the fixture differs from the panel's defaults on every
        // attribute below, so "unchanged" is a reading and not a tautology.
        assert_ne!(base.font_family, cp.font_family);
        assert_eq!(out.font_family, base.font_family);
        assert_eq!(out.font_weight, base.font_weight);
        assert_eq!(out.font_style, base.font_style);
        assert_eq!(out.text_decoration, base.text_decoration);
        assert_eq!(out.text_transform, base.text_transform);
        assert_eq!(out.font_variant, base.font_variant);
        assert_eq!(out.baseline_shift, base.baseline_shift);
        assert_eq!(out.letter_spacing, base.letter_spacing);
        assert_eq!(out.xml_lang, base.xml_lang);
        assert_eq!(out.aa_mode, base.aa_mode);
        assert_eq!(out.rotate, base.rotate);
        assert_eq!(out.horizontal_scale, base.horizontal_scale);
        assert_eq!(out.vertical_scale, base.vertical_scale);
        assert_eq!(out.kerning, base.kerning);
    }

    /// The sixteen element attributes, as `(name, value)`, so a change set can
    /// be computed without naming which group owns what — naming that here
    /// would re-implement `character_with_group` and the arm would agree with
    /// it by construction.
    fn as_pairs(a: &CharacterAttrs) -> Vec<(&'static str, String)> {
        vec![
            ("font_family", a.font_family.clone()),
            ("font_size", a.font_size.to_string()),
            ("font_weight", a.font_weight.clone()),
            ("font_style", a.font_style.clone()),
            ("text_decoration", a.text_decoration.clone()),
            ("text_transform", a.text_transform.clone()),
            ("font_variant", a.font_variant.clone()),
            ("baseline_shift", a.baseline_shift.clone()),
            ("line_height", a.line_height.clone()),
            ("letter_spacing", a.letter_spacing.clone()),
            ("xml_lang", a.xml_lang.clone()),
            ("aa_mode", a.aa_mode.clone()),
            ("rotate", a.rotate.clone()),
            ("horizontal_scale", a.horizontal_scale.clone()),
            ("vertical_scale", a.vertical_scale.clone()),
            ("kerning", a.kerning.clone()),
        ]
    }

    /// A panel whose every field differs from `attrs()`, so "this attribute did
    /// not change" is a reading and never an accident of two values matching.
    fn contrary_panel() -> CharacterPanelState {
        let mut cp = CharacterPanelState::default();
        cp.font_family = "Helvetica".into();
        cp.style_name = "Bold".into();
        cp.font_size = 48.0;
        cp.leading = 99.0;
        cp.kerning = "Metrics".into();
        cp.tracking = 250.0;
        cp.vertical_scale = 80.0;
        cp.horizontal_scale = 90.0;
        cp.baseline_shift = 7.0;
        cp.character_rotation = 45.0;
        cp.all_caps = false;
        cp.small_caps = false;
        cp.superscript = false;
        cp.subscript = true;
        cp.underline = false;
        cp.strikethrough = true;
        cp.language = "de".into();
        cp.anti_aliasing = "sharp".into();
        cp
    }

    /// **THE CLOBBER GUARD, OVER ALL EIGHTEEN GROUPS — the declared gap in
    /// W2b-6's price ("the 24 inputs' individual arms") for the apply side.**
    ///
    /// `transcripts/CHARACTER.md` records the defect this law exists to stop:
    /// a Tracking edit on a 30pt bold italic underlined Georgia run reset it to
    /// the panel's defaults — *sixteen attributes clobbered by one edit*. So
    /// for every key the panel declares: the edit must change at least one
    /// attribute (or the field is dead) and at most two (the largest groups —
    /// Style, Case — own exactly a pair), against a panel that differs from the
    /// element on every field.
    ///
    /// It deliberately does NOT assert WHICH attributes each group owns: that
    /// table is what `character_with_group` implements, and an arm that
    /// restated it would agree with the implementation by construction and
    /// survive any mutation of it.
    #[test]
    fn no_single_field_edit_clobbers_more_than_its_own_group() {
        let base = attrs();
        let cp = contrary_panel();
        let mut covered: std::collections::BTreeSet<&'static str> = Default::default();
        let mut sizes = Vec::new();
        for key in declared_panel_keys() {
            let Some(group) = CharacterEditGroup::from_field(&key) else { continue };
            let out = character_with_group(base.clone(), &cp, group);
            let before = as_pairs(&base);
            let after = as_pairs(&out);
            let changed: Vec<&'static str> = before.iter().zip(after.iter())
                .filter(|(b, a)| b.1 != a.1)
                .map(|(b, _)| b.0)
                .collect();
            assert!(!changed.is_empty(),
                    "`{key}` changed nothing: the field is dead, or the contrary \
                     panel happens to match the element on it");
            assert!(changed.len() <= 2,
                    "`{key}` wrote {} attributes {:?} — an edit must not reach \
                     outside its own group (CHARACTER.md, the field-scoped apply law)",
                    changed.len(), changed);
            sizes.push((key.clone(), changed.len()));
            covered.extend(changed);
        }
        assert_eq!(sizes.len(), 18, "not every mapped key was driven");
        // Anti-vacuity on the SWEEP, not just on each arm: if the groups
        // between them touched only one or two attributes, every assert above
        // would pass and the law would be untested over most of the element.
        assert!(covered.len() >= 12,
                "the eighteen edits touched only {} of the sixteen attributes \
                 {:?} — this arm is not exercising the law", covered.len(), covered);
    }

    /// The three groups with no tspan-level representation must say so, or a
    /// per-range write pushes an undo step that can express nothing.
    #[test]
    fn exactly_three_groups_cannot_be_written_on_a_range() {
        let cannot: Vec<&str> = ["font_family", "style_name", "font_size", "leading",
                                 "kerning", "tracking", "vertical_scale",
                                 "horizontal_scale", "baseline_shift", "superscript",
                                 "subscript", "character_rotation", "all_caps",
                                 "small_caps", "underline", "strikethrough",
                                 "language", "anti_aliasing"]
            .into_iter()
            .filter(|k| !CharacterEditGroup::from_field(k).unwrap().writes_tspan_field())
            .collect();
        assert_eq!(cannot, vec!["kerning", "vertical_scale", "horizontal_scale"]);
    }
}
