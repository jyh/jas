//! Binary document serialization using MessagePack + deflate.
//!
//! Format:
//!     [Magic 4B "JAS\0"] [Version u16 LE] [Flags u16 LE] [Payload]
//!
//! Flags bits 0-1: compression method (0=none, 1=raw deflate).
//! Payload: MessagePack-encoded document using positional arrays.

use std::io::{Read, Write};
use std::rc::Rc;

use flate2::read::DeflateDecoder;
use flate2::write::DeflateEncoder;
use flate2::Compression;
use rmpv::Value;

use crate::document::document::{
    Document, ElementPath, ElementSelection, Selection, SelectionKind, SortedCps,
};
use crate::geometry::element::*;

// -- Constants ---------------------------------------------------------------

pub const MAGIC: &[u8; 4] = b"JAS\0";
// v2 (CommonProps id+name): every element array carries name and id in the
// shared common block at indices 5 and 6; type-specific payload shifts to
// index 7. v1 (Layer-only name at index 5, no id) is a different positional
// layout and is NOT forward-readable — binary is a deferred secondary format
// with no real-world v1 data, so fixtures were regenerated to v2 rather than
// carrying a dual parse path.
pub const VERSION: u16 = 2;
pub const MIN_VERSION: u16 = 2;
const HEADER_SIZE: usize = 8; // 4 magic + 2 version + 2 flags

const COMPRESS_NONE: u16 = 0;
const COMPRESS_DEFLATE: u16 = 1;

// Element type tags.
const TAG_LAYER: i64 = 0;
const TAG_LINE: i64 = 1;
const TAG_RECT: i64 = 2;
const TAG_CIRCLE: i64 = 3;
const TAG_ELLIPSE: i64 = 4;
const TAG_POLYLINE: i64 = 5;
const TAG_POLYGON: i64 = 6;
const TAG_PATH: i64 = 7;
const TAG_TEXT: i64 = 8;
const TAG_TEXT_PATH: i64 = 9;
const TAG_GROUP: i64 = 10;
const TAG_LIVE: i64 = 11;

// Path command tags.
const CMD_MOVE_TO: i64 = 0;
const CMD_LINE_TO: i64 = 1;
const CMD_CURVE_TO: i64 = 2;
const CMD_SMOOTH_CURVE_TO: i64 = 3;
const CMD_QUAD_TO: i64 = 4;
const CMD_SMOOTH_QUAD_TO: i64 = 5;
const CMD_ARC_TO: i64 = 6;
const CMD_CLOSE_PATH: i64 = 7;

// Fill-rule tags. TAG_PATH slot 11 (see pack_element / unpack_element).
// Trailing-append, like width_points (slot 10) before it: a blob written
// before this slot existed simply has 11 slots and reads as NonZero, so
// nothing on disk is orphaned and the header stays at v2 — a version bump
// would make the frozen reference reader (which rejects version > 2)
// unable to read anything we write. JasSwift pins the identical slot and
// tag values so the two ports stay byte-identical.
const FILL_RULE_NON_ZERO: i64 = 0;
const FILL_RULE_EVEN_ODD: i64 = 1;

// -- The per-tag trailing common extension -----------------------------------
//
// RULED 2026-07-27 (transcripts/EDIT_SEMANTICS_FREEZE.md): `common.mode`,
// `common.mask` and `common.tool_origin` were dropped by this codec -- save as
// binary, reload, and they were gone -- and `stroke_brush` /
// `stroke_brush_overrides` with them on Path. A round trip speaks to NOTHING,
// so under the preservation law it must preserve EVERYTHING.
//
// The SHAPE is forced by the layout: `unpack_common` reads FIXED indices 1..6
// and every variant's payload starts at index 7, so the shared common block
// cannot be extended once. The three fields it never carried are therefore
// appended PER ELEMENT TAG, at the tag's own trailing edge, and the arity
// table below is what the two ports must agree on. `VERSION` STAYS AT 2: the
// frozen tag-pinned readers reject `version > 2` and index positionally
// without validating array length (verified on this commit in
// jas/geometry/binary.py `_unpack_element` and jas_ocaml/lib/geometry/
// binary.ml `unpack_element`, both of which read fixed indices and ignore
// trailing slots), so trailing append keeps them able to read what we write --
// the same reasoning that settled the fill_rule slot-11 decision.
//
// JasSwift/Sources/Geometry/Binary.swift mirrors these offsets, and
// test_fixtures/expected/binary_wire.json pins the resulting arity and BYTES
// for both ports at once. That byte-level gate is not optional: every other
// codec gate compares canonical test-JSON strings, and the fields this codec
// drops are a strict SUBSET of the fields that string oracle also drops, so a
// one-port slot mismatch here would otherwise land silently (coverage gap
// `codec-string-oracle-cannot-see-a-dropped-field`).
//
// NOTE 2026-07-28: the SUBSET claim above was true when written and is NOT true
// now -- canonical test-JSON was extended to carry all twelve formerly-dropped
// fields, so it drops NOTHING and binary drops only the two gradients. The
// oracle got STRONGER. This gate stays: BYTE-level, not string-level.

/// Offset of `common.mode` within a tag's extension block.
const EXT_MODE: usize = 0;
/// Offset of `common.mask` within a tag's extension block.
const EXT_MASK: usize = 1;
/// Offset of `common.tool_origin` within a tag's extension block.
const EXT_TOOL_ORIGIN: usize = 2;
/// Slots in the extension block that EVERY tag carries.
const COMMON_EXT_LEN: usize = 3;
/// TAG_PATH only, immediately after the common extension.
const EXT_STROKE_BRUSH: usize = COMMON_EXT_LEN;
const EXT_STROKE_BRUSH_OVERRIDES: usize = COMMON_EXT_LEN + 1;

/// Slots a tag carried BEFORE the extension -- equivalently, the index at
/// which its extension block starts. Mirrored by `tagBaseArity` in JasSwift
/// and declared as data in test_fixtures/expected/binary_wire.json.
fn tag_base_arity(tag: i64) -> usize {
    match tag {
        TAG_LAYER => 8,
        TAG_GROUP => 8,
        TAG_LINE => 13,
        TAG_RECT => 15,
        TAG_CIRCLE => 12,
        TAG_ELLIPSE => 13,
        TAG_POLYLINE => 10,
        TAG_POLYGON => 10,
        TAG_PATH => 12,
        TAG_TEXT => 20,
        TAG_TEXT_PATH => 18,
        TAG_LIVE => 10,
        // An unknown tag never reaches here: `unpack_element` rejects it
        // before the extension is read, and `pack_element` is exhaustive.
        _ => 0,
    }
}

/// The wire tag name for an element, for gate messages and for the
/// `tag_arity` keys of test_fixtures/expected/binary_wire.json. Mirrored by
/// `elementTagLabel` in JasSwift.
pub fn element_tag_label(elem: &Element) -> &'static str {
    match elem {
        Element::Layer(_) => "layer",
        Element::Group(_) => "group",
        Element::Line(_) => "line",
        Element::Rect(_) => "rect",
        Element::Circle(_) => "circle",
        Element::Ellipse(_) => "ellipse",
        Element::Polyline(_) => "polyline",
        Element::Polygon(_) => "polygon",
        Element::Path(_) => "path",
        Element::Text(_) => "text",
        Element::TextPath(_) => "text_path",
        Element::Live(_) => "live",
    }
}

/// The number of msgpack slots `pack_element` writes for `elem` -- the arity
/// the per-tag trailing append is defined against. Read by the shared
/// byte-level wire gate (test_fixtures/expected/binary_wire.json), whose whole
/// purpose is that a one-port slot mismatch cannot land silently. Mirrored by
/// `packedElementSlotCount` in JasSwift.
pub fn packed_element_slot_count(elem: &Element) -> usize {
    match pack_element(elem) {
        Value::Array(slots) => slots.len(),
        _ => 0,
    }
}

/// Decode a lowercase hex string to bytes, for gates that pin a blob as a
/// literal (the shared byte-level wire gate). Panics on a malformed literal,
/// which is a fixture bug, not runtime input.
pub fn unhex_for_tests(s: &str) -> Vec<u8> {
    (0..s.len() / 2)
        .map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16)
            .expect("wire fixture hex must be valid"))
        .collect()
}

/// Blend-mode wire tags, in `BlendMode`'s declaration order. Mirrored in
/// JasSwift; an unrecognized tag reads as `Normal`, the value every document
/// written before this slot existed was authored with.
fn blend_mode_tag(m: BlendMode) -> i64 {
    match m {
        BlendMode::Normal => 0,
        BlendMode::Darken => 1,
        BlendMode::Multiply => 2,
        BlendMode::ColorBurn => 3,
        BlendMode::Lighten => 4,
        BlendMode::Screen => 5,
        BlendMode::ColorDodge => 6,
        BlendMode::Overlay => 7,
        BlendMode::SoftLight => 8,
        BlendMode::HardLight => 9,
        BlendMode::Difference => 10,
        BlendMode::Exclusion => 11,
        BlendMode::Hue => 12,
        BlendMode::Saturation => 13,
        BlendMode::Color => 14,
        BlendMode::Luminosity => 15,
    }
}

fn blend_mode_from_tag(v: Option<&Value>) -> BlendMode {
    match v.and_then(|v| v.as_i64().or_else(|| v.as_u64().map(|u| u as i64))) {
        Some(1) => BlendMode::Darken,
        Some(2) => BlendMode::Multiply,
        Some(3) => BlendMode::ColorBurn,
        Some(4) => BlendMode::Lighten,
        Some(5) => BlendMode::Screen,
        Some(6) => BlendMode::ColorDodge,
        Some(7) => BlendMode::Overlay,
        Some(8) => BlendMode::SoftLight,
        Some(9) => BlendMode::HardLight,
        Some(10) => BlendMode::Difference,
        Some(11) => BlendMode::Exclusion,
        Some(12) => BlendMode::Hue,
        Some(13) => BlendMode::Saturation,
        Some(14) => BlendMode::Color,
        Some(15) => BlendMode::Luminosity,
        _ => BlendMode::Normal,
    }
}

// Color space tags.
const SPACE_RGB: i64 = 0;
const SPACE_HSB: i64 = 1;
const SPACE_CMYK: i64 = 2;

// -- Helper: build Value from common types -----------------------------------

fn vint(n: i64) -> Value { Value::Integer(n.into()) }
fn vuint(n: usize) -> Value { Value::Integer((n as i64).into()) }
fn vf64(f: f64) -> Value { Value::F64(f) }
fn vbool(b: bool) -> Value { Value::Boolean(b) }
fn vstr(s: &str) -> Value { Value::String(s.into()) }
fn vnil() -> Value { Value::Nil }

// Optional typed packers: `None` packs as `nil`; `Some(v)` as the
// inner value. Used for tspan override fields where an absent
// override is semantically distinct from a zero / empty override.
fn opt_f64(o: Option<f64>) -> Value {
    match o { Some(f) => vf64(f), None => vnil() }
}
fn opt_str(o: Option<&String>) -> Value {
    match o { Some(s) => vstr(s), None => vnil() }
}
fn opt_bool(o: Option<bool>) -> Value {
    match o { Some(b) => vbool(b), None => vnil() }
}

fn as_opt_f64(v: &Value) -> Result<Option<f64>, String> {
    if v.is_nil() { Ok(None) } else { Ok(Some(as_f64(v)?)) }
}
fn as_opt_str(v: &Value) -> Result<Option<String>, String> {
    if v.is_nil() { Ok(None) } else { Ok(Some(as_str(v)?.to_string())) }
}
fn as_opt_bool(v: &Value) -> Option<bool> {
    if v.is_nil() { None } else { v.as_bool() }
}

// -- Pack (Document -> Value) ------------------------------------------------

fn pack_color(c: &Color) -> Value {
    match c {
        Color::Rgb { r, g, b, a } =>
            Value::Array(vec![vint(SPACE_RGB), vf64(*r), vf64(*g), vf64(*b), vf64(0.0), vf64(*a)]),
        Color::Hsb { h, s, b, a } =>
            Value::Array(vec![vint(SPACE_HSB), vf64(*h), vf64(*s), vf64(*b), vf64(0.0), vf64(*a)]),
        Color::Cmyk { c, m, y, k, a } =>
            Value::Array(vec![vint(SPACE_CMYK), vf64(*c), vf64(*m), vf64(*y), vf64(*k), vf64(*a)]),
    }
}

fn pack_fill(fill: &Option<Fill>) -> Value {
    match fill {
        None => Value::Nil,
        Some(f) => Value::Array(vec![pack_color(&f.color), vf64(f.opacity)]),
    }
}

fn pack_stroke(stroke: &Option<Stroke>) -> Value {
    match stroke {
        None => Value::Nil,
        Some(s) => {
            let cap = match s.linecap {
                LineCap::Butt => 0,
                LineCap::Round => 1,
                LineCap::Square => 2,
            };
            let join = match s.linejoin {
                LineJoin::Miter => 0,
                LineJoin::Round => 1,
                LineJoin::Bevel => 2,
            };
            let align = match s.align {
                StrokeAlign::Center => 0,
                StrokeAlign::Inside => 1,
                StrokeAlign::Outside => 2,
            };
            let start_arrow = vstr(s.start_arrow.as_str());
            let end_arrow = vstr(s.end_arrow.as_str());
            let arrow_align = match s.arrow_align {
                ArrowAlign::TipAtEnd => 0,
                ArrowAlign::CenterAtEnd => 1,
            };
            // Dash pattern: pack as array of active values
            let dash: Vec<Value> = s.dash_array().iter().map(|&v| vf64(v)).collect();
            Value::Array(vec![
                pack_color(&s.color), vf64(s.width), vint(cap), vint(join), vf64(s.opacity),
                vf64(s.miter_limit), vint(align),
                Value::Array(dash),
                start_arrow, end_arrow,
                vf64(s.start_arrow_scale), vf64(s.end_arrow_scale),
                vint(arrow_align),
                // Element 13: dash_align_anchors (added with DASH_ALIGN.md).
                vbool(s.dash_align_anchors),
            ])
        }
    }
}

fn pack_width_points(pts: &[StrokeWidthPoint]) -> Value {
    if pts.is_empty() { return Value::Nil; }
    Value::Array(pts.iter().map(|p| {
        Value::Array(vec![vf64(p.t), vf64(p.width_left), vf64(p.width_right)])
    }).collect())
}

fn pack_transform(t: &Option<Transform>) -> Value {
    match t {
        None => Value::Nil,
        Some(t) => Value::Array(vec![vf64(t.a), vf64(t.b), vf64(t.c), vf64(t.d), vf64(t.e), vf64(t.f)]),
    }
}

fn pack_path_command(cmd: &PathCommand) -> Value {
    match cmd {
        PathCommand::MoveTo { x, y } =>
            Value::Array(vec![vint(CMD_MOVE_TO), vf64(*x), vf64(*y)]),
        PathCommand::LineTo { x, y } =>
            Value::Array(vec![vint(CMD_LINE_TO), vf64(*x), vf64(*y)]),
        PathCommand::CurveTo { x1, y1, x2, y2, x, y } =>
            Value::Array(vec![vint(CMD_CURVE_TO), vf64(*x1), vf64(*y1), vf64(*x2), vf64(*y2), vf64(*x), vf64(*y)]),
        PathCommand::SmoothCurveTo { x2, y2, x, y } =>
            Value::Array(vec![vint(CMD_SMOOTH_CURVE_TO), vf64(*x2), vf64(*y2), vf64(*x), vf64(*y)]),
        PathCommand::QuadTo { x1, y1, x, y } =>
            Value::Array(vec![vint(CMD_QUAD_TO), vf64(*x1), vf64(*y1), vf64(*x), vf64(*y)]),
        PathCommand::SmoothQuadTo { x, y } =>
            Value::Array(vec![vint(CMD_SMOOTH_QUAD_TO), vf64(*x), vf64(*y)]),
        PathCommand::ArcTo { rx, ry, x_rotation, large_arc, sweep, x, y } =>
            Value::Array(vec![vint(CMD_ARC_TO), vf64(*rx), vf64(*ry), vf64(*x_rotation),
                              vbool(*large_arc), vbool(*sweep), vf64(*x), vf64(*y)]),
        PathCommand::ClosePath =>
            Value::Array(vec![vint(CMD_CLOSE_PATH)]),
    }
}

/// Pack a single Tspan as a compact msgpack array. Field order is
/// stable and documented: id, content, baseline_shift, dx,
/// font_family, font_size, font_style, font_variant, font_weight,
/// jas_aa_mode, jas_fractional_widths, jas_kerning_mode, jas_no_break,
/// letter_spacing, line_height, rotate, style_name, text_decoration,
/// text_rendering, text_transform, transform, xml_lang. Each override
/// field is either its typed value or `nil` when unset.
fn pack_tspan(t: &crate::geometry::tspan::Tspan) -> Value {
    let decor = match &t.text_decoration {
        Some(members) => {
            let arr: Vec<Value> = members.iter().map(|s| vstr(s)).collect();
            Value::Array(arr)
        }
        None => vnil(),
    };
    let transform = match &t.transform {
        Some(tr) => Value::Array(vec![
            vf64(tr.a), vf64(tr.b), vf64(tr.c),
            vf64(tr.d), vf64(tr.e), vf64(tr.f),
        ]),
        None => vnil(),
    };
    Value::Array(vec![
        vuint(t.id as usize),
        vstr(&t.content),
        opt_f64(t.baseline_shift),
        opt_f64(t.dx),
        opt_str(t.font_family.as_ref()),
        opt_f64(t.font_size),
        opt_str(t.font_style.as_ref()),
        opt_str(t.font_variant.as_ref()),
        opt_str(t.font_weight.as_ref()),
        opt_str(t.jas_aa_mode.as_ref()),
        opt_bool(t.jas_fractional_widths),
        opt_str(t.jas_kerning_mode.as_ref()),
        opt_bool(t.jas_no_break),
        opt_f64(t.letter_spacing),
        opt_f64(t.line_height),
        opt_f64(t.rotate),
        opt_str(t.style_name.as_ref()),
        decor,
        opt_str(t.text_rendering.as_ref()),
        opt_str(t.text_transform.as_ref()),
        transform,
        opt_str(t.xml_lang.as_ref()),
        opt_str(t.jas_role.as_ref()),
        opt_f64(t.jas_left_indent),
        opt_f64(t.jas_right_indent),
        opt_bool(t.jas_hyphenate),
        opt_bool(t.jas_hanging_punctuation),
        opt_str(t.jas_list_style.as_ref()),
        opt_str(t.text_align.as_ref()),
        opt_str(t.text_align_last.as_ref()),
        opt_f64(t.text_indent),
        opt_f64(t.jas_space_before),
        opt_f64(t.jas_space_after),
        opt_f64(t.jas_word_spacing_min),
        opt_f64(t.jas_word_spacing_desired),
        opt_f64(t.jas_word_spacing_max),
        opt_f64(t.jas_letter_spacing_min),
        opt_f64(t.jas_letter_spacing_desired),
        opt_f64(t.jas_letter_spacing_max),
        opt_f64(t.jas_glyph_scaling_min),
        opt_f64(t.jas_glyph_scaling_desired),
        opt_f64(t.jas_glyph_scaling_max),
        opt_f64(t.jas_auto_leading),
        opt_str(t.jas_single_word_justify.as_ref()),
        opt_f64(t.jas_hyphenate_min_word),
        opt_f64(t.jas_hyphenate_min_before),
        opt_f64(t.jas_hyphenate_min_after),
        opt_f64(t.jas_hyphenate_limit),
        opt_f64(t.jas_hyphenate_zone),
        opt_f64(t.jas_hyphenate_bias),
        opt_bool(t.jas_hyphenate_capitalized),
    ])
}

/// Inverse of `pack_tspan`. Tolerant of trailing field additions:
/// any field not present in the blob falls back to the tspan default.
fn unpack_tspan(v: &Value) -> Result<crate::geometry::tspan::Tspan, String> {
    use crate::geometry::tspan::Tspan;
    let arr = as_array(v)?;
    let get = |i: usize| arr.get(i).unwrap_or(&Value::Nil);
    let id = if !arr.is_empty() { as_i64(&arr[0])? as u32 } else { 0 };
    let content = if arr.len() > 1 { as_str(&arr[1])?.to_string() } else { String::new() };
    let decor = match get(17) {
        Value::Array(xs) => Some(
            xs.iter()
                .map(|x| as_str(x).map(|s| s.to_string()))
                .collect::<Result<Vec<_>, String>>()?,
        ),
        _ => None,
    };
    let transform = match get(20) {
        Value::Array(xs) if xs.len() >= 6 => Some(crate::geometry::element::Transform {
            a: as_f64(&xs[0])?, b: as_f64(&xs[1])?, c: as_f64(&xs[2])?,
            d: as_f64(&xs[3])?, e: as_f64(&xs[4])?, f: as_f64(&xs[5])?,
        }),
        _ => None,
    };
    Ok(Tspan {
        id,
        content,
        baseline_shift: as_opt_f64(get(2))?,
        dx: as_opt_f64(get(3))?,
        font_family: as_opt_str(get(4))?,
        font_size: as_opt_f64(get(5))?,
        font_style: as_opt_str(get(6))?,
        font_variant: as_opt_str(get(7))?,
        font_weight: as_opt_str(get(8))?,
        jas_aa_mode: as_opt_str(get(9))?,
        jas_fractional_widths: as_opt_bool(get(10)),
        jas_kerning_mode: as_opt_str(get(11))?,
        jas_no_break: as_opt_bool(get(12)),
        letter_spacing: as_opt_f64(get(13))?,
        line_height: as_opt_f64(get(14))?,
        rotate: as_opt_f64(get(15))?,
        style_name: as_opt_str(get(16))?,
        text_decoration: decor,
        text_rendering: as_opt_str(get(18))?,
        text_transform: as_opt_str(get(19))?,
        transform,
        xml_lang: as_opt_str(get(21))?,
        jas_role: as_opt_str(get(22))?,
        jas_left_indent: as_opt_f64(get(23))?,
        jas_right_indent: as_opt_f64(get(24))?,
        jas_hyphenate: as_opt_bool(get(25)),
        jas_hanging_punctuation: as_opt_bool(get(26)),
        jas_list_style: as_opt_str(get(27))?,
        text_align: as_opt_str(get(28))?,
        text_align_last: as_opt_str(get(29))?,
        text_indent: as_opt_f64(get(30))?,
        jas_space_before: as_opt_f64(get(31))?,
        jas_space_after: as_opt_f64(get(32))?,
        jas_word_spacing_min: as_opt_f64(get(33))?,
        jas_word_spacing_desired: as_opt_f64(get(34))?,
        jas_word_spacing_max: as_opt_f64(get(35))?,
        jas_letter_spacing_min: as_opt_f64(get(36))?,
        jas_letter_spacing_desired: as_opt_f64(get(37))?,
        jas_letter_spacing_max: as_opt_f64(get(38))?,
        jas_glyph_scaling_min: as_opt_f64(get(39))?,
        jas_glyph_scaling_desired: as_opt_f64(get(40))?,
        jas_glyph_scaling_max: as_opt_f64(get(41))?,
        jas_auto_leading: as_opt_f64(get(42))?,
        jas_single_word_justify: as_opt_str(get(43))?,
        jas_hyphenate_min_word: as_opt_f64(get(44))?,
        jas_hyphenate_min_before: as_opt_f64(get(45))?,
        jas_hyphenate_min_after: as_opt_f64(get(46))?,
        jas_hyphenate_limit: as_opt_f64(get(47))?,
        jas_hyphenate_zone: as_opt_f64(get(48))?,
        jas_hyphenate_bias: as_opt_f64(get(49))?,
        jas_hyphenate_capitalized: as_opt_bool(get(50)),
    })
}

fn pack_common(c: &CommonProps) -> (Value, Value, Value, Value, Value, Value) {
    let vis = match c.visibility {
        Visibility::Invisible => 0,
        Visibility::Outline => 1,
        Visibility::Preview => 2,
    };
    // v2: name and id ride in the shared common block (indices 5 and 6),
    // emitted as value-or-nil so every element type round-trips them.
    (vbool(c.locked), vf64(c.opacity), vint(vis), pack_transform(&c.transform),
     opt_str(c.name.as_ref()), opt_str(c.id.as_ref()))
}

/// Pack an opacity mask: `[subtree, clip, invert, disabled, linked,
/// unlink_transform]`. The subtree is a full nested element, so a masked
/// element's mask artwork round-trips with all of its own fields.
fn pack_mask(m: &Option<Box<Mask>>) -> Value {
    match m {
        None => vnil(),
        Some(m) => Value::Array(vec![
            pack_element(&m.subtree),
            vbool(m.clip), vbool(m.invert), vbool(m.disabled), vbool(m.linked),
            pack_transform(&m.unlink_transform),
        ]),
    }
}

/// Inverse of `pack_mask`, tolerant in the same way `unpack_fill_rule` is: an
/// absent slot, a nil slot, a slot holding something that is not an array, and
/// an array whose subtree slot is not itself an element array ALL read as "no
/// mask" rather than erroring or guessing. A short-but-plausible array falls
/// back to the field defaults (`clip` and `linked` true, matching `Mask`'s own
/// serde defaults). This is the standing
/// `malformed_but_decodable_blob_errors_not_panics` contract: on wasm a panic
/// aborts the module and `save_session` reads localStorage on every startup.
fn unpack_mask(v: Option<&Value>) -> Result<Option<Box<Mask>>, String> {
    let arr = match v {
        Some(Value::Array(arr)) if matches!(arr.first(), Some(Value::Array(_))) => arr,
        _ => return Ok(None),
    };
    let get = |i: usize| arr.get(i).unwrap_or(&Value::Nil);
    Ok(Some(Box::new(Mask {
        subtree: Box::new(unpack_element(at(arr, 0)?)?),
        clip: get(1).as_bool().unwrap_or(true),
        invert: get(2).as_bool().unwrap_or(false),
        disabled: get(3).as_bool().unwrap_or(false),
        linked: get(4).as_bool().unwrap_or(true),
        unlink_transform: match get(5) {
            Value::Array(_) => unpack_transform(get(5))?,
            _ => None,
        },
    })))
}

/// The trailing per-tag extension block: the three `CommonProps` fields the
/// fixed 1..6 block cannot hold. Written for EVERY tag, always, so a tag's
/// arity is constant and the shared wire gate can assert it.
fn pack_common_ext(c: &CommonProps) -> Vec<Value> {
    vec![
        vint(blend_mode_tag(c.mode)),
        pack_mask(&c.mask),
        opt_str(c.tool_origin.as_ref()),
    ]
}

fn pack_element(elem: &Element) -> Value {
    let mut slots = pack_element_base(elem);
    // The per-tag trailing common extension (see EXT_* above). Appended here
    // rather than inside each arm so no tag can be forgotten.
    slots.extend(pack_common_ext(elem.common()));
    if let Element::Path(e) = elem {
        // Path-only, immediately after the common extension.
        slots.push(opt_str(e.stroke_brush.as_ref()));
        slots.push(opt_str(e.stroke_brush_overrides.as_ref()));
    }
    Value::Array(slots)
}

/// The tag's slots up to `tag_base_arity(tag)` -- everything the format
/// carried before the trailing extension.
fn pack_element_base(elem: &Element) -> Vec<Value> {
    match elem {
        Element::Layer(e) => {
            let (locked, opacity, vis, xform, name, id) = pack_common(&e.common);
            let children: Vec<Value> = e.children.iter().map(|c| pack_element(c)).collect();
            vec![vint(TAG_LAYER), locked, opacity, vis, xform, name, id,
                              Value::Array(children)]
        }
        Element::Group(e) => {
            let (locked, opacity, vis, xform, name, id) = pack_common(&e.common);
            let children: Vec<Value> = e.children.iter().map(|c| pack_element(c)).collect();
            vec![vint(TAG_GROUP), locked, opacity, vis, xform, name, id,
                              Value::Array(children)]
        }
        Element::Line(e) => {
            let (locked, opacity, vis, xform, name, id) = pack_common(&e.common);
            vec![vint(TAG_LINE), locked, opacity, vis, xform, name, id,
                              vf64(e.x1), vf64(e.y1), vf64(e.x2), vf64(e.y2),
                              pack_stroke(&e.stroke), pack_width_points(&e.width_points)]
        }
        Element::Rect(e) => {
            let (locked, opacity, vis, xform, name, id) = pack_common(&e.common);
            vec![vint(TAG_RECT), locked, opacity, vis, xform, name, id,
                              vf64(e.x), vf64(e.y), vf64(e.width), vf64(e.height),
                              vf64(e.rx), vf64(e.ry),
                              pack_fill(&e.fill), pack_stroke(&e.stroke)]
        }
        Element::Circle(e) => {
            let (locked, opacity, vis, xform, name, id) = pack_common(&e.common);
            vec![vint(TAG_CIRCLE), locked, opacity, vis, xform, name, id,
                              vf64(e.cx), vf64(e.cy), vf64(e.r),
                              pack_fill(&e.fill), pack_stroke(&e.stroke)]
        }
        Element::Ellipse(e) => {
            let (locked, opacity, vis, xform, name, id) = pack_common(&e.common);
            vec![vint(TAG_ELLIPSE), locked, opacity, vis, xform, name, id,
                              vf64(e.cx), vf64(e.cy), vf64(e.rx), vf64(e.ry),
                              pack_fill(&e.fill), pack_stroke(&e.stroke)]
        }
        Element::Polyline(e) => {
            let (locked, opacity, vis, xform, name, id) = pack_common(&e.common);
            let points: Vec<Value> = e.points.iter()
                .map(|(x, y)| Value::Array(vec![vf64(*x), vf64(*y)])).collect();
            vec![vint(TAG_POLYLINE), locked, opacity, vis, xform, name, id,
                              Value::Array(points), pack_fill(&e.fill), pack_stroke(&e.stroke)]
        }
        Element::Polygon(e) => {
            let (locked, opacity, vis, xform, name, id) = pack_common(&e.common);
            let points: Vec<Value> = e.points.iter()
                .map(|(x, y)| Value::Array(vec![vf64(*x), vf64(*y)])).collect();
            vec![vint(TAG_POLYGON), locked, opacity, vis, xform, name, id,
                              Value::Array(points), pack_fill(&e.fill), pack_stroke(&e.stroke)]
        }
        Element::Path(e) => {
            let (locked, opacity, vis, xform, name, id) = pack_common(&e.common);
            let cmds: Vec<Value> = e.d.iter().map(pack_path_command).collect();
            // fill_rule rides the trailing slot 11 (always written).
            vec![vint(TAG_PATH), locked, opacity, vis, xform, name, id,
                              Value::Array(cmds), pack_fill(&e.fill), pack_stroke(&e.stroke),
                              pack_width_points(&e.width_points),
                              pack_fill_rule(e.fill_rule)]
        }
        Element::Text(e) => {
            let (locked, opacity, vis, xform, name, id) = pack_common(&e.common);
            // The tspans field goes at the end so pre-tspan-codec
            // readers can still decode the first N fields. Writers
            // always emit tspans — round-trip of a multi-tspan Text
            // depends on it. Single no-override tspan blobs are still
            // decodable by old readers via the derived `content`.
            let tspans: Vec<Value> = e.tspans.iter().map(pack_tspan).collect();
            vec![vint(TAG_TEXT), locked, opacity, vis, xform, name, id,
                              vf64(e.x), vf64(e.y), vstr(&e.content()),
                              vstr(&e.font_family), vf64(e.font_size),
                              vstr(&e.font_weight), vstr(&e.font_style),
                              vstr(&e.text_decoration),
                              vf64(e.width), vf64(e.height),
                              pack_fill(&e.fill), pack_stroke(&e.stroke),
                              Value::Array(tspans)]
        }
        Element::TextPath(e) => {
            let (locked, opacity, vis, xform, name, id) = pack_common(&e.common);
            let cmds: Vec<Value> = e.d.iter().map(pack_path_command).collect();
            let tspans: Vec<Value> = e.tspans.iter().map(pack_tspan).collect();
            vec![vint(TAG_TEXT_PATH), locked, opacity, vis, xform, name, id,
                              Value::Array(cmds), vstr(&e.content()), vf64(e.start_offset),
                              vstr(&e.font_family), vf64(e.font_size),
                              vstr(&e.font_weight), vstr(&e.font_style),
                              vstr(&e.text_decoration),
                              pack_fill(&e.fill), pack_stroke(&e.stroke),
                              Value::Array(tspans)]
        }
        Element::Live(v) => match v {
            crate::geometry::live::LiveVariant::CompoundShape(cs) => {
                let (locked, opacity, vis, xform, name, id) = pack_common(&cs.common);
                let op = match cs.operation {
                    crate::geometry::live::CompoundOperation::Union => "union",
                    crate::geometry::live::CompoundOperation::SubtractFront => "subtract_front",
                    crate::geometry::live::CompoundOperation::Intersection => "intersection",
                    crate::geometry::live::CompoundOperation::Exclude => "exclude",
                };
                let operands: Vec<Value> = cs.operands.iter().map(|c| pack_element(c)).collect();
                // [tag, common(1..6), kind(7), operation(8), operands(9)]
                vec![vint(TAG_LIVE), locked, opacity, vis, xform, name, id,
                                  vstr("compound_shape"), vstr(op), Value::Array(operands)]
            }
            crate::geometry::live::LiveVariant::Reference(r) => {
                let (locked, opacity, vis, xform, name, id) = pack_common(&r.common);
                // [tag, common(1..6), kind(7), target(8), instance_transform(9)]
                // Symbols P4 (SYMBOLS.md §4 / Fork F2): the instance `transform`
                // (distinct from common.transform packed at slot 4) rides slot 9
                // via pack_transform; Nil when None. Old 9-element .bin (no slot
                // 9) still decode TOLERANTLY to None on the read side.
                vec![vint(TAG_LIVE), locked, opacity, vis, xform, name, id,
                                  vstr("reference"), vstr(&r.target.0),
                                  pack_transform(&r.transform)]
            }
            crate::geometry::live::LiveVariant::Recorded(rec) => {
                let (locked, opacity, vis, xform, name, id) = pack_common(&rec.common);
                // The recipe (inputs + ops) rides slots 8/9 as canonical JSON
                // strings (RECORDED_ELEMENTS.md). [tag, common(1..6), kind(7),
                // inputs-json(8), ops-json(9)].
                let inputs_json = serde_json::to_string(
                    &rec.inputs.iter().map(|i| i.0.clone()).collect::<Vec<_>>())
                    .unwrap_or_default();
                let ops_json = serde_json::to_string(&rec.ops).unwrap_or_default();
                vec![vint(TAG_LIVE), locked, opacity, vis, xform, name, id,
                                  vstr("recorded"), vstr(&inputs_json), vstr(&ops_json)]
            }
            crate::geometry::live::LiveVariant::Generated(ge) => {
                let (locked, opacity, vis, xform, name, id) = pack_common(&ge.common);
                // The concept id + params ride slots 8/9 (params as a canonical
                // JSON string). [tag, common(1..6), kind(7), concept(8), params(9)].
                let params_json = serde_json::to_string(&ge.params).unwrap_or_default();
                vec![vint(TAG_LIVE), locked, opacity, vis, xform, name, id,
                                  vstr("generated"), vstr(&ge.concept_id), vstr(&params_json)]
            }
        },
    }
}

fn pack_selection(sel: &Selection) -> Value {
    let mut entries: Vec<(Vec<usize>, Value)> = sel.iter().map(|es| {
        let path: Vec<Value> = es.path.iter().map(|&i| vuint(i)).collect();
        let kind = match &es.kind {
            SelectionKind::All => vint(0),
            SelectionKind::Partial(cps) => {
                let mut v = vec![vint(1)];
                v.extend(cps.iter().map(vuint));
                Value::Array(v)
            }
        };
        (es.path.clone(), Value::Array(vec![Value::Array(path), kind]))
    }).collect();
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    Value::Array(entries.into_iter().map(|(_, v)| v).collect())
}

fn pack_document(doc: &Document) -> Value {
    let layers: Vec<Value> = doc.layers.iter().map(|l| pack_element(l)).collect();
    // Symbols (master store, SYMBOLS.md §5): appended to the positional
    // document array AFTER the existing fields, as a (possibly empty) element
    // array sorted by common.id (the §2 deterministic-order rule). Trailing
    // position keeps existing .bin fixtures (which predate symbols) decodable
    // — unpack tolerates the field's absence via arr.get(3).
    let mut sorted: Vec<&Element> = doc.symbols.iter().collect();
    sorted.sort_by(|a, b| {
        a.common().id.as_deref().unwrap_or("")
            .cmp(b.common().id.as_deref().unwrap_or(""))
    });
    let symbols: Vec<Value> = sorted.iter().map(|m| pack_element(m)).collect();
    Value::Array(vec![
        Value::Array(layers),
        vuint(doc.selected_layer),
        pack_selection(&doc.selection),
        Value::Array(symbols),
    ])
}

// -- Unpack (Value -> Document) ----------------------------------------------

// The unpack helpers below return `Result` rather than panicking so a
// malformed-but-msgpack-decodable blob surfaces as an `Err` from
// `binary_to_document` instead of aborting the process. This matters on wasm,
// where `save_session` reads the blob from localStorage on every startup and a
// panic aborts the whole module (no `catch_unwind`): one corrupted entry would
// otherwise brick the app on every load. The Python reference raises a
// catchable exception on the same input.

fn as_i64(v: &Value) -> Result<i64, String> {
    v.as_i64()
        // Handle unsigned integers too.
        .or_else(|| v.as_u64().map(|u| u as i64))
        .ok_or_else(|| format!("expected integer, got {:?}", v))
}

fn as_f64(v: &Value) -> Result<f64, String> {
    match v {
        Value::F64(f) => Ok(*f),
        Value::F32(f) => Ok(*f as f64),
        Value::Integer(i) => i
            .as_f64()
            .ok_or_else(|| format!("expected float-compatible integer, got {:?}", i)),
        _ => Err(format!("expected f64, got {:?}", v)),
    }
}

fn as_bool(v: &Value) -> Result<bool, String> {
    v.as_bool().ok_or_else(|| format!("expected bool, got {:?}", v))
}

fn as_str(v: &Value) -> Result<&str, String> {
    v.as_str().ok_or_else(|| format!("expected string, got {:?}", v))
}

fn as_array(v: &Value) -> Result<&Vec<Value>, String> {
    v.as_array().ok_or_else(|| format!("expected array, got {:?}", v))
}

/// Bounds-checked positional access, replacing raw `arr[i]` in the unpack
/// path so a too-short array yields an `Err` instead of an index panic.
fn at(arr: &[Value], i: usize) -> Result<&Value, String> {
    arr.get(i)
        .ok_or_else(|| format!("index {} out of range (len {})", i, arr.len()))
}

/// Pack a fill rule as its wire tag.
fn pack_fill_rule(r: FillRule) -> Value {
    vint(match r {
        FillRule::NonZero => FILL_RULE_NON_ZERO,
        FillRule::EvenOdd => FILL_RULE_EVEN_ODD,
    })
}

/// Read the fill rule from an optional trailing slot. `None` (the slot is
/// absent in a pre-fill_rule blob) and any unrecognized tag both read as
/// the app default, NonZero — the value those documents were written with.
fn unpack_fill_rule(v: Option<&Value>) -> FillRule {
    match v.and_then(|v| v.as_i64().or_else(|| v.as_u64().map(|u| u as i64))) {
        Some(FILL_RULE_EVEN_ODD) => FillRule::EvenOdd,
        _ => FillRule::NonZero,
    }
}

fn unpack_color(v: &Value) -> Result<Color, String> {
    let arr = as_array(v)?;
    let space = as_i64(at(arr, 0)?)?;
    Ok(match space {
        SPACE_RGB => Color::Rgb {
            r: as_f64(at(arr, 1)?)?, g: as_f64(at(arr, 2)?)?, b: as_f64(at(arr, 3)?)?, a: as_f64(at(arr, 5)?)?,
        },
        SPACE_HSB => Color::Hsb {
            h: as_f64(at(arr, 1)?)?, s: as_f64(at(arr, 2)?)?, b: as_f64(at(arr, 3)?)?, a: as_f64(at(arr, 5)?)?,
        },
        SPACE_CMYK => Color::Cmyk {
            c: as_f64(at(arr, 1)?)?, m: as_f64(at(arr, 2)?)?, y: as_f64(at(arr, 3)?)?,
            k: as_f64(at(arr, 4)?)?, a: as_f64(at(arr, 5)?)?,
        },
        _ => return Err(format!("unknown color space: {}", space)),
    })
}

fn unpack_fill(v: &Value) -> Result<Option<Fill>, String> {
    if v.is_nil() { return Ok(None); }
    let arr = as_array(v)?;
    Ok(Some(Fill { color: unpack_color(at(arr, 0)?)?, opacity: as_f64(at(arr, 1)?)? }))
}

fn unpack_stroke(v: &Value) -> Result<Option<Stroke>, String> {
    if v.is_nil() { return Ok(None); }
    let arr = as_array(v)?;
    let cap = match as_i64(at(arr, 2)?)? {
        0 => LineCap::Butt,
        1 => LineCap::Round,
        2 => LineCap::Square,
        n => return Err(format!("unknown linecap: {}", n)),
    };
    let join = match as_i64(at(arr, 3)?)? {
        0 => LineJoin::Miter,
        1 => LineJoin::Round,
        2 => LineJoin::Bevel,
        n => return Err(format!("unknown linejoin: {}", n)),
    };
    // Extended fields (backward compatible: old files have 5 elements)
    let (miter_limit, align, dash_pattern, dash_len,
         start_arrow, end_arrow, start_arrow_scale, end_arrow_scale, arrow_align)
    = if arr.len() > 5 {
        let ml = as_f64(at(arr, 5)?)?;
        let al = match as_i64(at(arr, 6)?)? {
            1 => StrokeAlign::Inside,
            2 => StrokeAlign::Outside,
            _ => StrokeAlign::Center,
        };
        let dash_arr = as_array(at(arr, 7)?)?;
        let mut dp = [0.0f64; 6];
        let dl = dash_arr.len().min(6) as u8;
        for (i, dv) in dash_arr.iter().enumerate().take(6) {
            dp[i] = as_f64(dv)?;
        }
        let sa = Arrowhead::from_str(as_str(at(arr, 8)?)?);
        let ea = Arrowhead::from_str(as_str(at(arr, 9)?)?);
        let sas = as_f64(at(arr, 10)?)?;
        let eas = as_f64(at(arr, 11)?)?;
        let aa = match as_i64(at(arr, 12)?)? {
            1 => ArrowAlign::CenterAtEnd,
            _ => ArrowAlign::TipAtEnd,
        };
        (ml, al, dp, dl, sa, ea, sas, eas, aa)
    } else {
        (10.0, StrokeAlign::Center, [0.0; 6], 0,
         Arrowhead::None, Arrowhead::None, 100.0, 100.0, ArrowAlign::TipAtEnd)
    };
    // Element 13: dash_align_anchors (added later — backward compatible
    // with older files that had 13 elements).
    let dash_align_anchors = if arr.len() > 13 {
        as_bool(at(arr, 13)?)?
    } else {
        false
    };
    Ok(Some(Stroke {
        color: unpack_color(at(arr, 0)?)?,
        width: as_f64(at(arr, 1)?)?,
        linecap: cap,
        linejoin: join,
        miter_limit,
        align,
        dash_pattern,
        dash_len,
        dash_align_anchors,
        start_arrow,
        end_arrow,
        start_arrow_scale,
        end_arrow_scale,
        arrow_align,
        opacity: as_f64(at(arr, 4)?)?,
    }))
}

fn unpack_width_points(v: &Value) -> Result<Vec<StrokeWidthPoint>, String> {
    if v.is_nil() { return Ok(vec![]); }
    as_array(v)?.iter().map(|p| {
        let a = as_array(p)?;
        Ok(StrokeWidthPoint {
            t: as_f64(at(a, 0)?)?,
            width_left: as_f64(at(a, 1)?)?,
            width_right: as_f64(at(a, 2)?)?,
        })
    }).collect()
}

fn unpack_transform(v: &Value) -> Result<Option<Transform>, String> {
    if v.is_nil() { return Ok(None); }
    let arr = as_array(v)?;
    Ok(Some(Transform {
        a: as_f64(at(arr, 0)?)?, b: as_f64(at(arr, 1)?)?, c: as_f64(at(arr, 2)?)?,
        d: as_f64(at(arr, 3)?)?, e: as_f64(at(arr, 4)?)?, f: as_f64(at(arr, 5)?)?,
    }))
}

fn unpack_path_command(v: &Value) -> Result<PathCommand, String> {
    let arr = as_array(v)?;
    let tag = as_i64(at(arr, 0)?)?;
    Ok(match tag {
        CMD_MOVE_TO => PathCommand::MoveTo { x: as_f64(at(arr, 1)?)?, y: as_f64(at(arr, 2)?)? },
        CMD_LINE_TO => PathCommand::LineTo { x: as_f64(at(arr, 1)?)?, y: as_f64(at(arr, 2)?)? },
        CMD_CURVE_TO => PathCommand::CurveTo {
            x1: as_f64(at(arr, 1)?)?, y1: as_f64(at(arr, 2)?)?,
            x2: as_f64(at(arr, 3)?)?, y2: as_f64(at(arr, 4)?)?,
            x: as_f64(at(arr, 5)?)?, y: as_f64(at(arr, 6)?)?,
        },
        CMD_SMOOTH_CURVE_TO => PathCommand::SmoothCurveTo {
            x2: as_f64(at(arr, 1)?)?, y2: as_f64(at(arr, 2)?)?,
            x: as_f64(at(arr, 3)?)?, y: as_f64(at(arr, 4)?)?,
        },
        CMD_QUAD_TO => PathCommand::QuadTo {
            x1: as_f64(at(arr, 1)?)?, y1: as_f64(at(arr, 2)?)?,
            x: as_f64(at(arr, 3)?)?, y: as_f64(at(arr, 4)?)?,
        },
        CMD_SMOOTH_QUAD_TO => PathCommand::SmoothQuadTo {
            x: as_f64(at(arr, 1)?)?, y: as_f64(at(arr, 2)?)?,
        },
        CMD_ARC_TO => PathCommand::ArcTo {
            rx: as_f64(at(arr, 1)?)?, ry: as_f64(at(arr, 2)?)?,
            x_rotation: as_f64(at(arr, 3)?)?,
            large_arc: as_bool(at(arr, 4)?)?, sweep: as_bool(at(arr, 5)?)?,
            x: as_f64(at(arr, 6)?)?, y: as_f64(at(arr, 7)?)?,
        },
        CMD_CLOSE_PATH => PathCommand::ClosePath,
        _ => return Err(format!("unknown path command tag: {}", tag)),
    })
}

/// Read the shared common block at fixed indices 1..6, plus the tag's
/// TRAILING extension block at `tag_base_arity(tag)` (mode / mask /
/// tool_origin). The extension is read TOLERANTLY -- an absent slot yields the
/// documented default, so a blob written before the extension existed still
/// loads with exactly the values it was authored with.
fn unpack_common(arr: &[Value], tag: i64) -> Result<CommonProps, String> {
    let vis = match as_i64(at(arr, 3)?)? {
        0 => Visibility::Invisible,
        1 => Visibility::Outline,
        2 => Visibility::Preview,
        n => return Err(format!("unknown visibility: {}", n)),
    };
    let base = tag_base_arity(tag);
    Ok(CommonProps {
        locked: as_bool(at(arr, 1)?)?,
        opacity: as_f64(at(arr, 2)?)?,
        mode: blend_mode_from_tag(arr.get(base + EXT_MODE)),
        visibility: vis,
        transform: unpack_transform(at(arr, 4)?)?,
        mask: unpack_mask(arr.get(base + EXT_MASK))?,
        tool_origin: tolerant_opt_str(arr.get(base + EXT_TOOL_ORIGIN)),
        // v2: name and id ride in the shared common block at indices 5 and 6.
        name: as_opt_str(at(arr, 5)?)?,
        id: as_opt_str(at(arr, 6)?)?,
    })
}

/// A trailing optional-string slot: absent or nil is `None`, anything that is
/// not a string is `None` too rather than an error, matching the tolerance the
/// fill_rule slot established for a malformed-but-decodable blob.
fn tolerant_opt_str(v: Option<&Value>) -> Option<String> {
    v.and_then(|v| v.as_str()).map(|s| s.to_string())
}

fn unpack_element(v: &Value) -> Result<Element, String> {
    let arr = as_array(v)?;
    let tag = as_i64(at(arr, 0)?)?;
    let common = unpack_common(arr, tag)?;

    Ok(match tag {
        TAG_LAYER => {
            let children: Vec<Rc<Element>> = as_array(at(arr, 7)?)?.iter()
                .map(|c| Ok(Rc::new(unpack_element(c)?))).collect::<Result<Vec<_>, String>>()?;
            Element::Layer(LayerElem { children, common, isolated_blending: false, knockout_group: false })
        }
        TAG_GROUP => {
            let children: Vec<Rc<Element>> = as_array(at(arr, 7)?)?.iter()
                .map(|c| Ok(Rc::new(unpack_element(c)?))).collect::<Result<Vec<_>, String>>()?;
            Element::Group(GroupElem { children, common, isolated_blending: false, knockout_group: false })
        }
        TAG_LINE => Element::Line(LineElem {
            x1: as_f64(at(arr, 7)?)?, y1: as_f64(at(arr, 8)?)?,
            x2: as_f64(at(arr, 9)?)?, y2: as_f64(at(arr, 10)?)?,
            stroke: unpack_stroke(at(arr, 11)?)?,
            width_points: if arr.len() > 12 { unpack_width_points(at(arr, 12)?)? } else { vec![] },
            common,
                    stroke_gradient: None,
        }),
        TAG_RECT => Element::Rect(RectElem {
            x: as_f64(at(arr, 7)?)?, y: as_f64(at(arr, 8)?)?,
            width: as_f64(at(arr, 9)?)?, height: as_f64(at(arr, 10)?)?,
            rx: as_f64(at(arr, 11)?)?, ry: as_f64(at(arr, 12)?)?,
            fill: unpack_fill(at(arr, 13)?)?, stroke: unpack_stroke(at(arr, 14)?)?,
            common,
                    fill_gradient: None,
            stroke_gradient: None,
        }),
        TAG_CIRCLE => Element::Circle(CircleElem {
            cx: as_f64(at(arr, 7)?)?, cy: as_f64(at(arr, 8)?)?, r: as_f64(at(arr, 9)?)?,
            fill: unpack_fill(at(arr, 10)?)?, stroke: unpack_stroke(at(arr, 11)?)?,
            common,
                    fill_gradient: None,
            stroke_gradient: None,
        }),
        TAG_ELLIPSE => Element::Ellipse(EllipseElem {
            cx: as_f64(at(arr, 7)?)?, cy: as_f64(at(arr, 8)?)?,
            rx: as_f64(at(arr, 9)?)?, ry: as_f64(at(arr, 10)?)?,
            fill: unpack_fill(at(arr, 11)?)?, stroke: unpack_stroke(at(arr, 12)?)?,
            common,
                    fill_gradient: None,
            stroke_gradient: None,
        }),
        TAG_POLYLINE => {
            let points: Vec<(f64, f64)> = as_array(at(arr, 7)?)?.iter()
                .map(|p| { let a = as_array(p)?; Ok((as_f64(at(a, 0)?)?, as_f64(at(a, 1)?)?)) })
                .collect::<Result<Vec<_>, String>>()?;
            Element::Polyline(PolylineElem {
                points,
                fill: unpack_fill(at(arr, 8)?)?, stroke: unpack_stroke(at(arr, 9)?)?,
                common,
                            fill_gradient: None,
                stroke_gradient: None,
            })
        }
        TAG_POLYGON => {
            let points: Vec<(f64, f64)> = as_array(at(arr, 7)?)?.iter()
                .map(|p| { let a = as_array(p)?; Ok((as_f64(at(a, 0)?)?, as_f64(at(a, 1)?)?)) })
                .collect::<Result<Vec<_>, String>>()?;
            Element::Polygon(PolygonElem {
                points,
                fill: unpack_fill(at(arr, 8)?)?, stroke: unpack_stroke(at(arr, 9)?)?,
                common,
                            fill_gradient: None,
                stroke_gradient: None,
            })
        }
        TAG_PATH => {
            let cmds: Vec<PathCommand> = as_array(at(arr, 7)?)?.iter()
                .map(unpack_path_command).collect::<Result<Vec<_>, String>>()?;
            Element::Path(PathElem {
                d: cmds,
                fill: unpack_fill(at(arr, 8)?)?, stroke: unpack_stroke(at(arr, 9)?)?,
                width_points: if arr.len() > 10 { unpack_width_points(at(arr, 10)?)? } else { vec![] },
                common,
                            fill_gradient: None,
                stroke_gradient: None,
                // Path-only trailing slots, after the common extension.
                stroke_brush: tolerant_opt_str(
                    arr.get(tag_base_arity(TAG_PATH) + EXT_STROKE_BRUSH)),
                stroke_brush_overrides: tolerant_opt_str(
                    arr.get(tag_base_arity(TAG_PATH) + EXT_STROKE_BRUSH_OVERRIDES)),
                // Trailing slot 11; absent in pre-fill_rule blobs.
                fill_rule: unpack_fill_rule(arr.get(11)),
            })
        }
        TAG_TEXT => {
            let mut t = TextElem::from_string(
                as_f64(at(arr, 7)?)?, as_f64(at(arr, 8)?)?,
                as_str(at(arr, 9)?)?,
                as_str(at(arr, 10)?)?,
                as_f64(at(arr, 11)?)?,
                as_str(at(arr, 12)?)?,
                as_str(at(arr, 13)?)?,
                as_str(at(arr, 14)?)?,
                as_f64(at(arr, 15)?)?, as_f64(at(arr, 16)?)?,
                unpack_fill(at(arr, 17)?)?, unpack_stroke(at(arr, 18)?)?,
                common,
            );
            // Trailing tspans field overrides the single-default-tspan
            // seeded by from_string. Absent when the blob predates the
            // tspan codec extension (backward compatibility).
            if let Some(tspans_val) = arr.get(19) {
                if let Value::Array(xs) = tspans_val {
                    if !xs.is_empty() {
                        t.tspans = xs.iter().map(unpack_tspan).collect::<Result<Vec<_>, String>>()?;
                    }
                }
            }
            Element::Text(t)
        }
        TAG_TEXT_PATH => {
            let cmds: Vec<PathCommand> = as_array(at(arr, 7)?)?.iter()
                .map(unpack_path_command).collect::<Result<Vec<_>, String>>()?;
            let mut tp = TextPathElem::from_string(
                cmds,
                as_str(at(arr, 8)?)?,
                as_f64(at(arr, 9)?)?,
                as_str(at(arr, 10)?)?,
                as_f64(at(arr, 11)?)?,
                as_str(at(arr, 12)?)?,
                as_str(at(arr, 13)?)?,
                as_str(at(arr, 14)?)?,
                unpack_fill(at(arr, 15)?)?, unpack_stroke(at(arr, 16)?)?,
                common,
            );
            if let Some(tspans_val) = arr.get(17) {
                if let Value::Array(xs) = tspans_val {
                    if !xs.is_empty() {
                        tp.tspans = xs.iter().map(unpack_tspan).collect::<Result<Vec<_>, String>>()?;
                    }
                }
            }
            Element::TextPath(tp)
        }
        TAG_LIVE => {
            let kind = as_str(at(arr, 7)?)?;
            match kind {
                "compound_shape" => {
                    let operation = match as_str(at(arr, 8)?)? {
                        "subtract_front" => crate::geometry::live::CompoundOperation::SubtractFront,
                        "intersection" => crate::geometry::live::CompoundOperation::Intersection,
                        "exclude" => crate::geometry::live::CompoundOperation::Exclude,
                        _ => crate::geometry::live::CompoundOperation::Union,
                    };
                    let operands = as_array(at(arr, 9)?)?.iter()
                        .map(|c| Ok(Rc::new(unpack_element(c)?))).collect::<Result<Vec<_>, String>>()?;
                    Element::Live(crate::geometry::live::LiveVariant::CompoundShape(
                        crate::geometry::live::CompoundShape {
                            operation, operands, fill: None, stroke: None, common,
                        },
                    ))
                }
                "reference" => {
                    let target = crate::geometry::live::ElementRef(as_str(at(arr, 8)?)?.to_string());
                    let mut re = crate::geometry::live::ReferenceElem::new(target, common);
                    // Symbols P4: the instance `transform` rides slot 9, read
                    // TOLERANTLY so existing 9-element .bin (no slot 9) decode
                    // to None (SYMBOLS.md §4 / Fork F2).
                    if let Some(tv) = arr.get(9) {
                        re.transform = unpack_transform(tv)?;
                    }
                    Element::Live(crate::geometry::live::LiveVariant::Reference(re))
                }
                "recorded" => {
                    let inputs: Vec<String> =
                        serde_json::from_str(as_str(at(arr, 8)?)?).unwrap_or_default();
                    let inputs = inputs.into_iter()
                        .map(crate::geometry::live::ElementRef)
                        .collect();
                    let ops = serde_json::from_str(as_str(at(arr, 9)?)?).unwrap_or_default();
                    Element::Live(crate::geometry::live::LiveVariant::Recorded(
                        crate::geometry::live::RecordedElem::new(ops, inputs, common),
                    ))
                }
                "generated" => {
                    let concept_id = as_str(at(arr, 8)?)?.to_string();
                    let params = serde_json::from_str(as_str(at(arr, 9)?)?)
                        .unwrap_or(serde_json::Value::Object(Default::default()));
                    Element::Live(crate::geometry::live::LiveVariant::Generated(
                        crate::geometry::live::GeneratedElem::new(concept_id, params, common),
                    ))
                }
                other => return Err(format!("unknown live kind: {}", other)),
            }
        }
        _ => return Err(format!("unknown element tag: {}", tag)),
    })
}

fn unpack_selection(v: &Value) -> Result<Selection, String> {
    let arr = as_array(v)?;
    arr.iter().map(|item| {
        let item_arr = as_array(item)?;
        let path: ElementPath = as_array(at(item_arr, 0)?)?.iter()
            .map(|i| Ok(as_i64(i)? as usize)).collect::<Result<Vec<_>, String>>()?;
        let kind_val = at(item_arr, 1)?;
        let kind = if kind_val.is_i64() || kind_val.is_u64() {
            // kind == 0 means All
            SelectionKind::All
        } else {
            // kind == [1, ...cps]
            let kind_arr = as_array(kind_val)?;
            let cps: Vec<usize> = kind_arr.get(1..).unwrap_or(&[]).iter()
                .map(|v| Ok(as_i64(v)? as usize)).collect::<Result<Vec<_>, String>>()?;
            SelectionKind::Partial(SortedCps::from_iter(cps))
        };
        Ok(ElementSelection { path, kind })
    }).collect()
}

fn unpack_document(v: &Value) -> Result<Document, String> {
    let arr = as_array(v)?;
    let layers: Vec<Element> = as_array(at(arr, 0)?)?.iter()
        .map(unpack_element).collect::<Result<Vec<_>, String>>()?;
    let selected_layer = as_i64(at(arr, 1)?)? as usize;
    let selection = unpack_selection(at(arr, 2)?)?;
    // Symbols (master store): a trailing element array at index 3. TOLERANT of
    // its absence — existing .bin fixtures predate symbols and decode to an
    // empty store (arr.get(3) is None). Present-but-empty arrays decode the
    // same, so empty-symbols docs round-trip unchanged.
    let symbols: Vec<Element> = match arr.get(3) {
        Some(Value::Array(xs)) => xs.iter().map(unpack_element).collect::<Result<Vec<_>, String>>()?,
        _ => Vec::new(),
    };
    // Binary format predates the artboards feature — parsed docs
    // start with empty artboards. Callers that hand the result to the
    // app (session.rs::load_session) run
    // ensure_artboards_invariant after unpack to satisfy
    // ARTBOARDS.md §At-least-one-artboard invariant; the
    // cross-language round-trip tests intentionally don't (they
    // compare bytes, not semantics).
    Ok(Document {
        layers,
        symbols,
        selected_layer,
        selection,
        artboards: Vec::new(),
        artboard_options: crate::document::artboard::ArtboardOptions::default(),
        document_setup: crate::document::document_setup::DocumentSetup::default(),
        print_preferences: crate::document::print_preferences::PrintPreferences::default(),
    })
}

// -- Public API --------------------------------------------------------------

/// Serialize a Document to the JAS binary format.
///
/// Returns bytes: `[Magic][Version][Flags][Payload]`.
/// The payload is MessagePack, optionally compressed with raw deflate.
pub fn document_to_binary(doc: &Document, compress: bool) -> Vec<u8> {
    let value = pack_document(doc);
    let mut raw = Vec::new();
    rmpv::encode::write_value(&mut raw, &value).expect("msgpack encode failed");

    let (payload, flags): (Vec<u8>, u16) = if compress {
        let mut encoder = DeflateEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(&raw).expect("deflate compress failed");
        let compressed = encoder.finish().expect("deflate finish failed");
        (compressed, COMPRESS_DEFLATE)
    } else {
        (raw, COMPRESS_NONE)
    };

    let mut out: Vec<u8> = Vec::with_capacity(HEADER_SIZE + payload.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&flags.to_le_bytes());
    out.extend_from_slice(&payload);
    out
}

/// Deserialize a Document from the JAS binary format.
///
/// Returns `Err` on invalid magic, unsupported version, or
/// unsupported compression method.
pub fn binary_to_document(data: &[u8]) -> Result<Document, String> {
    if data.len() < HEADER_SIZE {
        return Err(format!("data too short: {} bytes, need at least {}", data.len(), HEADER_SIZE));
    }

    if &data[..4] != MAGIC {
        return Err(format!("invalid magic: {:?}", &data[..4]));
    }

    let version = u16::from_le_bytes([data[4], data[5]]);
    if version > VERSION {
        return Err(format!("unsupported version: {}, max supported is {}", version, VERSION));
    }
    if version < MIN_VERSION {
        // v1 used a different positional layout (no generic name/id slots);
        // a clean break, not forward-readable. See the VERSION comment.
        return Err(format!("unsupported legacy version: {}, min supported is {}", version, MIN_VERSION));
    }

    let flags = u16::from_le_bytes([data[6], data[7]]);
    let compression = flags & 0x03;
    let payload_bytes = &data[HEADER_SIZE..];

    let raw = match compression {
        COMPRESS_NONE => payload_bytes.to_vec(),
        COMPRESS_DEFLATE => {
            let mut decoder = DeflateDecoder::new(payload_bytes);
            let mut decompressed = Vec::new();
            decoder.read_to_end(&mut decompressed)
                .map_err(|e| format!("deflate decompress failed: {}", e))?;
            decompressed
        }
        _ => return Err(format!("unsupported compression method: {}", compression)),
    };

    let value = rmpv::decode::read_value(&mut &raw[..])
        .map_err(|e| format!("msgpack decode failed: {}", e))?;

    // Enforce the unique-id invariant on import (first-pre-order-wins);
    // a no-op for well-formed (unique-id) documents. See REFERENCE_GRAPH.md §2.5.
    Ok(crate::geometry::normalize::dedupe_element_ids(&unpack_document(&value)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(payload_value: &Value) -> Vec<u8> {
        // Wrap a msgpack Value in a valid, current-version, uncompressed header.
        let mut raw = Vec::new();
        rmpv::encode::write_value(&mut raw, payload_value).unwrap();
        let mut blob = Vec::new();
        blob.extend_from_slice(MAGIC);
        blob.extend_from_slice(&VERSION.to_le_bytes());
        blob.extend_from_slice(&0u16.to_le_bytes()); // flags: COMPRESS_NONE
        blob.extend_from_slice(&raw);
        blob
    }

    /// A blob with a valid header + version whose msgpack payload DECODES but
    /// has the wrong internal structure must return Err, not panic. On wasm a
    /// panic aborts the whole module (no catch_unwind), and since save_session
    /// loads from localStorage on every startup, a single corrupt entry would
    /// otherwise brick the app on every load. Regression guard for #8.
    ///
    /// Swift's side of this contract is
    /// JasSwift/Tests/Geometry/BinaryMalformedBlobTests.swift, which covers the
    /// whole decoder rather than the three cases below. It was written in
    /// 2026-07-27 after an audit found that JasSwift's decoder TRAPPED (16
    /// `fatalError` sites, 10 of them on the decode path) where this port
    /// returns `Err` — and that JasSwift's `Session.swift` reads a
    /// `tabN.jasbin` from disk on every cold launch, so the divergence was a
    /// launch abort, not a test-only concern.
    ///
    /// Two hardening rules that port needed and this one gets for free from
    /// rmpv, noted so a hand-rolled reader here would not lose them:
    /// rmpv does not preallocate on an array length prefix (issue 151), and it
    /// enforces `rmpv::decode::MAX_DEPTH == 1024`. JasSwift now does both.
    #[test]
    fn malformed_but_decodable_blob_errors_not_panics() {
        // (1) Top-level shape wrong: [0] should be an array of elements.
        let wrong_shape = Value::Array(vec![
            Value::from(0i64),      // expected: array of elements
            Value::from(0i64),
            Value::Array(vec![]),
        ]);
        assert!(
            binary_to_document(&frame(&wrong_shape)).is_err(),
            "wrong-shape payload should Err, not panic"
        );

        // (2) A structurally-plausible document whose single element array is
        // too short — exercises the bounds-checked `at()` inside unpack_common
        // (index 3 missing) where a raw arr[3] would have panicked.
        let short_element = Value::Array(vec![
            Value::Array(vec![Value::Array(vec![Value::from(TAG_RECT)])]), // layers: [ [TAG_RECT] ]
            Value::from(0i64),
            Value::Array(vec![]),
        ]);
        assert!(
            binary_to_document(&frame(&short_element)).is_err(),
            "too-short element should Err, not panic"
        );

        // (3) Unknown element tag must Err, not panic.
        let bad_tag = Value::Array(vec![
            Value::Array(vec![Value::Array(vec![
                Value::from(9999i64), Value::from(false), Value::from(1.0f64),
                Value::from(2i64), Value::Nil, Value::Nil, Value::Nil,
            ])]),
            Value::from(0i64),
            Value::Array(vec![]),
        ]);
        assert!(
            binary_to_document(&frame(&bad_tag)).is_err(),
            "unknown element tag should Err, not panic"
        );
    }

    // ------------------------------------------------------------------
    // fill_rule across the binary boundary (transcripts/BOOLEAN.md)
    //
    // Twin of JasSwift Tests/Geometry/BinaryFillRuleTests.swift. The two
    // ports must produce BYTE-IDENTICAL blobs, so the encoding is pinned
    // here as a positional index and a tag value, not just as a
    // round-trip.
    // ------------------------------------------------------------------

    fn donut_commands() -> Vec<PathCommand> {
        vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 0.0 },
            PathCommand::LineTo { x: 100.0, y: 100.0 },
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 25.0, y: 25.0 },
            PathCommand::LineTo { x: 75.0, y: 25.0 },
            PathCommand::LineTo { x: 75.0, y: 75.0 },
            PathCommand::ClosePath,
        ]
    }

    fn donut_doc(rule: FillRule) -> Document {
        let path = Element::Path(PathElem {
            d: donut_commands(),
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            width_points: vec![],
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
            fill_rule: rule,
            stroke_brush: None,
            stroke_brush_overrides: None,
        });
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(path)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        Document { layers: vec![layer], selected_layer: 0, ..Document::default() }
    }

    fn first_path_rule(doc: &Document) -> FillRule {
        match &*doc.layers[0].children().unwrap()[0] {
            Element::Path(p) => p.fill_rule,
            other => panic!("expected Path, got {other:?}"),
        }
    }

    #[test]
    fn binary_round_trips_even_odd_fill_rule() {
        for rule in [FillRule::NonZero, FillRule::EvenOdd] {
            let doc = donut_doc(rule);
            let blob = document_to_binary(&doc, true);
            let back = binary_to_document(&blob).expect("decode");
            assert_eq!(first_path_rule(&back), rule,
                       "binary dropped the declared fill rule {rule:?}");
        }
    }

    /// The wire encoding, pinned exactly: TAG_PATH slot 11 is an integer
    /// 0 = NonZero, 1 = EvenOdd, ALWAYS written. Swift's twin asserts the
    /// same slot and the same tag values, which is what makes the two
    /// ports byte-identical rather than merely both-correct.
    #[test]
    fn binary_fill_rule_is_path_slot_11() {
        for (rule, want) in [(FillRule::NonZero, 0i64), (FillRule::EvenOdd, 1i64)] {
            // Pack uncompressed so the payload is directly decodable.
            let blob = document_to_binary(&donut_doc(rule), false);
            let mut cursor = &blob[HEADER_SIZE..];
            let payload = rmpv::decode::read_value(&mut cursor).expect("msgpack");
            let Value::Array(top) = &payload else { panic!("payload not an array") };
            let Value::Array(layers) = &top[0] else { panic!("layers not an array") };
            let Value::Array(layer) = &layers[0] else { panic!("layer not an array") };
            // Layer children ride slot 7 of TAG_LAYER.
            let Value::Array(children) = &layer[7] else { panic!("children not an array") };
            let Value::Array(path) = &children[0] else { panic!("path not an array") };
            assert_eq!(path[0].as_i64(), Some(TAG_PATH));
            assert_eq!(path.len(), tag_base_arity(TAG_PATH) + COMMON_EXT_LEN + 2,
                       "TAG_PATH should carry its base arity (fill_rule last, slot 11) \
                        plus the trailing common extension and the two brush slots");
            assert_eq!(path[11].as_i64(), Some(want),
                       "fill_rule tag for {rule:?} should be {want}");
        }
    }

    /// Documents written before fill_rule joined the codec have only 11
    /// TAG_PATH slots. They MUST still load — the field is appended, not
    /// versioned, exactly as width_points (slot 10) and Text's tspans
    /// (slot 19) were before it. Nothing on disk is orphaned and the
    /// header stays at v2, so the frozen Python writer's blobs and ours
    /// remain mutually readable.
    #[test]
    fn binary_without_fill_rule_slot_still_loads_as_non_zero() {
        let blob = document_to_binary(&donut_doc(FillRule::EvenOdd), false);
        let mut cursor = &blob[HEADER_SIZE..];
        let payload = rmpv::decode::read_value(&mut cursor).expect("msgpack");
        // Truncate the path element back to its pre-fill_rule 11 slots.
        let Value::Array(mut top) = payload else { panic!("payload not an array") };
        let Value::Array(mut layers) = top[0].clone() else { panic!() };
        let Value::Array(mut layer) = layers[0].clone() else { panic!() };
        let Value::Array(mut children) = layer[7].clone() else { panic!() };
        let Value::Array(mut path) = children[0].clone() else { panic!() };
        assert_eq!(path.len(), tag_base_arity(TAG_PATH) + COMMON_EXT_LEN + 2);
        path.truncate(11);
        children[0] = Value::Array(path);
        layer[7] = Value::Array(children);
        layers[0] = Value::Array(layer);
        top[0] = Value::Array(layers);
        let old = binary_to_document(&frame(&Value::Array(top))).expect("old blob must load");
        assert_eq!(first_path_rule(&old), FillRule::NonZero,
                   "an absent fill_rule slot must read as the app default");
    }

    /// The header is NOT bumped by the fill_rule append: a version bump
    /// would make the frozen reference port (VERSION = 2, rejects
    /// version > VERSION) unable to read anything we write.
    #[test]
    fn binary_version_header_stays_at_two() {
        assert_eq!(VERSION, 2);
        assert_eq!(MIN_VERSION, 2);
        let blob = document_to_binary(&donut_doc(FillRule::EvenOdd), false);
        assert_eq!(u16::from_le_bytes([blob[4], blob[5]]), 2,
                   "fill_rule must ride a trailing slot, not a new version");
    }

    /// The uncompressed blob for `donut_doc`, byte for byte. JasSwift's
    /// twin asserts these SAME literals, which is what makes "the two
    /// ports are byte-identical" a checked statement rather than a
    /// claim. The two differ in exactly one byte — the fill-rule tag.
    ///
    /// To regenerate after an intentional codec change: print
    /// `document_to_binary(&donut_doc(rule), false)` as hex and update
    /// BOTH ports.
    const DONUT_NON_ZERO_HEX: &str = "4a4153000200000094919b00c2cb3ff000000000000002c0c0c091dc001107c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c00000c0c0c0c000c0c0009090";
    const DONUT_EVEN_ODD_HEX: &str = "4a4153000200000094919b00c2cb3ff000000000000002c0c0c091dc001107c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c00100c0c0c0c000c0c0009090";
    /// The SAME document as written BEFORE the per-tag common extension
    /// (RULED 2026-07-27) joined the codec: TAG_LAYER carries 8 slots (0x98)
    /// and TAG_PATH 12 (0x9c), with no mode / mask / tool_origin /
    /// stroke_brush / stroke_brush_overrides tail. These were the pinned
    /// literals up to that commit, kept verbatim -- the tolerant-read
    /// contract is only worth something if it is checked against REAL old
    /// bytes rather than bytes the current writer reconstructed.
    const DONUT_PRE_EXT_NON_ZERO_HEX: &str = "4a4153000200000094919800c2cb3ff000000000000002c0c0c0919c07c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c000009090";
    const DONUT_PRE_EXT_EVEN_ODD_HEX: &str = "4a4153000200000094919800c2cb3ff000000000000002c0c0c0919c07c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c001009090";
    /// The same document as written BEFORE fill_rule joined the codec:
    /// the TAG_PATH array header is 0x9b (11 slots) instead of 0x9c (12)
    /// and the trailing tag byte is gone. Kept as a literal so the
    /// old-format read path is pinned against real bytes, not against a
    /// value we reconstructed with the current writer.
    const DONUT_PRE_FILL_RULE_HEX: &str = "4a4153000200000094919800c2cb3ff000000000000002c0c0c0919b07c2cb3ff000000000000002c0c0c0989300cb0000000000000000cb00000000000000009301cb4059000000000000cb00000000000000009301cb4059000000000000cb405900000000000091079300cb4039000000000000cb40390000000000009301cb4052c00000000000cb40390000000000009301cb4052c00000000000cb4052c000000000009107929600cb0000000000000000cb0000000000000000cb0000000000000000cb0000000000000000cb3ff0000000000000cb3ff0000000000000c0c0009090";

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len() / 2)
            .map(|i| u8::from_str_radix(&s[i * 2..i * 2 + 2], 16).unwrap())
            .collect()
    }

    /// Regeneration helper for the pinned literals above, after an
    /// INTENTIONAL codec change. Run with:
    ///   cargo test print_pinned_binary_hex -- --ignored --nocapture
    /// then paste each line into BOTH ports.
    #[test]
    #[ignore]
    fn print_pinned_binary_hex() {
        println!("DONUT_NON_ZERO_HEX = {}",
                 hex(&document_to_binary(&donut_doc(FillRule::NonZero), false)));
        println!("DONUT_EVEN_ODD_HEX = {}",
                 hex(&document_to_binary(&donut_doc(FillRule::EvenOdd), false)));
    }

    #[test]
    fn binary_bytes_are_pinned_for_both_fill_rules() {
        assert_eq!(hex(&document_to_binary(&donut_doc(FillRule::NonZero), false)),
                   DONUT_NON_ZERO_HEX);
        assert_eq!(hex(&document_to_binary(&donut_doc(FillRule::EvenOdd), false)),
                   DONUT_EVEN_ODD_HEX);
        // Exactly one byte of difference: the appended tag.
        let a = unhex(DONUT_NON_ZERO_HEX);
        let b = unhex(DONUT_EVEN_ODD_HEX);
        assert_eq!(a.len(), b.len());
        let diffs: Vec<usize> = (0..a.len()).filter(|&i| a[i] != b[i]).collect();
        assert_eq!(diffs.len(), 1, "the rule must cost exactly one byte");
    }

    /// A PRE-EXTENSION blob (8 layer slots, 12 path slots) with the
    /// fill-rule slot's `00` replaced by `slot_hex`. Built from the
    /// PRE-fill_rule literal so the splice point is derived from real bytes
    /// rather than an index counted by hand: bump the TAG_PATH array header
    /// from 11 slots to 12, then insert the slot just before the document's
    /// trailing `selected_layer` + two empty arrays. Twin of JasSwift's
    /// `donutWithFillRuleSlot`.
    fn donut_with_fill_rule_slot(slot_hex: &str) -> Vec<u8> {
        let tail = "009090";
        let head = DONUT_PRE_FILL_RULE_HEX.replace("919b07", "919c07");
        let body = &head[..head.len() - tail.len()];
        unhex(&format!("{body}{slot_hex}{tail}"))
    }

    /// The splice reproduces the PRE-EXTENSION writer exactly, which is what
    /// makes the tolerance vectors below statements about a format that
    /// really existed on disk rather than about a string we assembled.
    #[test]
    fn fill_rule_slot_splice_matches_the_pre_extension_writer() {
        assert_eq!(hex(&donut_with_fill_rule_slot("00")), DONUT_PRE_EXT_NON_ZERO_HEX);
        assert_eq!(hex(&donut_with_fill_rule_slot("01")), DONUT_PRE_EXT_EVEN_ODD_HEX);
    }

    /// A pre-extension blob loads with the fill rule it was written with AND
    /// the documented defaults for every extension slot -- the tolerant read
    /// checked against real old bytes, not a reconstruction.
    #[test]
    fn binary_reads_a_pre_extension_blob() {
        for (literal, rule) in [(DONUT_PRE_EXT_NON_ZERO_HEX, FillRule::NonZero),
                                (DONUT_PRE_EXT_EVEN_ODD_HEX, FillRule::EvenOdd)] {
            let doc = binary_to_document(&unhex(literal))
                .expect("a pre-extension blob must still load");
            assert_eq!(first_path_rule(&doc), rule);
            let p = match &*doc.layers[0].children().unwrap()[0] {
                Element::Path(p) => p.clone(),
                other => panic!("expected Path, got {other:?}"),
            };
            assert_eq!(p.common.mode, BlendMode::Normal);
            assert_eq!(p.common.mask, None);
            assert_eq!(p.common.tool_origin, None);
            assert_eq!(p.stroke_brush, None);
            assert_eq!(p.stroke_brush_overrides, None);
            assert_eq!(doc.layers[0].common().mode, BlendMode::Normal);
            // Geometry, so the row above is not a statement about a husk.
            assert_eq!(p.d.len(), 8);
        }
    }

    /// A fill-rule slot that is not the exact EvenOdd integer tag must read
    /// as NonZero without panicking -- the standing
    /// `malformed_but_decodable_blob_errors_not_panics` contract, applied
    /// to this slot. Rust already behaved this way; the pin exists because
    /// JasSwift did NOT (its `asInt` called `fatalError` on nil / string /
    /// array and truncated a float), and this is the statement the two
    /// ports now have to keep agreeing on. Twin of JasSwift's
    /// `binaryToleratesAMalformedFillRuleSlot`.
    #[test]
    fn binary_tolerates_a_malformed_fill_rule_slot() {
        for (label, slot_hex) in [
            ("msgpack nil", "c0"),
            ("a string", "a178"),
            ("an empty array", "90"),
            ("a float64 1.0", "cb3ff0000000000000"),
            ("an out-of-range tag", "07"),
        ] {
            let doc = binary_to_document(&donut_with_fill_rule_slot(slot_hex))
                .unwrap_or_else(|e| panic!("{label} should still load: {e}"));
            assert_eq!(
                first_path_rule(&doc), FillRule::NonZero,
                "a fill-rule slot holding {label} must read as NonZero"
            );
            match &*doc.layers[0].children().unwrap()[0] {
                Element::Path(p) => assert_eq!(p.d.len(), 8, "{label} lost the geometry"),
                other => panic!("expected Path for {label}, got {other:?}"),
            }
        }
    }

    // ------------------------------------------------------------------
    // The per-tag trailing common extension (RULED 2026-07-27, see
    // transcripts/EDIT_SEMANTICS_FREEZE.md): `common.mode`, `common.mask`
    // and `common.tool_origin` were dropped by the codec in both ports --
    // save as binary, reload, gone -- and `stroke_brush` /
    // `stroke_brush_overrides` with them on Path. A round trip speaks to
    // NOTHING, so it must preserve EVERYTHING.
    //
    // Twins, per test, because this block's tests live in TWO Swift files and
    // an earlier one-line "Twins in BinaryCommonExtensionTests.swift" named a
    // file that held no twin of the last two:
    //
    //   binary_round_trips_the_path_common_extension
    //   binary_round_trips_the_common_extension_on_every_tag
    //       -> JasSwift/Tests/Geometry/BinaryCommonExtensionTests.swift
    //   binary_without_the_common_extension_still_loads
    //       -> aPreExtensionBlobStillLoads
    //   binary_tolerates_malformed_common_extension_slots
    //       -> toleratedExtensionSlotsStayTolerated
    //       (both in JasSwift/Tests/Geometry/BinaryMalformedBlobTests.swift)
    // ------------------------------------------------------------------

    /// A Path carrying every field of the extension at a non-default value.
    fn ext_path() -> PathElem {
        PathElem {
            d: donut_commands(),
            fill: Some(Fill::new(Color::BLACK)),
            stroke: None,
            width_points: vec![],
            common: CommonProps {
                mode: BlendMode::Multiply,
                mask: Some(Box::new(Mask {
                    subtree: Box::new(Element::Rect(RectElem {
                        x: 1.0, y: 2.0, width: 3.0, height: 4.0, rx: 0.0, ry: 0.0,
                        fill: Some(Fill::new(Color::Rgb { r: 1.0, g: 1.0, b: 1.0, a: 1.0 })),
                        stroke: None,
                        common: CommonProps::default(),
                        fill_gradient: None,
                        stroke_gradient: None,
                    })),
                    clip: true,
                    invert: true,
                    disabled: false,
                    linked: false,
                    unlink_transform: Some(Transform {
                        a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 9.0, f: 9.0,
                    }),
                })),
                tool_origin: Some("blob_brush".to_string()),
                ..CommonProps::default()
            },
            fill_gradient: None,
            stroke_gradient: None,
            fill_rule: FillRule::EvenOdd,
            stroke_brush: Some("basic/calligraphic_5".to_string()),
            stroke_brush_overrides: Some("{\"angle\":30}".to_string()),
        }
    }

    fn doc_with(elem: Element) -> Document {
        let layer = Element::Layer(LayerElem {
            children: vec![Rc::new(elem)],
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps::default(),
        });
        Document { layers: vec![layer], selected_layer: 0, ..Document::default() }
    }

    fn first_child(doc: &Document) -> Element {
        (*doc.layers[0].children().unwrap()[0]).clone()
    }

    /// The whole extension, on the one kind that carries all five fields.
    #[test]
    fn binary_round_trips_the_path_common_extension() {
        let before = ext_path();
        let doc = doc_with(Element::Path(before.clone()));
        let back = binary_to_document(&document_to_binary(&doc, true)).expect("decode");
        let after = match first_child(&back) {
            Element::Path(p) => p,
            other => panic!("expected Path, got {other:?}"),
        };
        assert_eq!(after.common.mode, before.common.mode, "binary dropped common.mode");
        assert_eq!(after.common.mask, before.common.mask, "binary dropped common.mask");
        assert_eq!(after.common.tool_origin, before.common.tool_origin,
                   "binary dropped common.tool_origin");
        assert_eq!(after.stroke_brush, before.stroke_brush, "binary dropped stroke_brush");
        assert_eq!(after.stroke_brush_overrides, before.stroke_brush_overrides,
                   "binary dropped stroke_brush_overrides");
        // Field-list-free batteries are structurally blind to geometry, so
        // one GEOMETRY-VALUE assertion rides with the field list.
        assert_eq!(after.d, before.d, "the extension cost the path its geometry");
        assert_eq!(after.fill_rule, FillRule::EvenOdd);
    }

    /// The three common fields belong to EVERY tag, not just Path: the
    /// extension is per-tag precisely because `unpack_common` reads fixed
    /// indices. One representative of each tag, each carrying all three.
    #[test]
    fn binary_round_trips_the_common_extension_on_every_tag() {
        let mode = BlendMode::HardLight;
        let mask = Some(Box::new(Mask {
            subtree: Box::new(Element::Circle(CircleElem {
                cx: 1.0, cy: 2.0, r: 3.0,
                fill: Some(Fill::new(Color::BLACK)),
                stroke: None,
                common: CommonProps::default(),
                fill_gradient: None,
                stroke_gradient: None,
            })),
            clip: false,
            invert: true,
            disabled: true,
            linked: false,
            unlink_transform: None,
        }));
        let common = CommonProps {
            mode,
            mask: mask.clone(),
            tool_origin: Some("blob_brush".to_string()),
            ..CommonProps::default()
        };
        for elem in every_tag_elements(&common) {
            let tag_label = element_tag_label(&elem);
            let doc = doc_with(elem.clone());
            let back = binary_to_document(&document_to_binary(&doc, false))
                .unwrap_or_else(|e| panic!("{tag_label}: decode failed: {e}"));
            let after = first_child(&back);
            assert_eq!(after.common().mode, mode, "{tag_label} dropped common.mode");
            assert_eq!(after.common().mask, mask, "{tag_label} dropped common.mask");
            assert_eq!(after.common().tool_origin, Some("blob_brush".to_string()),
                       "{tag_label} dropped common.tool_origin");
        }
        // The wrapping Layer carries the extension too -- it is the one tag
        // the loop above cannot reach as a child.
        let mut lc = common.clone();
        lc.name = Some("Layer 1".to_string());
        let doc = Document {
            layers: vec![Element::Layer(LayerElem {
                children: vec![], isolated_blending: false, knockout_group: false, common: lc,
            })],
            selected_layer: 0,
            ..Document::default()
        };
        let back = binary_to_document(&document_to_binary(&doc, false)).expect("decode");
        assert_eq!(back.layers[0].common().mode, mode, "TAG_LAYER dropped common.mode");
        assert_eq!(back.layers[0].common().mask, mask, "TAG_LAYER dropped common.mask");
        assert_eq!(back.layers[0].common().tool_origin, Some("blob_brush".to_string()),
                   "TAG_LAYER dropped common.tool_origin");
    }

    /// One element per element TAG, each wearing `common`. Group and Layer
    /// appear as children so the loop reaches every tag except the document
    /// root (asserted separately).
    fn every_tag_elements(common: &CommonProps) -> Vec<Element> {
        use crate::geometry::live::*;
        vec![
            Element::Line(LineElem {
                x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0, stroke: None, width_points: vec![],
                common: common.clone(), stroke_gradient: None,
            }),
            Element::Rect(RectElem {
                x: 0.0, y: 0.0, width: 1.0, height: 2.0, rx: 0.0, ry: 0.0,
                fill: None, stroke: None, common: common.clone(),
                fill_gradient: None, stroke_gradient: None,
            }),
            Element::Circle(CircleElem {
                cx: 0.0, cy: 0.0, r: 1.0, fill: None, stroke: None,
                common: common.clone(), fill_gradient: None, stroke_gradient: None,
            }),
            Element::Ellipse(EllipseElem {
                cx: 0.0, cy: 0.0, rx: 1.0, ry: 2.0, fill: None, stroke: None,
                common: common.clone(), fill_gradient: None, stroke_gradient: None,
            }),
            Element::Polyline(PolylineElem {
                points: vec![(0.0, 0.0), (1.0, 1.0)], fill: None, stroke: None,
                common: common.clone(), fill_gradient: None, stroke_gradient: None,
            }),
            Element::Polygon(PolygonElem {
                points: vec![(0.0, 0.0), (1.0, 1.0), (2.0, 0.0)], fill: None, stroke: None,
                common: common.clone(), fill_gradient: None, stroke_gradient: None,
            }),
            Element::Path(PathElem {
                d: donut_commands(), fill: None, stroke: None, width_points: vec![],
                common: common.clone(), fill_gradient: None, stroke_gradient: None,
                fill_rule: FillRule::NonZero, stroke_brush: None, stroke_brush_overrides: None,
            }),
            Element::Text(TextElem::from_string(
                1.0, 2.0, "hi", "Arial", 12.0, "normal", "normal", "none", 10.0, 12.0,
                None, None, common.clone())),
            Element::TextPath(TextPathElem::from_string(
                donut_commands(), "hi", 0.0, "Arial", 12.0, "normal", "normal", "none",
                None, None, common.clone())),
            Element::Group(GroupElem {
                children: vec![], isolated_blending: false, knockout_group: false,
                common: common.clone(),
            }),
            Element::Live(LiveVariant::CompoundShape(CompoundShape {
                operation: CompoundOperation::Union, operands: vec![], fill: None, stroke: None,
                common: common.clone(),
            })),
            Element::Live(LiveVariant::Reference(
                ReferenceElem::new(ElementRef("m1".to_string()), common.clone()))),
            Element::Live(LiveVariant::Recorded(
                RecordedElem::new(vec![], vec![], common.clone()))),
            Element::Live(LiveVariant::Generated(
                GeneratedElem::new("spiral".to_string(),
                                   serde_json::Value::Object(Default::default()),
                                   common.clone()))),
        ]
    }

    /// A blob written BEFORE the extension existed has only the tag's base
    /// arity, and must still load -- the same tolerant-read contract the
    /// fill_rule slot earned, applied to five more slots at once.
    #[test]
    fn binary_without_the_common_extension_still_loads() {
        let doc = doc_with(Element::Path(ext_path()));
        let blob = document_to_binary(&doc, false);
        let mut cursor = &blob[HEADER_SIZE..];
        let payload = rmpv::decode::read_value(&mut cursor).expect("msgpack");
        let Value::Array(mut top) = payload else { panic!("payload not an array") };
        let Value::Array(mut layers) = top[0].clone() else { panic!() };
        let Value::Array(mut layer) = layers[0].clone() else { panic!() };
        let Value::Array(mut children) = layer[7].clone() else { panic!() };
        let Value::Array(mut path) = children[0].clone() else { panic!() };
        assert_eq!(path.len(), tag_base_arity(TAG_PATH) + COMMON_EXT_LEN + 2,
                   "TAG_PATH should carry its base arity plus the extension");
        // Truncate BOTH the path and its enclosing layer back to their
        // pre-extension arities.
        path.truncate(tag_base_arity(TAG_PATH));
        children[0] = Value::Array(path);
        layer[7] = Value::Array(children);
        layer.truncate(tag_base_arity(TAG_LAYER));
        layers[0] = Value::Array(layer);
        top[0] = Value::Array(layers);
        let old = binary_to_document(&frame(&Value::Array(top)))
            .expect("a pre-extension blob must still load");
        let p = match first_child(&old) {
            Element::Path(p) => p,
            other => panic!("expected Path, got {other:?}"),
        };
        assert_eq!(p.common.mode, BlendMode::Normal, "an absent mode slot reads as Normal");
        assert_eq!(p.common.mask, None, "an absent mask slot reads as None");
        assert_eq!(p.common.tool_origin, None, "an absent tool_origin slot reads as None");
        assert_eq!(p.stroke_brush, None);
        assert_eq!(p.stroke_brush_overrides, None);
        // And the document is otherwise intact, not a default-shaped husk.
        assert_eq!(p.d.len(), 8, "the old blob lost its geometry");
        assert_eq!(p.fill_rule, FillRule::EvenOdd, "the old blob lost its fill rule");
    }

    /// Garbage in any extension slot must read as the documented default
    /// without panicking -- the standing
    /// `malformed_but_decodable_blob_errors_not_panics` contract extended to
    /// the new slots.
    #[test]
    fn binary_tolerates_malformed_common_extension_slots() {
        let doc = doc_with(Element::Path(ext_path()));
        let blob = document_to_binary(&doc, false);
        let mut cursor = &blob[HEADER_SIZE..];
        let payload = rmpv::decode::read_value(&mut cursor).expect("msgpack");
        let base = tag_base_arity(TAG_PATH);
        for (label, junk) in [
            ("a string", Value::String("nope".into())),
            ("an empty array", Value::Array(vec![])),
            ("a float", Value::F64(1.5)),
            ("a bool", Value::Boolean(true)),
        ] {
            for slot in base..base + COMMON_EXT_LEN + 2 {
                let Value::Array(mut top) = payload.clone() else { panic!() };
                let Value::Array(mut layers) = top[0].clone() else { panic!() };
                let Value::Array(mut layer) = layers[0].clone() else { panic!() };
                let Value::Array(mut children) = layer[7].clone() else { panic!() };
                let Value::Array(mut path) = children[0].clone() else { panic!() };
                path[slot] = junk.clone();
                children[0] = Value::Array(path);
                layer[7] = Value::Array(children);
                layers[0] = Value::Array(layer);
                top[0] = Value::Array(layers);
                let doc = binary_to_document(&frame(&Value::Array(top)))
                    .unwrap_or_else(|e| panic!("{label} in slot {slot} should still load: {e}"));
                match first_child(&doc) {
                    Element::Path(p) => assert_eq!(p.d.len(), 8,
                        "{label} in slot {slot} lost the geometry"),
                    other => panic!("expected Path, got {other:?}"),
                }
            }
        }
    }

    /// Every tspan override field survives the binary codec. This port always
    /// wrote all 51 slots, so this test was GREEN the day it was written -- it
    /// exists as the twin of `binaryRoundTripsASaturatedTspan` in
    /// JasSwift/Tests/Geometry/BinaryTspanTests.swift, which was RED: JasSwift's
    /// `packTspan` wrote only 22 slots and its `unpackTspan` read only 22, so
    /// that port dropped 29 tspan fields on a round trip. Found 2026-07-27 by
    /// the byte-level wire gate. Keeping a twin here is what stops the two
    /// ports drifting apart at this payload again in the other direction.
    #[test]
    fn binary_round_trips_a_saturated_tspan() {
        use crate::geometry::tspan::Tspan;
        let before = Tspan {
            id: 7,
            content: "hi".to_string(),
            baseline_shift: Some(1.5), dx: Some(2.5),
            font_family: Some("Georgia".to_string()), font_size: Some(13.5),
            font_style: Some("italic".to_string()),
            font_variant: Some("small-caps".to_string()),
            font_weight: Some("700".to_string()),
            jas_aa_mode: Some("crisp".to_string()), jas_fractional_widths: Some(true),
            jas_kerning_mode: Some("optical".to_string()), jas_no_break: Some(true),
            jas_role: Some("paragraph".to_string()),
            jas_left_indent: Some(3.5), jas_right_indent: Some(4.5),
            jas_hyphenate: Some(true), jas_hanging_punctuation: Some(true),
            jas_list_style: Some("disc".to_string()),
            text_align: Some("justify".to_string()),
            text_align_last: Some("right".to_string()),
            text_indent: Some(5.5),
            jas_space_before: Some(6.5), jas_space_after: Some(7.5),
            jas_word_spacing_min: Some(8.5), jas_word_spacing_desired: Some(9.5),
            jas_word_spacing_max: Some(10.5),
            jas_letter_spacing_min: Some(11.5), jas_letter_spacing_desired: Some(12.5),
            jas_letter_spacing_max: Some(13.5),
            jas_glyph_scaling_min: Some(14.5), jas_glyph_scaling_desired: Some(15.5),
            jas_glyph_scaling_max: Some(16.5),
            jas_auto_leading: Some(17.5),
            jas_single_word_justify: Some("center".to_string()),
            jas_hyphenate_min_word: Some(18.5), jas_hyphenate_min_before: Some(19.5),
            jas_hyphenate_min_after: Some(20.5), jas_hyphenate_limit: Some(21.5),
            jas_hyphenate_zone: Some(22.5), jas_hyphenate_bias: Some(23.5),
            jas_hyphenate_capitalized: Some(true),
            letter_spacing: Some(24.5), line_height: Some(25.5),
            rotate: Some(26.5), style_name: Some("Heading".to_string()),
            text_decoration: Some(vec!["underline".to_string(), "overline".to_string()]),
            text_rendering: Some("geometricPrecision".to_string()),
            text_transform: Some("uppercase".to_string()),
            transform: Some(Transform { a: 2.0, b: 0.0, c: 0.0, d: 3.0, e: 5.0, f: 7.0 }),
            xml_lang: Some("fr".to_string()),
        };
        let mut text = TextElem::from_string(
            1.0, 2.0, "hi", "Arial", 12.0, "normal", "normal", "none", 0.0, 0.0,
            None, None, CommonProps::default());
        text.tspans = vec![before.clone()];
        let doc = doc_with(Element::Text(text));
        let back = binary_to_document(&document_to_binary(&doc, true)).expect("decode");
        let t = match first_child(&back) {
            Element::Text(t) => t,
            other => panic!("expected Text, got {other:?}"),
        };
        assert_eq!(t.tspans.len(), 1);
        assert_eq!(t.tspans[0], before, "binary dropped at least one tspan field");
        // Geometry, so a whole-struct comparison is not the only statement.
        assert_eq!(t.x, 1.0);
        assert_eq!(t.y, 2.0);
    }

    #[test]
    fn binary_reads_a_pre_fill_rule_blob() {
        let doc = binary_to_document(&unhex(DONUT_PRE_FILL_RULE_HEX))
            .expect("a pre-fill_rule blob must still load");
        assert_eq!(first_path_rule(&doc), FillRule::NonZero);
        // And it is otherwise the same document, so the read path is not
        // just returning a default-shaped husk.
        assert_eq!(doc.layers[0].children().unwrap().len(), 1);
        match &*doc.layers[0].children().unwrap()[0] {
            Element::Path(p) => assert_eq!(p.d.len(), 8),
            other => panic!("expected Path, got {other:?}"),
        }
    }
}
