//! SVG import and export.
//!
//! Internal coordinates are in points (pt). SVG coordinates are in pixels (px).
//! Conversion factor: 96/72 (CSS px per pt at 96 DPI).

use std::collections::HashMap;
use std::rc::Rc;

use crate::document::document::Document;
use crate::geometry::element::*;
use crate::geometry::normalize::{normalize_document, dedupe_element_ids};

const PT_TO_PX: f64 = 96.0 / 72.0;
const PX_TO_PT: f64 = 72.0 / 96.0;

fn px(v: f64) -> f64 {
    v * PT_TO_PX
}

fn pt(v: f64) -> f64 {
    v * PX_TO_PT
}

/// The workspace-private stroke PROFILE attributes: the brush slug, its
/// per-instance overrides, and the variable-width points.
///
/// SVG is this app's SAVE format (`menu_bar`'s `"save"` arm writes
/// `document_to_svg`), so an attribute the writer omits is artwork the artist
/// loses on save. The reader already accepted `jas:stroke-brush` and the writer
/// never wrote it — an asymmetry that made the round trip lossy in one
/// direction only. Width points were carried by neither side.
///
/// `jas:width-points` is a space-separated list of `t,left,right` triples,
/// each number through the same `fmt` as every other coordinate (so it
/// inherits the four-decimal floor rather than inventing a second precision
/// rule — see BOARD-the-four-decimal-floor). Emitted ONLY when non-default, so
/// existing files stay byte-identical.
fn width_points_value(pts: &[crate::geometry::element::StrokeWidthPoint]) -> String {
    pts.iter()
        .map(|p| format!("{},{},{}", fmt(p.t), fmt(p.width_left), fmt(p.width_right)))
        .collect::<Vec<_>>()
        .join(" ")
}

fn parse_width_points(s: &str) -> Vec<crate::geometry::element::StrokeWidthPoint> {
    use crate::geometry::element::StrokeWidthPoint;
    s.split_whitespace()
        .filter_map(|triple| {
            let mut it = triple.split(',');
            let t = it.next()?.parse().ok()?;
            let width_left = it.next()?.parse().ok()?;
            let width_right = it.next()?.parse().ok()?;
            // A trailing field means a newer writer; refuse the row rather
            // than silently reading three of four.
            if it.next().is_some() {
                return None;
            }
            Some(StrokeWidthPoint { t, width_left, width_right })
        })
        .collect()
}

fn stroke_profile_attrs(
    width_points: &[crate::geometry::element::StrokeWidthPoint],
    stroke_brush: &Option<String>,
    stroke_brush_overrides: &Option<String>,
) -> String {
    let mut s = String::new();
    if !width_points.is_empty() {
        s += &format!(" jas:width-points=\"{}\"", width_points_value(width_points));
    }
    if let Some(b) = stroke_brush.as_deref().filter(|b| !b.is_empty()) {
        s += &format!(" jas:stroke-brush=\"{}\"", escape_xml(b));
    }
    if let Some(o) = stroke_brush_overrides.as_deref().filter(|o| !o.is_empty()) {
        s += &format!(" jas:stroke-brush-overrides=\"{}\"", escape_xml(o));
    }
    s
}

/// FLOATSPELL — the one spelling of a FULL-PRECISION f64 both ports must write.
///
/// RULED 2026-08-05 (council; the ruling's substance is inlined below): the
/// transform matrix carries full precision while positions and radii stay at
/// 4 dp. "Full precision" has no single spelling, and the two ports do not
/// agree on one — Rust's `Display` writes `1e-7` as `0.0000001` where Swift
/// writes `1e-07`, and Swift gives integral values a trailing `.0` that Rust
/// omits. **The 4 dp floor was accidentally shielding us from this**, because
/// `{:.4}` is fixed-notation in both languages; removing the floor without
/// fixing the spelling would make the two ports write DIFFERENT FILES for the
/// same document.
///
/// The rule: the shortest decimal that round-trips, in FIXED notation, never
/// exponent, no trailing `.0`. Rust's `Display` already satisfies it — this
/// function exists to NAME the contract and give the cross-language corpus
/// (`test_fixtures/algorithms/float_format.json`) something to bind to, so a
/// future formatting change reds instead of silently diverging from Swift.
/// Twin: `fmtFull` in JasSwift/Sources/Geometry/Svg.swift.
pub fn fmt_full(v: f64) -> String {
    format!("{}", v)
}

fn fmt(v: f64) -> String {
    let s = format!("{:.4}", v);
    let s = s.trim_end_matches('0');
    let s = s.trim_end_matches('.');
    s.to_string()
}

/// THE MATRIX-ENTRY SPELLING RULE (JYH, R2, 2026-07-31). Print `v` so that
/// reading it back yields the SAME f64, bit for bit:
///
///   1. NO EXPONENT NOTATION, ever — positional digits at any magnitude.
///   2. EXACTLY ONE decimal point, always present.
///   3. Shortest digit string that round-trips, with trailing fraction
///      zeros stripped down to — but not past — ONE digit (`1` → `1.0`).
///   4. `-0.0` keeps its sign, as [`fmt`] already does: `-0.0`.
///
/// SPELLED IDENTICALLY IN JasSwift — `fmtMatrixEntry` in
/// `JasSwift/Sources/Geometry/Svg.swift`. The two comments cross-reference
/// each other; neither may move without the other. The literal bytes are
/// pinned by `matrix_entry_spelling_matches_the_shared_vector_table`, whose
/// comment also names the ONE BAND where the two ports are not yet known to
/// agree: JasSwift reaches rule 3 by searching for the fewest DECIMAL
/// PLACES that round-trip, which is the same function as fewest
/// SIGNIFICANT DIGITS only below |v| ≈ 1e11 — far above any real multiplier,
/// but not proven, and so not claimed.
///
/// # Why matrix entries and not positions
///
/// `a`/`b`/`c`/`d` are MULTIPLIERS. 1e-4 of a multiplier is not 1e-4 of
/// anything — it is 1e-4 × whatever it multiplies, so 0.15pt on a 5000pt
/// element. Rotate 30°: `a = cos30 = 0.8660254037844387` printed at 4dp is
/// `0.866`, and the reopened matrix has `a² + b² = 0.999956` — NO LONGER
/// ORTHONORMAL, a 2.2e-5 shrink with a shear baked in. It COMPOUNDS,
/// because every later transform composes onto the drifted one
/// (`op_apply.rs`, `matrix.multiply(&current)`): rotate a logo, save,
/// reopen, rotate back, and it does not land on its guides.
///
/// A POSITION at 4dp is 0.0001pt, far below what any artist or renderer
/// resolves. Same quantizer, two entirely different meanings — which is
/// why `x`, `y`, `cx`, `rx`, path coordinates and the matrix's OWN
/// TRANSLATION `e`/`f` all still go through [`fmt`]. `e`/`f` are positions
/// that happen to live in a matrix; they are also the only two entries that
/// cross the pt↔px conversion, which is not exactly invertible (`fl(4/3)`
/// then ×0.75 loses an ulp for ~18% of values), so full precision would buy
/// them long noisy digit strings and still not bit-exact reloading. At 4dp
/// they SETTLE on the first save and never move again —
/// `a_reopened_matrix_is_bit_identical_on_every_later_save_and_reopen`.
///
/// # Why this exact spelling, and not something simpler
///
/// Three cheaper spellings were measured and rejected:
///
/// * A LONG FIXED PRECISION (`{:.17}`) breaks BOTH ports' readers —
///   serde_json and JSONSerialization each mis-round 19-significant-digit
///   literals by one ulp. Precision is not the same thing as fidelity.
/// * A BARE `format!("{}")` diverges from Swift in BYTES while agreeing in
///   VALUE, which is the worst of both: "shortest round-trip" is spelled
///   three ways. Rust's `Display` never uses exponent notation and never
///   appends `.0`; Swift's `.description` and Python's `repr` do both,
///   outside roughly [1e-4, 1e16). `1e-5` is `0.00001` in Rust and `1e-05`
///   in Swift. Rules 1 and 2 exist to pin the intersection: rule 1 is what
///   Rust already does and Swift must be told to do, rule 2 is what Swift
///   already does and Rust must be told to do.
/// * A NAIVE `{}` also regresses `-0.0` to `-0`; rule 2 restores the sign
///   AND the point in one move.
///
/// THE SURFACE IS DELIBERATELY NARROW — matrix multipliers only, the two
/// `matrix(...)` writers below and nothing else. That narrowness is the
/// whole reason this is safe. Applying it corpus-wide would make
/// byte-level float formatting a cross-language contract in the very layer
/// that exists to detect contract breaks. DO NOT WIDEN IT.
///
/// Non-finite entries are excluded and keep their pre-existing behaviour
/// ([`fmt`], which yields `NaN`/`inf`): SVG's number grammar cannot express
/// them at any precision, so `parse_transform` drops such a matrix on
/// reload either way, and inventing a shared spelling for them would add a
/// cross-port contract without adding a representable value. A subnormal
/// entry expands to ~330 positional characters; that is a bounded cost on a
/// matrix already too singular to invert.
fn fmt_matrix_entry(v: f64) -> String {
    if !v.is_finite() {
        return fmt(v);
    }
    // Rust's `Display` for f64 is already rules 1 and 3: positional at
    // every magnitude, and the shortest digit string that round-trips
    // (so never a trailing fraction zero). Rule 2 is the one addition.
    let mut s = format!("{}", v);
    if !s.contains('.') {
        s.push_str(".0");
    }
    s
}

/// The `matrix(a,b,c,d,e,f)` value shared by the two writers that emit one —
/// the standard `transform` attribute and the Symbols P4 private
/// `data-jas-instance-transform`. ONE function, so the multipliers cannot
/// gain precision at one site and silently keep 4dp at the other; see
/// [`fmt_matrix_entry`] for why the six entries split two ways.
fn matrix_value(t: &Transform) -> String {
    format!(
        "matrix({},{},{},{},{},{})",
        fmt_matrix_entry(t.a), fmt_matrix_entry(t.b),
        fmt_matrix_entry(t.c), fmt_matrix_entry(t.d),
        fmt(px(t.e)), fmt(px(t.f))
    )
}

fn color_str(c: &Color) -> String {
    let (rv, gv, bv, a) = c.to_rgba();
    let r = (rv * 255.0).round() as u8;
    let g = (gv * 255.0).round() as u8;
    let b = (bv * 255.0).round() as u8;
    if a < 1.0 {
        format!("rgba({},{},{},{})", r, g, b, fmt(a))
    } else {
        format!("rgb({},{},{})", r, g, b)
    }
}

fn fill_attrs(fill: &Option<Fill>) -> String {
    match fill {
        None => " fill=\"none\"".to_string(),
        Some(f) => {
            let mut s = format!(" fill=\"{}\"", color_str(&f.color));
            if f.opacity < 1.0 {
                s.push_str(&format!(" fill-opacity=\"{}\"", fmt(f.opacity)));
            }
            s
        }
    }
}

fn stroke_attrs(stroke: &Option<Stroke>) -> String {
    match stroke {
        None => " stroke=\"none\"".to_string(),
        Some(s) => {
            let mut parts = vec![format!(" stroke=\"{}\"", color_str(&s.color))];
            parts.push(format!(" stroke-width=\"{}\"", fmt(px(s.width))));
            match s.linecap {
                LineCap::Round => parts.push(" stroke-linecap=\"round\"".to_string()),
                LineCap::Square => parts.push(" stroke-linecap=\"square\"".to_string()),
                _ => {}
            }
            match s.linejoin {
                LineJoin::Round => parts.push(" stroke-linejoin=\"round\"".to_string()),
                LineJoin::Bevel => parts.push(" stroke-linejoin=\"bevel\"".to_string()),
                _ => {}
            }
            if s.opacity < 1.0 {
                parts.push(format!(" stroke-opacity=\"{}\"", fmt(s.opacity)));
            }
            // STANDARD SVG presentation attributes, both identity-omitted so
            // a plain stroke stays byte-clean. Lengths ride the same pt→px
            // conversion as `stroke-width`; `stroke-miterlimit` is a ratio and
            // is unitless. Until CODECSAT neither was written and neither was
            // read, so a dashed stroke saved to SVG came back SOLID in both
            // ports — while the jas-private attribute that says HOW to lay the
            // dashes out (below) was carried faithfully.
            if s.dash_len > 0 {
                let vals: Vec<String> = s.dash_array().iter()
                    .map(|v| fmt(px(*v)))
                    .collect();
                parts.push(format!(" stroke-dasharray=\"{}\"", vals.join(",")));
            }
            if s.miter_limit != 10.0 {
                parts.push(format!(" stroke-miterlimit=\"{}\"", fmt(s.miter_limit)));
            }
            // Custom workspace-private attribute — see DASH_ALIGN.md
            // §Persistence. Identity-omitted when false; round-trips
            // through jas-authored files; ignored on import from
            // non-jas SVG.
            if s.dash_align_anchors {
                parts.push(" data-jas-dash-align-anchors=\"true\"".to_string());
            }
            // Arrowheads — workspace-private, in the `jas:` namespace declared on
            // the root <svg> (see JAS_NS). Each attr is identity-omitted at its
            // default so a plain stroke stays byte-clean; parsed back by
            // parse_stroke, ignored on import from non-jas SVG.
            if s.start_arrow != Arrowhead::None {
                parts.push(format!(" jas:start-arrow=\"{}\"", s.start_arrow.as_str()));
            }
            if s.end_arrow != Arrowhead::None {
                parts.push(format!(" jas:end-arrow=\"{}\"", s.end_arrow.as_str()));
            }
            if s.start_arrow_scale != 100.0 {
                parts.push(format!(" jas:start-arrow-scale=\"{}\"", fmt(s.start_arrow_scale)));
            }
            if s.end_arrow_scale != 100.0 {
                parts.push(format!(" jas:end-arrow-scale=\"{}\"", fmt(s.end_arrow_scale)));
            }
            if s.arrow_align == ArrowAlign::CenterAtEnd {
                parts.push(" jas:arrow-align=\"center_at_end\"".to_string());
            }
            parts.join("")
        }
    }
}

fn transform_attr(t: &Option<Transform>) -> String {
    match t {
        None => String::new(),
        Some(t) => format!(" transform=\"{}\"", matrix_value(t)),
    }
}

fn opacity_attr(opacity: f64) -> String {
    if opacity >= 1.0 {
        String::new()
    } else {
        format!(" opacity=\"{}\"", fmt(opacity))
    }
}

/// Inkscape-compatible label attribute for the user-visible element
/// name. We use inkscape:label rather than a <title> child because
/// our writers emit self-closing tags for shapes; switching every
/// writer to open/close just to host a child would be intrusive.
/// Reader accepts both inkscape:label and a <title> child for
/// interop with tools that round-trip through one or the other.
fn name_attr(name: &Option<String>) -> String {
    match name {
        None => String::new(),
        Some(n) if n.is_empty() => String::new(),
        Some(n) => format!(" inkscape:label=\"{}\"", escape_xml(n)),
    }
}

/// The `jas:tool-origin` attribute identifying the tool that produced this
/// element (BLOB_BRUSH_TOOL.md §Fill and stroke). `parse_common` has always
/// READ this attribute for every element; until CODECSAT nothing wrote it, so
/// Rust dropped it at the SVG boundary while JasSwift's `<path>` writer
/// carried it. Written for `<path>` only, which is where Blob Brush commits
/// and where JasSwift both writes and reads it — widening the attribute to
/// every element kind would put Rust ahead of the other port's reader and is a
/// design question, not a repair.
fn tool_origin_attr(origin: &Option<String>) -> String {
    match origin {
        None => String::new(),
        Some(s) if s.is_empty() => String::new(),
        Some(s) => format!(" jas:tool-origin=\"{}\"", escape_xml(s)),
    }
}

/// The standard SVG `id` attribute for an element's stable identity, followed
/// by the workspace-private `jas:locked` flag.
///
/// `id` is emitted ONLY when set (Some/non-empty) and `jas:locked` ONLY when
/// true, so an id-less unlocked element serializes byte-identically to before —
/// keeping the SVG fixtures and the cross-language test_json comparison green.
/// Measured when `jas:locked` was added (LOCKSVG, 2026-07-28): 0 of the
/// elements across the 60 SVG fixtures carry `locked = true`, so the
/// conditional attribute moved ZERO goldens. Same convention as
/// `fill-rule="evenodd"`, `data-jas-dash-align-anchors` and the five arrowhead
/// attributes.
///
/// WHY THE TWO FIELDS SHARE ONE HELPER, and it is not tidiness. `element_svg`
/// hand-inlines its attribute lists in sixteen arms, so an attribute added
/// per-arm is added SIXTEEN TIMES and a missed arm is a silent drop that no
/// compiler can see — the omission class `common_attrs_no_name` was created to
/// close for opacity/transform/id, and the one JasSwift keeps re-learning
/// (`project_swift_copy_site_omission_class`). `id_attr` was already called by
/// EVERY arm, so widening its signature makes the COMPILER enumerate the
/// sixteen sites instead of a human. Mirrors JasSwift's `idLockAttrs`.
///
/// `urn:jas:1` is the namespace, not `sodipodi:insensitive` or `data-locked`:
/// it is where the sibling CommonProps field `tool_origin` already lives
/// (`jas:tool-origin`, written below and read by `parse_common`), and JasSwift
/// declares `xmlns:jas` by matching the ` jas:` PREFIX in its emitted body, so
/// a new `jas:`-namespaced attribute is covered by that guard automatically.
/// An attribute in any other prefix would need its own declaration trigger, and
/// forgetting one makes Foundation reject the WHOLE document.
/// The Opacity panel's two page-level blending flags, as workspace-private
/// attributes on a `<g>`. Written ONLY when true, so an ordinary group or
/// layer serializes byte-identically to before and no shipped golden moved
/// (measured: 0 of the containers across the SVG fixtures carry either flag).
///
/// WHY A `jas:` EXTENSION AND NOT A STANDARD ATTRIBUTE. There is no standard
/// one. CSS `isolation: isolate` is the nearest thing to isolated blending,
/// but it is a RENDERING property a jas file would then be promising to
/// honour, and neither port's renderer implements either flag yet
/// (transcripts/OPACITY.md marks both `pending_renderer`); knockout groups are
/// a PDF transparency-group concept with no SVG analogue at all. So this is
/// exactly the shape `jas:locked` landed in one day earlier -- a
/// workspace-private boolean in the `urn:jas:1` namespace, alongside the
/// sibling `jas:tool-origin`. Emitting a standard property we do not honour
/// would be the guess the Preservation Law forbids; dropping the value
/// silently was the defect. Mirrors JasSwift's `containerBlendAttrs`.
fn container_blend_attrs(isolated_blending: bool, knockout_group: bool) -> String {
    let mut s = String::new();
    if isolated_blending {
        s.push_str(" jas:isolated-blending=\"true\"");
    }
    if knockout_group {
        s.push_str(" jas:knockout-group=\"true\"");
    }
    s
}

fn id_lock_attrs(id: &Option<String>, locked: bool) -> String {
    let id_part = match id {
        None => String::new(),
        Some(s) if s.is_empty() => String::new(),
        Some(s) => format!(" id=\"{}\"", escape_xml(s)),
    };
    if locked {
        format!("{} jas:locked=\"true\"", id_part)
    } else {
        id_part
    }
}

/// The opacity+transform+id attribute tail shared by the text family
/// (Text/TextPath) and live elements. These writers hand-inline their many
/// type-specific attributes, and historically forgot the common ones — Text
/// dropped both `id` and `transform`, TextPath dropped `id`. Funnelling the
/// common tail through one helper (mirroring `test_json`'s `common_fields`)
/// means no future edit to these arms can silently drop one again. Each
/// sub-helper emits nothing for an unset value, so id-/transform-less elements
/// stay byte-identical to the pre-helper output and the fixtures remain green.
///
/// `name` is excluded, and as of 2026-07-27 the only remaining callers are the
/// TEXT FAMILY (Text / TextPath). That omission is a BANKED GAP, not a rule: a
/// `<text>` the artist has named exports with no `inkscape:label` and comes
/// back unnamed, in BOTH active ports (JasSwift's SVG writer calls `nameAttr`
/// at exactly nine arms — the seven shapes plus group and layer — and text is
/// not among them). Symmetric, so no port-vs-port gate can see it; see the
/// `svg-text-family-drops-inkscape-label` row in scripts/corpus_manifest.json.
///
/// The LIVE arms used to route through here too, which is why a named compound
/// survived a save/load in neither port. They now use [`common_attrs`].
fn common_attrs_no_name(c: &CommonProps) -> String {
    format!(
        "{}{}{}",
        opacity_attr(c.opacity),
        transform_attr(&c.transform),
        id_lock_attrs(&c.id, c.locked),
    )
}

/// [`common_attrs_no_name`] plus the `inkscape:label` name, for the LIVE
/// element arms. ANY ELEMENT CARRIES A NAME; a compound / reference /
/// recorded / generated element is no exception, and this port's SVG READER
/// already lifted the label into `common.name` generically — only the writer
/// dropped it. `name_attr` emits nothing for `None`, so an unnamed live
/// element serializes byte-identically to before and no existing golden moves.
fn common_attrs(c: &CommonProps) -> String {
    format!("{}{}", common_attrs_no_name(c), name_attr(&c.name))
}

fn path_data(commands: &[PathCommand]) -> String {
    let mut parts = Vec::new();
    for cmd in commands {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                parts.push(format!("M{},{}", fmt(px(*x)), fmt(px(*y))));
            }
            PathCommand::LineTo { x, y } => {
                parts.push(format!("L{},{}", fmt(px(*x)), fmt(px(*y))));
            }
            PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                parts.push(format!(
                    "C{},{} {},{} {},{}",
                    fmt(px(*x1)), fmt(px(*y1)),
                    fmt(px(*x2)), fmt(px(*y2)),
                    fmt(px(*x)), fmt(px(*y))
                ));
            }
            PathCommand::SmoothCurveTo { x2, y2, x, y } => {
                parts.push(format!(
                    "S{},{} {},{}",
                    fmt(px(*x2)), fmt(px(*y2)),
                    fmt(px(*x)), fmt(px(*y))
                ));
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                parts.push(format!(
                    "Q{},{} {},{}",
                    fmt(px(*x1)), fmt(px(*y1)),
                    fmt(px(*x)), fmt(px(*y))
                ));
            }
            PathCommand::SmoothQuadTo { x, y } => {
                parts.push(format!("T{},{}", fmt(px(*x)), fmt(px(*y))));
            }
            PathCommand::ArcTo { rx, ry, x_rotation, large_arc, sweep, x, y } => {
                let la = if *large_arc { 1 } else { 0 };
                let sw = if *sweep { 1 } else { 0 };
                parts.push(format!(
                    "A{},{} {} {},{} {},{}",
                    fmt(px(*rx)), fmt(px(*ry)),
                    fmt(*x_rotation), la, sw,
                    fmt(px(*x)), fmt(px(*y))
                ));
            }
            PathCommand::ClosePath => {
                parts.push("Z".to_string());
            }
        }
    }
    parts.join(" ")
}

fn escape_xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

pub fn element_svg(elem: &Element, indent: &str) -> String {
    match elem {
        Element::Line(e) => {
            format!(
                "{}<line x1=\"{}\" y1=\"{}\" x2=\"{}\" y2=\"{}\"{}{}{}{}{}/>\n",
                indent,
                fmt(px(e.x1)), fmt(px(e.y1)), fmt(px(e.x2)), fmt(px(e.y2)),
                stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity),
                transform_attr(&e.common.transform),
                id_lock_attrs(&e.common.id, e.common.locked),
                name_attr(&e.common.name),
            )
        }
        Element::Rect(e) => {
            let mut rxy = String::new();
            if e.rx > 0.0 {
                rxy.push_str(&format!(" rx=\"{}\"", fmt(px(e.rx))));
            }
            if e.ry > 0.0 {
                rxy.push_str(&format!(" ry=\"{}\"", fmt(px(e.ry))));
            }
            format!(
                "{}<rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\"{}{}{}{}{}{}{}/>\n",
                indent,
                fmt(px(e.x)), fmt(px(e.y)), fmt(px(e.width)), fmt(px(e.height)),
                rxy,
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
                id_lock_attrs(&e.common.id, e.common.locked),
                name_attr(&e.common.name),
            )
        }
        Element::Ellipse(e) => {
            // THE TAG IS RE-DERIVED, not stored. Equal radii emit `<circle>`,
            // so a file's `<circle>` elements survive a round trip even though
            // the model no longer has a circle kind.
            //
            // THE TAG IS DECIDED FROM THE VALUES AS THEY WILL BE PRINTED, so
            // the export is SELF-CONSISTENT: what we write is what we would
            // read back. `fmt` prints four decimals, and an exact `rx == ry`
            // test asked a question the file cannot answer -- radii differing
            // below that precision (rx=5.00001, ry=5.00002) both print "5", so
            // the element went out as `<ellipse rx="5" ry="5">`, a file that
            // reopens EXACTLY round. The tag flipped to `<circle>` on the very
            // next save, and the derived type token
            // (`algorithms::layers_filter::type_value`) and the auto-generated
            // label flipped with it. Comparing the PRINTED strings settles both
            // directions at once: the `<circle>` we write re-reads round, and
            // an `<ellipse>` we write re-reads squashed. JasSwift's
            // `Sources/Geometry/Svg.swift` spells this the same way.
            //
            // THE MIRROR IS A REWRITE WE ACCEPT: an author's deliberate
            // `<ellipse rx="5" ry="5">` comes back out as `<circle>`. That is
            // the price of one kind, and it is pinned by
            // `round_ellipses_serialize_as_circle_and_squashed_ones_do_not`
            // so it stays a decision rather than a surprise.
            //
            // The transform is NOT consulted. It is emitted as its own
            // attribute and survives either tag, and a `<circle transform>`
            // re-reads to exactly what was written.
            let common_attrs = format!(
                "{}{}{}{}{}{}",
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
                id_lock_attrs(&e.common.id, e.common.locked),
                name_attr(&e.common.name),
            );
            // The very strings the attributes will carry, so the tag cannot
            // disagree with the numbers beside it.
            let rx_txt = fmt(px(e.rx));
            let ry_txt = fmt(px(e.ry));
            if rx_txt == ry_txt {
                format!(
                    "{}<circle cx=\"{}\" cy=\"{}\" r=\"{}\"{}/>\n",
                    indent, fmt(px(e.cx)), fmt(px(e.cy)), rx_txt, common_attrs,
                )
            } else {
                format!(
                    "{}<ellipse cx=\"{}\" cy=\"{}\" rx=\"{}\" ry=\"{}\"{}/>\n",
                    indent, fmt(px(e.cx)), fmt(px(e.cy)),
                    rx_txt, ry_txt, common_attrs,
                )
            }
        }
        Element::Polyline(e) => {
            let ps: String = e.points.iter()
                .map(|(x, y)| format!("{},{}", fmt(px(*x)), fmt(px(*y))))
                .collect::<Vec<_>>()
                .join(" ");
            format!(
                "{}<polyline points=\"{}\"{}{}{}{}{}{}/>\n",
                indent, ps,
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
                id_lock_attrs(&e.common.id, e.common.locked),
                name_attr(&e.common.name),
            )
        }
        Element::Polygon(e) => {
            let ps: String = e.points.iter()
                .map(|(x, y)| format!("{},{}", fmt(px(*x)), fmt(px(*y))))
                .collect::<Vec<_>>()
                .join(" ");
            format!(
                "{}<polygon points=\"{}\"{}{}{}{}{}{}/>\n",
                indent, ps,
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
                id_lock_attrs(&e.common.id, e.common.locked),
                name_attr(&e.common.name),
            )
        }
        Element::Path(e) => {
            let fr_attr = match e.fill_rule {
                crate::geometry::element::FillRule::EvenOdd => " fill-rule=\"evenodd\"",
                crate::geometry::element::FillRule::NonZero => "",
            };
            format!(
                "{}<path d=\"{}\"{}{}{}{}{}{}{}{}{}/>\n",
                indent,
                path_data(&e.d),
                fill_attrs(&e.fill), stroke_attrs(&e.stroke), fr_attr,
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
                tool_origin_attr(&e.common.tool_origin),
                id_lock_attrs(&e.common.id, e.common.locked),
                name_attr(&e.common.name),
                stroke_profile_attrs(
                    &e.width_points, &e.stroke_brush, &e.stroke_brush_overrides,
                ),
            )
        }
        Element::Text(e) => {
            let mut area_attrs = String::new();
            if e.width > 0.0 && e.height > 0.0 {
                area_attrs = format!(
                    " style=\"inline-size: {}px; white-space: pre-wrap;\"",
                    fmt(px(e.width))
                );
            }
            let fw_attr = if e.font_weight != "normal" {
                format!(" font-weight=\"{}\"", e.font_weight)
            } else { String::new() };
            let fst_attr = if e.font_style != "normal" {
                format!(" font-style=\"{}\"", e.font_style)
            } else { String::new() };
            let td_attr = if e.text_decoration != "none" && !e.text_decoration.is_empty() {
                format!(" text-decoration=\"{}\"", e.text_decoration)
            } else { String::new() };
            let tt_attr = if !e.text_transform.is_empty() {
                format!(" text-transform=\"{}\"", e.text_transform)
            } else { String::new() };
            let fv_attr = if !e.font_variant.is_empty() {
                format!(" font-variant=\"{}\"", e.font_variant)
            } else { String::new() };
            let bs_attr = if !e.baseline_shift.is_empty() {
                format!(" baseline-shift=\"{}\"", e.baseline_shift)
            } else { String::new() };
            let lh_attr = if !e.line_height.is_empty() {
                format!(" line-height=\"{}\"", e.line_height)
            } else { String::new() };
            let ls_attr = if !e.letter_spacing.is_empty() {
                format!(" letter-spacing=\"{}\"", e.letter_spacing)
            } else { String::new() };
            let lang_attr = if !e.xml_lang.is_empty() {
                format!(" xml:lang=\"{}\"", escape_xml(&e.xml_lang))
            } else { String::new() };
            let aa_attr = if !e.aa_mode.is_empty() {
                format!(" urn:jas:1:aa-mode=\"{}\"", escape_xml(&e.aa_mode))
            } else { String::new() };
            let rotate_attr = if !e.rotate.is_empty() {
                format!(" rotate=\"{}\"", e.rotate)
            } else { String::new() };
            let hs_attr = if !e.horizontal_scale.is_empty() {
                format!(" horizontal-scale=\"{}\"", e.horizontal_scale)
            } else { String::new() };
            let vs_attr = if !e.vertical_scale.is_empty() {
                format!(" vertical-scale=\"{}\"", e.vertical_scale)
            } else { String::new() };
            let kern_attr = if !e.kerning.is_empty() {
                format!(" urn:jas:1:kerning-mode=\"{}\"", escape_xml(&e.kerning))
            } else { String::new() };
            let svg_y = e.y + e.font_size * 0.8;
            let is_flat = e.tspans.len() == 1 && e.tspans[0].has_no_overrides();
            if is_flat {
                // Pre-Tspan-compatible emission: no <tspan> wrapper.
                format!(
                    "{}<text x=\"{}\" y=\"{}\" font-family=\"{}\" font-size=\"{}\"{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}>{}</text>\n",
                    indent,
                    fmt(px(e.x)), fmt(px(svg_y)),
                    escape_xml(&e.font_family), fmt(px(e.font_size)),
                    fw_attr, fst_attr, td_attr, tt_attr, fv_attr, bs_attr,
                    lh_attr, ls_attr, lang_attr, aa_attr,
                    rotate_attr, hs_attr, vs_attr, kern_attr,
                    area_attrs,
                    fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                    common_attrs_no_name(&e.common),
                    escape_xml(&e.content()),
                )
            } else {
                // Multi-tspan or overriding tspan: wrap children, carry
                // xml:space="preserve" so inter-glyph whitespace is stable
                // across round-trips (TSPAN.md SVG serialization).
                let tspan_xml: String = e.tspans.iter().map(tspan_svg).collect();
                format!(
                    "{}<text x=\"{}\" y=\"{}\" font-family=\"{}\" font-size=\"{}\"{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{} xml:space=\"preserve\">{}</text>\n",
                    indent,
                    fmt(px(e.x)), fmt(px(svg_y)),
                    escape_xml(&e.font_family), fmt(px(e.font_size)),
                    fw_attr, fst_attr, td_attr, tt_attr, fv_attr, bs_attr,
                    lh_attr, ls_attr, lang_attr, aa_attr,
                    rotate_attr, hs_attr, vs_attr, kern_attr,
                    area_attrs,
                    fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                    common_attrs_no_name(&e.common),
                    tspan_xml,
                )
            }
        }
        Element::TextPath(e) => {
            let offset_attr = if e.start_offset > 0.0 {
                format!(" startOffset=\"{}%\"", fmt(e.start_offset * 100.0))
            } else { String::new() };
            let fw_attr = if e.font_weight != "normal" {
                format!(" font-weight=\"{}\"", e.font_weight)
            } else { String::new() };
            let fst_attr = if e.font_style != "normal" {
                format!(" font-style=\"{}\"", e.font_style)
            } else { String::new() };
            let td_attr = if e.text_decoration != "none" && !e.text_decoration.is_empty() {
                format!(" text-decoration=\"{}\"", e.text_decoration)
            } else { String::new() };
            let tt_attr = if !e.text_transform.is_empty() {
                format!(" text-transform=\"{}\"", e.text_transform)
            } else { String::new() };
            let fv_attr = if !e.font_variant.is_empty() {
                format!(" font-variant=\"{}\"", e.font_variant)
            } else { String::new() };
            let bs_attr = if !e.baseline_shift.is_empty() {
                format!(" baseline-shift=\"{}\"", e.baseline_shift)
            } else { String::new() };
            let lh_attr = if !e.line_height.is_empty() {
                format!(" line-height=\"{}\"", e.line_height)
            } else { String::new() };
            let ls_attr = if !e.letter_spacing.is_empty() {
                format!(" letter-spacing=\"{}\"", e.letter_spacing)
            } else { String::new() };
            let lang_attr = if !e.xml_lang.is_empty() {
                format!(" xml:lang=\"{}\"", escape_xml(&e.xml_lang))
            } else { String::new() };
            let aa_attr = if !e.aa_mode.is_empty() {
                format!(" urn:jas:1:aa-mode=\"{}\"", escape_xml(&e.aa_mode))
            } else { String::new() };
            let rotate_attr = if !e.rotate.is_empty() {
                format!(" rotate=\"{}\"", e.rotate)
            } else { String::new() };
            let hs_attr = if !e.horizontal_scale.is_empty() {
                format!(" horizontal-scale=\"{}\"", e.horizontal_scale)
            } else { String::new() };
            let vs_attr = if !e.vertical_scale.is_empty() {
                format!(" vertical-scale=\"{}\"", e.vertical_scale)
            } else { String::new() };
            let kern_attr = if !e.kerning.is_empty() {
                format!(" urn:jas:1:kerning-mode=\"{}\"", escape_xml(&e.kerning))
            } else { String::new() };
            let is_flat = e.tspans.len() == 1 && e.tspans[0].has_no_overrides();
            let (space_attr, body) = if is_flat {
                (String::new(), escape_xml(&e.content()))
            } else {
                (
                    " xml:space=\"preserve\"".to_string(),
                    e.tspans.iter().map(tspan_svg).collect::<String>(),
                )
            };
            format!(
                "{}<text{}{} font-family=\"{}\" font-size=\"{}\"{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}><textPath path=\"{}\"{}{}>{}</textPath></text>\n",
                indent,
                fill_attrs(&e.fill), stroke_attrs(&e.stroke),
                escape_xml(&e.font_family), fmt(px(e.font_size)),
                fw_attr, fst_attr, td_attr, tt_attr, fv_attr, bs_attr,
                lh_attr, ls_attr, lang_attr, aa_attr,
                rotate_attr, hs_attr, vs_attr, kern_attr,
                common_attrs_no_name(&e.common),
                path_data(&e.d), offset_attr, space_attr,
                body,
            )
        }
        Element::Layer(e) => {
            // inkscape:groupmode="layer" lets the parser distinguish
            // a Layer from a named Group (both carry inkscape:label).
            let mut lines = vec![format!(
                "{}<g inkscape:groupmode=\"layer\"{}{}{}{}{}>",
                indent, id_lock_attrs(&e.common.id, e.common.locked), name_attr(&e.common.name),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
                container_blend_attrs(e.isolated_blending, e.knockout_group),
            )];
            let child_indent = format!("{}  ", indent);
            for child in &e.children {
                lines.push(element_svg(child, &child_indent));
            }
            lines.push(format!("{}</g>", indent));
            lines.join("\n")
        }
        Element::Group(e) => {
            let mut lines = vec![format!(
                "{}<g{}{}{}{}{}>",
                indent, id_lock_attrs(&e.common.id, e.common.locked), name_attr(&e.common.name),
                opacity_attr(e.common.opacity), transform_attr(&e.common.transform),
                container_blend_attrs(e.isolated_blending, e.knockout_group),
            )];
            let child_indent = format!("{}  ", indent);
            for child in &e.children {
                lines.push(element_svg(child, &child_indent));
            }
            lines.push(format!("{}</g>", indent));
            lines.join("\n")
        }
        // Live elements (phase 1): emit as a group of operands so SVG
        // export remains lossless-ish. Phase 2 will replace this with
        // the evaluated geometry once the boolean pipeline is wired.
        Element::Live(v) => match v {
            crate::geometry::live::LiveVariant::CompoundShape(cs) => {
                let op = match cs.operation {
                    crate::geometry::live::CompoundOperation::Union => "union",
                    crate::geometry::live::CompoundOperation::SubtractFront => "subtract_front",
                    crate::geometry::live::CompoundOperation::Intersection => "intersection",
                    crate::geometry::live::CompoundOperation::Exclude => "exclude",
                };
                let mut lines = vec![format!(
                    "{}<g data-jas-live=\"compound_shape\" data-jas-operation=\"{}\"{}>",
                    indent,
                    op,
                    common_attrs(&cs.common),
                )];
                let child_indent = format!("{}  ", indent);
                for child in &cs.operands {
                    lines.push(element_svg(child, &child_indent));
                }
                lines.push(format!("{}</g>", indent));
                lines.join("\n")
            }
            crate::geometry::live::LiveVariant::Reference(r) => {
                // A reference is native SVG <use href="#id"> (Phase 2). Its own
                // id/opacity/transform ride the common attrs; the target is the
                // href. Any <use> imports back as a live reference (F-svg-use).
                //
                // Symbols P4 (SYMBOLS.md §4 / Fork F2): the instance `transform`
                // field is distinct from common.transform (which rides the
                // <use transform=...> attr via common_attrs_no_name). It is
                // emitted as data-jas-instance-transform in the same matrix
                // format as transform_attr, and ONLY when set so existing <use>
                // fixtures stay byte-identical.
                let inst_xform = match &r.transform {
                    None => String::new(),
                    Some(t) => format!(
                        " data-jas-instance-transform=\"{}\"", matrix_value(t)
                    ),
                };
                format!(
                    "{}<use href=\"#{}\"{}{}/>",
                    indent,
                    escape_xml(&r.target.0),
                    common_attrs(&r.common),
                    inst_xform,
                )
            }
            crate::geometry::live::LiveVariant::Recorded(rec) => {
                // Recorded elements export as a data-jas-live group carrying the
                // recipe's input ids. Full SVG round-trip (the ops) is deferred
                // (RECORDED_ELEMENTS.md §8); no current fixture exercises it.
                let inputs = rec.inputs.iter()
                    .map(|i| i.0.as_str()).collect::<Vec<_>>().join(",");
                format!(
                    "{}<g data-jas-live=\"recorded\" data-jas-inputs=\"{}\"{}></g>",
                    indent,
                    escape_xml(&inputs),
                    common_attrs(&rec.common),
                )
            }
            crate::geometry::live::LiveVariant::Generated(ge) => {
                // Generated elements export as a data-jas-live group carrying the
                // concept id + params JSON. Full SVG round-trip is deferred
                // (CONCEPTS.md); no current fixture exercises it.
                let params = serde_json::to_string(&ge.params).unwrap_or_default();
                format!(
                    "{}<g data-jas-live=\"generated\" data-jas-concept=\"{}\" data-jas-params=\"{}\"{}></g>",
                    indent,
                    escape_xml(&ge.concept_id),
                    escape_xml(&params),
                    common_attrs(&ge.common),
                )
            }
        },
    }
}

const INKSCAPE_NS: &str = "http://www.inkscape.org/namespaces/inkscape";
const SODIPODI_NS: &str = "http://sodipodi.sourceforge.net/DTD/sodipodi-0.0.dtd";
const JAS_NS: &str = "urn:jas:1";

/// Convert a Document to an SVG string.
pub fn document_to_svg(doc: &Document) -> String {
    use crate::document::document_setup::DocumentSetup;
    use crate::document::print_preferences::PrintPreferences;

    let (bx, by, bw, bh) = doc.bounds();
    let vb = format!(
        "{} {} {} {}",
        fmt(px(bx)), fmt(px(by)), fmt(px(bw)), fmt(px(bh))
    );
    let mut lines = vec![
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>".to_string(),
        format!(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:inkscape=\"{}\" xmlns:sodipodi=\"{}\" xmlns:jas=\"{}\" viewBox=\"{}\" width=\"{}\" height=\"{}\">",
            INKSCAPE_NS, SODIPODI_NS, JAS_NS, vb, fmt(px(bw)), fmt(px(bh))
        ),
    ];
    // Artboard persistence: SVG itself has no artboards concept, so
    // we use Inkscape's <sodipodi:namedview> + <inkscape:page>
    // convention. Renders correctly in Inkscape (their "pages" are
    // our artboards) and lets us round-trip artboard geometry +
    // names + ids without losing data on save/reopen. The same
    // namedview also hosts <jas:document-setup> /
    // <jas:print-preferences> when those differ from defaults
    // (PRINT.md §Phase 2).
    let setup_default = doc.document_setup == DocumentSetup::default();
    let prefs_default = doc.print_preferences == PrintPreferences::default();
    let want_namedview =
        !doc.artboards.is_empty() || !setup_default || !prefs_default;
    if want_namedview {
        lines.push("  <sodipodi:namedview id=\"namedview1\">".to_string());
        for ab in &doc.artboards {
            lines.push(format!(
                "    <inkscape:page x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" id=\"{}\" inkscape:label=\"{}\"/>",
                fmt(px(ab.x)), fmt(px(ab.y)),
                fmt(px(ab.width)), fmt(px(ab.height)),
                escape_xml(&ab.id),
                escape_xml(&ab.name),
            ));
        }
        if !setup_default {
            lines.push(document_setup_to_xml(&doc.document_setup, "    "));
        }
        if !prefs_default {
            lines.push(print_preferences_to_xml(&doc.print_preferences, "    "));
        }
        lines.push("  </sodipodi:namedview>".to_string());
    }
    // Symbols (master store, SYMBOLS.md §5 / Fork S3): masters serialize
    // inside a single <defs> block (each as its normal element SVG, carrying
    // its id), placed before the layer content so the standard SVG
    // non-rendered-definition mechanism applies. Emitted only when the store
    // is non-empty (so existing fixtures stay byte-identical), sorted by id
    // (the §2 deterministic-order rule). Instances ride the existing
    // <use href="#id"> path in the layer tree. On import, <defs> children
    // become doc.symbols (see svg_to_document).
    if !doc.symbols.is_empty() {
        let mut sorted: Vec<&Element> = doc.symbols.iter().collect();
        sorted.sort_by(|a, b| {
            a.common().id.as_deref().unwrap_or("")
                .cmp(b.common().id.as_deref().unwrap_or(""))
        });
        lines.push("  <defs>".to_string());
        for master in sorted {
            lines.push(element_svg(master, "    "));
        }
        lines.push("  </defs>".to_string());
    }
    for layer in &doc.layers {
        lines.push(element_svg(layer, "  "));
    }
    lines.push("</svg>".to_string());
    lines.join("\n")
}

// ---------------------------------------------------------------------------
// SVG Import: simple XML parser (no external crate)
// ---------------------------------------------------------------------------

/// Minimal XML element for SVG parsing.
#[derive(Debug)]
struct XmlNode {
    tag: String,
    attrs: HashMap<String, String>,
    children: Vec<XmlNode>,
    text: String,
}

/// Parse a minimal subset of XML sufficient for SVG import.
/// Not a full XML parser — handles elements, attributes, text, self-closing tags.
fn parse_xml(input: &str) -> Option<XmlNode> {
    let input = input.trim();
    // Skip XML declaration
    let input = if input.starts_with("<?xml") {
        if let Some(pos) = input.find("?>") {
            input[pos + 2..].trim()
        } else {
            input
        }
    } else {
        input
    };
    // Skip DOCTYPE
    let input = if input.starts_with("<!DOCTYPE") {
        if let Some(pos) = input.find('>') {
            input[pos + 1..].trim()
        } else {
            input
        }
    } else {
        input
    };
    let (node, _) = parse_xml_node(input)?;
    Some(node)
}

fn parse_xml_node(input: &str) -> Option<(XmlNode, &str)> {
    let input = input.trim();
    if !input.starts_with('<') {
        return None;
    }
    let input = &input[1..]; // skip '<'

    // Parse tag name
    let (tag, rest) = parse_tag_name(input)?;

    // Parse attributes
    let (attrs, rest, self_closing) = parse_attributes(rest)?;

    if self_closing {
        return Some((XmlNode { tag, attrs, children: Vec::new(), text: String::new() }, rest));
    }

    // Parse children and text until closing tag
    let mut children = Vec::new();
    let mut text = String::new();
    let mut rest = rest;
    let _close_tag = format!("</{}", tag.split(':').next_back().unwrap_or(&tag));
    // Also handle namespaced close tags
    loop {
        rest = rest.trim_start();
        if rest.is_empty() {
            break;
        }
        // Check for closing tag (handle namespace stripping)
        if rest.starts_with("</") {
            // Find the end of the close tag
            if let Some(pos) = rest.find('>') {
                rest = &rest[pos + 1..];
                break;
            }
            break;
        }
        // Check for comment
        if rest.starts_with("<!--") {
            if let Some(pos) = rest.find("-->") {
                rest = &rest[pos + 3..];
                continue;
            }
            break;
        }
        // Try to parse child element
        if rest.starts_with('<') {
            if let Some((child, new_rest)) = parse_xml_node(rest) {
                children.push(child);
                rest = new_rest;
                continue;
            }
            break;
        }
        // Text content
        if let Some(pos) = rest.find('<') {
            text.push_str(&unescape_xml(&rest[..pos]));
            rest = &rest[pos..];
        } else {
            text.push_str(&unescape_xml(rest));
            rest = "";
            break;
        }
    }

    Some((XmlNode { tag, attrs, children, text }, rest))
}

fn parse_tag_name(input: &str) -> Option<(String, &str)> {
    let end = input.find(|c: char| c.is_whitespace() || c == '/' || c == '>')?;
    let tag = input[..end].to_string();
    Some((tag, &input[end..]))
}

fn parse_attributes(mut input: &str) -> Option<(HashMap<String, String>, &str, bool)> {
    let mut attrs = HashMap::new();
    loop {
        input = input.trim_start();
        if let Some(rest) = input.strip_prefix("/>") {
            return Some((attrs, rest, true));
        }
        if let Some(rest) = input.strip_prefix('>') {
            return Some((attrs, rest, false));
        }
        // Parse attribute name
        let eq_pos = input.find('=')?;
        let name = input[..eq_pos].trim().to_string();
        input = input[eq_pos + 1..].trim_start();
        // Parse attribute value
        let quote = input.as_bytes().first()?;
        if *quote != b'"' && *quote != b'\'' {
            return None;
        }
        let q = *quote as char;
        input = &input[1..];
        let end = input.find(q)?;
        let value = input[..end].to_string();
        input = &input[end + 1..];
        attrs.insert(name, value);
    }
}

fn unescape_xml(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
}

// ---------------------------------------------------------------------------
// SVG element parsing
// ---------------------------------------------------------------------------

/// Emit a single Tspan as an SVG `<tspan ...>content</tspan>` element.
/// Only overridden attributes are emitted (inherited values are absent).
fn tspan_svg(t: &crate::geometry::tspan::Tspan) -> String {
    let mut attrs = String::new();
    if let Some(v) = &t.font_family {
        attrs.push_str(&format!(" font-family=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = t.font_size {
        attrs.push_str(&format!(" font-size=\"{}\"", fmt(px(v))));
    }
    if let Some(v) = &t.font_weight {
        attrs.push_str(&format!(" font-weight=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = &t.font_style {
        attrs.push_str(&format!(" font-style=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = &t.text_decoration
        && !v.is_empty()
    {
        let joined = v.join(" ");
        attrs.push_str(&format!(
            " text-decoration=\"{}\"",
            escape_xml(&joined)
        ));
    }
    // Per-tspan rotation. Our model stores a single f64 per tspan, so
    // per-glyph varying rotations require each glyph to live in its
    // own tspan (enforced by the Touch Type tool). SVG's multi-value
    // `rotate="a1 a2 …"` form is handled on the parse side by
    // splitting the tspan into one per glyph — see [`parse_tspan`].
    if let Some(v) = t.rotate {
        attrs.push_str(&format!(" rotate=\"{}\"", fmt(v)));
    }
    if let Some(v) = &t.jas_role {
        attrs.push_str(&format!(" urn:jas:1:role=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = t.jas_left_indent {
        attrs.push_str(&format!(" urn:jas:1:left-indent=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_right_indent {
        attrs.push_str(&format!(" urn:jas:1:right-indent=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate {
        attrs.push_str(&format!(" urn:jas:1:hyphenate=\"{}\"", v));
    }
    if let Some(v) = t.jas_hanging_punctuation {
        attrs.push_str(&format!(" urn:jas:1:hanging-punctuation=\"{}\"", v));
    }
    if let Some(v) = &t.jas_list_style {
        attrs.push_str(&format!(" urn:jas:1:list-style=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = &t.text_align {
        attrs.push_str(&format!(" text-align=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = &t.text_align_last {
        attrs.push_str(&format!(" text-align-last=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = t.text_indent {
        attrs.push_str(&format!(" text-indent=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_space_before {
        attrs.push_str(&format!(" urn:jas:1:space-before=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_space_after {
        attrs.push_str(&format!(" urn:jas:1:space-after=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_word_spacing_min {
        attrs.push_str(&format!(" urn:jas:1:word-spacing-min=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_word_spacing_desired {
        attrs.push_str(&format!(" urn:jas:1:word-spacing-desired=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_word_spacing_max {
        attrs.push_str(&format!(" urn:jas:1:word-spacing-max=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_letter_spacing_min {
        attrs.push_str(&format!(" urn:jas:1:letter-spacing-min=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_letter_spacing_desired {
        attrs.push_str(&format!(" urn:jas:1:letter-spacing-desired=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_letter_spacing_max {
        attrs.push_str(&format!(" urn:jas:1:letter-spacing-max=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_glyph_scaling_min {
        attrs.push_str(&format!(" urn:jas:1:glyph-scaling-min=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_glyph_scaling_desired {
        attrs.push_str(&format!(" urn:jas:1:glyph-scaling-desired=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_glyph_scaling_max {
        attrs.push_str(&format!(" urn:jas:1:glyph-scaling-max=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_auto_leading {
        attrs.push_str(&format!(" urn:jas:1:auto-leading=\"{}\"", fmt(v)));
    }
    if let Some(v) = &t.jas_single_word_justify {
        attrs.push_str(&format!(" urn:jas:1:single-word-justify=\"{}\"", escape_xml(v)));
    }
    if let Some(v) = t.jas_hyphenate_min_word {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-min-word=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_min_before {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-min-before=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_min_after {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-min-after=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_limit {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-limit=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_zone {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-zone=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_bias {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-bias=\"{}\"", fmt(v)));
    }
    if let Some(v) = t.jas_hyphenate_capitalized {
        attrs.push_str(&format!(" urn:jas:1:hyphenate-capitalized=\"{}\"", v));
    }
    format!("<tspan{}>{}</tspan>", attrs, escape_xml(&t.content))
}

/// Parse an SVG `<tspan>` child node into one or more Tspans.
///
/// Returns a `Vec` so SVG's multi-value `rotate="a b c …"` syntax can
/// be expanded into one tspan per glyph (each carrying its own rotate
/// angle). The single-value case returns a one-element vec. Ids are
/// left at `0`; the caller assigns fresh sequential ids across the
/// whole tspan list.
fn parse_tspan(node: &XmlNode) -> Vec<crate::geometry::tspan::Tspan> {
    use crate::geometry::tspan::Tspan;
    let base = Tspan {
        id: 0,
        content: node.text.clone(),
        font_family: node.attrs.get("font-family").cloned(),
        font_size: node
            .attrs
            .get("font-size")
            .and_then(|s| s.parse::<f64>().ok())
            .map(pt),
        font_weight: node.attrs.get("font-weight").cloned(),
        font_style: node.attrs.get("font-style").cloned(),
        text_decoration: node.attrs.get("text-decoration").map(|s| {
            let mut parts: Vec<String> = s
                .split_whitespace()
                .filter(|x| *x != "none" && !x.is_empty())
                .map(String::from)
                .collect();
            parts.sort();
            parts
        }),
        jas_role: node.attrs.get("urn:jas:1:role").cloned(),
        jas_left_indent: node.attrs.get("urn:jas:1:left-indent")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_right_indent: node.attrs.get("urn:jas:1:right-indent")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate: node.attrs.get("urn:jas:1:hyphenate")
            .map(|v| v == "true"),
        jas_hanging_punctuation: node.attrs.get("urn:jas:1:hanging-punctuation")
            .map(|v| v == "true"),
        jas_list_style: node.attrs.get("urn:jas:1:list-style").cloned(),
        text_align: node.attrs.get("text-align").cloned(),
        text_align_last: node.attrs.get("text-align-last").cloned(),
        text_indent: node.attrs.get("text-indent")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_space_before: node.attrs.get("urn:jas:1:space-before")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_space_after: node.attrs.get("urn:jas:1:space-after")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_word_spacing_min: node.attrs.get("urn:jas:1:word-spacing-min")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_word_spacing_desired: node.attrs.get("urn:jas:1:word-spacing-desired")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_word_spacing_max: node.attrs.get("urn:jas:1:word-spacing-max")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_letter_spacing_min: node.attrs.get("urn:jas:1:letter-spacing-min")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_letter_spacing_desired: node.attrs.get("urn:jas:1:letter-spacing-desired")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_letter_spacing_max: node.attrs.get("urn:jas:1:letter-spacing-max")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_glyph_scaling_min: node.attrs.get("urn:jas:1:glyph-scaling-min")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_glyph_scaling_desired: node.attrs.get("urn:jas:1:glyph-scaling-desired")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_glyph_scaling_max: node.attrs.get("urn:jas:1:glyph-scaling-max")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_auto_leading: node.attrs.get("urn:jas:1:auto-leading")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_single_word_justify: node.attrs.get("urn:jas:1:single-word-justify").cloned(),
        jas_hyphenate_min_word: node.attrs.get("urn:jas:1:hyphenate-min-word")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_min_before: node.attrs.get("urn:jas:1:hyphenate-min-before")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_min_after: node.attrs.get("urn:jas:1:hyphenate-min-after")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_limit: node.attrs.get("urn:jas:1:hyphenate-limit")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_zone: node.attrs.get("urn:jas:1:hyphenate-zone")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_bias: node.attrs.get("urn:jas:1:hyphenate-bias")
            .and_then(|s| s.parse::<f64>().ok()),
        jas_hyphenate_capitalized: node.attrs.get("urn:jas:1:hyphenate-capitalized")
            .map(|v| v == "true"),
        ..Tspan::default_tspan()
    };
    // Multi-value rotate: SVG allows `rotate="a1 a2 a3 …"` on a tspan,
    // where each angle applies to the corresponding glyph. Our model
    // represents this by splitting the tspan into one per glyph.
    let rotate_vals: Vec<f64> = node
        .attrs
        .get("rotate")
        .map(|s| {
            s.split_whitespace()
                .filter_map(|x| x.parse::<f64>().ok())
                .collect()
        })
        .unwrap_or_default();
    let chars: Vec<char> = base.content.chars().collect();
    match rotate_vals.len() {
        0 => vec![base],
        1 => {
            let mut t = base;
            t.rotate = Some(rotate_vals[0]);
            vec![t]
        }
        _ if chars.len() <= 1 => {
            // Multi-value but content is at most one char — first
            // angle applies; extras are harmless.
            let mut t = base;
            t.rotate = Some(rotate_vals[0]);
            vec![t]
        }
        _ => {
            // Split the tspan into one per glyph. Each inherits
            // the base's override fields and gets the matching
            // rotate angle; the last angle is reused for any
            // trailing glyphs past the end of the list (per SVG).
            let last_angle = *rotate_vals
                .last()
                .expect("unreachable: match arms above cover len 0 and 1");
            chars
                .into_iter()
                .enumerate()
                .map(|(i, c)| {
                    let mut t = base.clone();
                    t.content = c.to_string();
                    t.rotate = Some(*rotate_vals.get(i).unwrap_or(&last_angle));
                    t
                })
                .collect()
        }
    }
}

fn strip_ns(tag: &str) -> &str {
    if let Some(pos) = tag.rfind('}') {
        &tag[pos + 1..]
    } else if let Some(pos) = tag.find(':') {
        &tag[pos + 1..]
    } else {
        tag
    }
}

fn get_f(node: &XmlNode, name: &str, default: f64) -> f64 {
    node.attrs.get(name)
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(default)
}

fn get_s<'a>(node: &'a XmlNode, name: &str, default: &'a str) -> &'a str {
    node.attrs.get(name).map(|s| s.as_str()).unwrap_or(default)
}

fn parse_color(s: &str) -> Option<Color> {
    let s = s.trim();
    if s == "none" {
        return None;
    }
    // Named colors
    if let Some(&(r, g, b)) = get_named_colors().get(s.to_lowercase().as_str()) {
        return Some(Color::Rgb { r: r as f64 / 255.0, g: g as f64 / 255.0, b: b as f64 / 255.0, a: 1.0 });
    }
    // Hex
    if let Some(h) = s.strip_prefix('#') {
        if h.len() == 3 {
            let r = u8::from_str_radix(&h[0..1].repeat(2), 16).ok()? as f64 / 255.0;
            let g = u8::from_str_radix(&h[1..2].repeat(2), 16).ok()? as f64 / 255.0;
            let b = u8::from_str_radix(&h[2..3].repeat(2), 16).ok()? as f64 / 255.0;
            return Some(Color::Rgb { r, g, b, a: 1.0 });
        }
        if h.len() == 4 {
            let r = u8::from_str_radix(&h[0..1].repeat(2), 16).ok()? as f64 / 255.0;
            let g = u8::from_str_radix(&h[1..2].repeat(2), 16).ok()? as f64 / 255.0;
            let b = u8::from_str_radix(&h[2..3].repeat(2), 16).ok()? as f64 / 255.0;
            let a = u8::from_str_radix(&h[3..4].repeat(2), 16).ok()? as f64 / 255.0;
            return Some(Color::Rgb { r, g, b, a });
        }
        if h.len() == 6 {
            let r = u8::from_str_radix(&h[0..2], 16).ok()? as f64 / 255.0;
            let g = u8::from_str_radix(&h[2..4], 16).ok()? as f64 / 255.0;
            let b = u8::from_str_radix(&h[4..6], 16).ok()? as f64 / 255.0;
            return Some(Color::Rgb { r, g, b, a: 1.0 });
        }
        if h.len() == 8 {
            let r = u8::from_str_radix(&h[0..2], 16).ok()? as f64 / 255.0;
            let g = u8::from_str_radix(&h[2..4], 16).ok()? as f64 / 255.0;
            let b = u8::from_str_radix(&h[4..6], 16).ok()? as f64 / 255.0;
            let a = u8::from_str_radix(&h[6..8], 16).ok()? as f64 / 255.0;
            return Some(Color::Rgb { r, g, b, a });
        }
        return None;
    }
    // rgb()/rgba()
    if s.starts_with("rgb") {
        let inner = s.split('(').nth(1)?.trim_end_matches(')');
        let parts: Vec<&str> = inner.split(',').collect();
        if parts.len() >= 3 {
            let r = parts[0].trim().parse::<f64>().ok()? / 255.0;
            let g = parts[1].trim().parse::<f64>().ok()? / 255.0;
            let b = parts[2].trim().parse::<f64>().ok()? / 255.0;
            let a = if parts.len() > 3 { parts[3].trim().parse::<f64>().ok()? } else { 1.0 };
            return Some(Color::Rgb { r, g, b, a });
        }
    }
    None
}

fn parse_fill(node: &XmlNode) -> Option<Fill> {
    let val = node.attrs.get("fill")?;
    if val == "none" {
        return None;
    }
    let opacity = get_f(node, "fill-opacity", 1.0);
    Some(Fill { color: parse_color(val)?, opacity })
}

fn parse_stroke(node: &XmlNode) -> Option<Stroke> {
    let val = node.attrs.get("stroke")?;
    if val == "none" {
        return None;
    }
    let color = parse_color(val)?;
    let width = get_f(node, "stroke-width", 1.0) * PX_TO_PT;
    let lc = match get_s(node, "stroke-linecap", "butt") {
        "round" => LineCap::Round,
        "square" => LineCap::Square,
        _ => LineCap::Butt,
    };
    let lj = match get_s(node, "stroke-linejoin", "miter") {
        "round" => LineJoin::Round,
        "bevel" => LineJoin::Bevel,
        _ => LineJoin::Miter,
    };
    let opacity = get_f(node, "stroke-opacity", 1.0);
    // `stroke-dasharray` accepts commas, whitespace, or both as separators
    // (SVG 1.1 "list of lengths"), and `none` for no dashing. Values arrive in
    // px and are stored in pt. The model holds at most SIX, so a longer list
    // from a foreign file is TRUNCATED rather than silently reinterpreted —
    // mirrored in JasSwift so the two ports keep the same ceiling.
    let (dash_pattern, dash_len) = {
        let mut arr = [0.0f64; 6];
        let mut n = 0usize;
        let raw = get_s(node, "stroke-dasharray", "");
        if raw.trim() != "none" {
            for tok in raw.split([',', ' ', '\t', '\n']).filter(|t| !t.is_empty()) {
                if n == 6 { break; }
                match tok.parse::<f64>() {
                    Ok(v) => { arr[n] = v * PX_TO_PT; n += 1; }
                    Err(_) => { n = 0; break; }
                }
            }
        }
        (arr, n as u8)
    };
    let miter_limit = get_f(node, "stroke-miterlimit", 10.0);
    let dash_align_anchors = matches!(
        get_s(node, "data-jas-dash-align-anchors", "").trim(),
        "true" | "1"
    );
    // Arrowheads — round-tripped from the `jas:` namespace (see stroke_attr).
    // Each defaults to its identity value when the attr is absent (plain SVG).
    let start_arrow = Arrowhead::from_str(get_s(node, "jas:start-arrow", "none"));
    let end_arrow = Arrowhead::from_str(get_s(node, "jas:end-arrow", "none"));
    let start_arrow_scale = get_f(node, "jas:start-arrow-scale", 100.0);
    let end_arrow_scale = get_f(node, "jas:end-arrow-scale", 100.0);
    let arrow_align = match get_s(node, "jas:arrow-align", "tip_at_end") {
        "center_at_end" => ArrowAlign::CenterAtEnd,
        _ => ArrowAlign::TipAtEnd,
    };
    Some(Stroke { color, width, linecap: lc, linejoin: lj, miter_limit, align: StrokeAlign::Center, dash_pattern, dash_len, dash_align_anchors, start_arrow, end_arrow, start_arrow_scale, end_arrow_scale, arrow_align, opacity })
}

fn parse_transform(node: &XmlNode) -> Option<Transform> {
    let val = node.attrs.get("transform")?;
    if val.starts_with("matrix(") {
        let inner = val.trim_start_matches("matrix(").trim_end_matches(')');
        let parts: Vec<f64> = inner.split([',', ' '])
            .filter(|s| !s.is_empty())
            .filter_map(|s| s.parse().ok())
            .collect();
        if parts.len() == 6 {
            return Some(Transform {
                a: parts[0], b: parts[1], c: parts[2], d: parts[3],
                e: pt(parts[4]), f: pt(parts[5]),
            });
        }
    }
    if val.starts_with("translate(") {
        let inner = val.trim_start_matches("translate(").trim_end_matches(')');
        let parts: Vec<f64> = inner.split([',', ' '])
            .filter(|s| !s.is_empty())
            .filter_map(|s| s.parse().ok())
            .collect();
        let tx = parts.first().copied().unwrap_or(0.0);
        let ty = parts.get(1).copied().unwrap_or(0.0);
        return Some(Transform::translate(pt(tx), pt(ty)));
    }
    if val.starts_with("rotate(") {
        let inner = val.trim_start_matches("rotate(").trim_end_matches(')');
        if let Ok(angle) = inner.trim().parse::<f64>() {
            return Some(Transform::rotate(angle));
        }
    }
    if val.starts_with("scale(") {
        let inner = val.trim_start_matches("scale(").trim_end_matches(')');
        let parts: Vec<f64> = inner.split([',', ' '])
            .filter(|s| !s.is_empty())
            .filter_map(|s| s.parse().ok())
            .collect();
        let sx = parts.first().copied().unwrap_or(1.0);
        let sy = parts.get(1).copied().unwrap_or(sx);
        return Some(Transform::scale(sx, sy));
    }
    None
}

/// Parse a `matrix(a,b,c,d,e,f)` value from the named attribute, returning
/// `None` when the attribute is absent or malformed. Used for the Symbols P4
/// instance transform (data-jas-instance-transform); e/f are converted from px
/// to pt to match the common transform attr (SYMBOLS.md §4 / Fork F2).
fn parse_matrix_attr(node: &XmlNode, attr: &str) -> Option<Transform> {
    let val = node.attrs.get(attr)?;
    if val.starts_with("matrix(") {
        let inner = val.trim_start_matches("matrix(").trim_end_matches(')');
        let parts: Vec<f64> = inner.split([',', ' '])
            .filter(|s| !s.is_empty())
            .filter_map(|s| s.parse().ok())
            .collect();
        if parts.len() == 6 {
            return Some(Transform {
                a: parts[0], b: parts[1], c: parts[2], d: parts[3],
                e: pt(parts[4]), f: pt(parts[5]),
            });
        }
    }
    None
}

fn parse_opacity(node: &XmlNode) -> f64 {
    get_f(node, "opacity", 1.0)
}

fn parse_common(node: &XmlNode) -> CommonProps {
    // `visibility` is runtime-only state — it is not preserved in
    // SVG, so it always loads as `Preview`. See SELECTION.md /
    // DOCUMENT.md for the rationale.
    CommonProps {
        opacity: parse_opacity(node),
        mode: crate::geometry::element::BlendMode::default(),
        transform: parse_transform(node),
        // LOCKSVG (2026-07-28): the workspace-private lock flag, written by
        // `id_lock_attrs` above. It was hard-coded `false` here from the day
        // this function was written, which is why locking a layer, saving and
        // reopening lost the protection entirely — and why every SVG-seeded
        // fixture in the shared corpus was blind to lock as a precondition.
        // Only the exact string "true" locks: a foreign or malformed value
        // must not silently protect artwork the artist never protected.
        locked: node.attrs.get("jas:locked").map(|v| v == "true").unwrap_or(false),
        visibility: crate::geometry::element::Visibility::default(),
        mask: None,
        tool_origin: node.attrs.get("jas:tool-origin").cloned(),
        // User-visible name. Read inkscape:label attribute first
        // (matches what we write); fall back to a <title> child for
        // interop with tools that round-trip via the standard
        // accessibility element. LYR-091 enabler.
        name: node.attrs.get("inkscape:label").cloned()
            .or_else(|| node.children.iter()
                .find(|c| c.tag == "title")
                .map(|c| c.text.clone()))
            .filter(|s| !s.is_empty()),
        // Stable identity. Read the standard SVG `id` attribute (what
        // our writer emits via id_attr); absent -> None. Reading a
        // foreign id is fine. Mirrors the inkscape:label name read above.
        id: node.attrs.get("id").cloned().filter(|s| !s.is_empty()),
    }
}

fn parse_points(s: &str) -> Vec<(f64, f64)> {
    let mut result = Vec::new();
    for pair in s.split_whitespace() {
        let parts: Vec<&str> = pair.split(',').collect();
        if parts.len() == 2
            && let (Ok(x), Ok(y)) = (parts[0].parse::<f64>(), parts[1].parse::<f64>()) {
                result.push((pt(x), pt(y)));
            }
    }
    result
}

// ---------------------------------------------------------------------------
// Path d-attribute tokenizer
// ---------------------------------------------------------------------------

fn parse_path_d(d: &str) -> Vec<PathCommand> {
    let mut commands = Vec::new();
    let tokens = tokenize_path(d);
    let mut i = 0;
    let mut cur_x = 0.0_f64;
    let mut cur_y = 0.0_f64;
    let mut start_x = 0.0_f64;
    let mut start_y = 0.0_f64;
    let mut cmd = ' ';

    let next_num = |i: &mut usize, tokens: &[PathToken]| -> f64 {
        while *i < tokens.len() {
            if let PathToken::Num(v) = tokens[*i] {
                *i += 1;
                return v;
            }
            *i += 1;
        }
        0.0
    };

    while i < tokens.len() {
        match &tokens[i] {
            PathToken::Cmd(c) => {
                cmd = *c;
                i += 1;
            }
            PathToken::Num(_) => {
                // implicit repeat of previous command
            }
        }

        match cmd {
            'Z' | 'z' => {
                commands.push(PathCommand::ClosePath);
                cur_x = start_x;
                cur_y = start_y;
            }
            'M' => {
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::MoveTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
                start_x = x; start_y = y;
                cmd = 'L'; // implicit lineto after moveto
            }
            'm' => {
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::MoveTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
                start_x = x; start_y = y;
                cmd = 'l';
            }
            'L' => {
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
            }
            'l' => {
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
            }
            'H' => {
                let x = next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(x), y: pt(cur_y) });
                cur_x = x;
            }
            'h' => {
                let x = cur_x + next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(x), y: pt(cur_y) });
                cur_x = x;
            }
            'V' => {
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(cur_x), y: pt(y) });
                cur_y = y;
            }
            'v' => {
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::LineTo { x: pt(cur_x), y: pt(y) });
                cur_y = y;
            }
            'C' => {
                let x1 = next_num(&mut i, &tokens);
                let y1 = next_num(&mut i, &tokens);
                let x2 = next_num(&mut i, &tokens);
                let y2 = next_num(&mut i, &tokens);
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::CurveTo {
                    x1: pt(x1), y1: pt(y1), x2: pt(x2), y2: pt(y2), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'c' => {
                let x1 = cur_x + next_num(&mut i, &tokens);
                let y1 = cur_y + next_num(&mut i, &tokens);
                let x2 = cur_x + next_num(&mut i, &tokens);
                let y2 = cur_y + next_num(&mut i, &tokens);
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::CurveTo {
                    x1: pt(x1), y1: pt(y1), x2: pt(x2), y2: pt(y2), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'S' => {
                let x2 = next_num(&mut i, &tokens);
                let y2 = next_num(&mut i, &tokens);
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::SmoothCurveTo {
                    x2: pt(x2), y2: pt(y2), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            's' => {
                let x2 = cur_x + next_num(&mut i, &tokens);
                let y2 = cur_y + next_num(&mut i, &tokens);
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::SmoothCurveTo {
                    x2: pt(x2), y2: pt(y2), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'Q' => {
                let x1 = next_num(&mut i, &tokens);
                let y1 = next_num(&mut i, &tokens);
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::QuadTo {
                    x1: pt(x1), y1: pt(y1), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'q' => {
                let x1 = cur_x + next_num(&mut i, &tokens);
                let y1 = cur_y + next_num(&mut i, &tokens);
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::QuadTo {
                    x1: pt(x1), y1: pt(y1), x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'T' => {
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::SmoothQuadTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
            }
            't' => {
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::SmoothQuadTo { x: pt(x), y: pt(y) });
                cur_x = x; cur_y = y;
            }
            'A' => {
                let rx = next_num(&mut i, &tokens);
                let ry = next_num(&mut i, &tokens);
                let rotation = next_num(&mut i, &tokens);
                let large_arc = next_num(&mut i, &tokens) != 0.0;
                let sweep = next_num(&mut i, &tokens) != 0.0;
                let x = next_num(&mut i, &tokens);
                let y = next_num(&mut i, &tokens);
                commands.push(PathCommand::ArcTo {
                    rx: pt(rx), ry: pt(ry), x_rotation: rotation,
                    large_arc, sweep, x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            'a' => {
                let rx = next_num(&mut i, &tokens);
                let ry = next_num(&mut i, &tokens);
                let rotation = next_num(&mut i, &tokens);
                let large_arc = next_num(&mut i, &tokens) != 0.0;
                let sweep = next_num(&mut i, &tokens) != 0.0;
                let x = cur_x + next_num(&mut i, &tokens);
                let y = cur_y + next_num(&mut i, &tokens);
                commands.push(PathCommand::ArcTo {
                    rx: pt(rx), ry: pt(ry), x_rotation: rotation,
                    large_arc, sweep, x: pt(x), y: pt(y),
                });
                cur_x = x; cur_y = y;
            }
            _ => { i += 1; }
        }
    }
    commands
}

#[derive(Debug)]
enum PathToken {
    Cmd(char),
    Num(f64),
}

fn tokenize_path(d: &str) -> Vec<PathToken> {
    let mut tokens = Vec::new();
    let mut chars = d.chars().peekable();
    while let Some(&c) = chars.peek() {
        if c.is_whitespace() || c == ',' {
            chars.next();
            continue;
        }
        if "MmLlHhVvCcSsQqTtAaZz".contains(c) {
            tokens.push(PathToken::Cmd(c));
            chars.next();
            continue;
        }
        // Number
        let mut num = String::new();
        if c == '-' || c == '+' {
            num.push(c);
            chars.next();
        }
        while let Some(&c) = chars.peek() {
            if c.is_ascii_digit() || c == '.' {
                num.push(c);
                chars.next();
            } else if (c == 'e' || c == 'E') && !num.is_empty() {
                num.push(c);
                chars.next();
                if let Some(&c2) = chars.peek()
                    && (c2 == '+' || c2 == '-') {
                        num.push(c2);
                        chars.next();
                    }
            } else {
                break;
            }
        }
        if !num.is_empty() {
            if let Ok(v) = num.parse::<f64>() {
                tokens.push(PathToken::Num(v));
            }
        } else {
            chars.next(); // skip unrecognized
        }
    }
    tokens
}

// ---------------------------------------------------------------------------
// Parse SVG element tree to Document elements
// ---------------------------------------------------------------------------

fn parse_element(node: &XmlNode) -> Option<Element> {
    let tag = strip_ns(&node.tag);
    let common = parse_common(node);

    match tag {
        "line" => Some(Element::Line(LineElem {
            x1: pt(get_f(node, "x1", 0.0)),
            y1: pt(get_f(node, "y1", 0.0)),
            x2: pt(get_f(node, "x2", 0.0)),
            y2: pt(get_f(node, "y2", 0.0)),
            stroke: parse_stroke(node),
            width_points: vec![],
            common,
                    stroke_gradient: None,
        })),
        "rect" => Some(Element::Rect(RectElem {
            x: pt(get_f(node, "x", 0.0)),
            y: pt(get_f(node, "y", 0.0)),
            width: pt(get_f(node, "width", 0.0)),
            height: pt(get_f(node, "height", 0.0)),
            rx: pt(get_f(node, "rx", 0.0)),
            ry: pt(get_f(node, "ry", 0.0)),
            fill: parse_fill(node),
            stroke: parse_stroke(node),
            common,
                    fill_gradient: None,
            stroke_gradient: None,
        })),
        // ONE ROUND KIND (JYH, 2026-07-30). `<circle r>` is an ellipse whose
        // radii are equal. Keeping a separate kind made the type PROVENANCE
        // rather than geometry -- `apply_scale` composes a matrix onto
        // common.transform and never touches radii, so a `circle` stayed typed
        // `circle` while drawn as an egg. The tag is re-derived on the way out,
        // so `<circle>` still round-trips.
        "circle" => {
            let r = pt(get_f(node, "r", 0.0));
            Some(Element::Ellipse(EllipseElem {
                cx: pt(get_f(node, "cx", 0.0)),
                cy: pt(get_f(node, "cy", 0.0)),
                rx: r,
                ry: r,
                fill: parse_fill(node),
                stroke: parse_stroke(node),
                common,
                fill_gradient: None,
                stroke_gradient: None,
            }))
        }
        "ellipse" => Some(Element::Ellipse(EllipseElem {
            cx: pt(get_f(node, "cx", 0.0)),
            cy: pt(get_f(node, "cy", 0.0)),
            rx: pt(get_f(node, "rx", 0.0)),
            ry: pt(get_f(node, "ry", 0.0)),
            fill: parse_fill(node),
            stroke: parse_stroke(node),
            common,
                    fill_gradient: None,
            stroke_gradient: None,
        })),
        "polyline" => {
            let pts = parse_points(get_s(node, "points", ""));
            Some(Element::Polyline(PolylineElem {
                points: pts,
                fill: parse_fill(node),
                stroke: parse_stroke(node),
                common,
                            fill_gradient: None,
                stroke_gradient: None,
            }))
        }
        "polygon" => {
            let pts = parse_points(get_s(node, "points", ""));
            Some(Element::Polygon(PolygonElem {
                points: pts,
                fill: parse_fill(node),
                stroke: parse_stroke(node),
                common,
                            fill_gradient: None,
                stroke_gradient: None,
            }))
        }
        "path" => {
            let d = parse_path_d(get_s(node, "d", ""));
            Some(Element::Path(PathElem {
                d,
                fill: parse_fill(node),
                stroke: parse_stroke(node),
                width_points: parse_width_points(get_s(node, "jas:width-points", "")),
                common,
                            fill_gradient: None,
                stroke_gradient: None,
                // Unescaped on the way in: the OVERRIDES are a JSON object,
                // so the value is full of quotes the writer must escape. The
                // brush read here predates the writer and never unescaped —
                // latent until something with a special character rode it.
                stroke_brush: {
                    let s = get_s(node, "jas:stroke-brush", "");
                    if s.is_empty() { None } else { Some(unescape_xml(s)) }
                },
                stroke_brush_overrides: {
                    let s = get_s(node, "jas:stroke-brush-overrides", "");
                    if s.is_empty() { None } else { Some(unescape_xml(s)) }
                },
                fill_rule: {
                    match get_s(node, "fill-rule", "") {
                        "evenodd" => crate::geometry::element::FillRule::EvenOdd,
                        _ => crate::geometry::element::FillRule::NonZero,
                    }
                },
            }))
        }
        "text" => {
            let ff = get_s(node, "font-family", "sans-serif").to_string();
            let fs = pt(get_f(node, "font-size", 16.0));
            let fw = get_s(node, "font-weight", "normal").to_string();
            let fst = get_s(node, "font-style", "normal").to_string();
            let td = get_s(node, "text-decoration", "none").to_string();
            let tt = get_s(node, "text-transform", "").to_string();
            let fv = get_s(node, "font-variant", "").to_string();
            let bs = get_s(node, "baseline-shift", "").to_string();
            let lh = get_s(node, "line-height", "").to_string();
            let ls = get_s(node, "letter-spacing", "").to_string();
            let lang = node.attrs.get("xml:lang")
                .or_else(|| node.attrs.get("lang"))
                .cloned()
                .unwrap_or_default();
            let aa = node.attrs.get("urn:jas:1:aa-mode")
                .cloned()
                .unwrap_or_default();
            let rotate = get_s(node, "rotate", "").to_string();
            let h_scale = get_s(node, "horizontal-scale", "").to_string();
            let v_scale = get_s(node, "vertical-scale", "").to_string();
            let kerning = node.attrs.get("urn:jas:1:kerning-mode")
                .cloned()
                .unwrap_or_default();

            // Check for textPath child
            for child in &node.children {
                let ctag = strip_ns(&child.tag);
                if ctag == "textPath" {
                    let d_str = child.attrs.get("path")
                        .or_else(|| child.attrs.get("d"))
                        .map(|s| s.as_str())
                        .unwrap_or("");
                    let d = parse_path_d(d_str);
                    let offset_str = get_s(child, "startOffset", "0");
                    let start_offset = if offset_str.ends_with('%') {
                        offset_str.trim_end_matches('%').parse::<f64>().unwrap_or(0.0) / 100.0
                    } else {
                        offset_str.parse::<f64>().unwrap_or(0.0)
                    };
                    // TextPath can host tspan children; if any are present,
                    // build the tspan list from them. Otherwise fall back to
                    // the child's flat text as a single default tspan.
                    let tp_tspan_children: Vec<&XmlNode> = child
                        .children
                        .iter()
                        .filter(|c| strip_ns(&c.tag) == "tspan")
                        .collect();
                    let tspans = if tp_tspan_children.is_empty() {
                        vec![crate::geometry::tspan::Tspan {
                            content: child.text.clone(),
                            ..crate::geometry::tspan::Tspan::default_tspan()
                        }]
                    } else {
                        tp_tspan_children
                            .iter()
                            .enumerate()
                            .flat_map(|(_, c)| parse_tspan(c))
                            .enumerate()
                            .map(|(idx, mut t)| { t.id = idx as u32; t })
                            .collect()
                    };
                    return Some(Element::TextPath(TextPathElem {
                        d,
                        tspans,
                        start_offset,
                        font_family: ff,
                        font_size: fs,
                        font_weight: fw,
                        font_style: fst,
                        text_decoration: td,
                        text_transform: tt.clone(),
                        font_variant: fv.clone(),
                        baseline_shift: bs.clone(),
                        line_height: lh.clone(),
                        letter_spacing: ls.clone(),
                        xml_lang: lang.clone(),
                        aa_mode: aa.clone(),
                        rotate: rotate.clone(),
                        horizontal_scale: h_scale.clone(),
                        vertical_scale: v_scale.clone(),
                        kerning: kerning.clone(),
                        fill: parse_fill(node),
                        stroke: parse_stroke(node),
                        common,
                    }));
                }
            }

            // Tspan children of a <text> element — if present, they are the
            // authoritative content; node.text (the inter-tspan whitespace
            // that XML collected into one field) is discarded.
            let text_tspan_children: Vec<&XmlNode> = node
                .children
                .iter()
                .filter(|c| strip_ns(&c.tag) == "tspan")
                .collect();
            let tspans: Vec<crate::geometry::tspan::Tspan> = if text_tspan_children.is_empty() {
                vec![crate::geometry::tspan::Tspan {
                    content: node.text.clone(),
                    ..crate::geometry::tspan::Tspan::default_tspan()
                }]
            } else {
                text_tspan_children
                    .iter()
                    .flat_map(|c| parse_tspan(c))
                    .enumerate()
                    .map(|(idx, mut t)| { t.id = idx as u32; t })
                    .collect()
            };
            let content: String = tspans.iter().map(|t| t.content.as_str()).collect();
            let mut tw = 0.0;
            if let Some(style) = node.attrs.get("style")
                && let Some(pos) = style.find("inline-size:") {
                    let rest = &style[pos + 12..];
                    let num_str: String = rest.trim_start().chars()
                        .take_while(|c| c.is_ascii_digit() || *c == '.')
                        .collect();
                    if let Ok(v) = num_str.parse::<f64>() {
                        tw = pt(v);
                    }
                }
            let th = if tw > 0.0 {
                let lines = (content.len() as f64 * fs * super::element::APPROX_CHAR_WIDTH_FACTOR / tw).ceil().max(1.0);
                lines * fs * 1.2
            } else { 0.0 };

            // SVG `y` is the baseline of the first line; convert it to
            // the layout-box top by subtracting the ascent (0.8 * fs).
            let svg_y = pt(get_f(node, "y", 0.0));
            Some(Element::Text(TextElem {
                x: pt(get_f(node, "x", 0.0)),
                y: svg_y - fs * 0.8,
                tspans,
                font_family: ff,
                font_size: fs,
                font_weight: fw,
                font_style: fst,
                text_decoration: td,
                text_transform: tt,
                font_variant: fv,
                baseline_shift: bs,
                line_height: lh,
                letter_spacing: ls,
                xml_lang: lang,
                aa_mode: aa,
                rotate,
                horizontal_scale: h_scale,
                vertical_scale: v_scale,
                kerning,
                width: tw,
                height: th,
                fill: parse_fill(node),
                stroke: parse_stroke(node),
                common,
            }))
        }
        "g" => {
            let mut children = Vec::new();
            for child in &node.children {
                if let Some(elem) = parse_element(child) {
                    children.push(Rc::new(elem));
                }
            }
            // A live compound shape is <g data-jas-live="compound_shape">
            // (REFERENCE_GRAPH.md Phase 2): rebuild it instead of demoting to
            // a plain Group. Operation comes from data-jas-operation.
            if node.attrs.get("data-jas-live").map(|s| s.as_str()) == Some("compound_shape") {
                let operation = match node.attrs.get("data-jas-operation").map(|s| s.as_str()) {
                    Some("subtract_front") => crate::geometry::live::CompoundOperation::SubtractFront,
                    Some("intersection") => crate::geometry::live::CompoundOperation::Intersection,
                    Some("exclude") => crate::geometry::live::CompoundOperation::Exclude,
                    _ => crate::geometry::live::CompoundOperation::Union,
                };
                return Some(Element::Live(crate::geometry::live::LiveVariant::CompoundShape(
                    crate::geometry::live::CompoundShape {
                        operation, operands: children, fill: None, stroke: None, common,
                    },
                )));
            }
            // Layer detection: only inkscape:groupmode="layer"
            // promotes a <g> to a Layer. inkscape:label alone is a
            // Group name (the new common.name path); the parser
            // already populated common.name from inkscape:label
            // earlier in parse_common.
            let group_mode = node.attrs.get("inkscape:groupmode").cloned();
            // common.name is already populated from inkscape:label
            // by parse_common; both Layer and Group inherit it from there.
            // The two container-only flags ride workspace-private attributes
            // (see `container_blend_attrs`); absent means false, so every
            // pre-existing file still reads exactly as it was authored.
            let iso = node.attrs.get("jas:isolated-blending").map(|v| v == "true").unwrap_or(false);
            let ko = node.attrs.get("jas:knockout-group").map(|v| v == "true").unwrap_or(false);
            if group_mode.as_deref() == Some("layer") {
                Some(Element::Layer(LayerElem {
                    children, common, isolated_blending: iso, knockout_group: ko,
                }))
            } else {
                Some(Element::Group(GroupElem {
                    children, common, isolated_blending: iso, knockout_group: ko,
                }))
            }
        }
        "use" => {
            // Native SVG <use href="#id"> imports as a live reference
            // (F-svg-use: any <use> becomes a reference). The reference's own
            // id/opacity/transform came from `common`; href is the target.
            let target = node.attrs.get("href")
                .or_else(|| node.attrs.get("xlink:href"))
                .map(|h| h.trim_start_matches('#').to_string())
                .unwrap_or_default();
            let mut re = crate::geometry::live::ReferenceElem::new(
                crate::geometry::live::ElementRef(target),
                common,
            );
            // Symbols P4: the instance `transform` field rides
            // data-jas-instance-transform (same matrix format as the common
            // transform attr; e/f are px on the wire, pt in the model).
            re.transform = parse_matrix_attr(node, "data-jas-instance-transform");
            Some(Element::Live(crate::geometry::live::LiveVariant::Reference(re)))
        }
        _ => None,
    }
}

/// Parse an SVG string and return a Document.
pub fn svg_to_document(svg: &str) -> Document {
    let root = match parse_xml(svg) {
        Some(r) => r,
        None => return Document::default(),
    };
    let artboards = parse_artboards(&root);
    let (document_setup, print_preferences) = parse_jas_print_blocks(&root);
    let mut layers: Vec<Element> = Vec::new();
    // Symbols (master store, SYMBOLS.md §5 / Fork S3): <defs> children parse
    // into doc.symbols (NOT into layers), so masters are never painted in
    // document order. Each <defs> child is its normal element (carrying its
    // id); instances ride the existing <use href="#id"> path in the layers.
    let mut symbols: Vec<Element> = Vec::new();
    for child in &root.children {
        // Skip Inkscape's namedview block — it carries artboard
        // (page) metadata which has been pulled out above by
        // parse_artboards. parse_element returns None for it
        // anyway; this short-circuit just makes the intent explicit.
        if strip_ns(&child.tag) == "namedview" {
            continue;
        }
        // A <defs> block holds the master store: its element children become
        // doc.symbols, never layers.
        if strip_ns(&child.tag) == "defs" {
            for def in &child.children {
                if let Some(master) = parse_element(def) {
                    symbols.push(master);
                }
            }
            continue;
        }
        let elem = match parse_element(child) {
            Some(e) => e,
            None => continue,
        };
        match &elem {
            Element::Layer(_) => {
                layers.push(elem);
            }
            Element::Group(g) => {
                // Promote top-level groups to layers
                layers.push(Element::Layer(LayerElem {
                    children: g.children.clone(),
                    common: g.common.clone(),
                    isolated_blending: g.isolated_blending,
                    knockout_group: g.knockout_group,
                }));
            }
            _ => {
                // Wrap standalone elements in a default layer
                if layers.is_empty() || !layers.last().is_some_and(|l| {
                    if let Element::Layer(le) = l { le.name().is_empty() } else { false }
                }) {
                    layers.push(Element::Layer(LayerElem {
                        children: vec![Rc::new(elem)],
                        common: CommonProps::default(),
                        isolated_blending: false,
                        knockout_group: false,
                    }));
                } else if let Some(Element::Layer(le)) = layers.last_mut() {
                    le.children.push(Rc::new(elem));
                }
            }
        }
    }
    // SVG has no artboards concept. Parsed SVG documents produce
    // an empty artboards list; native loaders enforce the
    // at-least-one invariant at app load time. See
    // ARTBOARDS.md §At-least-one-artboard invariant for the
    // load-time repair contract.
    if layers.is_empty() {
        let mut d = Document::default();
        d.symbols = symbols;
        d.artboards = artboards;
        d.artboard_options = crate::document::artboard::ArtboardOptions::default();
        d.document_setup = document_setup;
        d.print_preferences = print_preferences;
        return d;
    }
    let doc = Document {
        layers,
        symbols,
        selected_layer: 0,
        selection: Vec::new(),
        artboards,
        artboard_options: crate::document::artboard::ArtboardOptions::default(),
        document_setup,
        print_preferences,
    };
    // Opacity normalization, then enforce the unique-id invariant
    // (first-pre-order-wins) so the live-reference index never collides.
    dedupe_element_ids(&normalize_document(&doc))
}

/// Parse <inkscape:page> children of any top-level
/// <sodipodi:namedview> block into Artboard structs. Per the
/// document_to_svg side, x/y/width/height are stored in px and
/// converted back to internal pt units here. Returns an empty
/// vec when no namedview / pages are present — callers (the open
/// path in clipboard.rs, session restore in session.rs) repair
/// the at-least-one-artboard invariant separately.
fn parse_artboards(root: &XmlNode) -> Vec<crate::document::artboard::Artboard> {
    use crate::document::artboard::{Artboard, ArtboardFill};
    let mut out = Vec::new();
    for child in &root.children {
        if strip_ns(&child.tag) != "namedview" { continue; }
        for page in &child.children {
            if strip_ns(&page.tag) != "page" { continue; }
            // inkscape:label carries the user-visible name; fall
            // back to the id if absent (older Inkscape files
            // sometimes omit the label).
            let label = page.attrs.get("inkscape:label")
                .or_else(|| page.attrs.get("label"))
                .cloned()
                .unwrap_or_default();
            let id = page.attrs.get("id").cloned().unwrap_or_default();
            let name = if label.is_empty() { id.clone() } else { label };
            out.push(Artboard {
                id,
                name,
                x: pt(get_f(page, "x", 0.0)),
                y: pt(get_f(page, "y", 0.0)),
                width: pt(get_f(page, "width", 0.0)),
                height: pt(get_f(page, "height", 0.0)),
                // Phase-1 jas-specific fields are not round-tripped
                // through SVG; default them. Adding `jas:`-prefixed
                // attributes for the on/off toggles is a follow-up
                // when they become user-controllable.
                fill: ArtboardFill::Transparent,
                show_center_mark: false,
                show_cross_hairs: false,
                show_video_safe_areas: false,
                video_ruler_pixel_aspect_ratio: 1.0,
            });
        }
    }
    out
}

// ---------------------------------------------------------------------------
// DocumentSetup + PrintPreferences serialization (PRINT.md §Phase 2)
//
// These live as <jas:document-setup> and <jas:print-preferences>
// children of the <sodipodi:namedview> block. Bleed values are stored
// as raw point values (no px conversion) to keep the on-disk numbers
// intelligible and stable across viewports — they're print-domain
// quantities, not canvas geometry.
// ---------------------------------------------------------------------------

fn bool_str(b: bool) -> &'static str {
    if b { "true" } else { "false" }
}

fn parse_bool(s: &str, default: bool) -> bool {
    match s {
        "true" | "1" | "yes" => true,
        "false" | "0" | "no" => false,
        _ => default,
    }
}

fn get_attr<'a>(node: &'a XmlNode, name: &str) -> Option<&'a str> {
    // Try the bare name first; fall back to a `jas:`-prefixed
    // variant for files written by namespace-aware writers.
    node.attrs.get(name).map(String::as_str)
        .or_else(|| node.attrs.get(&format!("jas:{}", name)).map(String::as_str))
}

fn document_setup_to_xml(
    s: &crate::document::document_setup::DocumentSetup,
    indent: &str,
) -> String {
    use crate::document::print_preferences::flattener_preset_str;
    format!(
        "{indent}<jas:document-setup bleed-top=\"{bt}\" bleed-right=\"{br}\" bleed-bottom=\"{bb}\" bleed-left=\"{bl}\" bleed-uniform=\"{bu}\" show-images-outline=\"{sio}\" highlight-substituted-glyphs=\"{hsg}\" grid-size=\"{gs}\" grid-color=\"{gc}\" paper-color=\"{pc}\" simulate-colored-paper=\"{scp}\" transparency-flattener-preset=\"{tfp}\" discard-white-overprint=\"{dwo}\"/>",
        indent = indent,
        bt = fmt(s.bleed_top), br = fmt(s.bleed_right),
        bb = fmt(s.bleed_bottom), bl = fmt(s.bleed_left),
        bu = bool_str(s.bleed_uniform),
        sio = bool_str(s.show_images_outline),
        hsg = bool_str(s.highlight_substituted_glyphs),
        gs = fmt(s.grid_size),
        gc = escape_xml(&s.grid_color),
        pc = escape_xml(&s.paper_color),
        scp = bool_str(s.simulate_colored_paper),
        tfp = flattener_preset_str(&s.transparency_flattener_preset),
        dwo = bool_str(s.discard_white_overprint),
    )
}

fn parse_document_setup(
    node: &XmlNode,
) -> crate::document::document_setup::DocumentSetup {
    use crate::document::document_setup::DocumentSetup;
    let d = DocumentSetup::default();
    DocumentSetup {
        bleed_top: get_attr(node, "bleed-top")
            .and_then(|s| s.parse().ok()).unwrap_or(d.bleed_top),
        bleed_right: get_attr(node, "bleed-right")
            .and_then(|s| s.parse().ok()).unwrap_or(d.bleed_right),
        bleed_bottom: get_attr(node, "bleed-bottom")
            .and_then(|s| s.parse().ok()).unwrap_or(d.bleed_bottom),
        bleed_left: get_attr(node, "bleed-left")
            .and_then(|s| s.parse().ok()).unwrap_or(d.bleed_left),
        bleed_uniform: get_attr(node, "bleed-uniform")
            .map(|s| parse_bool(s, d.bleed_uniform)).unwrap_or(d.bleed_uniform),
        show_images_outline: get_attr(node, "show-images-outline")
            .map(|s| parse_bool(s, d.show_images_outline)).unwrap_or(d.show_images_outline),
        highlight_substituted_glyphs: get_attr(node, "highlight-substituted-glyphs")
            .map(|s| parse_bool(s, d.highlight_substituted_glyphs)).unwrap_or(d.highlight_substituted_glyphs),
        grid_size: get_attr(node, "grid-size")
            .and_then(|s| s.parse().ok()).unwrap_or(d.grid_size),
        grid_color: get_attr(node, "grid-color")
            .map(str::to_string).unwrap_or(d.grid_color),
        paper_color: get_attr(node, "paper-color")
            .map(str::to_string).unwrap_or(d.paper_color),
        simulate_colored_paper: get_attr(node, "simulate-colored-paper")
            .map(|s| parse_bool(s, d.simulate_colored_paper))
            .unwrap_or(d.simulate_colored_paper),
        transparency_flattener_preset: get_attr(node, "transparency-flattener-preset")
            .and_then(crate::document::print_preferences::flattener_preset_from)
            .unwrap_or(d.transparency_flattener_preset),
        discard_white_overprint: get_attr(node, "discard-white-overprint")
            .map(|s| parse_bool(s, d.discard_white_overprint))
            .unwrap_or(d.discard_white_overprint),
    }
}

fn marks_and_bleed_to_xml(
    m: &crate::document::print_preferences::MarksAndBleed,
    indent: &str,
) -> String {
    use crate::document::print_preferences::printer_mark_type_str;
    format!(
        "{indent}<jas:marks-and-bleed all-printer-marks=\"{apm}\" trim-marks=\"{tm}\" registration-marks=\"{rm}\" color-bars=\"{cb}\" page-information=\"{pi}\" printer-mark-type=\"{pmt}\" trim-mark-weight=\"{tmw}\" mark-offset=\"{mo}\" use-document-bleed=\"{udb}\" bleed-top=\"{bt}\" bleed-right=\"{br}\" bleed-bottom=\"{bb}\" bleed-left=\"{bl}\"/>",
        indent = indent,
        apm = bool_str(m.all_printer_marks),
        tm = bool_str(m.trim_marks),
        rm = bool_str(m.registration_marks),
        cb = bool_str(m.color_bars),
        pi = bool_str(m.page_information),
        pmt = printer_mark_type_str(&m.printer_mark_type),
        tmw = fmt(m.trim_mark_weight),
        mo = fmt(m.mark_offset),
        udb = bool_str(m.use_document_bleed),
        bt = fmt(m.bleed_top), br = fmt(m.bleed_right),
        bb = fmt(m.bleed_bottom), bl = fmt(m.bleed_left),
    )
}

fn parse_marks_and_bleed(
    node: &XmlNode,
) -> crate::document::print_preferences::MarksAndBleed {
    use crate::document::print_preferences::{MarksAndBleed, printer_mark_type_from};
    let d = MarksAndBleed::default();
    MarksAndBleed {
        all_printer_marks: get_attr(node, "all-printer-marks")
            .map(|s| parse_bool(s, d.all_printer_marks)).unwrap_or(d.all_printer_marks),
        trim_marks: get_attr(node, "trim-marks")
            .map(|s| parse_bool(s, d.trim_marks)).unwrap_or(d.trim_marks),
        registration_marks: get_attr(node, "registration-marks")
            .map(|s| parse_bool(s, d.registration_marks)).unwrap_or(d.registration_marks),
        color_bars: get_attr(node, "color-bars")
            .map(|s| parse_bool(s, d.color_bars)).unwrap_or(d.color_bars),
        page_information: get_attr(node, "page-information")
            .map(|s| parse_bool(s, d.page_information)).unwrap_or(d.page_information),
        printer_mark_type: get_attr(node, "printer-mark-type")
            .and_then(printer_mark_type_from).unwrap_or(d.printer_mark_type),
        trim_mark_weight: get_attr(node, "trim-mark-weight")
            .and_then(|s| s.parse().ok()).unwrap_or(d.trim_mark_weight),
        mark_offset: get_attr(node, "mark-offset")
            .and_then(|s| s.parse().ok()).unwrap_or(d.mark_offset),
        use_document_bleed: get_attr(node, "use-document-bleed")
            .map(|s| parse_bool(s, d.use_document_bleed)).unwrap_or(d.use_document_bleed),
        bleed_top: get_attr(node, "bleed-top")
            .and_then(|s| s.parse().ok()).unwrap_or(d.bleed_top),
        bleed_right: get_attr(node, "bleed-right")
            .and_then(|s| s.parse().ok()).unwrap_or(d.bleed_right),
        bleed_bottom: get_attr(node, "bleed-bottom")
            .and_then(|s| s.parse().ok()).unwrap_or(d.bleed_bottom),
        bleed_left: get_attr(node, "bleed-left")
            .and_then(|s| s.parse().ok()).unwrap_or(d.bleed_left),
    }
}

fn ink_override_to_xml(
    ink: &crate::document::print_preferences::InkOverride,
    indent: &str,
) -> String {
    use crate::document::print_preferences::dot_shape_str;
    format!(
        "{indent}<jas:ink name=\"{name}\" print=\"{p}\" frequency=\"{f}\" angle=\"{a}\" dot-shape=\"{ds}\"/>",
        indent = indent,
        name = escape_xml(&ink.name),
        p = bool_str(ink.print),
        f = fmt(ink.frequency),
        a = fmt(ink.angle),
        ds = dot_shape_str(&ink.dot_shape),
    )
}

fn advanced_to_xml(
    a: &crate::document::print_preferences::Advanced,
    indent: &str,
) -> String {
    use crate::document::print_preferences::flattener_preset_str;
    format!(
        "{indent}<jas:advanced print-as-bitmap=\"{pab}\" overprint-flattener-preset=\"{ofp}\"/>",
        indent = indent,
        pab = bool_str(a.print_as_bitmap),
        ofp = flattener_preset_str(&a.overprint_flattener_preset),
    )
}

fn parse_advanced(
    node: &XmlNode,
) -> crate::document::print_preferences::Advanced {
    use crate::document::print_preferences::*;
    let d = Advanced::default();
    Advanced {
        print_as_bitmap: get_attr(node, "print-as-bitmap")
            .map(|s| parse_bool(s, d.print_as_bitmap)).unwrap_or(d.print_as_bitmap),
        overprint_flattener_preset: get_attr(node, "overprint-flattener-preset")
            .and_then(flattener_preset_from).unwrap_or(d.overprint_flattener_preset),
    }
}

fn color_management_to_xml(
    c: &crate::document::print_preferences::ColorManagement,
    indent: &str,
) -> String {
    use crate::document::print_preferences::*;
    format!(
        "{indent}<jas:color-management document-profile=\"{dp}\" color-handling=\"{ch}\" printer-profile=\"{pp}\" rendering-intent=\"{ri}\" preserve-rgb-numbers=\"{prn}\"/>",
        indent = indent,
        dp = escape_xml(&c.document_profile),
        ch = color_handling_str(&c.color_handling),
        pp = escape_xml(&c.printer_profile),
        ri = rendering_intent_str(&c.rendering_intent),
        prn = bool_str(c.preserve_rgb_numbers),
    )
}

fn parse_color_management(
    node: &XmlNode,
) -> crate::document::print_preferences::ColorManagement {
    use crate::document::print_preferences::*;
    let d = ColorManagement::default();
    ColorManagement {
        document_profile: get_attr(node, "document-profile")
            .map(str::to_string).unwrap_or(d.document_profile),
        color_handling: get_attr(node, "color-handling")
            .and_then(color_handling_from).unwrap_or(d.color_handling),
        printer_profile: get_attr(node, "printer-profile")
            .map(str::to_string).unwrap_or(d.printer_profile),
        rendering_intent: get_attr(node, "rendering-intent")
            .and_then(rendering_intent_from).unwrap_or(d.rendering_intent),
        preserve_rgb_numbers: get_attr(node, "preserve-rgb-numbers")
            .map(|s| parse_bool(s, d.preserve_rgb_numbers))
            .unwrap_or(d.preserve_rgb_numbers),
    }
}

fn graphics_to_xml(
    g: &crate::document::print_preferences::Graphics,
    indent: &str,
) -> String {
    use crate::document::print_preferences::*;
    format!(
        "{indent}<jas:graphics flatness=\"{fl}\" font-download=\"{fd}\" postscript-level=\"{pl}\" data-format=\"{df}\" compatible-gradient-printing=\"{cgp}\" raster-effects-resolution=\"{rer}\"/>",
        indent = indent,
        fl = fmt(g.flatness),
        fd = font_download_str(&g.font_download),
        pl = postscript_level_str(&g.postscript_level),
        df = data_format_str(&g.data_format),
        cgp = bool_str(g.compatible_gradient_printing),
        rer = fmt(g.raster_effects_resolution),
    )
}

fn parse_graphics(
    node: &XmlNode,
) -> crate::document::print_preferences::Graphics {
    use crate::document::print_preferences::*;
    let d = Graphics::default();
    Graphics {
        flatness: get_attr(node, "flatness")
            .and_then(|s| s.parse().ok()).unwrap_or(d.flatness),
        font_download: get_attr(node, "font-download")
            .and_then(font_download_from).unwrap_or(d.font_download),
        postscript_level: get_attr(node, "postscript-level")
            .and_then(postscript_level_from).unwrap_or(d.postscript_level),
        data_format: get_attr(node, "data-format")
            .and_then(data_format_from).unwrap_or(d.data_format),
        compatible_gradient_printing: get_attr(node, "compatible-gradient-printing")
            .map(|s| parse_bool(s, d.compatible_gradient_printing))
            .unwrap_or(d.compatible_gradient_printing),
        raster_effects_resolution: get_attr(node, "raster-effects-resolution")
            .and_then(|s| s.parse().ok()).unwrap_or(d.raster_effects_resolution),
    }
}

fn output_to_xml(
    o: &crate::document::print_preferences::Output,
    indent: &str,
) -> String {
    use crate::document::print_preferences::*;
    let inner = format!("{}  ", indent);
    let mut s = format!(
        "{indent}<jas:output mode=\"{m}\" emulsion=\"{e}\" image-polarity=\"{ip}\" printer-resolution=\"{pr}\" convert-spot-to-process=\"{csp}\" overprint-black=\"{ob}\">",
        indent = indent,
        m = output_mode_str(&o.mode),
        e = emulsion_str(&o.emulsion),
        ip = image_polarity_str(&o.image_polarity),
        pr = escape_xml(&o.printer_resolution),
        csp = bool_str(o.convert_spot_to_process),
        ob = bool_str(o.overprint_black),
    );
    for ink in &o.inks {
        s.push('\n');
        s.push_str(&ink_override_to_xml(ink, &inner));
    }
    s.push('\n');
    s.push_str(indent);
    s.push_str("</jas:output>");
    s
}

fn parse_ink_override(
    node: &XmlNode,
) -> crate::document::print_preferences::InkOverride {
    use crate::document::print_preferences::*;
    let d = InkOverride { name: String::new(), print: true, frequency: 75.0, angle: 45.0, dot_shape: DotShape::Round };
    InkOverride {
        name: get_attr(node, "name").map(str::to_string).unwrap_or(d.name),
        print: get_attr(node, "print")
            .map(|s| parse_bool(s, d.print)).unwrap_or(d.print),
        frequency: get_attr(node, "frequency")
            .and_then(|s| s.parse().ok()).unwrap_or(d.frequency),
        angle: get_attr(node, "angle")
            .and_then(|s| s.parse().ok()).unwrap_or(d.angle),
        dot_shape: get_attr(node, "dot-shape")
            .and_then(dot_shape_from).unwrap_or(d.dot_shape),
    }
}

fn parse_output(
    node: &XmlNode,
) -> crate::document::print_preferences::Output {
    use crate::document::print_preferences::*;
    let d = Output::default();
    let mut o = Output {
        mode: get_attr(node, "mode")
            .and_then(output_mode_from).unwrap_or(d.mode),
        emulsion: get_attr(node, "emulsion")
            .and_then(emulsion_from).unwrap_or(d.emulsion),
        image_polarity: get_attr(node, "image-polarity")
            .and_then(image_polarity_from).unwrap_or(d.image_polarity),
        printer_resolution: get_attr(node, "printer-resolution")
            .map(str::to_string).unwrap_or(d.printer_resolution),
        convert_spot_to_process: get_attr(node, "convert-spot-to-process")
            .map(|s| parse_bool(s, d.convert_spot_to_process))
            .unwrap_or(d.convert_spot_to_process),
        overprint_black: get_attr(node, "overprint-black")
            .map(|s| parse_bool(s, d.overprint_black))
            .unwrap_or(d.overprint_black),
        // Default to an empty list; populated below from <jas:ink>
        // children. Falls back to the CMYK defaults when no children
        // are present, so a missing <jas:output> in older files still
        // ends up with the standard four-row table.
        inks: Vec::new(),
    };
    for child in &node.children {
        if strip_ns(&child.tag) == "ink" {
            o.inks.push(parse_ink_override(child));
        }
    }
    if o.inks.is_empty() {
        o.inks = InkOverride::process_cmyk_defaults();
    }
    o
}

fn print_preferences_to_xml(
    p: &crate::document::print_preferences::PrintPreferences,
    indent: &str,
) -> String {
    use crate::document::print_preferences::*;
    let inner_indent = format!("{}  ", indent);
    let mut s = format!(
        "{indent}<jas:print-preferences preset-name=\"{pn}\" copies=\"{c}\" collate=\"{co}\" reverse-order=\"{ro}\" artboard-range-mode=\"{arm}\" artboard-range=\"{ar}\" ignore-artboards=\"{ia}\" skip-blank-artboards=\"{sba}\" media-size=\"{ms}\" media-width=\"{mw}\" media-height=\"{mh}\" orientation=\"{o}\" auto-rotate=\"{aro}\" transverse=\"{tv}\" print-layers=\"{pl}\" placement-x=\"{px}\" placement-y=\"{py}\" scaling-mode=\"{sm}\" custom-scale=\"{cs}\" tile-overlap-h=\"{toh}\" tile-overlap-v=\"{tov}\" tile-range=\"{tr}\"",
        indent = indent,
        pn = escape_xml(&p.preset_name),
        c = p.copies,
        co = bool_str(p.collate),
        ro = bool_str(p.reverse_order),
        arm = artboard_range_mode_str(&p.artboard_range_mode),
        ar = escape_xml(&p.artboard_range),
        ia = bool_str(p.ignore_artboards),
        sba = bool_str(p.skip_blank_artboards),
        ms = media_size_str(&p.media_size),
        mw = fmt(p.media_width), mh = fmt(p.media_height),
        o = orientation_str(&p.orientation),
        aro = bool_str(p.auto_rotate),
        tv = bool_str(p.transverse),
        pl = print_layers_str(&p.print_layers),
        px = fmt(p.placement_x), py = fmt(p.placement_y),
        sm = scaling_mode_str(&p.scaling_mode),
        cs = fmt(p.custom_scale),
        toh = fmt(p.tile_overlap_h), tov = fmt(p.tile_overlap_v),
        tr = escape_xml(&p.tile_range),
    );
    // printer-name is optional — emit only when set so the absent
    // case round-trips back to None instead of Some("").
    if let Some(name) = &p.printer_name {
        s.push_str(&format!(" printer-name=\"{}\"", escape_xml(name)));
    }
    s.push('>');
    s.push('\n');
    s.push_str(&marks_and_bleed_to_xml(&p.marks_and_bleed, &inner_indent));
    s.push('\n');
    s.push_str(&output_to_xml(&p.output, &inner_indent));
    s.push('\n');
    s.push_str(&graphics_to_xml(&p.graphics, &inner_indent));
    s.push('\n');
    s.push_str(&color_management_to_xml(&p.color_management, &inner_indent));
    s.push('\n');
    s.push_str(&advanced_to_xml(&p.advanced, &inner_indent));
    s.push('\n');
    s.push_str(indent);
    s.push_str("</jas:print-preferences>");
    s
}

fn parse_print_preferences(
    node: &XmlNode,
) -> crate::document::print_preferences::PrintPreferences {
    use crate::document::print_preferences::*;
    let d = PrintPreferences::default();
    let mut p = PrintPreferences {
        preset_name: get_attr(node, "preset-name")
            .map(str::to_string).unwrap_or(d.preset_name),
        printer_name: get_attr(node, "printer-name").map(str::to_string),
        copies: get_attr(node, "copies")
            .and_then(|s| s.parse().ok()).unwrap_or(d.copies),
        collate: get_attr(node, "collate")
            .map(|s| parse_bool(s, d.collate)).unwrap_or(d.collate),
        reverse_order: get_attr(node, "reverse-order")
            .map(|s| parse_bool(s, d.reverse_order)).unwrap_or(d.reverse_order),
        artboard_range_mode: get_attr(node, "artboard-range-mode")
            .and_then(artboard_range_mode_from).unwrap_or(d.artboard_range_mode),
        artboard_range: get_attr(node, "artboard-range")
            .map(str::to_string).unwrap_or(d.artboard_range),
        ignore_artboards: get_attr(node, "ignore-artboards")
            .map(|s| parse_bool(s, d.ignore_artboards)).unwrap_or(d.ignore_artboards),
        skip_blank_artboards: get_attr(node, "skip-blank-artboards")
            .map(|s| parse_bool(s, d.skip_blank_artboards)).unwrap_or(d.skip_blank_artboards),
        media_size: get_attr(node, "media-size")
            .and_then(media_size_from).unwrap_or(d.media_size),
        media_width: get_attr(node, "media-width")
            .and_then(|s| s.parse().ok()).unwrap_or(d.media_width),
        media_height: get_attr(node, "media-height")
            .and_then(|s| s.parse().ok()).unwrap_or(d.media_height),
        orientation: get_attr(node, "orientation")
            .and_then(orientation_from).unwrap_or(d.orientation),
        auto_rotate: get_attr(node, "auto-rotate")
            .map(|s| parse_bool(s, d.auto_rotate)).unwrap_or(d.auto_rotate),
        transverse: get_attr(node, "transverse")
            .map(|s| parse_bool(s, d.transverse)).unwrap_or(d.transverse),
        print_layers: get_attr(node, "print-layers")
            .and_then(print_layers_from).unwrap_or(d.print_layers),
        placement_x: get_attr(node, "placement-x")
            .and_then(|s| s.parse().ok()).unwrap_or(d.placement_x),
        placement_y: get_attr(node, "placement-y")
            .and_then(|s| s.parse().ok()).unwrap_or(d.placement_y),
        scaling_mode: get_attr(node, "scaling-mode")
            .and_then(scaling_mode_from).unwrap_or(d.scaling_mode),
        custom_scale: get_attr(node, "custom-scale")
            .and_then(|s| s.parse().ok()).unwrap_or(d.custom_scale),
        tile_overlap_h: get_attr(node, "tile-overlap-h")
            .and_then(|s| s.parse().ok()).unwrap_or(d.tile_overlap_h),
        tile_overlap_v: get_attr(node, "tile-overlap-v")
            .and_then(|s| s.parse().ok()).unwrap_or(d.tile_overlap_v),
        tile_range: get_attr(node, "tile-range")
            .map(str::to_string).unwrap_or(d.tile_range),
        marks_and_bleed: MarksAndBleed::default(),
        output: Output::default(),
        graphics: Graphics::default(),
        color_management: ColorManagement::default(),
        advanced: Advanced::default(),
    };
    for child in &node.children {
        match strip_ns(&child.tag) {
            "marks-and-bleed" => p.marks_and_bleed = parse_marks_and_bleed(child),
            "output" => p.output = parse_output(child),
            "graphics" => p.graphics = parse_graphics(child),
            "color-management" => p.color_management = parse_color_management(child),
            "advanced" => p.advanced = parse_advanced(child),
            _ => {}
        }
    }
    p
}

/// Walk the namedview block(s) for `<jas:document-setup>` and
/// `<jas:print-preferences>` children and return the parsed pair.
/// Missing children produce defaults — matching the writer's
/// "omit when default" behavior.
fn parse_jas_print_blocks(
    root: &XmlNode,
) -> (
    crate::document::document_setup::DocumentSetup,
    crate::document::print_preferences::PrintPreferences,
) {
    use crate::document::document_setup::DocumentSetup;
    use crate::document::print_preferences::PrintPreferences;
    let mut setup = DocumentSetup::default();
    let mut prefs = PrintPreferences::default();
    for child in &root.children {
        if strip_ns(&child.tag) != "namedview" { continue; }
        for sub in &child.children {
            match strip_ns(&sub.tag) {
                "document-setup" => setup = parse_document_setup(sub),
                "print-preferences" => prefs = parse_print_preferences(sub),
                _ => {}
            }
        }
    }
    (setup, prefs)
}

// ---------------------------------------------------------------------------
// Named colors
// ---------------------------------------------------------------------------

fn named_colors_map() -> HashMap<&'static str, (u8, u8, u8)> {
    let mut m = HashMap::new();
    m.insert("black", (0, 0, 0));
    m.insert("white", (255, 255, 255));
    m.insert("red", (255, 0, 0));
    m.insert("green", (0, 128, 0));
    m.insert("blue", (0, 0, 255));
    m.insert("yellow", (255, 255, 0));
    m.insert("cyan", (0, 255, 255));
    m.insert("magenta", (255, 0, 255));
    m.insert("gray", (128, 128, 128));
    m.insert("grey", (128, 128, 128));
    m.insert("silver", (192, 192, 192));
    m.insert("maroon", (128, 0, 0));
    m.insert("olive", (128, 128, 0));
    m.insert("lime", (0, 255, 0));
    m.insert("aqua", (0, 255, 255));
    m.insert("teal", (0, 128, 128));
    m.insert("navy", (0, 0, 128));
    m.insert("fuchsia", (255, 0, 255));
    m.insert("purple", (128, 0, 128));
    m.insert("orange", (255, 165, 0));
    m.insert("pink", (255, 192, 203));
    m.insert("brown", (165, 42, 42));
    m.insert("coral", (255, 127, 80));
    m.insert("crimson", (220, 20, 60));
    m.insert("gold", (255, 215, 0));
    m.insert("indigo", (75, 0, 130));
    m.insert("ivory", (255, 255, 240));
    m.insert("khaki", (240, 230, 140));
    m.insert("lavender", (230, 230, 250));
    m.insert("plum", (221, 160, 221));
    m.insert("salmon", (250, 128, 114));
    m.insert("sienna", (160, 82, 45));
    m.insert("tan", (210, 180, 140));
    m.insert("tomato", (255, 99, 71));
    m.insert("turquoise", (64, 224, 208));
    m.insert("violet", (238, 130, 238));
    m.insert("wheat", (245, 222, 179));
    m.insert("steelblue", (70, 130, 180));
    m.insert("skyblue", (135, 206, 235));
    m.insert("slategray", (112, 128, 144));
    m.insert("slategrey", (112, 128, 144));
    m.insert("darkgray", (169, 169, 169));
    m.insert("darkgrey", (169, 169, 169));
    m.insert("lightgray", (211, 211, 211));
    m.insert("lightgrey", (211, 211, 211));
    m.insert("darkblue", (0, 0, 139));
    m.insert("darkgreen", (0, 100, 0));
    m.insert("darkred", (139, 0, 0));
    m
}

use std::sync::OnceLock;

static NAMED_COLORS: OnceLock<HashMap<&'static str, (u8, u8, u8)>> = OnceLock::new();

fn get_named_colors() -> &'static HashMap<&'static str, (u8, u8, u8)> {
    NAMED_COLORS.get_or_init(named_colors_map)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::element::*;

    fn make_rect(x: f64, y: f64, w: f64, h: f64) -> Element {
        Element::Rect(RectElem {
            x, y, width: w, height: h, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),
            stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn make_line(x1: f64, y1: f64, x2: f64, y2: f64) -> Element {
        Element::Line(LineElem {
            x1, y1, x2, y2,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
                    stroke_gradient: None,
        })
    }

    fn make_circle(cx: f64, cy: f64, r: f64) -> Element {
        Element::Ellipse(EllipseElem {
            cx, cy, rx: r, ry: r,
            fill: Some(Fill::new(Color::rgb(0.0, 0.0, 1.0))),
            stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn make_doc(children: Vec<Element>) -> Document {
        Document {
            layers: vec![Element::Layer(LayerElem {
                children: children.into_iter().map(Rc::new).collect(),
                isolated_blending: false,
                knockout_group: false,
                common: CommonProps {
                    name: Some("Layer".to_string()),
                    ..Default::default()
                },
            })],
            selected_layer: 0,
            selection: vec![],
            ..Document::default()
        }
    }

    #[test]
    fn export_empty_document() {
        let doc = Document::default();
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<svg"));
        assert!(svg.contains("</svg>"));
    }

    #[test]
    fn export_contains_rect() {
        let doc = make_doc(vec![make_rect(10.0, 20.0, 30.0, 40.0)]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<rect"));
    }

    #[test]
    fn export_contains_line() {
        let doc = make_doc(vec![make_line(0.0, 0.0, 50.0, 50.0)]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<line"));
    }

    #[test]
    fn export_contains_circle() {
        let doc = make_doc(vec![make_circle(50.0, 50.0, 20.0)]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<circle"));
    }

    #[test]
    fn export_rounded_rect_has_rx_ry() {
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 10.0, y: 20.0, width: 100.0, height: 50.0,
            rx: 10.0, ry: 10.0,
            fill: Some(Fill::new(Color::WHITE)),
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("rx=\""), "expected rx attribute in: {svg}");
        assert!(svg.contains("ry=\""), "expected ry attribute in: {svg}");
    }

    #[test]
    fn export_plain_rect_omits_rx_ry() {
        let doc = make_doc(vec![make_rect(10.0, 20.0, 30.0, 40.0)]);
        let svg = document_to_svg(&doc);
        assert!(!svg.contains("rx=\""), "plain rect should not emit rx: {svg}");
        assert!(!svg.contains("ry=\""), "plain rect should not emit ry: {svg}");
    }

    #[test]
    fn roundtrip_rounded_rect_preserves_rx_ry() {
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 10.0, y: 20.0, width: 100.0, height: 50.0,
            rx: 10.0, ry: 10.0,
            fill: Some(Fill::new(Color::WHITE)),
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Rect(r) = &*children[0] {
            assert!(r.rx > 0.0, "expected rx > 0 after roundtrip, got {}", r.rx);
            assert!(r.ry > 0.0, "expected ry > 0 after roundtrip, got {}", r.ry);
        } else {
            panic!("expected Rect, got {:?}", &*children[0]);
        }
    }

    /// BRUSHSAVE: SVG *is* the save format (menu_bar's `"save"` arm calls
    /// `document_to_svg` and downloads it), so anything the writer omits is
    /// artwork the artist loses on save. The reader already accepts
    /// `jas:stroke-brush`; the writer never emitted it, and neither side ever
    /// carried the variable-width profile.
    #[test]
    fn roundtrip_path_keeps_its_stroke_brush_and_width_profile() {
        use crate::geometry::element::{PathCommand, PathElem, StrokeWidthPoint};
        let path = Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 30.0, y: 40.0 },
            ],
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 2.0)),
            width_points: vec![
                StrokeWidthPoint { t: 0.25, width_left: 3.5, width_right: 1.25 },
                StrokeWidthPoint { t: 0.75, width_left: 2.0, width_right: 2.0 },
            ],
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
            stroke_brush: Some("default_brushes/flat_10".to_string()),
            stroke_brush_overrides: Some("{\"size\":4}".to_string()),
            fill_rule: crate::geometry::element::FillRule::NonZero,
        });
        let doc = make_doc(vec![path]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Path(p) = &*children[0] else {
            panic!("expected Path, got {:?}", &*children[0]);
        };
        assert_eq!(
            p.stroke_brush.as_deref(),
            Some("default_brushes/flat_10"),
            "a brushed stroke must survive save-and-reopen"
        );
        assert_eq!(
            p.stroke_brush_overrides.as_deref(),
            Some("{\"size\":4}"),
            "and its per-instance overrides with it"
        );
        assert_eq!(
            p.width_points.len(),
            2,
            "a variable-width profile must survive save-and-reopen"
        );
        assert_eq!(p.width_points[0].t, 0.25);
        assert_eq!(p.width_points[0].width_left, 3.5);
        assert_eq!(p.width_points[0].width_right, 1.25);
        assert_eq!(p.width_points[1].width_left, 2.0);
    }

    /// ⛔ ALSO UNREGISTERED — no `#[test]`, so SVG rect round-tripping has never
    /// been exercised by this suite. Second of two found by the same sweep on
    /// 2026-08-27; see `mask_plan_clip_not_inverted_is_clip_in` in canvas/render.rs.
    #[test]
    fn roundtrip_rect() {
        let doc = make_doc(vec![make_rect(10.0, 20.0, 30.0, 40.0)]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        if let Element::Rect(r) = &*children[0] {
            // SVG uses pt-to-px conversion (96/72), check approximately
            assert!(r.width > 0.0);
            assert!(r.height > 0.0);
        } else {
            panic!("expected Rect, got {:?}", &*children[0]);
        }
    }

    #[test]
    fn roundtrip_line() {
        let doc = make_doc(vec![make_line(0.0, 0.0, 100.0, 100.0)]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Line(_)));
    }

    #[test]
    fn roundtrip_circle() {
        let doc = make_doc(vec![make_circle(50.0, 50.0, 20.0)]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Ellipse(_)));
    }

    #[test]
    fn roundtrip_multiple_elements() {
        let doc = make_doc(vec![
            make_rect(0.0, 0.0, 10.0, 10.0),
            make_line(0.0, 0.0, 50.0, 50.0),
            make_circle(30.0, 30.0, 15.0),
        ]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 3);
    }

    #[test]
    fn roundtrip_group() {
        let g = Element::Group(GroupElem {
            children: vec![Rc::new(make_rect(0.0, 0.0, 10.0, 10.0)), Rc::new(make_line(0.0, 0.0, 5.0, 5.0))],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = make_doc(vec![g]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Group(_)));
        let group_children = children[0].children().unwrap();
        assert_eq!(group_children.len(), 2);
    }

    #[test]
    fn roundtrip_text_preserves_y_as_top() {
        // Internally `e.y` is the top of the layout box. Round-tripping
        // through SVG (which uses the baseline as `y`) must put us back
        // at the same top-of-box position.
        let t = TextElem::from_string(
            10.0, 20.0, "Hi",
            "sans-serif", 16.0,
            "normal", "normal", "none",
            0.0, 0.0,
            Some(Fill::new(Color::BLACK)), None,
            CommonProps::default(),
        );
        let doc = make_doc(vec![Element::Text(t)]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Text(t2) = &*children[0] {
            assert!((t2.y - 20.0).abs() < 1e-3, "got y = {}", t2.y);
            assert!((t2.x - 10.0).abs() < 1e-3, "got x = {}", t2.x);
        } else {
            panic!("expected Text");
        }
        assert!(svg.contains("<text"));
    }

    #[test]
    fn import_minimal_svg() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg"><rect x="10" y="20" width="30" height="40"/></svg>"#;
        let doc = svg_to_document(svg);
        assert!(!doc.layers.is_empty());
        let children = doc.layers[0].children().unwrap();
        assert_eq!(children.len(), 1);
        assert!(matches!(&*children[0], Element::Rect(_)));
    }

    #[test]
    fn import_svg_with_fill() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="10" height="10" fill="red"/></svg>"#;
        let doc = svg_to_document(svg);
        let children = doc.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            assert!(r.fill.is_some());
            let c = r.fill.unwrap().color;
            let (rv, _, _, _) = c.to_rgba();
            assert!((rv - 1.0).abs() < 0.01);
        }
    }

    #[test]
    fn import_empty_svg() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg"></svg>"#;
        let doc = svg_to_document(svg);
        assert!(!doc.layers.is_empty());
    }

    // -----------------------------------------------------------------------
    // Artboard round-trip via Inkscape's <sodipodi:namedview> +
    // <inkscape:page> convention. SVG itself has no artboards
    // concept; using Inkscape's convention keeps documents
    // interoperable with Inkscape and lets jas_dioxus reopen its
    // own saves without losing artboard geometry.
    // -----------------------------------------------------------------------

    #[test]
    fn export_writes_inkscape_pages_for_each_artboard() {
        use crate::document::artboard::{Artboard, ArtboardFill};
        let mut doc = Document::default();
        doc.artboards = vec![
            Artboard {
                id: "ab-a".into(), name: "Cover".into(),
                x: 0.0, y: 0.0, width: 612.0, height: 792.0,
                fill: ArtboardFill::Transparent,
                show_center_mark: false, show_cross_hairs: false,
                show_video_safe_areas: false,
                video_ruler_pixel_aspect_ratio: 1.0,
            },
            Artboard {
                id: "ab-b".into(), name: "Inside".into(),
                x: 700.0, y: 0.0, width: 612.0, height: 792.0,
                fill: ArtboardFill::Transparent,
                show_center_mark: false, show_cross_hairs: false,
                show_video_safe_areas: false,
                video_ruler_pixel_aspect_ratio: 1.0,
            },
        ];
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<sodipodi:namedview"),
                "missing namedview block:\n{svg}");
        // Two pages, both with their labels, in the SVG order.
        let pages: Vec<&str> = svg.matches("<inkscape:page").collect();
        assert_eq!(pages.len(), 2, "expected 2 pages, svg:\n{svg}");
        assert!(svg.contains("inkscape:label=\"Cover\""), "svg:\n{svg}");
        assert!(svg.contains("inkscape:label=\"Inside\""), "svg:\n{svg}");
    }

    #[test]
    fn round_trip_preserves_artboards_geometry_and_names() {
        use crate::document::artboard::{Artboard, ArtboardFill};
        let mut doc = Document::default();
        doc.artboards = vec![
            Artboard {
                id: "ab-a".into(), name: "Cover".into(),
                x: 0.0, y: 0.0, width: 612.0, height: 792.0,
                fill: ArtboardFill::Transparent,
                show_center_mark: false, show_cross_hairs: false,
                show_video_safe_areas: false,
                video_ruler_pixel_aspect_ratio: 1.0,
            },
            Artboard {
                id: "ab-b".into(), name: "Inside".into(),
                x: 700.0, y: 50.0, width: 400.0, height: 300.0,
                fill: ArtboardFill::Transparent,
                show_center_mark: false, show_cross_hairs: false,
                show_video_safe_areas: false,
                video_ruler_pixel_aspect_ratio: 1.0,
            },
        ];
        let svg = document_to_svg(&doc);
        let parsed = svg_to_document(&svg);
        assert_eq!(parsed.artboards.len(), 2, "svg:\n{svg}");

        // Ordering preserved.
        let a = &parsed.artboards[0];
        let b = &parsed.artboards[1];
        assert_eq!(a.name, "Cover");
        assert_eq!(b.name, "Inside");

        // Geometry preserved within float tolerance (px<->pt round-trip).
        let close = |x: f64, y: f64| (x - y).abs() < 0.01;
        assert!(close(a.x, 0.0)   && close(a.y, 0.0));
        assert!(close(a.width, 612.0) && close(a.height, 792.0));
        assert!(close(b.x, 700.0) && close(b.y, 50.0));
        assert!(close(b.width, 400.0) && close(b.height, 300.0));

        // ids preserved (Inkscape uses `id="..."` on inkscape:page;
        // round-tripping it lets the at-least-one-artboard repair on
        // load skip when the saved file already provides one).
        assert_eq!(a.id, "ab-a");
        assert_eq!(b.id, "ab-b");
    }

    #[test]
    fn import_svg_without_namedview_yields_empty_artboards() {
        // Pre-existing contract: SVG without inkscape:page produces
        // a Document with empty artboards, deferring to the caller's
        // ensure_artboards_invariant repair. Don't break this.
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>"#;
        let doc = svg_to_document(svg);
        assert!(doc.artboards.is_empty());
    }

    // -----------------------------------------------------------------------
    // Hex color parsing (4-digit and 8-digit)
    // -----------------------------------------------------------------------

    #[test]
    fn parse_color_4_digit_hex() {
        let c = parse_color("#F00A").unwrap();
        let (r, g, b, a) = c.to_rgba();
        assert!((r - 1.0).abs() < 0.01, "r={r}");
        assert!((g - 0.0).abs() < 0.01, "g={g}");
        assert!((b - 0.0).abs() < 0.01, "b={b}");
        // 0xAA / 255 ≈ 0.667
        assert!((a - 0.667).abs() < 0.01, "a={a}");
    }

    #[test]
    fn parse_color_8_digit_hex() {
        let c = parse_color("#FF000080").unwrap();
        let (r, g, b, a) = c.to_rgba();
        assert!((r - 1.0).abs() < 0.01, "r={r}");
        assert!((g - 0.0).abs() < 0.01, "g={g}");
        assert!((b - 0.0).abs() < 0.01, "b={b}");
        // 0x80 / 255 ≈ 0.502
        assert!((a - 0.502).abs() < 0.01, "a={a}");
    }

    // -----------------------------------------------------------------------
    // fill-opacity / stroke-opacity parsing
    // -----------------------------------------------------------------------

    #[test]
    fn import_fill_opacity() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="10" height="10" fill="red" fill-opacity="0.5"/></svg>"#;
        let doc = svg_to_document(svg);
        let children = doc.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            // After normalization, fill.opacity should be 0.5 (color was opaque)
            assert!((r.fill.unwrap().opacity - 0.5).abs() < 0.01);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn import_stroke_opacity() {
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg"><rect x="0" y="0" width="10" height="10" stroke="blue" stroke-width="2" stroke-opacity="0.3"/></svg>"#;
        let doc = svg_to_document(svg);
        let children = doc.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            assert!((r.stroke.unwrap().opacity - 0.3).abs() < 0.01);
        } else {
            panic!("expected Rect");
        }
    }

    // -----------------------------------------------------------------------
    // fill-opacity / stroke-opacity export
    // -----------------------------------------------------------------------

    #[test]
    fn export_fill_opacity() {
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::rgb(1.0, 0.0, 0.0), opacity: 0.5 }),
            stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("fill-opacity=\"0.5\""), "svg={svg}");
    }

    #[test]
    fn export_stroke_opacity() {
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None,
            stroke: Some(Stroke { opacity: 0.4, ..Stroke::new(Color::BLACK, 1.0) }),
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        })]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("stroke-opacity=\"0.4\""), "svg={svg}");
    }

    #[test]
    fn export_omits_opacity_when_one() {
        let doc = make_doc(vec![make_rect(0.0, 0.0, 10.0, 10.0)]);
        let svg = document_to_svg(&doc);
        assert!(!svg.contains("fill-opacity"), "svg={svg}");
        assert!(!svg.contains("stroke-opacity"), "svg={svg}");
    }

    // -----------------------------------------------------------------------
    // Normalizer
    // -----------------------------------------------------------------------

    #[test]
    fn normalize_extracts_fill_alpha() {
        use crate::geometry::normalize::normalize_document;
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::new(1.0, 0.0, 0.0, 0.5), opacity: 1.0 }),
            stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })]);
        let doc2 = normalize_document(&doc);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            let f = r.fill.unwrap();
            assert!((f.opacity - 0.5).abs() < 1e-9, "fill opacity={}", f.opacity);
            assert!((f.color.alpha() - 1.0).abs() < 1e-9, "color alpha={}", f.color.alpha());
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn normalize_multiplies_existing() {
        use crate::geometry::normalize::normalize_document;
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::new(1.0, 0.0, 0.0, 0.5), opacity: 0.8 }),
            stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })]);
        let doc2 = normalize_document(&doc);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            let f = r.fill.unwrap();
            assert!((f.opacity - 0.4).abs() < 1e-9, "fill opacity={}", f.opacity);
            assert!((f.color.alpha() - 1.0).abs() < 1e-9);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn normalize_stroke_alpha() {
        use crate::geometry::normalize::normalize_document;
        let doc = make_doc(vec![Element::Line(LineElem {
            x1: 0.0, y1: 0.0, x2: 10.0, y2: 10.0,
            stroke: Some(Stroke::new(Color::new(0.0, 0.0, 0.0, 0.25), 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
                    stroke_gradient: None,
        })]);
        let doc2 = normalize_document(&doc);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Line(e) = &*children[0] {
            let s = e.stroke.unwrap();
            assert!((s.opacity - 0.25).abs() < 1e-9, "stroke opacity={}", s.opacity);
            assert!((s.color.alpha() - 1.0).abs() < 1e-9);
        } else {
            panic!("expected Line");
        }
    }

    #[test]
    fn normalize_no_fill_unchanged() {
        use crate::geometry::normalize::normalize_document;
        let doc = make_doc(vec![make_line(0.0, 0.0, 10.0, 10.0)]);
        let doc2 = normalize_document(&doc);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Line(e) = &*children[0] {
            assert!(e.stroke.is_some());
            assert!((e.stroke.unwrap().opacity - 1.0).abs() < 1e-9);
        } else {
            panic!("expected Line");
        }
    }

    #[test]
    fn normalize_recursive() {
        use crate::geometry::normalize::normalize_document;
        let inner = Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::new(1.0, 0.0, 0.0, 0.5), opacity: 1.0 }),
            stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let group = Element::Group(GroupElem {
            children: vec![Rc::new(inner)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        let doc = make_doc(vec![group]);
        let doc2 = normalize_document(&doc);
        let layers = doc2.layers[0].children().unwrap();
        let group_children = layers[0].children().unwrap();
        if let Element::Rect(r) = &*group_children[0] {
            let f = r.fill.unwrap();
            assert!((f.opacity - 0.5).abs() < 1e-9);
            assert!((f.color.alpha() - 1.0).abs() < 1e-9);
        } else {
            panic!("expected Rect inside group");
        }
    }

    #[test]
    fn normalize_idempotent() {
        use crate::geometry::normalize::normalize_document;
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::new(1.0, 0.0, 0.0, 0.5), opacity: 0.8 }),
            stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })]);
        let doc2 = normalize_document(&doc);
        let doc3 = normalize_document(&doc2);
        let c2 = doc2.layers[0].children().unwrap();
        let c3 = doc3.layers[0].children().unwrap();
        if let (Element::Rect(r2), Element::Rect(r3)) = (&*c2[0], &*c3[0]) {
            let f2 = r2.fill.unwrap();
            let f3 = r3.fill.unwrap();
            assert!((f2.opacity - f3.opacity).abs() < 1e-9);
            assert!((f2.color.alpha() - f3.color.alpha()).abs() < 1e-9);
        }
    }

    #[test]
    fn dash_align_anchors_roundtrips_when_true() {
        // DASH_ALIGN.md §Persistence — when true, emit
        // data-jas-dash-align-anchors="true". Reading it back must
        // produce a Stroke with dash_align_anchors = true.
        let mut stroke = Stroke::new(Color::rgb(0.0, 0.0, 0.0), 1.0);
        stroke.dash_align_anchors = true;
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 60.0, rx: 0.0, ry: 0.0,
            fill: None,
            stroke: Some(stroke),
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        })]);
        let svg = document_to_svg(&doc);
        assert!(
            svg.contains("data-jas-dash-align-anchors=\"true\""),
            "expected attr in emitted SVG, got: {svg}",
        );
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            assert_eq!(r.stroke.unwrap().dash_align_anchors, true);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn dash_align_anchors_omitted_when_false() {
        // DASH_ALIGN.md §Persistence — identity-omitted when false.
        let stroke = Stroke::new(Color::rgb(0.0, 0.0, 0.0), 1.0);
        // dash_align_anchors defaults to false from Stroke::new.
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 60.0, rx: 0.0, ry: 0.0,
            fill: None,
            stroke: Some(stroke),
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
        })]);
        let svg = document_to_svg(&doc);
        assert!(
            !svg.contains("data-jas-dash-align-anchors"),
            "attr must be omitted when false, got: {svg}",
        );
    }

    #[test]
    fn dash_align_anchors_defaults_false_on_import() {
        // Plain SVG (no jas-specific attrs) must parse to
        // dash_align_anchors=false. This is the cross-tool round-trip
        // guarantee per DASH_ALIGN.md §Persistence.
        let svg = r#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect x="0" y="0" width="100" height="60" stroke="black" stroke-width="1"/></svg>"#;
        let doc = svg_to_document(svg);
        let children = doc.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            assert_eq!(r.stroke.unwrap().dash_align_anchors, false);
        } else {
            panic!("expected Rect");
        }
    }

    #[test]
    fn arrowheads_roundtrip_on_line() {
        // ARROWFIX2 item 2 — all five arrow fields survive save->load on a line.
        let mut stroke = Stroke::new(Color::rgb(0.0, 0.0, 0.0), 2.0);
        stroke.start_arrow = Arrowhead::SimpleArrow;
        stroke.end_arrow = Arrowhead::Diamond;
        stroke.start_arrow_scale = 150.0;
        stroke.end_arrow_scale = 200.0;
        stroke.arrow_align = ArrowAlign::CenterAtEnd;
        let doc = make_doc(vec![Element::Line(LineElem {
            x1: 0.0, y1: 0.0, x2: 100.0, y2: 0.0,
            stroke: Some(stroke),
            width_points: vec![],
            common: CommonProps::default(),
            stroke_gradient: None,
        })]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("jas:start-arrow=\"simple_arrow\""), "{svg}");
        assert!(svg.contains("jas:end-arrow=\"diamond\""), "{svg}");
        assert!(svg.contains("jas:start-arrow-scale=\"150\""), "{svg}");
        assert!(svg.contains("jas:end-arrow-scale=\"200\""), "{svg}");
        assert!(svg.contains("jas:arrow-align=\"center_at_end\""), "{svg}");
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Line(l) = &*children[0] {
            let s = l.stroke.unwrap();
            assert_eq!(s.start_arrow, Arrowhead::SimpleArrow);
            assert_eq!(s.end_arrow, Arrowhead::Diamond);
            assert_eq!(s.start_arrow_scale, 150.0);
            assert_eq!(s.end_arrow_scale, 200.0);
            assert_eq!(s.arrow_align, ArrowAlign::CenterAtEnd);
        } else {
            panic!("expected Line");
        }
    }

    #[test]
    fn arrowheads_roundtrip_on_path() {
        // A one-armed arrowed path: end arrow only, default scale + align, so
        // only jas:end-arrow is emitted.
        let mut stroke = Stroke::new(Color::rgb(0.0, 0.0, 0.0), 6.6667);
        stroke.end_arrow = Arrowhead::StealthArrow;
        let doc = make_doc(vec![Element::Path(PathElem {
            d: vec![PathCommand::MoveTo { x: 0.0, y: 0.0 },
                    PathCommand::CurveTo { x1: 0.0, y1: 40.0, x2: 40.0, y2: 40.0, x: 40.0, y: 0.0 }],
            fill: None,
            stroke: Some(stroke),
            width_points: vec![],
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
            fill_rule: FillRule::default(),
            stroke_brush: None,
            stroke_brush_overrides: None,
        })]);
        let svg = document_to_svg(&doc);
        assert!(svg.contains("jas:end-arrow=\"stealth_arrow\""), "{svg}");
        // Default scale/align stay omitted even on an armed stroke.
        assert!(!svg.contains("jas:start-arrow"), "{svg}");
        assert!(!svg.contains("jas:start-arrow-scale"), "{svg}");
        assert!(!svg.contains("jas:end-arrow-scale"), "{svg}");
        assert!(!svg.contains("jas:arrow-align"), "{svg}");
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Path(p) = &*children[0] {
            let s = p.stroke.unwrap();
            assert_eq!(s.start_arrow, Arrowhead::None);
            assert_eq!(s.end_arrow, Arrowhead::StealthArrow);
            assert_eq!(s.start_arrow_scale, 100.0);
            assert_eq!(s.end_arrow_scale, 100.0);
            assert_eq!(s.arrow_align, ArrowAlign::TipAtEnd);
        } else {
            panic!("expected Path");
        }
    }

    #[test]
    fn plain_stroke_emits_no_jas_arrow_attrs() {
        // Byte-cleanliness: a stroke with no arrowheads emits none of the
        // jas:arrow attributes (clean SVG for ordinary strokes).
        let stroke = Stroke::new(Color::rgb(0.0, 0.0, 0.0), 1.0);
        let doc = make_doc(vec![Element::Line(LineElem {
            x1: 0.0, y1: 0.0, x2: 50.0, y2: 50.0,
            stroke: Some(stroke),
            width_points: vec![],
            common: CommonProps::default(),
            stroke_gradient: None,
        })]);
        let svg = document_to_svg(&doc);
        assert!(!svg.contains("jas:start-arrow"), "{svg}");
        assert!(!svg.contains("jas:end-arrow"), "{svg}");
        assert!(!svg.contains("jas:arrow-align"), "{svg}");
    }

    #[test]
    fn plain_svg_import_defaults_arrows_to_none() {
        // Cross-tool: plain SVG (no jas attrs) parses to no arrows.
        let svg = r#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><line x1="0" y1="0" x2="100" y2="0" stroke="black" stroke-width="2"/></svg>"#;
        let doc = svg_to_document(svg);
        let children = doc.layers[0].children().unwrap();
        if let Element::Line(l) = &*children[0] {
            let s = l.stroke.unwrap();
            assert_eq!(s.start_arrow, Arrowhead::None);
            assert_eq!(s.end_arrow, Arrowhead::None);
            assert_eq!(s.start_arrow_scale, 100.0);
            assert_eq!(s.end_arrow_scale, 100.0);
            assert_eq!(s.arrow_align, ArrowAlign::TipAtEnd);
        } else {
            panic!("expected Line");
        }
    }

    #[test]
    fn roundtrip_fill_opacity() {
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 10.0, y: 20.0, width: 30.0, height: 40.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill { color: Color::rgb(1.0, 0.0, 0.0), opacity: 0.5 }),
            stroke: None, common: CommonProps::default(),
                    fill_gradient: None,
            stroke_gradient: None,
        })]);
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        if let Element::Rect(r) = &*children[0] {
            assert!((r.fill.unwrap().opacity - 0.5).abs() < 0.01, "opacity={}", r.fill.unwrap().opacity);
        } else {
            panic!("expected Rect");
        }
    }

    // ── tspan rotate roundtrip ───────────────────────────────────────

    /// Build a minimal SVG string of the form produced by our writer,
    /// wrapping a single `<text>` with the given tspan children.
    fn tspan_svg_doc(tspan_markup: &str) -> String {
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><text x="0" y="20" font-size="12">{}</text></svg>"#,
            tspan_markup
        )
    }

    #[test]
    fn tspan_svg_emits_rotate_attribute() {
        use crate::geometry::tspan::Tspan;
        let t = Tspan { content: "X".into(), rotate: Some(45.0),
                        ..Tspan::default_tspan() };
        let svg = tspan_svg(&t);
        assert!(svg.contains(r#"rotate="45""#), "got: {}", svg);
    }

    #[test]
    fn svg_single_value_rotate_roundtrips() {
        let svg = tspan_svg_doc(r#"<tspan rotate="30">abc</tspan>"#);
        let doc = svg_to_document(&svg);
        let children = doc.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 1);
        assert_eq!(t.tspans[0].content, "abc");
        assert_eq!(t.tspans[0].rotate, Some(30.0));
    }

    #[test]
    fn svg_multi_value_rotate_splits_into_per_glyph_tspans() {
        // rotate="a b c" on a 3-char tspan → three tspans, each
        // carrying one glyph and its own rotate angle.
        let svg = tspan_svg_doc(r#"<tspan rotate="45 90 0">abc</tspan>"#);
        let doc = svg_to_document(&svg);
        let children = doc.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 3);
        assert_eq!(t.tspans[0].content, "a");
        assert_eq!(t.tspans[0].rotate, Some(45.0));
        assert_eq!(t.tspans[1].content, "b");
        assert_eq!(t.tspans[1].rotate, Some(90.0));
        assert_eq!(t.tspans[2].content, "c");
        assert_eq!(t.tspans[2].rotate, Some(0.0));
    }

    #[test]
    fn svg_multi_value_rotate_reuses_last_for_extra_glyphs() {
        // SVG spec: "rotate" with fewer values than glyphs reuses
        // the last value for the remainder.
        let svg = tspan_svg_doc(r#"<tspan rotate="45 90">abcd</tspan>"#);
        let doc = svg_to_document(&svg);
        let children = doc.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 4);
        assert_eq!(t.tspans[0].rotate, Some(45.0));
        assert_eq!(t.tspans[1].rotate, Some(90.0));
        assert_eq!(t.tspans[2].rotate, Some(90.0));
        assert_eq!(t.tspans[3].rotate, Some(90.0));
    }

    /// TSPAN.md specifies nested-tspan flattening on import (unimplemented
    /// in the active ports); leading-whitespace-in-tspan also diverges
    /// (Rust trims, Swift preserves) and is corpus-unexercised;
    /// implementation deferred to the Paragraph-panel phase.
    ///
    /// This probe pins CURRENT behavior, not the spec: the Rust parser
    /// reads only the direct character data of the outer <tspan> and DROPS
    /// the nested <tspan>'s content ("b"), yielding one tspan "a". Swift's
    /// mirror probe (SvgTests.swift `nestedTspanCurrentBehaviorProbe`)
    /// observes "ab" — the active ports diverge on nested-tspan input
    /// today, which is why no cross-language fixture carries one.
    #[test]
    fn nested_tspan_current_behavior_probe() {
        let svg = r#"<?xml version="1.0" encoding="UTF-8"?><svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><text y="20" font-size="10"><tspan>a<tspan>b</tspan></tspan></text></svg>"#;
        let doc = svg_to_document(svg);
        let children = doc.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 1);
        assert_eq!(
            t.tspans[0].content, "a",
            "current Rust behavior: the nested tspan's content is dropped"
        );
    }

    #[test]
    fn svg_phase1b1_attrs_round_trip_through_document() {
        // Phase 1b1: a wrapper tspan carrying the 5 remaining
        // panel-surface paragraph attrs round-trips through the
        // document SVG: text-align, text-align-last, text-indent
        // (signed), jas:space-before, jas:space-after.
        use crate::geometry::tspan::Tspan;
        let mut doc = Document::default();
        let mut t = crate::geometry::element::empty_text_elem(10.0, 20.0, 0.0, 0.0);
        let mut wrapper = Tspan::default_tspan();
        wrapper.id = 0;
        wrapper.jas_role = Some("paragraph".into());
        wrapper.text_align = Some("justify".into());
        wrapper.text_align_last = Some("left".into());
        wrapper.text_indent = Some(-18.0);
        wrapper.jas_space_before = Some(6.0);
        wrapper.jas_space_after = Some(12.0);
        t.tspans = vec![
            wrapper,
            Tspan { id: 1, content: "hello".into(), ..Tspan::default_tspan() },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        assert!(svg.contains(r#"text-align="justify""#),
                "expected text-align in serialised SVG, got: {}", svg);
        assert!(svg.contains(r#"text-align-last="left""#));
        assert!(svg.contains(r#"text-indent="-18""#));
        assert!(svg.contains(r#"urn:jas:1:space-before="6""#));
        assert!(svg.contains(r#"urn:jas:1:space-after="12""#));
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        let w = &t.tspans[0];
        assert_eq!(w.text_align.as_deref(), Some("justify"));
        assert_eq!(w.text_align_last.as_deref(), Some("left"));
        assert_eq!(w.text_indent, Some(-18.0));
        assert_eq!(w.jas_space_before, Some(6.0));
        assert_eq!(w.jas_space_after, Some(12.0));
    }

    #[test]
    fn svg_phase3b_attrs_round_trip_through_document() {
        // Phase 3b: a wrapper tspan carrying the 5 panel-surface
        // paragraph attrs round-trips through the document SVG.
        use crate::geometry::tspan::Tspan;
        let mut doc = Document::default();
        let mut t = crate::geometry::element::empty_text_elem(10.0, 20.0, 0.0, 0.0);
        let mut wrapper = Tspan::default_tspan();
        wrapper.id = 0;
        wrapper.jas_role = Some("paragraph".into());
        wrapper.jas_left_indent = Some(18.0);
        wrapper.jas_right_indent = Some(9.0);
        wrapper.jas_hyphenate = Some(true);
        wrapper.jas_hanging_punctuation = Some(true);
        wrapper.jas_list_style = Some("num-decimal".into());
        t.tspans = vec![
            wrapper,
            Tspan { id: 1, content: "hello".into(), ..Tspan::default_tspan() },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        assert!(svg.contains(r#"urn:jas:1:left-indent="18""#),
                "expected left-indent in serialised SVG, got: {}", svg);
        assert!(svg.contains(r#"urn:jas:1:right-indent="9""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate="true""#));
        assert!(svg.contains(r#"urn:jas:1:hanging-punctuation="true""#));
        assert!(svg.contains(r#"urn:jas:1:list-style="num-decimal""#));
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 2);
        let w = &t.tspans[0];
        assert_eq!(w.jas_role.as_deref(), Some("paragraph"));
        assert_eq!(w.jas_left_indent, Some(18.0));
        assert_eq!(w.jas_right_indent, Some(9.0));
        assert_eq!(w.jas_hyphenate, Some(true));
        assert_eq!(w.jas_hanging_punctuation, Some(true));
        assert_eq!(w.jas_list_style.as_deref(), Some("num-decimal"));
    }

    #[test]
    fn svg_jas_role_paragraph_roundtrips_through_document() {
        // Phase 1a: a <tspan urn:jas:1:role="paragraph"> in document SVG
        // parses with jas_role=Some("paragraph") and serialises back
        // with the role attribute preserved.
        use crate::geometry::tspan::Tspan;
        let mut doc = Document::default();
        let mut t = crate::geometry::element::empty_text_elem(10.0, 20.0, 0.0, 0.0);
        t.tspans = vec![
            Tspan {
                id: 0,
                jas_role: Some("paragraph".into()),
                ..Tspan::default_tspan()
            },
            Tspan {
                id: 1,
                content: "hello".into(),
                ..Tspan::default_tspan()
            },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        assert!(svg.contains(r#"urn:jas:1:role="paragraph""#),
                "expected urn:jas:1:role in serialised SVG, got: {}", svg);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        // The wrapper tspan and the content tspan both round-trip.
        assert_eq!(t.tspans.len(), 2);
        assert_eq!(t.tspans[0].jas_role.as_deref(), Some("paragraph"));
        assert!(t.tspans[1].jas_role.is_none());
        assert_eq!(t.tspans[1].content, "hello");
    }

    #[test]
    fn svg_per_glyph_tspan_rotate_roundtrip() {
        // Build a doc with three per-glyph tspans and verify the
        // emitted SVG preserves each rotate value (emits separate
        // <tspan rotate="N">x</tspan> elements).
        let mut doc = Document::default();
        let mut t = crate::geometry::element::empty_text_elem(10.0, 20.0, 0.0, 0.0);
        use crate::geometry::tspan::Tspan;
        t.tspans = vec![
            Tspan { id: 0, content: "a".into(), rotate: Some(45.0),
                    ..Tspan::default_tspan() },
            Tspan { id: 1, content: "b".into(), rotate: Some(90.0),
                    ..Tspan::default_tspan() },
            Tspan { id: 2, content: "c".into(), rotate: Some(0.0),
                    ..Tspan::default_tspan() },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        assert_eq!(t.tspans.len(), 3);
        assert_eq!(t.tspans[0].rotate, Some(45.0));
        assert_eq!(t.tspans[1].rotate, Some(90.0));
        assert_eq!(t.tspans[2].rotate, Some(0.0));
    }

    #[test]
    fn svg_phase8_justification_attrs_round_trip_through_document() {
        // Phase 1b2 / Phase 8: 11 Justification dialog attrs on a
        // paragraph wrapper round-trip through document SVG.
        use crate::geometry::tspan::Tspan;
        let mut doc = Document::default();
        let mut t = crate::geometry::element::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        let mut wrapper = Tspan::default_tspan();
        wrapper.id = 0;
        wrapper.jas_role = Some("paragraph".into());
        wrapper.jas_word_spacing_min = Some(75.0);
        wrapper.jas_word_spacing_desired = Some(95.0);
        wrapper.jas_word_spacing_max = Some(150.0);
        wrapper.jas_letter_spacing_min = Some(-5.0);
        wrapper.jas_letter_spacing_desired = Some(0.0);
        wrapper.jas_letter_spacing_max = Some(10.0);
        wrapper.jas_glyph_scaling_min = Some(95.0);
        wrapper.jas_glyph_scaling_desired = Some(100.0);
        wrapper.jas_glyph_scaling_max = Some(105.0);
        wrapper.jas_auto_leading = Some(140.0);
        wrapper.jas_single_word_justify = Some("left".into());
        t.tspans = vec![
            wrapper,
            Tspan { id: 1, content: "x".into(), ..Tspan::default_tspan() },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        // Spot-check a few attributes appear with the urn:jas:1: prefix.
        assert!(svg.contains(r#"urn:jas:1:word-spacing-min="75""#));
        assert!(svg.contains(r#"urn:jas:1:letter-spacing-desired="0""#));
        assert!(svg.contains(r#"urn:jas:1:glyph-scaling-max="105""#));
        assert!(svg.contains(r#"urn:jas:1:auto-leading="140""#));
        assert!(svg.contains(r#"urn:jas:1:single-word-justify="left""#));
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        let w = &t.tspans[0];
        assert_eq!(w.jas_word_spacing_min, Some(75.0));
        assert_eq!(w.jas_word_spacing_desired, Some(95.0));
        assert_eq!(w.jas_word_spacing_max, Some(150.0));
        assert_eq!(w.jas_letter_spacing_min, Some(-5.0));
        assert_eq!(w.jas_letter_spacing_desired, Some(0.0));
        assert_eq!(w.jas_letter_spacing_max, Some(10.0));
        assert_eq!(w.jas_glyph_scaling_min, Some(95.0));
        assert_eq!(w.jas_glyph_scaling_desired, Some(100.0));
        assert_eq!(w.jas_glyph_scaling_max, Some(105.0));
        assert_eq!(w.jas_auto_leading, Some(140.0));
        assert_eq!(w.jas_single_word_justify.as_deref(), Some("left"));
    }

    #[test]
    fn svg_phase9_hyphenation_attrs_round_trip_through_document() {
        // Phase 1b3 / Phase 9: 7 Hyphenation dialog attrs on a
        // paragraph wrapper round-trip through document SVG.
        use crate::geometry::tspan::Tspan;
        let mut doc = Document::default();
        let mut t = crate::geometry::element::empty_text_elem(0.0, 0.0, 0.0, 0.0);
        let mut wrapper = Tspan::default_tspan();
        wrapper.id = 0;
        wrapper.jas_role = Some("paragraph".into());
        wrapper.jas_hyphenate_min_word = Some(6.0);
        wrapper.jas_hyphenate_min_before = Some(3.0);
        wrapper.jas_hyphenate_min_after = Some(2.0);
        wrapper.jas_hyphenate_limit = Some(2.0);
        wrapper.jas_hyphenate_zone = Some(36.0);
        wrapper.jas_hyphenate_bias = Some(0.5);
        wrapper.jas_hyphenate_capitalized = Some(true);
        t.tspans = vec![
            wrapper,
            Tspan { id: 1, content: "x".into(), ..Tspan::default_tspan() },
        ];
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Text(t)));
        let svg = document_to_svg(&doc);
        assert!(svg.contains(r#"urn:jas:1:hyphenate-min-word="6""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-min-before="3""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-min-after="2""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-limit="2""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-zone="36""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-bias="0.5""#));
        assert!(svg.contains(r#"urn:jas:1:hyphenate-capitalized="true""#));
        let doc2 = svg_to_document(&svg);
        let children = doc2.layers[0].children().unwrap();
        let Element::Text(t) = &*children[0] else { panic!("expected Text"); };
        let w = &t.tspans[0];
        assert_eq!(w.jas_hyphenate_min_word, Some(6.0));
        assert_eq!(w.jas_hyphenate_min_before, Some(3.0));
        assert_eq!(w.jas_hyphenate_min_after, Some(2.0));
        assert_eq!(w.jas_hyphenate_limit, Some(2.0));
        assert_eq!(w.jas_hyphenate_zone, Some(36.0));
        assert_eq!(w.jas_hyphenate_bias, Some(0.5));
        assert_eq!(w.jas_hyphenate_capitalized, Some(true));
    }

    #[test]
    fn common_name_round_trips_through_svg() {
        // Element name persists through document_to_svg →
        // svg_to_document. Tests Group + Rect to cover both the
        // open/close container writer and the self-closing shape
        // writer paths.
        use crate::geometry::element::{
            CommonProps, GroupElem, RectElem, Color, Fill,
        };
        let mut rect = RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        };
        rect.common.name = Some("My Rect".into());
        let mut group = GroupElem {
            children: vec![std::rc::Rc::new(Element::Rect(rect))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        };
        group.common.name = Some("My Group".into());
        let mut doc = Document::default();
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Group(group)));
        let svg = document_to_svg(&doc);
        assert!(
            svg.contains(r#"inkscape:label="My Rect""#),
            "rect inkscape:label not in SVG: {svg}",
        );
        assert!(
            svg.contains(r#"inkscape:label="My Group""#),
            "group inkscape:label not in SVG: {svg}",
        );
        let parsed = svg_to_document(&svg);
        // Layer 0 → Group → Rect.
        let group_elem = parsed.layers[0].children().unwrap()[0].as_ref();
        assert_eq!(
            group_elem.common().name.as_deref(),
            Some("My Group"),
            "round-trip lost group name",
        );
        let rect_elem = group_elem.children().unwrap()[0].as_ref();
        assert_eq!(
            rect_elem.common().name.as_deref(),
            Some("My Rect"),
            "round-trip lost rect name",
        );
    }

    #[test]
    fn common_id_round_trips_through_svg() {
        // Element id (stable identity) persists through
        // document_to_svg → svg_to_document for every element kind whose
        // SVG writer hand-inlines its attributes: Group + Rect (the
        // open/close container and self-closing shape paths) AND the text
        // family (Text/TextPath), whose writers historically omitted id.
        // The Text case also carries a transform to pin the sibling fix —
        // the Text writer previously dropped `transform` as well.
        use crate::geometry::element::{
            CommonProps, GroupElem, RectElem, TextElem, TextPathElem,
            Color, Fill, Transform, PathCommand,
        };
        let mut rect = RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        };
        rect.common.id = Some("rect-1".into());
        let mut group = GroupElem {
            children: vec![std::rc::Rc::new(Element::Rect(rect))],
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        };
        group.common.id = Some("group-1".into());

        let mut text = TextElem::from_string(
            10.0, 20.0, "Hi", "sans-serif", 16.0,
            "normal", "normal", "none", 0.0, 0.0,
            Some(Fill::new(Color::BLACK)), None, CommonProps::default(),
        );
        text.common.id = Some("text-1".into());
        text.common.transform = Some(Transform::translate(5.0, 7.0));

        let mut text_path = TextPathElem::from_string(
            vec![
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 50.0, y: 0.0 },
            ],
            "Hi", 0.0, "sans-serif", 16.0,
            "normal", "normal", "none",
            Some(Fill::new(Color::BLACK)), None, CommonProps::default(),
        );
        text_path.common.id = Some("textpath-1".into());

        let mut doc = Document::default();
        {
            let kids = doc.layers[0].children_mut().unwrap();
            kids.push(std::rc::Rc::new(Element::Group(group)));
            kids.push(std::rc::Rc::new(Element::Text(text)));
            kids.push(std::rc::Rc::new(Element::TextPath(text_path)));
        }
        let svg = document_to_svg(&doc);
        for id in ["rect-1", "group-1", "text-1", "textpath-1"] {
            assert!(
                svg.contains(&format!("id=\"{id}\"")),
                "id {id} not in SVG: {svg}",
            );
        }
        let parsed = svg_to_document(&svg);
        // Layer 0 → [Group → Rect, Text, TextPath].
        let kids = parsed.layers[0].children().unwrap();
        let group_elem = kids[0].as_ref();
        assert_eq!(
            group_elem.common().id.as_deref(),
            Some("group-1"),
            "round-trip lost group id",
        );
        let rect_elem = group_elem.children().unwrap()[0].as_ref();
        assert_eq!(
            rect_elem.common().id.as_deref(),
            Some("rect-1"),
            "round-trip lost rect id",
        );
        let text_elem = kids[1].as_ref();
        assert_eq!(
            text_elem.common().id.as_deref(),
            Some("text-1"),
            "round-trip lost text id",
        );
        assert!(
            text_elem.common().transform.is_some(),
            "round-trip lost text transform",
        );
        let tp_elem = kids[2].as_ref();
        assert_eq!(
            tp_elem.common().id.as_deref(),
            Some("textpath-1"),
            "round-trip lost textPath id",
        );
    }

    #[test]
    fn import_dedupes_duplicate_ids() {
        // Foreign input can carry duplicate ids (SVG requires unique ids
        // but the world doesn't enforce it). Import normalizes to the
        // unique-id invariant: first occurrence in pre-order keeps the id,
        // later duplicates are cleared. See REFERENCE_GRAPH.md §2.5.
        let svg = r#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" viewBox="0 0 192 96"><g inkscape:groupmode="layer" inkscape:label="Layer 1"><rect x="0" y="0" width="96" height="96" fill="rgb(255,0,0)" stroke="none" id="dup"/><rect x="96" y="0" width="96" height="96" fill="rgb(0,0,255)" stroke="none" id="dup"/></g></svg>"#;
        let doc = svg_to_document(svg);
        let kids = doc.layers[0].children().unwrap();
        assert_eq!(
            kids[0].common().id.as_deref(),
            Some("dup"),
            "first pre-order occurrence keeps its id",
        );
        assert_eq!(
            kids[1].common().id,
            None,
            "later duplicate id is cleared",
        );
    }

    #[test]
    fn live_reference_and_compound_round_trip_through_svg() {
        // Phase 2 SVG codec: a reference emits/parses as <use href="#id"> and
        // a compound emits/parses as <g data-jas-live="compound_shape"
        // data-jas-operation=...> — both round-trip (the compound previously
        // demoted to a plain Group and lost its operation).
        use crate::geometry::live::{
            LiveVariant, CompoundShape, CompoundOperation, ReferenceElem, ElementRef,
        };
        use crate::geometry::element::{RectElem, CommonProps, Color, Fill};
        let rect_at = |x: f64| RectElem {
            x, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(), fill_gradient: None, stroke_gradient: None,
        };
        let mut target = rect_at(0.0);
        target.common.id = Some("r1".into());
        let mut reference = ReferenceElem::new(ElementRef("r1".into()), CommonProps::default());
        reference.common.id = Some("ref1".into());
        let compound = CompoundShape {
            operation: CompoundOperation::SubtractFront,
            operands: vec![
                std::rc::Rc::new(Element::Rect(rect_at(0.0))),
                std::rc::Rc::new(Element::Rect(rect_at(5.0))),
            ],
            fill: None, stroke: None, common: CommonProps::default(),
        };
        let mut doc = Document::default();
        doc.artboards.clear();
        {
            let kids = doc.layers[0].children_mut().unwrap();
            kids.push(std::rc::Rc::new(Element::Rect(target)));
            kids.push(std::rc::Rc::new(Element::Live(LiveVariant::Reference(reference))));
            kids.push(std::rc::Rc::new(Element::Live(LiveVariant::CompoundShape(compound))));
        }
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<use href=\"#r1\""), "reference -> <use href: {svg}");
        assert!(svg.contains("data-jas-operation=\"subtract_front\""),
            "compound emits its operation: {svg}");
        let parsed = svg_to_document(&svg);
        let kids = parsed.layers[0].children().unwrap();
        match kids[1].as_ref() {
            Element::Live(LiveVariant::Reference(r)) => {
                assert_eq!(r.target.0, "r1");
                assert_eq!(r.common.id.as_deref(), Some("ref1"), "reference id round-trips");
            }
            other => panic!("expected a Reference, got {other:?}"),
        }
        match kids[2].as_ref() {
            Element::Live(LiveVariant::CompoundShape(cs)) => {
                assert_eq!(cs.operation, CompoundOperation::SubtractFront);
                assert_eq!(cs.operands.len(), 2);
            }
            other => panic!("expected a CompoundShape, got {other:?}"),
        }
    }

    #[test]
    fn idless_element_emits_no_id_attr() {
        // An element with no id (the default) must not emit an `id`
        // attribute — this is what keeps id-less SVG byte-identical to
        // the pre-id output and the existing fixtures green.
        use crate::geometry::element::{CommonProps, RectElem, Color, Fill};
        let rect = RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::BLACK)), stroke: None,
            common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        };
        assert!(rect.common.id.is_none());
        let mut doc = Document::default();
        // Clear artboards so no <sodipodi:namedview>/<inkscape:page> is
        // emitted — those carry their own (page) `id` attributes that
        // are unrelated to element identity and must not be touched.
        doc.artboards.clear();
        doc.layers[0].children_mut().unwrap()
            .push(std::rc::Rc::new(Element::Rect(rect)));
        let svg = document_to_svg(&doc);
        assert!(
            !svg.contains(" id=\""),
            "id-less document must not emit an id attribute: {svg}",
        );
    }

    // -----------------------------------------------------------------------
    // DocumentSetup + PrintPreferences persistence under sodipodi:namedview
    // (PRINT.md §Phase 2). Stored as <jas:document-setup> /
    // <jas:print-preferences> elements so Inkscape and other SVG tools
    // treat them as foreign metadata and round-trip them unchanged.
    // -----------------------------------------------------------------------

    #[test]
    fn empty_document_emits_no_jas_blocks() {
        // A pristine Document (default DocumentSetup, default
        // PrintPreferences) must not produce any <jas:*> metadata —
        // keeps minimal SVG files minimal. Artboards are cleared so
        // no namedview is emitted at all.
        let mut doc = Document::default();
        doc.artboards.clear();
        let svg = document_to_svg(&doc);
        assert!(!svg.contains("<jas:document-setup"), "svg:\n{svg}");
        assert!(!svg.contains("<jas:print-preferences"), "svg:\n{svg}");
        assert!(!svg.contains("<sodipodi:namedview"), "svg:\n{svg}");
    }

    #[test]
    fn non_default_document_setup_round_trips() {
        use crate::document::document_setup::DocumentSetup;
        let mut doc = Document::default();
        doc.document_setup = DocumentSetup {
            bleed_top: 9.0, bleed_right: 18.0,
            bleed_bottom: 36.0, bleed_left: 12.0,
            bleed_uniform: false,
            show_images_outline: true,
            highlight_substituted_glyphs: true,
            ..DocumentSetup::default()
        };
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<jas:document-setup"),
                "missing jas:document-setup:\n{svg}");
        assert!(svg.contains("xmlns:jas="),
                "missing jas namespace decl:\n{svg}");

        let parsed = svg_to_document(&svg);
        assert_eq!(parsed.document_setup, doc.document_setup);
    }

    #[test]
    fn non_default_print_preferences_round_trip() {
        use crate::document::print_preferences::*;
        let mut doc = Document::default();
        doc.print_preferences = PrintPreferences {
            preset_name: "My Preset".into(),
            printer_name: Some("LaserJet 5000".into()),
            copies: 3,
            collate: true,
            reverse_order: true,
            artboard_range_mode: ArtboardRangeMode::Range,
            artboard_range: "1-3,5".into(),
            ignore_artboards: true,
            skip_blank_artboards: true,
            media_size: MediaSize::A4,
            media_width: 595.0,
            media_height: 842.0,
            orientation: Orientation::Landscape,
            auto_rotate: false,
            transverse: true,
            print_layers: PrintLayers::Visible,
            placement_x: 12.5,
            placement_y: -3.25,
            scaling_mode: ScalingMode::Custom,
            custom_scale: 75.0,
            tile_overlap_h: 1.0,
            tile_overlap_v: 2.0,
            tile_range: "1-2".into(),
            marks_and_bleed: MarksAndBleed {
                all_printer_marks: true,
                trim_marks: true,
                registration_marks: true,
                color_bars: true,
                page_information: true,
                printer_mark_type: PrinterMarkType::Japanese,
                trim_mark_weight: 0.5,
                mark_offset: 12.0,
                use_document_bleed: false,
                bleed_top: 4.0, bleed_right: 5.0,
                bleed_bottom: 6.0, bleed_left: 7.0,
            },
            output: Output::default(),
            graphics: Graphics::default(),
            color_management: ColorManagement::default(),
            advanced: Advanced::default(),
        };
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<jas:print-preferences"),
                "missing jas:print-preferences:\n{svg}");
        assert!(svg.contains("<jas:marks-and-bleed"),
                "missing jas:marks-and-bleed:\n{svg}");

        let parsed = svg_to_document(&svg);
        assert_eq!(parsed.print_preferences, doc.print_preferences);
    }

    #[test]
    fn output_sub_record_round_trips_through_svg() {
        use crate::document::print_preferences::*;
        let mut doc = Document::default();
        doc.print_preferences.output = Output {
            mode: OutputMode::Separations,
            emulsion: Emulsion::DownRight,
            image_polarity: ImagePolarity::Negative,
            printer_resolution: "150 lpi / 1200 dpi".to_string(),
            convert_spot_to_process: true,
            overprint_black: true,
            inks: vec![
                InkOverride { name: "Process Cyan".into(),    print: false, frequency: 100.0, angle: 105.0, dot_shape: DotShape::Ellipse },
                InkOverride { name: "PANTONE 185 C".into(),   print: true,  frequency:  85.0, angle:  45.0, dot_shape: DotShape::Square },
            ],
        };
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<jas:output"), "svg:\n{svg}");
        assert!(svg.contains("<jas:ink"), "svg:\n{svg}");
        assert!(svg.contains("PANTONE 185 C"), "spot ink missing:\n{svg}");
        let parsed = svg_to_document(&svg);
        assert_eq!(parsed.print_preferences.output, doc.print_preferences.output);
    }

    #[test]
    fn advanced_sub_record_round_trips_through_svg() {
        use crate::document::print_preferences::*;
        let mut doc = Document::default();
        doc.print_preferences.advanced = Advanced {
            print_as_bitmap: true,
            overprint_flattener_preset: FlattenerPreset::HighResolution,
        };
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<jas:advanced"), "svg:\n{svg}");
        assert!(svg.contains("print-as-bitmap=\"true\""), "svg:\n{svg}");
        assert!(svg.contains("overprint-flattener-preset=\"high_resolution\""),
                "svg:\n{svg}");
        let parsed = svg_to_document(&svg);
        assert_eq!(parsed.print_preferences.advanced, doc.print_preferences.advanced);
    }

    #[test]
    fn document_setup_phase6_fields_round_trip_through_svg() {
        use crate::document::document_setup::DocumentSetup;
        use crate::document::print_preferences::FlattenerPreset;
        let mut doc = Document::default();
        doc.document_setup = DocumentSetup {
            grid_size: 36.0,
            grid_color: "#0099ff".to_string(),
            paper_color: "#fff8e7".to_string(),
            simulate_colored_paper: true,
            transparency_flattener_preset: FlattenerPreset::HighResolution,
            discard_white_overprint: true,
            ..DocumentSetup::default()
        };
        let svg = document_to_svg(&doc);
        assert!(svg.contains("grid-size=\"36\""), "svg:\n{svg}");
        assert!(svg.contains("paper-color=\"#fff8e7\""), "svg:\n{svg}");
        assert!(svg.contains("simulate-colored-paper=\"true\""), "svg:\n{svg}");
        assert!(svg.contains("transparency-flattener-preset=\"high_resolution\""),
                "svg:\n{svg}");
        let parsed = svg_to_document(&svg);
        assert_eq!(parsed.document_setup, doc.document_setup);
    }

    #[test]
    fn color_management_sub_record_round_trips_through_svg() {
        use crate::document::print_preferences::*;
        let mut doc = Document::default();
        doc.print_preferences.color_management = ColorManagement {
            document_profile: "sRGB IEC61966-2.1".to_string(),
            color_handling: ColorHandling::PostscriptColorManagement,
            printer_profile: "U.S. Web Coated (SWOP) v2".to_string(),
            rendering_intent: RenderingIntent::Saturation,
            preserve_rgb_numbers: true,
        };
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<jas:color-management"), "svg:\n{svg}");
        assert!(svg.contains("color-handling=\"postscript_color_management\""), "svg:\n{svg}");
        assert!(svg.contains("rendering-intent=\"saturation\""), "svg:\n{svg}");
        assert!(svg.contains("sRGB IEC61966-2.1"), "svg:\n{svg}");
        let parsed = svg_to_document(&svg);
        assert_eq!(parsed.print_preferences.color_management,
                   doc.print_preferences.color_management);
    }

    #[test]
    fn graphics_sub_record_round_trips_through_svg() {
        use crate::document::print_preferences::*;
        let mut doc = Document::default();
        doc.print_preferences.graphics = Graphics {
            flatness: 0.4,
            font_download: FontDownload::Complete,
            postscript_level: PostScriptLevel::Level2,
            data_format: DataFormat::Ascii,
            compatible_gradient_printing: true,
            raster_effects_resolution: 600.0,
        };
        let svg = document_to_svg(&doc);
        assert!(svg.contains("<jas:graphics"), "svg:\n{svg}");
        assert!(svg.contains("flatness=\"0.4\""), "svg:\n{svg}");
        assert!(svg.contains("font-download=\"complete\""), "svg:\n{svg}");
        let parsed = svg_to_document(&svg);
        assert_eq!(parsed.print_preferences.graphics, doc.print_preferences.graphics);
    }

    #[test]
    fn jas_blocks_coexist_with_artboards() {
        use crate::document::artboard::{Artboard, ArtboardFill};
        use crate::document::document_setup::DocumentSetup;
        let mut doc = Document::default();
        doc.artboards = vec![Artboard {
            id: "ab-a".into(), name: "Cover".into(),
            x: 0.0, y: 0.0, width: 612.0, height: 792.0,
            fill: ArtboardFill::Transparent,
            show_center_mark: false, show_cross_hairs: false,
            show_video_safe_areas: false,
            video_ruler_pixel_aspect_ratio: 1.0,
        }];
        doc.document_setup = DocumentSetup {
            bleed_top: 9.0, bleed_right: 9.0,
            bleed_bottom: 9.0, bleed_left: 9.0,
            bleed_uniform: true,
            show_images_outline: false,
            highlight_substituted_glyphs: false,
            ..DocumentSetup::default()
        };
        let svg = document_to_svg(&doc);
        // Both metadata blocks live inside the same namedview.
        assert!(svg.contains("<sodipodi:namedview"));
        assert!(svg.contains("<inkscape:page"));
        assert!(svg.contains("<jas:document-setup"));

        let parsed = svg_to_document(&svg);
        assert_eq!(parsed.artboards.len(), 1);
        assert_eq!(parsed.document_setup, doc.document_setup);
    }

    // -------------------------------------------------------------------
    // MATRIX ENTRY PRECISION (R2, ruled 2026-07-31)
    //
    // These tests measure the PROPERTY — that a matrix which leaves the
    // writer and comes back is still the SAME LINEAR MAP — not the
    // spelling that achieves it. The spelling is pinned separately, and
    // only because it is a cross-port contract; if a future edit finds a
    // better spelling, only those tests should have to move.
    // -------------------------------------------------------------------

    /// One save-and-reopen for an element-level transform: doc → svg → doc.
    /// Returns the matrix as the reopened document sees it.
    fn reopen(t: Transform) -> Transform {
        let doc = make_doc(vec![Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 50.0, rx: 0.0, ry: 0.0,
            fill: Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),
            stroke: None,
            common: CommonProps { transform: Some(t), ..Default::default() },
            fill_gradient: None,
            stroke_gradient: None,
        })]);
        let reopened = svg_to_document(&document_to_svg(&doc));
        let children = reopened.layers[0].children().unwrap();
        children[0]
            .common()
            .transform
            .expect("the SVG round trip dropped the transform entirely")
    }

    /// A rotation matrix is ORTHONORMAL: `a² + b² == 1`, to within the
    /// ulp or two that `cos`/`sin` themselves cost. Quantising the
    /// multipliers destroys that — at 4dp cos30 lands on `0.866`, the
    /// reopened map shrinks by 2.2e-5 and carries a shear it never had.
    ///
    /// Fuzzed over the whole circle rather than pinned at 30°: a rule
    /// about a MULTIPLIER has no lucky angles the way `DYADICSIDE`'s
    /// round trip had lucky zooms, but a single vector would still leave
    /// a future edit free to be right in one place and wrong everywhere.
    #[test]
    fn rotation_stays_orthonormal_across_a_save_and_reopen() {
        const TOL: f64 = 4.0 * f64::EPSILON;
        let mut worst_deg = 0.0f64;
        let mut worst_err = 0.0f64;
        for deg in 0..360 {
            let angle = deg as f64;
            let m = reopen(Transform::rotate(angle));
            let err = (m.a * m.a + m.b * m.b - 1.0).abs();
            if err > worst_err {
                worst_err = err;
                worst_deg = angle;
            }
        }
        assert!(
            worst_err <= TOL,
            "a reopened rotation is no longer orthonormal: worst |a²+b²-1| = {:e} \
             at {}°, tolerance {:e}",
            worst_err, worst_deg, TOL
        );
    }

    /// The four MULTIPLIERS survive a save-and-reopen BIT-EXACTLY.
    ///
    /// They can, and so they must: `a`/`b`/`c`/`d` are unitless, so unlike
    /// `e`/`f` they never pass through the pt↔px conversion, and nothing
    /// but the writer's own precision stands between the value that was
    /// saved and the value that comes back.
    #[test]
    fn matrix_multipliers_survive_a_save_and_reopen_bit_exactly() {
        for deg in 0..360 {
            let t = Transform::rotate(deg as f64);
            let m = reopen(t);
            for (name, got, want) in [
                ("a", m.a, t.a), ("b", m.b, t.b),
                ("c", m.c, t.c), ("d", m.d, t.d),
            ] {
                assert_eq!(
                    got.to_bits(), want.to_bits(),
                    "rotate({deg}°) came back with {name} = {got}, saved {want}"
                );
            }
        }
    }

    /// Once reopened, a matrix is a FIXPOINT: saving and reopening it
    /// again changes not one bit of any of the SIX entries.
    ///
    /// This is the property that keeps drift from COMPOUNDING across
    /// sessions, and it is stated over all six deliberately. `e`/`f` are
    /// positions and stay at 4dp, so they are NOT expected to survive the
    /// first save unchanged — they are expected to SETTLE on it, and then
    /// never move again however many times the file is opened.
    #[test]
    fn a_reopened_matrix_is_bit_identical_on_every_later_save_and_reopen() {
        for deg in 0..360 {
            for (tx, ty) in [(0.0, 0.0), (12.3456789, -98.7654321), (0.00001, 5000.25)] {
                let t = Transform { e: tx, f: ty, ..Transform::rotate(deg as f64) };
                let m1 = reopen(t);
                let m2 = reopen(m1);
                for (name, got, want) in [
                    ("a", m2.a, m1.a), ("b", m2.b, m1.b),
                    ("c", m2.c, m1.c), ("d", m2.d, m1.d),
                    ("e", m2.e, m1.e), ("f", m2.f, m1.f),
                ] {
                    assert_eq!(
                        got.to_bits(), want.to_bits(),
                        "rotate({deg}°)+translate({tx},{ty}) is not a fixpoint: \
                         {name} moved from {want} to {got} on the second reopen"
                    );
                }
            }
        }
    }

    /// THE ARTIST SYMPTOM: rotate a logo, save, reopen, rotate BACK.
    /// It must land on its guides — the composition must be the identity,
    /// not a 0.99998 scale with a shear in it.
    #[test]
    fn rotating_back_after_a_save_and_reopen_lands_on_the_identity() {
        const TOL: f64 = 4.0 * f64::EPSILON;
        for deg in 0..720 {
            let angle = deg as f64 * 0.5;
            let there = reopen(Transform::rotate(angle));
            let back = Transform::rotate(-angle).multiply(&there);
            for (name, got, want) in [
                ("a", back.a, 1.0), ("b", back.b, 0.0),
                ("c", back.c, 0.0), ("d", back.d, 1.0),
            ] {
                assert!(
                    (got - want).abs() <= TOL,
                    "rotate({angle}°), save, reopen, rotate(-{angle}°) did not \
                     return to the identity: {name} = {got}, expected {want}"
                );
            }
        }
    }

    /// And the error does not merely persist, it COMPOUNDS. Each new
    /// transform composes onto the reloaded one (`op_apply.rs`,
    /// `matrix.multiply(&current)`), so a per-save error in the
    /// multipliers is re-multiplied on every subsequent edit.
    ///
    /// SEVERAL ANGLES, AND ORTHONORMALITY CHECKED AT EVERY CYCLE, because
    /// a single angle can be lucky in a way that hides the whole defect:
    /// 15° at 4dp is a PERIODIC orbit — `(0.9659, 0.2588)` and its
    /// rotations are each other's quantised images, so after 24 cycles it
    /// lands back on an exact `(1, 0)` and the accumulated drift cancels
    /// to nothing. Written that way first, this test passed against the
    /// unfixed writer.
    #[test]
    fn repeated_save_and_reopen_cycles_do_not_accumulate_scale_drift() {
        // 64 ulp: 24 chained `multiply` calls cost ~12 ulp of their own
        // even with a perfect writer (measured), and the defect this
        // guards against is 3e-5 to 6e-4 — nine orders of magnitude away.
        const TOL: f64 = 64.0 * f64::EPSILON;
        for step_deg in [7.0, 15.0, 30.0, 41.3, 0.5, 123.456] {
            let mut m = Transform::IDENTITY;
            for cycle in 1..=24 {
                m = reopen(Transform::rotate(step_deg).multiply(&m));
                let err = (m.a * m.a + m.b * m.b - 1.0).abs();
                assert!(
                    err <= TOL,
                    "after {cycle} rotate({step_deg}°)/save/reopen cycles the \
                     element is scaled by {}: |a²+b²-1| = {err:e}, tolerance {TOL:e}",
                    (m.a * m.a + m.b * m.b).sqrt()
                );
            }
        }
    }

    // -------------------------------------------------------------------
    // THE SPELLING RULE ITSELF. Pinned separately from the properties
    // above, and pinned at all only because it is a CROSS-PORT CONTRACT:
    // JasSwift must emit the same bytes for the same f64. Each of the four
    // clauses of the rule in `fmt_matrix_entry`'s doc comment gets a test.
    // -------------------------------------------------------------------

    /// Clause 1: no exponent notation, at any magnitude. A bare Swift
    /// `.description` would spell `1e-5` as `1e-05`, agreeing on the value
    /// and disagreeing on the bytes.
    #[test]
    fn matrix_entry_spelling_never_uses_exponent_notation() {
        for v in [
            1e-5, 1.5e-7, -3e-9, 1e20, 2.5e18, 1e16, -1e17,
            f64::MIN_POSITIVE, f64::MAX, 5e-324,
        ] {
            let s = fmt_matrix_entry(v);
            assert!(
                !s.contains('e') && !s.contains('E'),
                "{v:?} was spelled {s}, which is exponent notation"
            );
        }
    }

    /// Clauses 2 and 3: exactly one decimal point, always present, with a
    /// fraction that is never empty and never has a strippable trailing
    /// zero. A bare Rust `Display` would spell `1.0` as `1`.
    #[test]
    fn matrix_entry_spelling_always_has_exactly_one_point_and_no_padding() {
        for v in [
            0.0, -0.0, 1.0, -2.0, 0.5, 100.0, 1e20, 1e-5,
            0.8660254037844387, 0.25881904510252074, -0.5,
        ] {
            let s = fmt_matrix_entry(v);
            assert_eq!(s.matches('.').count(), 1, "{v:?} was spelled {s}");
            let frac = s.split('.').nth(1).unwrap();
            assert!(!frac.is_empty(), "{v:?} was spelled {s} with an empty fraction");
            assert!(
                frac == "0" || !frac.ends_with('0'),
                "{v:?} was spelled {s} with an unstripped trailing zero"
            );
        }
    }

    /// Clause 4: negative zero keeps its sign — a naive `{}` gives `-0`,
    /// and 4dp `fmt` gives `-0`; the rule gives `-0.0`, and both spellings
    /// must still READ BACK as negative zero.
    #[test]
    fn matrix_entry_spelling_preserves_negative_zero() {
        assert_eq!(fmt_matrix_entry(0.0), "0.0");
        assert_eq!(fmt_matrix_entry(-0.0), "-0.0");
        assert!(
            fmt_matrix_entry(-0.0).parse::<f64>().unwrap().is_sign_negative(),
            "a reopened -0.0 lost its sign"
        );
        assert!(fmt_matrix_entry(0.0).parse::<f64>().unwrap().is_sign_positive());
    }

    /// The reason the whole rule exists: what is printed reads back as the
    /// same f64, BIT FOR BIT. Fuzzed over raw bit patterns rather than a
    /// pretty range, because the hard cases are the ones nobody would
    /// think to type — subnormals, values near a binade edge, 17-digit
    /// mantissas. A fixed `{:.17}` fails this, mis-rounding by one ulp.
    #[test]
    fn matrix_entry_spelling_round_trips_bit_exactly() {
        // xorshift64, seeded from the digits of pi — deterministic, so a
        // failure is reproducible rather than a once-a-month mystery.
        let mut state: u64 = 0x243F_6A88_85A3_08D3;
        let mut checked = 0u32;
        let fixed = [
            0.0f64, -0.0, 1.0, -1.0, 0.8660254037844387, 0.5,
            1.0 / 3.0, f64::MIN_POSITIVE, 5e-324, f64::MAX, -f64::MAX,
        ];
        for i in 0..200_000u32 {
            let v = if (i as usize) < fixed.len() {
                fixed[i as usize]
            } else {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                f64::from_bits(state)
            };
            if !v.is_finite() {
                continue;
            }
            let s = fmt_matrix_entry(v);
            let back: f64 = s.parse().unwrap_or_else(|e| {
                panic!("{v:?} was spelled {s}, which does not parse as f64: {e}")
            });
            assert_eq!(
                back.to_bits(), v.to_bits(),
                "{v:?} was spelled {s}, which reads back as {back:?}"
            );
            checked += 1;
        }
        assert!(checked > 100_000, "the fuzz only reached {checked} finite samples");
    }

    /// THE SHARED VECTOR TABLE — the literal bytes, so the two ports can be
    /// DIFFED and not merely both described as "shortest round-trip". Mirror
    /// this table verbatim in JasSwift's `SvgTests`.
    ///
    /// Every entry is in the range a real matrix multiplier occupies. That
    /// is on purpose: a rotation, scale or shear entry lives within a few
    /// orders of 1, and "shortest round-trip" is only unambiguous there.
    /// FOR ABSURD MAGNITUDES THE TWO PORTS' SPELLINGS ARE NOT KNOWN TO
    /// AGREE — measured, over 400k random bit patterns, against a
    /// simulation of JasSwift's shortest-`%.Nf` search: zero disagreements
    /// below |v| = 1e9, the first at |v| ≈ 7.2e11 (`-722043421803.1563`
    /// here, `-722043421803.1562` there — both reparse to the same f64),
    /// and pervasive above 1e18, where "fewest DECIMAL PLACES that
    /// round-trips" and "fewest SIGNIFICANT DIGITS that round-trips" stop
    /// being the same function. A multiplier that large is a degenerate
    /// matrix, so this table does not pretend to settle it; the band is
    /// named here so that whoever needs it settled can find it.
    #[test]
    fn matrix_entry_spelling_matches_the_shared_vector_table() {
        for (v, want) in [
            (0.0f64, "0.0"),
            (-0.0, "-0.0"),
            (1.0, "1.0"),
            (-1.0, "-1.0"),
            (2.0, "2.0"),
            (0.5, "0.5"),
            (-0.5, "-0.5"),
            (0.7071, "0.7071"),
            // cos/sin of 30°, 15° and 45° — the multipliers this rule exists for.
            (0.8660254037844387, "0.8660254037844387"),
            (0.49999999999999994, "0.49999999999999994"),
            (0.9659258262890683, "0.9659258262890683"),
            (0.25881904510252074, "0.25881904510252074"),
            (0.7071067811865476, "0.7071067811865476"),
            (-0.7071067811865475, "-0.7071067811865475"),
            (1.0 / 3.0, "0.3333333333333333"),
            // Below Swift's exponent-notation floor of 1e-4, where a bare
            // `.description` would say `1e-05`.
            (0.00001, "0.00001"),
            (0.000015, "0.000015"),
            (-0.0000001, "-0.0000001"),
            // At and above Swift's exponent-notation ceiling of 1e16.
            (10000000000000000.0, "10000000000000000.0"),
            (100000000000000000000.0, "100000000000000000000.0"),
        ] {
            assert_eq!(
                fmt_matrix_entry(v), want,
                "shared vector table: {v:?} must be spelled {want}"
            );
        }
    }

    /// The rule reaches the SYMBOLS instance matrix too, not just the
    /// standard `transform` attribute — one `matrix_value` writer, so the
    /// two cannot drift apart.
    #[test]
    fn both_matrix_writers_use_the_full_precision_spelling() {
        let t = Transform::rotate(30.0);
        assert!(
            transform_attr(&Some(t)).contains("0.8660254037844387"),
            "transform attr: {}", transform_attr(&Some(t))
        );
        let doc = make_doc(vec![Element::Live(
            crate::geometry::live::LiveVariant::Reference(
                crate::geometry::live::ReferenceElem {
                    transform: Some(t),
                    ..crate::geometry::live::ReferenceElem::new(
                        crate::geometry::live::ElementRef("r1".to_string()),
                        CommonProps::default(),
                    )
                },
            ),
        )]);
        let svg = document_to_svg(&doc);
        assert!(
            svg.contains("data-jas-instance-transform=\"matrix(0.8660254037844387,"),
            "instance transform kept 4dp:\n{svg}"
        );
    }
}

