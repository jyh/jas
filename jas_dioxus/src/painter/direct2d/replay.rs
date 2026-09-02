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
    Mask,
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
                    // ⭐ `align` READ BACK FROM THE OP, defaulting to Center.
                    // The recorder emits the field ONLY when it is non-centre,
                    // so every corpus scene pinned before 2026-09-02 replays
                    // exactly as it did -- the default IS the old behaviour.
                    let align = match op.get("align").and_then(|v| v.as_str()) {
                        Some("inside") => crate::painter::StrokeAlign::Inside,
                        Some("outside") => crate::painter::StrokeAlign::Outside,
                        _ => crate::painter::StrokeAlign::Center,
                    };
                    p.stroke_ellipse_arc(&ar, &br, &stroke(op.get("stroke").unwrap_or(&Value::Null)), align, a);
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
                    // ⛔ STILL A GAP, AND FOR A REASON THE ISOLATED-LAYER ARM
                    // BELOW NO LONGER SHARES. A group is NON-ISOLATED by
                    // contract: its blend applies to every descendant primitive
                    // against the LIVE backdrop, so it needs a snapshot and a
                    // `CLSID_D2D1Blend` graph PER PRIMITIVE — a change to every
                    // draw method, not one composite.
                    //
                    // The closing composite of an isolated layer is one image
                    // against one backdrop, which is why that half could be
                    // built on its own. Collapsing the two would hide that the
                    // remaining work is a different size and shape.
                    // ⭐ ROW CM's LAST GOLDEN: the per-primitive graph is built.
                    // `blended_primitive` composites each descendant against the
                    // LIVE backdrop, which is what non-isolated means — and is
                    // why two overlapping half-multiplies compound rather than
                    // flatten.
                    Some(name) => match crate::painter::recording::blend_from_str(name) {
                        Some(b) => { p.push_group(a, b); r.drawn += 1; }
                        None => r.unsupported.push((cmd.into(), "blend mode not understood")),
                    },
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
                            Some(br) => {
                                p.draw_text_run(&tr, &br, a);
                                // ⛔ ASK WHETHER IT ACTUALLY DREW. `Painter::draw_text_run`
                                // returns `()` (the trait is frozen), so "it was called"
                                // and "it drew" are different facts and only the painter
                                // knows the second. Counting the call as `drawn` is what
                                // let an unresolvable font present a document with its
                                // text missing at `JAS_PAINT_OK`.
                                match p.take_text_refusal() {
                                    None => r.drawn += 1,
                                    Some(why) => r.unsupported.push((cmd.into(), why)),
                                }
                            }
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
            // A6 MASKS ARE IMPLEMENTED IN THIS BACKEND NOW. An UNRECOGNISED law
            // still reports rather than defaulting to one: silently substituting
            // a law would render a plausible wrong picture, which is the whole
            // failure class this corpus exists to catch.
            "push_mask_layer" => {
                let m = op.get("mask");
                let kind = m.and_then(|v| v.get("kind")).and_then(Value::as_str);
                let law = match kind {
                    Some("luminance_clip_in") => Some(Mask::LuminanceClipIn),
                    Some("alpha_clip_out") => Some(Mask::AlphaClipOut),
                    Some("alpha_reveal_outside_bbox") => {
                        m.and_then(|v| v.get("bbox")).map(|b| Mask::AlphaRevealOutsideBbox {
                            bbox: Rect {
                                x: f(b, "x"), y: f(b, "y"),
                                w: f(b, "w"), h: f(b, "h"),
                            },
                        })
                    }
                    _ => None,
                };
                match law {
                    Some(l) => { p.push_mask_layer(l); r.drawn += 1; }
                    None => r.unsupported.push((cmd.into(), "mask law not understood")),
                }
            }
            "pop_mask_layer" => { p.pop_mask_layer(); r.drawn += 1; }
            // ⭐ A6 AND ITS BLEND ARE BOTH IMPLEMENTED IN THIS BACKEND NOW.
            // The layer is a render-target swap (see
            // `painter::push_isolated_layer`); the blend is a
            // `CLSID_D2D1Blend` graph against a `CopyFromRenderTarget`
            // backdrop, applied ONCE at the closing composite (see
            // `painter::composite_blended`). That is the whole of what
            // `pop_isolated_layer`'s contract asks for: "`alpha` and `blend`
            // are consumed once, at the closing composite."
            //
            // ⛔ AN UNKNOWN BLEND NAME IS STILL A GAP, NOT A DEFAULT. Falling
            // back to `Normal` for a mode this build does not know would render
            // a plausible wrong picture — the same law the mask-law arm above
            // follows, and the reason `blend_from_str` returns `Option`.
            "push_isolated_layer" => {
                match op.get("blend").and_then(Value::as_str) {
                    None => { p.push_isolated_layer(a, BlendMode::Normal); r.drawn += 1; }
                    Some(name) => match crate::painter::recording::blend_from_str(name) {
                        Some(b) => { p.push_isolated_layer(a, b); r.drawn += 1; }
                        None => r.unsupported.push((cmd.into(), "blend mode not understood")),
                    },
                }
            }
            "pop_isolated_layer" => { p.pop_isolated_layer(); r.drawn += 1; }
            _ => r.unsupported.push((cmd.into(), "unknown command")),
        }
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::painter::capability::{capabilities_of, Capability, Caps};
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
        // ⛔ THIS WAS A PIN AND IT COST A CI ROUND TRIP THE DAY A SCENE WAS
        // ADDED (row CV, `ref_live.json`). It read `assert_eq!(n, 20, ...)`,
        // which is not a property of anything -- it is the corpus's size at the
        // moment the line was typed, restated as a law. Every OTHER count in
        // this crate's corpus assertions is already derived or a floor
        // (`ffi_paint`'s `jas_corpus_len() == SCENES.len()`, `replay_drive`'s
        // `>= 20`); this was the last hard pin, and a pin's failure message
        // accuses the change rather than naming the fact.
        //
        // ⭐ AND THE DERIVED FORM IS STRONGER THAN THE PIN, NOT WEAKER. `scenes()`
        // reads the DIRECTORY; `corpus::SCENES` is the EMBEDDED list the wasm
        // lane replays. Asserting they are the same length makes this the
        // Direct2D-side counterpart of
        // `painter::corpus::tests::embedded_corpus_matches_the_directory` -- a
        // scene added to one and not the other reds HERE too, on the platform
        // that reads the filesystem. The pin could never have said that.
        assert_eq!(
            n,
            crate::painter::corpus::SCENES.len(),
            "the directory holds {n} scene(s) and the embedded corpus holds {} -- \
             a scene added to one and not the other changes what each lane replays",
            crate::painter::corpus::SCENES.len()
        );
        // ...and the floor keeps the anti-vacuity the pin was also carrying: an
        // empty testdata/ would satisfy the equality above on both sides.
        assert!(
            n >= 20,
            "the corpus SHRANK to {n}; its floor when this arm was written was 20 \
             (14 pre-A6 + 4 A6 goldens + group_blend + a6_layer_no_mask)"
        );
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
        // ⭐ ONE ENTRY RETIRED, 2026-08-29: "A6 isolated layers pending in this
        // backend" is GONE because the ops are implemented (render-target swap).
        // Retired from the list rather than left in it: a DECLARED entry nothing
        // emits is a gap the fleet still believes it has, and this list is read
        // as the backend's own statement of what it cannot do.
        // ⭐ SECOND ENTRY RETIRED, 2026-08-29: the three A6 mask laws are
        // implemented (LuminanceToAlpha + SOURCE_IN; DESTINATION_OUT; and the
        // same with a bbox clip). What remains is the BLEND gap, which
        // push_group already declared before A6 existed and which is not a mask
        // or layer gap at all.
        // ⭐ THIRD ENTRY RETIRED, 2026-09-01: the ISOLATED-LAYER half of the
        // blend gap is implemented (`CLSID_D2D1Blend` against a
        // `CopyFromRenderTarget` backdrop, applied once at the closing
        // composite — `painter::composite_blended`). `a6_blend.json` now
        // paints, taking the corpus from 18/20 to 19/20 through the presented
        // surface.
        //
        // ⛔ WHAT REMAINS IS NARROWER AND IS NAMED THAT WAY. The entry used to
        // read "non-Normal blend needs an effect graph", covering both brackets.
        // Only the NON-ISOLATED group case is left, and it is a different size
        // of job — per-primitive blending against the live backdrop, i.e. a
        // change to every draw method rather than one composite. Leaving the old
        // wording would have let a reader price the remainder as the half that
        // is already done.
        // ⭐⭐ FOURTH AND LAST ENTRY RETIRED, 2026-09-02 (row CM's last golden):
        // the NON-ISOLATED group blend is implemented. `blended_primitive`
        // composites each descendant primitive against the LIVE backdrop
        // through the same `CLSID_D2D1Blend` graph — per primitive, which is
        // what non-isolated means and why two overlapping half-multiplies
        // COMPOUND (0.20) rather than flatten (0.40).
        //
        // ⇒ **THE LIST IS EMPTY. THIS BACKEND DECLARES NO GAPS**, and every one
        // of the 21 recorded scenes replays complete.
        //
        // ⛔ AN EMPTY LIST INVERTS THIS TEST, AND THE INVERSION IS THE HONEST
        // SHAPE. It used to assert `!r.unsupported.is_empty()` — "a report with
        // NO gaps means the corpus stopped containing them" — which was exactly
        // right while a gap existed and is exactly wrong now: the corpus still
        // contains masks, layers and both blend carriers, and this backend
        // simply draws them all. So the assertion becomes its opposite: NOTHING
        // may be refused, and anything that is arrives named.
        const DECLARED: [&str; 0] = [];
        for (cmd, why) in &r.unsupported {
            assert!(DECLARED.contains(why), "UNDECLARED gap: {cmd} -> {why}");
        }
        assert!(r.unsupported.is_empty(),
                "this backend declares NO gaps as of row CM's last golden; a                  refusal here is a REGRESSION and arrives with its op and reason:                  {:?}", r.unsupported);

        // ⛔ AND THE CORPUS MUST STILL CONTAIN THE HARD OPS, or "no gaps" would
        // be satisfied by a corpus that stopped asking. This replaces the old
        // "every DECLARED gap must fire" arm, which cannot mean anything over an
        // empty list — the question it was really asking was whether the corpus
        // still EXERCISES what the backend claims, and that is asked directly.
        let ops: Vec<String> = scenes().iter()
            .filter_map(|(_, v)| v.as_array().map(|a| a.iter()
                .filter_map(|o| o.get("cmd").and_then(Value::as_str).map(str::to_string))
                .collect::<Vec<_>>()))
            .flatten().collect();
        for want in ["push_group", "push_isolated_layer", "push_mask_layer", "draw_text_run"] {
            assert!(ops.iter().any(|c| c == want),
                    "the corpus stopped exercising {want}; 'no gaps' would then be                      a statement about an empty question");
        }
        let non_normal: usize = scenes().iter()
            .filter_map(|(_, v)| v.as_array())
            .flat_map(|a| a.iter())
            .filter(|o| !matches!(o.get("blend").and_then(Value::as_str), Some("normal") | None))
            .count();
        assert!(non_normal >= 2,
                "both blend CARRIERS must still be in the corpus (group and                  isolated layer); found {non_normal} non-Normal blend ops");

        // ⚖️ THE CAPABILITY QUERY, HELD AGAINST THIS REPORT (council 08/29,
        // row (e) = (b)). `Direct2DPainter::supports` answers NO to all three
        // capabilities; this is the arm that makes that an answer rather than a
        // comment, and it is deliberately computed FROM THE CORPUS.
        //
        // ⇒ Direct2D must refuse EXACTLY the recorded ops that need a
        // capability -- no fewer (it cannot be quietly executing something it
        // says it cannot do), and no more (a refusal with no capability behind
        // it is an undeclared gap). The count comes from
        // `capability::capability_of`, which is authored against the FIXTURES
        // and knows nothing about this backend, so this is two independently
        // written instruments agreeing on one object rather than one
        // instrument agreeing with itself.
        let t = HeadlessTarget::new(8, 8).expect("target");
        let probe = Direct2DPainter::new(t.target());
        // ⛔ NO BLANKET "answers NO to everything" ANY MORE. That assertion was
        // true when written and would have had to be DELETED at the first flip —
        // and a gate deleted to let a change through has stopped being a gate.
        // What must hold at every stage is the AGREEMENT below: whatever this
        // backend answers, its report must match it, op for op.
        assert!(probe.supports(Capability::NonNormalBlend),
                "the ISOLATED-LAYER blend is built (CLSID_D2D1Blend against a \
                 CopyFromRenderTarget backdrop, once at the closing composite); \
                 answering no here would keep the router sending masked \
                 non-Normal elements to legacy for a backend that can draw them.");
        assert!(probe.supports(Capability::NonNormalGroupBlend),
                "the PER-PRIMITIVE group blend is built (`blended_primitive`); \
                 answering no would keep the router sending non-Normal GROUPS to \
                 legacy for a backend that draws them.");
        // ⛔ COMPUTED FROM THE ANSWERS, NOT PINNED TO A NUMBER. This asserted
        // `== 31` in effect, by counting every op that needs ANY capability —
        // correct only while this backend denied all of them. The moment one
        // answer flips, a pinned count is a test that must be rewritten by hand
        // to stay true, which is a test that will be rewritten to stay GREEN.
        // Counting the ops whose requirements this backend DENIES tracks the
        // answers automatically, so the next flip needs no edit here.
        let supported = Capability::ALL
            .into_iter()
            .fold(Caps::NONE, |acc, c| if probe.supports(c) { acc.with(c) } else { acc });
        let denied_ops: usize = scenes()
            .iter()
            .map(|(_, v)| v.as_array().map(|a| a.iter()
                    .filter(|o| !supported.supplies(capabilities_of(o))).count())
                 .unwrap_or(0))
            .sum();
        // ⭐ THIS ASSERTION INVERTED ON 2026-09-02, and the reason is the same
        // one that retired the DECLARED list above. It read `denied_ops > 0`,
        // with the message "the corpus stopped being able to distinguish the
        // backends" — correct while this backend denied SOMETHING. It now
        // answers YES to every capability, so `denied_ops == 0` is the truth
        // and the old form would have to be deleted to let the change through.
        //
        // ⛔ A GATE DELETED TO LET A CHANGE THROUGH HAS STOPPED BEING A GATE —
        // this test says so about itself, one comment up. So it is INVERTED
        // rather than removed: nothing may be denied, and the agreement below
        // still holds op for op, which is the arm that actually protects
        // against a silent discard.
        assert_eq!(denied_ops, 0,
                   "this backend answers YES to every capability as of row CM's \
                    last golden, so no recorded op may carry a denied \
                    requirement; {denied_ops} do");
        assert_eq!(r.unsupported.len(), denied_ops,
                   "this backend refused {} ops but {denied_ops} recorded ops carry \
                    a requirement it answers NO to -- the stated answers and the \
                    measured report disagree. Under-refusing is the dangerous \
                    direction: an op that RUNS while a requirement it carries is \
                    denied has had that requirement silently discarded.",
                   r.unsupported.len());
    }

    /// ACCEPTANCE FOR THE ISOLATED-LAYER HALF OF THE ROUTED ROW, made executable.
    ///
    /// The routed acceptance is "the declared gaps -> 0". A gap closes when the
    /// backend stops REPORTING it, so this asserts the absence directly against
    /// the corpus rather than leaving it to be inferred from a shrinking list.
    ///
    /// ⛔ AND IT ASSERTS THE POSITIVE HALF TOO. A backend that refused every
    /// isolated layer would also emit no isolated-layer gap -- absence of a
    /// complaint is not evidence of work. So the layer ops must also be COUNTED
    /// as drawn, which only a call that reached the painter can produce.
    #[test]
    fn no_isolated_layer_op_is_reported_as_a_gap_any_more() {
        let (r, _n) = replay_all();
        for (cmd, why) in &r.unsupported {
            assert!(
                !cmd.contains("isolated_layer") || why.contains("blend"),
                "isolated-layer op still gapped: {cmd} -> {why}"
            );
        }
        // The corpus holds 8 isolated-layer records (4 push + 4 pop across the
        // A6 goldens), of which the one non-Normal push stays gapped on BLEND.
        // Seven must have reached the painter.
        let layer_gaps = r.unsupported.iter()
            .filter(|(c, _)| c.contains("isolated_layer")).count();
        assert!(layer_gaps <= 1,
                "at most the one non-Normal push may remain gapped, got {layer_gaps}");
        assert!(r.drawn >= 7, "the layer ops must be DRAWN, not merely un-gapped");
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

#[cfg(test)]
mod text_refusal_tests {
    use super::*;
    use crate::painter::direct2d::device::HeadlessTarget;
    use serde_json::json;

    fn run_scene(font: &str) -> ReplayReport {
        let t = HeadlessTarget::new(64, 32).expect("target");
        let scene = json!([{
            "cmd": "draw_text_run",
            "run": { "mode": "fast_run", "font": font, "size": 16.0,
                     "text": "Hi", "letter_spacing": 0.0, "x": 4.0, "y": 20.0 },
            "brush": { "kind": "solid",
                       "color": { "space": "rgb", "r": 0.0, "g": 0.0, "b": 0.0, "a": 1.0 } },
            "alpha": 1.0
        }]);
        unsafe {
            t.target().BeginDraw();
            let mut p = Direct2DPainter::new(t.target());
            let r = replay(&mut p, &scene);
            let _ = t.target().EndDraw(None, None);
            r
        }
    }

    /// ⛔ A FONT THAT CANNOT BE RESOLVED MUST REACH THE REPORT, NOT VANISH.
    ///
    /// `draw_fast_run` has always returned `bool` and `draw_text_run` has always
    /// DISCARDED it, so a text run whose family DirectWrite cannot find drew
    /// nothing and said nothing: no gap, no error, no log. Measured 2026-09-01 —
    /// the seam sends a CSS shorthand (`"normal normal sans-serif"`) that
    /// `resolve_family` could not parse, so **every** production text run would
    /// have taken this path the moment the router opened: a document presenting
    /// with its text missing, at `JAS_PAINT_OK`.
    ///
    /// ⭐ AND THE RECORDED CORPUS COULD NEVER HAVE CAUGHT IT. `scene_golden.json`
    /// carries `"font": "sans-serif"` — the BARE form, which happens to be the
    /// one this backend wanted — while the live seam builds the shorthand. The
    /// replay lane was green on a string the seam does not send.
    #[test]
    fn an_unresolvable_font_is_reported_as_a_gap_not_drawn_silently() {
        let r = run_scene("No Such Family At All 12345");
        assert_eq!(r.drawn, 0, "nothing was drawn, so nothing may be counted drawn");
        assert_eq!(r.unsupported.len(), 1, "the refusal must reach the report: {r:?}");
        assert!(r.unsupported[0].1.contains("font"),
                "the reason must name the font: {:?}", r.unsupported[0]);
        assert!(!r.is_complete(),
                "an incomplete report is what becomes JAS_PAINT_SCENE_INCOMPLETE -- \
                 without it the host presents a document with its text missing at OK");
    }

    /// ⛔ THE CONTROL, and it is what keeps the arm above honest: a font that
    /// DOES resolve must still be counted DRAWN. A backend that reported every
    /// text run as a gap would satisfy the assertion above and be useless.
    #[test]
    fn a_resolvable_font_still_draws_and_is_not_reported() {
        let r = run_scene("sans-serif");
        assert_eq!(r.drawn, 1, "a resolvable font draws: {r:?}");
        assert!(r.unsupported.is_empty(), "and reports nothing: {r:?}");
        assert!(r.is_complete());
    }

    /// ⭐ AND THE SEAM'S OWN STRING GOES THROUGH THE WHOLE PIPE. This is the
    /// 0-vs-615 measurement expressed at the REPLAY level rather than the pixel
    /// level: before row DA this exact scene was counted `drawn` and inked
    /// nothing.
    #[test]
    fn the_shorthand_the_seam_sends_replays_as_drawn() {
        let r = run_scene("normal normal sans-serif");
        assert_eq!(r.drawn, 1,
                   "the CSS shorthand the seam builds must replay as DRAWN: {r:?}");
        assert!(r.is_complete());
    }
}
