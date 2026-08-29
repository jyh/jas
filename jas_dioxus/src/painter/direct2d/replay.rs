//! Replay a recorded Painter scene through `Direct2DPainter`.
//!
//! This is B1's real instrument. The 14 scenes in `painter/testdata/` were
//! recorded from the Canvas2D path via `RecordingPainter`, so replaying them
//! through Direct2D drives the SAME display list a shipping backend produced —
//! which is what "display-list equivalence" means in practice, and why it is
//! the doctrine rather than pixel comparison (B1 measured GPU and WARP
//! rasterisers differing on 14.93% of pixels; golden images cannot cross that).
//!
//! # It must never skip silently
//!
//! Every recorded command either DRAWS or is counted as unsupported WITH A
//! REASON. A harness that quietly ignored what it could not do would report a
//! clean replay of a scene it had half-drawn — and that is the exact shape this
//! seat has spent a week finding in other people's instruments. The support
//! figure is therefore a measurement, not a claim.
//!
//! # The precision trap, pinned here because this is where it bites
//!
//! The corpus emits FOUR DECIMAL PLACES (`recording::canonical_f64`). A full
//! ellipse sweep records as `6.2832`, which is 1.5e-5 short of `TAU`. Compare
//! against this corpus with an f64-grade tolerance and every recorded circle
//! reads as a partial arc — which the painter then correctly refuses to draw,
//! silently, producing an empty scene and no error. Anything comparing to these
//! files must use the corpus's precision.

use serde_json::Value;

use super::painter::Direct2DPainter;
use crate::geometry::element::Color;
use crate::painter::{
    BlendMode, Brush, ColorStop, EllipseArc, FillRule, LinearGradient, LineCap, LineJoin,
    Painter, PathCommand, RadialGradient, Rect, StrokeStyle, TextRun, Transform,
};

/// What a replay actually managed. `unsupported` carries a reason per command
/// so the report is a work list rather than a number.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ReplayReport {
    pub drawn: usize,
    pub unsupported: Vec<(String, &'static str)>,
}

impl ReplayReport {
    pub fn total(&self) -> usize {
        self.drawn + self.unsupported.len()
    }
    pub fn is_complete(&self) -> bool {
        self.unsupported.is_empty()
    }
}

fn f(v: &Value, k: &str) -> f64 {
    v.get(k).and_then(Value::as_f64).unwrap_or(0.0)
}

fn color(v: &Value) -> Color {
    // Only the rgb space appears in the corpus; anything else would be a new
    // recording feature and should be noticed, not coerced.
    Color::new(f(v, "r"), f(v, "g"), f(v, "b"), f(v, "a"))
}

fn stops(v: &Value) -> Vec<ColorStop> {
    v.get("stops").and_then(Value::as_array).map(|a| {
        a.iter().map(|s| ColorStop {
            offset: f(s, "offset"),
            color: color(s.get("color").unwrap_or(&Value::Null)),
        }).collect()
    }).unwrap_or_default()
}

fn brush(v: &Value) -> Option<Brush> {
    match v.get("kind").and_then(Value::as_str)? {
        "solid" => Some(Brush::Solid(color(v.get("color")?))),
        "linear" => {
            let g = v.get("gradient")?;
            Some(Brush::Linear(LinearGradient {
                x0: f(g, "x0"), y0: f(g, "y0"), x1: f(g, "x1"), y1: f(g, "y1"),
                stops: stops(g),
            }))
        }
        "radial" => {
            let g = v.get("gradient")?;
            Some(Brush::Radial(RadialGradient {
                x0: f(g, "x0"), y0: f(g, "y0"), r0: f(g, "r0"),
                x1: f(g, "x1"), y1: f(g, "y1"), r1: f(g, "r1"),
                stops: stops(g),
            }))
        }
        _ => None,
    }
}

fn winding(v: &Value) -> FillRule {
    match v.get("winding").and_then(Value::as_str) {
        Some("evenodd") => FillRule::EvenOdd,
        _ => FillRule::NonZero,
    }
}

fn stroke(v: &Value) -> StrokeStyle {
    StrokeStyle {
        width: f(v, "width"),
        cap: match v.get("cap").and_then(Value::as_str) {
            Some("round") => LineCap::Round,
            Some("square") => LineCap::Square,
            _ => LineCap::Butt,
        },
        join: match v.get("join").and_then(Value::as_str) {
            Some("round") => LineJoin::Round,
            Some("bevel") => LineJoin::Bevel,
            _ => LineJoin::Miter,
        },
        miter: f(v, "miter"),
        dash: v.get("dash").and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_f64).collect())
            .unwrap_or_default(),
    }
}

fn path(v: &Value) -> Vec<PathCommand> {
    v.as_array().map(|a| a.iter().filter_map(|c| {
        Some(match c.get("op").and_then(Value::as_str)? {
            "M" => PathCommand::MoveTo { x: f(c, "x"), y: f(c, "y") },
            "L" => PathCommand::LineTo { x: f(c, "x"), y: f(c, "y") },
            "C" => PathCommand::CurveTo {
                x1: f(c, "x1"), y1: f(c, "y1"), x2: f(c, "x2"), y2: f(c, "y2"),
                x: f(c, "x"), y: f(c, "y"),
            },
            "Q" => PathCommand::QuadTo {
                x1: f(c, "x1"), y1: f(c, "y1"), x: f(c, "x"), y: f(c, "y"),
            },
            "Z" => PathCommand::ClosePath,
            _ => return None,
        })
    }).collect()).unwrap_or_default()
}

fn arc(v: &Value) -> EllipseArc {
    EllipseArc {
        cx: f(v, "cx"), cy: f(v, "cy"), rx: f(v, "rx"), ry: f(v, "ry"),
        rotation: f(v, "rotation"), start: f(v, "start"), end: f(v, "end"),
        ccw: v.get("ccw").and_then(Value::as_bool).unwrap_or(false),
    }
}

/// Drive one recorded scene. Returns what was drawn and what was refused.
pub fn replay(p: &mut Direct2DPainter, scene: &Value) -> ReplayReport {
    let mut r = ReplayReport::default();
    let Some(ops) = scene.as_array() else { return r };

    for op in ops {
        let Some(cmd) = op.get("cmd").and_then(Value::as_str) else {
            r.unsupported.push(("<no cmd>".into(), "record has no cmd field"));
            continue;
        };
        let a = op.get("alpha").and_then(Value::as_f64).unwrap_or(1.0);
        let b = op.get("brush").and_then(brush);

        match cmd {
            "fill_rect" | "stroke_rect" => {
                let Some(br) = b else {
                    r.unsupported.push((cmd.into(), "brush kind not understood"));
                    continue;
                };
                let rc = op.get("rect").unwrap_or(&Value::Null);
                let rect = Rect { x: f(rc, "x"), y: f(rc, "y"), w: f(rc, "w"), h: f(rc, "h") };
                if cmd == "fill_rect" {
                    p.fill_rect(rect, &br, a);
                } else {
                    p.stroke_rect(rect, &br, &stroke(op.get("stroke").unwrap_or(&Value::Null)), a);
                }
                r.drawn += 1;
            }
            "fill_path" | "stroke_path" => {
                let Some(br) = b else {
                    r.unsupported.push((cmd.into(), "brush kind not understood"));
                    continue;
                };
                let pth = path(op.get("path").unwrap_or(&Value::Null));
                if cmd == "fill_path" {
                    p.fill_path(&pth, winding(op), &br, a);
                } else {
                    p.stroke_path(&pth, &br, &stroke(op.get("stroke").unwrap_or(&Value::Null)), a);
                }
                r.drawn += 1;
            }
            "fill_ellipse_arc" | "stroke_ellipse_arc" => {
                let Some(br) = b else {
                    r.unsupported.push((cmd.into(), "brush kind not understood"));
                    continue;
                };
                let ar = arc(op.get("arc").unwrap_or(&Value::Null));
                if cmd == "fill_ellipse_arc" {
                    p.fill_ellipse_arc(&ar, winding(op), &br, a);
                } else {
                    p.stroke_ellipse_arc(&ar, &br, &stroke(op.get("stroke").unwrap_or(&Value::Null)), a);
                }
                r.drawn += 1;
            }
            "clip" => {
                p.clip(&path(op.get("path").unwrap_or(&Value::Null)), winding(op));
                r.drawn += 1;
            }
            "push_state" => {
                let t = op.get("transform").unwrap_or(&Value::Null);
                p.push_state(Transform {
                    a: f(t, "a"), b: f(t, "b"), c: f(t, "c"),
                    d: f(t, "d"), e: f(t, "e"), f: f(t, "f"),
                });
                r.drawn += 1;
            }
            "pop_state" => { p.pop_state(); r.drawn += 1; }
            "push_group" => {
                match op.get("blend").and_then(Value::as_str) {
                    Some("normal") | None => { p.push_group(a, BlendMode::Normal); r.drawn += 1; }
                    // B1: the 15 non-Normal modes need a backdrop snapshot plus
                    // a CLSID_D2D1Blend graph per primitive. Not built.
                    Some(_) => r.unsupported.push((cmd.into(), "non-Normal blend needs an effect graph")),
                }
            }
            "pop_group" => { p.pop_group(); r.drawn += 1; }
            "draw_text_run" => {
                let run = op.get("run").unwrap_or(&Value::Null);
                match run.get("mode").and_then(Value::as_str) {
                    Some("fast_run") => {
                        let tr = TextRun::FastRun {
                            font: run.get("font").and_then(Value::as_str).unwrap_or("").into(),
                            size: f(run, "size"),
                            text: run.get("text").and_then(Value::as_str).unwrap_or("").into(),
                            letter_spacing: f(run, "letter_spacing"),
                            x: f(run, "x"),
                            y: f(run, "y"),
                        };
                        match op.get("brush").and_then(brush) {
                            Some(br) => { p.draw_text_run(&tr, &br, a); r.drawn += 1; }
                            None => r.unsupported.push((cmd.into(), "brush kind not understood")),
                        }
                    }
                    _ => r.unsupported.push((cmd.into(), "PlacedGlyphs mode not built")),
                }
            }
            // A6 is RATIFIED (2026-08-27); what is pending is this backend's
            // implementation, not a ruling. Both brackets are DECLARED gaps so
            // they land in the report instead of the "unknown command" arm --
            // an unimplemented op and an unrecognised one are different facts.
            "push_mask_layer" | "pop_mask_layer" =>
                r.unsupported.push((cmd.into(), "masks pending the A6 implementation in this backend")),
            "push_isolated_layer" | "pop_isolated_layer" =>
                r.unsupported.push((cmd.into(), "A6 isolated layers pending in this backend")),
            _ => r.unsupported.push((cmd.into(), "unknown command")),
        }
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::painter::direct2d::device::HeadlessTarget;
    use windows::Win32::Graphics::Direct2D::Common::D2D1_COLOR_F;

    fn scenes() -> Vec<(String, Value)> {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("src/painter/testdata");
        let mut v: Vec<_> = std::fs::read_dir(&dir).expect("testdata")
            .filter_map(Result::ok)
            .filter(|e| e.path().extension().map(|x| x == "json").unwrap_or(false))
            .map(|e| {
                let name = e.file_name().to_string_lossy().into_owned();
                let txt = std::fs::read_to_string(e.path()).unwrap();
                (name, serde_json::from_str(&txt).unwrap())
            })
            .collect();
        v.sort_by(|a, b| a.0.cmp(&b.0));
        v
    }

    fn replay_all() -> (ReplayReport, usize) {
        let t = HeadlessTarget::new(320, 320).expect("target");
        let mut total = ReplayReport::default();
        let n = scenes().len();
        for (_name, scene) in scenes() {
            unsafe {
                t.target().BeginDraw();
                t.target().Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }));
                let mut p = Direct2DPainter::new(t.target());
                let r = replay(&mut p, &scene);
                total.drawn += r.drawn;
                total.unsupported.extend(r.unsupported);
                t.target().EndDraw(None, None).expect("EndDraw");
            }
        }
        (total, n)
    }

    /// THE B1 MILESTONE. Every recorded scene drives Direct2D end to end, and
    /// the harness reports exactly what it could not do.
    #[test]
    fn every_recorded_scene_replays_and_reports_its_gap() {
        let (r, n) = replay_all();

        // ⛔ THE STATED LIMIT THIS TEST CARRIED IS NOW GONE, AND THAT IS THE
        // POINT OF A6's CORPUS. It used to read: "masks and non-Normal blend
        // remain unimplemented by design -- THE CORPUS SIMPLY CONTAINS NONE,
        // which is itself a stated limit of this measurement rather than
        // evidence they work." B1 measured exactly that: 14 scenes, ZERO mask
        // ops. A backend could refuse every mask in existence and this test
        // would have gone green, because nothing asked.
        //
        // The four A6 goldens (design block §6) put masks, nested layers and a
        // non-Normal blend into the corpus. So the assertion inverts: the gap
        // must now be REPORTED, and it must be EXACTLY the declared one.
        assert_eq!(n, 20, "14 pre-A6 + 4 A6 goldens + group_blend + a6_layer_no_mask");
        for want in ["a6_law_variants.json", "a6_alpha_law.json",
                     "a6_nested_layers.json", "a6_blend.json"] {
            assert!(scenes().iter().any(|(name, _)| name == want),
                    "A6 scene {want} vanished from the corpus");
        }
        assert!(r.total() >= 56, "all recorded ops accounted for, got {}", r.total());

        // ⛔ EVERY OP ACCOUNTED FOR — AGAINST THE SCENES, NOT AGAINST ITSELF.
        // My first cut here asserted `r.drawn + r.unsupported.len() == r.total()`,
        // which is a TAUTOLOGY: total() is DEFINED as that sum, so it can never
        // fail. The question worth asking is whether the report accounts for
        // every record the corpus actually holds — a command silently skipped
        // without being reported makes the report SMALLER than the corpus, and
        // only the corpus can say so.
        let recorded: usize = scenes()
            .iter()
            .map(|(_, v)| v.as_array().map(|a| a.len()).unwrap_or(0))
            .sum();
        assert_eq!(r.total(), recorded,
                   "replay accounted for {} ops but the corpus holds {recorded}", r.total());

        // ⛔ AND EVERY GAP MUST BE A DECLARED ONE. This is the arm that keeps the
        // test honest now that it can no longer be complete: a NEW gap, or an op
        // falling through to "unknown command", still reds.
        const DECLARED: [&str; 3] = [
            "masks pending the A6 implementation in this backend",
            "A6 isolated layers pending in this backend",
            "non-Normal blend needs an effect graph",
        ];
        for (cmd, why) in &r.unsupported {
            assert!(DECLARED.contains(why),
                    "UNDECLARED gap: {cmd} -> {why}");
        }
        assert!(!r.unsupported.is_empty(),
                "the A6 scenes contain masks and a non-Normal blend; a report with \
                 NO gaps means the corpus stopped containing them");

        // ⛔ EVERY DECLARED GAP MUST ACTUALLY FIRE, NOT MERELY BE PERMITTED.
        // Measured 2026-08-29: DECLARED[2] — the non-Normal blend gap — fired on
        // NO scene in this corpus. It reads only a `push_group`'s mode, both
        // `push_group` ops here were `normal`, and the corpus's single
        // non-Normal blend rode `push_isolated_layer` and landed in the
        // isolated-layer gap instead. So the arm was unreachable and this test
        // could not tell that from a backend that handles group blend fine.
        //
        // That is the SAME defect this test's own comment celebrates removing
        // for masks ("the corpus simply contains none, which is itself a stated
        // limit of this measurement rather than evidence they work") — repaired
        // for the mask half and left standing for the group-blend half in the
        // same breath. `group_blend.json` closes it.
        //
        // ⇒ THE ASSERTION IS THAT EACH DECLARED REASON IS *OBSERVED*. A declared
        // gap nothing drives is indistinguishable from one that cannot fire, and
        // the DECLARED list is where a stale entry would hide longest.
        for want in DECLARED {
            assert!(r.unsupported.iter().any(|(_, why)| *why == want),
                    "DECLARED gap never fired on any scene: {want:?} -- either \
                     the corpus stopped exercising it or the gap is stale");
        }
    }

    /// The harness must NOT report success on a command it silently dropped.
    /// A fabricated unknown command has to surface.
    #[test]
    fn an_unknown_command_is_reported_not_skipped() {
        let t = HeadlessTarget::new(8, 8).unwrap();
        let scene: Value = serde_json::json!([{ "cmd": "teleport_the_artboard" }]);
        unsafe { t.target().BeginDraw() };
        let mut p = Direct2DPainter::new(t.target());
        let r = replay(&mut p, &scene);
        unsafe { let _ = t.target().EndDraw(None, None); }
        assert_eq!(r.drawn, 0);
        assert_eq!(r.unsupported, vec![("teleport_the_artboard".to_string(), "unknown command")]);
        assert!(!r.is_complete());
    }

    /// A gradient scene must actually DRAW rather than fall back to nothing --
    /// the earlier increment returned None for gradients, and a harness that
    /// counted that as drawn would have hidden it.
    #[test]
    fn the_gradient_scene_draws_every_op() {
        let t = HeadlessTarget::new(320, 320).unwrap();
        let (_, scene) = scenes().into_iter().find(|(n, _)| n == "ref_gradients.json").expect("scene");
        unsafe {
            t.target().BeginDraw();
            t.target().Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }));
        }
        let mut p = Direct2DPainter::new(t.target());
        let r = replay(&mut p, &scene);
        unsafe { t.target().EndDraw(None, None).expect("EndDraw") };
        assert!(r.is_complete(), "gradients still unsupported: {:?}", r.unsupported);
        let px = t.read_bgra().unwrap();
        assert!(px.chunks(4).any(|q| q[3] != 0), "the gradient scene painted nothing");
    }
}
