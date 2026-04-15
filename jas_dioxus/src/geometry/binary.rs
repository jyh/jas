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
pub const VERSION: u16 = 1;
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

// Path command tags.
const CMD_MOVE_TO: i64 = 0;
const CMD_LINE_TO: i64 = 1;
const CMD_CURVE_TO: i64 = 2;
const CMD_SMOOTH_CURVE_TO: i64 = 3;
const CMD_QUAD_TO: i64 = 4;
const CMD_SMOOTH_QUAD_TO: i64 = 5;
const CMD_ARC_TO: i64 = 6;
const CMD_CLOSE_PATH: i64 = 7;

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
            Value::Array(vec![
                pack_color(&s.color), vf64(s.width), vint(cap), vint(join), vf64(s.opacity),
            ])
        }
    }
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

fn pack_common(c: &CommonProps) -> (Value, Value, Value, Value) {
    let vis = match c.visibility {
        Visibility::Invisible => 0,
        Visibility::Outline => 1,
        Visibility::Preview => 2,
    };
    (vbool(c.locked), vf64(c.opacity), vint(vis), pack_transform(&c.transform))
}

fn pack_element(elem: &Element) -> Value {
    match elem {
        Element::Layer(e) => {
            let (locked, opacity, vis, xform) = pack_common(&e.common);
            let children: Vec<Value> = e.children.iter().map(|c| pack_element(c)).collect();
            Value::Array(vec![vint(TAG_LAYER), locked, opacity, vis, xform,
                              vstr(&e.name), Value::Array(children)])
        }
        Element::Group(e) => {
            let (locked, opacity, vis, xform) = pack_common(&e.common);
            let children: Vec<Value> = e.children.iter().map(|c| pack_element(c)).collect();
            Value::Array(vec![vint(TAG_GROUP), locked, opacity, vis, xform,
                              Value::Array(children)])
        }
        Element::Line(e) => {
            let (locked, opacity, vis, xform) = pack_common(&e.common);
            Value::Array(vec![vint(TAG_LINE), locked, opacity, vis, xform,
                              vf64(e.x1), vf64(e.y1), vf64(e.x2), vf64(e.y2),
                              pack_stroke(&e.stroke)])
        }
        Element::Rect(e) => {
            let (locked, opacity, vis, xform) = pack_common(&e.common);
            Value::Array(vec![vint(TAG_RECT), locked, opacity, vis, xform,
                              vf64(e.x), vf64(e.y), vf64(e.width), vf64(e.height),
                              vf64(e.rx), vf64(e.ry),
                              pack_fill(&e.fill), pack_stroke(&e.stroke)])
        }
        Element::Circle(e) => {
            let (locked, opacity, vis, xform) = pack_common(&e.common);
            Value::Array(vec![vint(TAG_CIRCLE), locked, opacity, vis, xform,
                              vf64(e.cx), vf64(e.cy), vf64(e.r),
                              pack_fill(&e.fill), pack_stroke(&e.stroke)])
        }
        Element::Ellipse(e) => {
            let (locked, opacity, vis, xform) = pack_common(&e.common);
            Value::Array(vec![vint(TAG_ELLIPSE), locked, opacity, vis, xform,
                              vf64(e.cx), vf64(e.cy), vf64(e.rx), vf64(e.ry),
                              pack_fill(&e.fill), pack_stroke(&e.stroke)])
        }
        Element::Polyline(e) => {
            let (locked, opacity, vis, xform) = pack_common(&e.common);
            let points: Vec<Value> = e.points.iter()
                .map(|(x, y)| Value::Array(vec![vf64(*x), vf64(*y)])).collect();
            Value::Array(vec![vint(TAG_POLYLINE), locked, opacity, vis, xform,
                              Value::Array(points), pack_fill(&e.fill), pack_stroke(&e.stroke)])
        }
        Element::Polygon(e) => {
            let (locked, opacity, vis, xform) = pack_common(&e.common);
            let points: Vec<Value> = e.points.iter()
                .map(|(x, y)| Value::Array(vec![vf64(*x), vf64(*y)])).collect();
            Value::Array(vec![vint(TAG_POLYGON), locked, opacity, vis, xform,
                              Value::Array(points), pack_fill(&e.fill), pack_stroke(&e.stroke)])
        }
        Element::Path(e) => {
            let (locked, opacity, vis, xform) = pack_common(&e.common);
            let cmds: Vec<Value> = e.d.iter().map(pack_path_command).collect();
            Value::Array(vec![vint(TAG_PATH), locked, opacity, vis, xform,
                              Value::Array(cmds), pack_fill(&e.fill), pack_stroke(&e.stroke)])
        }
        Element::Text(e) => {
            let (locked, opacity, vis, xform) = pack_common(&e.common);
            Value::Array(vec![vint(TAG_TEXT), locked, opacity, vis, xform,
                              vf64(e.x), vf64(e.y), vstr(&e.content),
                              vstr(&e.font_family), vf64(e.font_size),
                              vstr(&e.font_weight), vstr(&e.font_style),
                              vstr(&e.text_decoration),
                              vf64(e.width), vf64(e.height),
                              pack_fill(&e.fill), pack_stroke(&e.stroke)])
        }
        Element::TextPath(e) => {
            let (locked, opacity, vis, xform) = pack_common(&e.common);
            let cmds: Vec<Value> = e.d.iter().map(pack_path_command).collect();
            Value::Array(vec![vint(TAG_TEXT_PATH), locked, opacity, vis, xform,
                              Value::Array(cmds), vstr(&e.content), vf64(e.start_offset),
                              vstr(&e.font_family), vf64(e.font_size),
                              vstr(&e.font_weight), vstr(&e.font_style),
                              vstr(&e.text_decoration),
                              pack_fill(&e.fill), pack_stroke(&e.stroke)])
        }
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
    Value::Array(vec![
        Value::Array(layers),
        vuint(doc.selected_layer),
        pack_selection(&doc.selection),
    ])
}

// -- Unpack (Value -> Document) ----------------------------------------------

fn as_i64(v: &Value) -> i64 {
    v.as_i64().unwrap_or_else(|| {
        // Handle unsigned integers too.
        v.as_u64().map(|u| u as i64).expect("expected integer")
    })
}

fn as_f64(v: &Value) -> f64 {
    match v {
        Value::F64(f) => *f,
        Value::F32(f) => *f as f64,
        Value::Integer(i) => {
            i.as_f64().expect("expected float-compatible integer")
        }
        _ => panic!("expected f64, got {:?}", v),
    }
}

fn as_bool(v: &Value) -> bool {
    v.as_bool().expect("expected bool")
}

fn as_str(v: &Value) -> &str {
    v.as_str().expect("expected string")
}

fn as_array(v: &Value) -> &Vec<Value> {
    v.as_array().expect("expected array")
}

fn unpack_color(v: &Value) -> Color {
    let arr = as_array(v);
    let space = as_i64(&arr[0]);
    match space {
        SPACE_RGB => Color::Rgb {
            r: as_f64(&arr[1]), g: as_f64(&arr[2]), b: as_f64(&arr[3]), a: as_f64(&arr[5]),
        },
        SPACE_HSB => Color::Hsb {
            h: as_f64(&arr[1]), s: as_f64(&arr[2]), b: as_f64(&arr[3]), a: as_f64(&arr[5]),
        },
        SPACE_CMYK => Color::Cmyk {
            c: as_f64(&arr[1]), m: as_f64(&arr[2]), y: as_f64(&arr[3]),
            k: as_f64(&arr[4]), a: as_f64(&arr[5]),
        },
        _ => panic!("unknown color space: {}", space),
    }
}

fn unpack_fill(v: &Value) -> Option<Fill> {
    if v.is_nil() { return None; }
    let arr = as_array(v);
    Some(Fill { color: unpack_color(&arr[0]), opacity: as_f64(&arr[1]) })
}

fn unpack_stroke(v: &Value) -> Option<Stroke> {
    if v.is_nil() { return None; }
    let arr = as_array(v);
    let cap = match as_i64(&arr[2]) {
        0 => LineCap::Butt,
        1 => LineCap::Round,
        2 => LineCap::Square,
        n => panic!("unknown linecap: {}", n),
    };
    let join = match as_i64(&arr[3]) {
        0 => LineJoin::Miter,
        1 => LineJoin::Round,
        2 => LineJoin::Bevel,
        n => panic!("unknown linejoin: {}", n),
    };
    Some(Stroke {
        color: unpack_color(&arr[0]),
        width: as_f64(&arr[1]),
        linecap: cap,
        linejoin: join,
        miter_limit: 10.0,
        align: StrokeAlign::Center,
        dash_pattern: [0.0; 6],
        dash_len: 0,
        opacity: as_f64(&arr[4]),
    })
}

fn unpack_transform(v: &Value) -> Option<Transform> {
    if v.is_nil() { return None; }
    let arr = as_array(v);
    Some(Transform {
        a: as_f64(&arr[0]), b: as_f64(&arr[1]), c: as_f64(&arr[2]),
        d: as_f64(&arr[3]), e: as_f64(&arr[4]), f: as_f64(&arr[5]),
    })
}

fn unpack_path_command(v: &Value) -> PathCommand {
    let arr = as_array(v);
    let tag = as_i64(&arr[0]);
    match tag {
        CMD_MOVE_TO => PathCommand::MoveTo { x: as_f64(&arr[1]), y: as_f64(&arr[2]) },
        CMD_LINE_TO => PathCommand::LineTo { x: as_f64(&arr[1]), y: as_f64(&arr[2]) },
        CMD_CURVE_TO => PathCommand::CurveTo {
            x1: as_f64(&arr[1]), y1: as_f64(&arr[2]),
            x2: as_f64(&arr[3]), y2: as_f64(&arr[4]),
            x: as_f64(&arr[5]), y: as_f64(&arr[6]),
        },
        CMD_SMOOTH_CURVE_TO => PathCommand::SmoothCurveTo {
            x2: as_f64(&arr[1]), y2: as_f64(&arr[2]),
            x: as_f64(&arr[3]), y: as_f64(&arr[4]),
        },
        CMD_QUAD_TO => PathCommand::QuadTo {
            x1: as_f64(&arr[1]), y1: as_f64(&arr[2]),
            x: as_f64(&arr[3]), y: as_f64(&arr[4]),
        },
        CMD_SMOOTH_QUAD_TO => PathCommand::SmoothQuadTo {
            x: as_f64(&arr[1]), y: as_f64(&arr[2]),
        },
        CMD_ARC_TO => PathCommand::ArcTo {
            rx: as_f64(&arr[1]), ry: as_f64(&arr[2]),
            x_rotation: as_f64(&arr[3]),
            large_arc: as_bool(&arr[4]), sweep: as_bool(&arr[5]),
            x: as_f64(&arr[6]), y: as_f64(&arr[7]),
        },
        CMD_CLOSE_PATH => PathCommand::ClosePath,
        _ => panic!("unknown path command tag: {}", tag),
    }
}

fn unpack_common(arr: &[Value]) -> CommonProps {
    let vis = match as_i64(&arr[3]) {
        0 => Visibility::Invisible,
        1 => Visibility::Outline,
        2 => Visibility::Preview,
        n => panic!("unknown visibility: {}", n),
    };
    CommonProps {
        locked: as_bool(&arr[1]),
        opacity: as_f64(&arr[2]),
        visibility: vis,
        transform: unpack_transform(&arr[4]),
    }
}

fn unpack_element(v: &Value) -> Element {
    let arr = as_array(v);
    let tag = as_i64(&arr[0]);
    let common = unpack_common(arr);

    match tag {
        TAG_LAYER => {
            let name = as_str(&arr[5]).to_string();
            let children: Vec<Rc<Element>> = as_array(&arr[6]).iter()
                .map(|c| Rc::new(unpack_element(c))).collect();
            Element::Layer(LayerElem { name, children, common })
        }
        TAG_GROUP => {
            let children: Vec<Rc<Element>> = as_array(&arr[5]).iter()
                .map(|c| Rc::new(unpack_element(c))).collect();
            Element::Group(GroupElem { children, common })
        }
        TAG_LINE => Element::Line(LineElem {
            x1: as_f64(&arr[5]), y1: as_f64(&arr[6]),
            x2: as_f64(&arr[7]), y2: as_f64(&arr[8]),
            stroke: unpack_stroke(&arr[9]),
            common,
        }),
        TAG_RECT => Element::Rect(RectElem {
            x: as_f64(&arr[5]), y: as_f64(&arr[6]),
            width: as_f64(&arr[7]), height: as_f64(&arr[8]),
            rx: as_f64(&arr[9]), ry: as_f64(&arr[10]),
            fill: unpack_fill(&arr[11]), stroke: unpack_stroke(&arr[12]),
            common,
        }),
        TAG_CIRCLE => Element::Circle(CircleElem {
            cx: as_f64(&arr[5]), cy: as_f64(&arr[6]), r: as_f64(&arr[7]),
            fill: unpack_fill(&arr[8]), stroke: unpack_stroke(&arr[9]),
            common,
        }),
        TAG_ELLIPSE => Element::Ellipse(EllipseElem {
            cx: as_f64(&arr[5]), cy: as_f64(&arr[6]),
            rx: as_f64(&arr[7]), ry: as_f64(&arr[8]),
            fill: unpack_fill(&arr[9]), stroke: unpack_stroke(&arr[10]),
            common,
        }),
        TAG_POLYLINE => {
            let points: Vec<(f64, f64)> = as_array(&arr[5]).iter()
                .map(|p| { let a = as_array(p); (as_f64(&a[0]), as_f64(&a[1])) }).collect();
            Element::Polyline(PolylineElem {
                points,
                fill: unpack_fill(&arr[6]), stroke: unpack_stroke(&arr[7]),
                common,
            })
        }
        TAG_POLYGON => {
            let points: Vec<(f64, f64)> = as_array(&arr[5]).iter()
                .map(|p| { let a = as_array(p); (as_f64(&a[0]), as_f64(&a[1])) }).collect();
            Element::Polygon(PolygonElem {
                points,
                fill: unpack_fill(&arr[6]), stroke: unpack_stroke(&arr[7]),
                common,
            })
        }
        TAG_PATH => {
            let cmds: Vec<PathCommand> = as_array(&arr[5]).iter()
                .map(unpack_path_command).collect();
            Element::Path(PathElem {
                d: cmds,
                fill: unpack_fill(&arr[6]), stroke: unpack_stroke(&arr[7]),
                common,
            })
        }
        TAG_TEXT => Element::Text(TextElem {
            x: as_f64(&arr[5]), y: as_f64(&arr[6]),
            content: as_str(&arr[7]).to_string(),
            font_family: as_str(&arr[8]).to_string(),
            font_size: as_f64(&arr[9]),
            font_weight: as_str(&arr[10]).to_string(),
            font_style: as_str(&arr[11]).to_string(),
            text_decoration: as_str(&arr[12]).to_string(),
            width: as_f64(&arr[13]), height: as_f64(&arr[14]),
            fill: unpack_fill(&arr[15]), stroke: unpack_stroke(&arr[16]),
            common,
        }),
        TAG_TEXT_PATH => {
            let cmds: Vec<PathCommand> = as_array(&arr[5]).iter()
                .map(unpack_path_command).collect();
            Element::TextPath(TextPathElem {
                d: cmds,
                content: as_str(&arr[6]).to_string(),
                start_offset: as_f64(&arr[7]),
                font_family: as_str(&arr[8]).to_string(),
                font_size: as_f64(&arr[9]),
                font_weight: as_str(&arr[10]).to_string(),
                font_style: as_str(&arr[11]).to_string(),
                text_decoration: as_str(&arr[12]).to_string(),
                fill: unpack_fill(&arr[13]), stroke: unpack_stroke(&arr[14]),
                common,
            })
        }
        _ => panic!("unknown element tag: {}", tag),
    }
}

fn unpack_selection(v: &Value) -> Selection {
    let arr = as_array(v);
    arr.iter().map(|item| {
        let item_arr = as_array(item);
        let path: ElementPath = as_array(&item_arr[0]).iter()
            .map(|i| as_i64(i) as usize).collect();
        let kind = if item_arr[1].is_i64() || item_arr[1].is_u64() {
            // kind == 0 means All
            SelectionKind::All
        } else {
            // kind == [1, ...cps]
            let kind_arr = as_array(&item_arr[1]);
            let cps = SortedCps::from_iter(
                kind_arr[1..].iter().map(|v| as_i64(v) as usize)
            );
            SelectionKind::Partial(cps)
        };
        ElementSelection { path, kind }
    }).collect()
}

fn unpack_document(v: &Value) -> Document {
    let arr = as_array(v);
    let layers: Vec<Element> = as_array(&arr[0]).iter()
        .map(unpack_element).collect();
    let selected_layer = as_i64(&arr[1]) as usize;
    let selection = unpack_selection(&arr[2]);
    Document { layers, selected_layer, selection }
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

    Ok(unpack_document(&value))
}
