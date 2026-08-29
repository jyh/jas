//! ONE DISPATCH, DRIVING THE RECORDED CORPUS THROUGH ANY [`Painter`].
//!
//! #56 got both backends reading the same ARTIFACT. This gets them running the
//! same DISPATCH: the per-command decode-and-call loop lived twice — once in
//! `direct2d/replay.rs` (native, Windows) and once inside the Canvas2D browser
//! test — and a capability answer measured by two different loops is two
//! measurements of two things.
//!
//! ⚠️ WHAT THIS MEASURES, AND WHAT IT DOES NOT. It reports whether each recorded
//! command EXECUTED or was REFUSED. It says nothing about pixels — the goldens
//! own what a scene looks like. That narrow question is exactly what
//! [`Painter::supports`] claims an answer to, which is why
//! [`assert_answers_match_the_corpus`] can hold a backend's stated answers
//! against what driving the corpus actually did.
//!
//! 📌 `direct2d/replay.rs` still carries its own loop and its own private copies
//! of the decoders. It is Windows- and `d2d`-gated and CANNOT BE COMPILED on the
//! machine this landed from, so folding it onto this one would be an
//! unverifiable edit whose only instrument is CI. It gets the capability
//! cross-check in its own file instead, computed from the same corpus.

use serde_json::Value;

use super::capability::{capability_of, Capability};
use super::replay_decode as d;
use super::{Painter, TextRun};

/// What driving one scene did. `refused` carries the op INDEX and its `cmd`, so
/// a refusal can be traced back to the recorded command that caused it — a bare
/// count could not be classified, and classification is the whole point here.
#[derive(Debug, Default)]
pub(crate) struct DriveReport {
    pub executed: usize,
    pub refused: Vec<(usize, String)>,
}

/// Drive one decoded scene through `p`.
///
/// ⛔ NOTHING IS SKIPPED SILENTLY. A command this dispatch cannot issue is
/// RECORDED as refused rather than passed over, because a driver that quietly
/// ignored what it could not do would report a clean replay of a scene it had
/// half-drawn.
pub(crate) fn drive(p: &mut dyn Painter, ops: &[Value]) -> DriveReport {
    let mut r = DriveReport::default();
    for (i, op) in ops.iter().enumerate() {
        let Some(cmd) = op.get("cmd").and_then(Value::as_str) else {
            r.refused.push((i, "<no cmd>".to_string()));
            continue;
        };
        let a = op.get("alpha").and_then(Value::as_f64).unwrap_or(1.0);
        let br = op.get("brush").and_then(d::brush);
        let ok = match cmd {
            "fill_rect" => br.map(|b| p.fill_rect(d::rect(op.get("rect").unwrap()), &b, a)).is_some(),
            "stroke_rect" => br.map(|b| p.stroke_rect(
                d::rect(op.get("rect").unwrap()), &b,
                &d::stroke(op.get("stroke").unwrap()), a)).is_some(),
            "fill_path" => br.map(|b| p.fill_path(
                &d::path(op.get("path").unwrap()), d::winding(op), &b, a)).is_some(),
            "stroke_path" => br.map(|b| p.stroke_path(
                &d::path(op.get("path").unwrap()), &b,
                &d::stroke(op.get("stroke").unwrap()), a)).is_some(),
            "fill_ellipse_arc" => br.map(|b| p.fill_ellipse_arc(
                &d::arc(op.get("arc").unwrap()), d::winding(op), &b, a)).is_some(),
            "stroke_ellipse_arc" => br.map(|b| p.stroke_ellipse_arc(
                &d::arc(op.get("arc").unwrap()), &b,
                &d::stroke(op.get("stroke").unwrap()), a)).is_some(),
            "clip" => { p.clip(&d::path(op.get("path").unwrap()), d::winding(op)); true }
            "push_state" => { p.push_state(d::transform(op.get("transform").unwrap())); true }
            "pop_state" => { p.pop_state(); true }
            "push_group" => d::blend(op).map(|b| p.push_group(a, b)).is_some(),
            "pop_group" => { p.pop_group(); true }
            "push_isolated_layer" => d::blend(op).map(|b| p.push_isolated_layer(a, b)).is_some(),
            "pop_isolated_layer" => { p.pop_isolated_layer(); true }
            "push_mask_layer" => d::mask(op).map(|m| p.push_mask_layer(m)).is_some(),
            "pop_mask_layer" => { p.pop_mask_layer(); true }
            "draw_text_run" => {
                let run = op.get("run").unwrap_or(&Value::Null);
                match run.get("mode").and_then(Value::as_str) {
                    Some("fast_run") => {
                        let tr = TextRun::FastRun {
                            font: run.get("font").and_then(Value::as_str)
                                .unwrap_or("sans-serif").to_string(),
                            size: d::f(run, "size"),
                            text: run.get("text").and_then(Value::as_str).unwrap_or("").to_string(),
                            letter_spacing: d::f(run, "letter_spacing"),
                            x: d::f(run, "x"),
                            y: d::f(run, "y"),
                        };
                        match br { Some(b) => { p.draw_text_run(&tr, &b, a); true } None => false }
                    }
                    // PlacedGlyphs is PH3 and the corpus holds none. This arm
                    // says so rather than pretending -- and note it is NOT a
                    // Capability: a capability nothing in the corpus drives
                    // would be a stale entry with a future.
                    _ => false,
                }
            }
            _ => false,
        };
        if ok { r.executed += 1; } else { r.refused.push((i, cmd.to_string())); }
    }
    r
}

/// ⚖️ THE ANSWERS ARE CHECKED, NOT TRUSTED.
///
/// Holds a backend's stated [`Painter::supports`] answers against what driving
/// the WHOLE corpus through it actually did, in both directions:
///
/// * every REFUSAL must be an op that needs a capability the backend answers
///   NO to — a refusal with no capability behind it is an undeclared gap, and a
///   refusal of a capability the backend CLAIMS is a false yes;
/// * every op needing a capability the backend answers NO to must have BEEN
///   refused — otherwise the backend is executing something it says it cannot,
///   and the "no" is a false no that routes work away for no reason.
///
/// `scenes` is `(name, ops, refused)` per scene, so a failure names its scene.
pub(crate) fn assert_answers_match_the_corpus(
    supports: &dyn Fn(Capability) -> bool,
    scenes: &[(&str, Vec<Value>, Vec<(usize, String)>)],
) {
    // ANTI-VACUITY: with no scenes, every loop below is empty and every
    // assertion holds. A backend could then "agree with the corpus" having
    // touched none of it.
    let total: usize = scenes.iter().map(|(_, ops, _)| ops.len()).sum();
    assert!(
        scenes.len() >= 20 && total >= 124,
        "the corpus shrank to {} scenes / {total} ops; this check compares a \
         backend against whatever it is given",
        scenes.len()
    );

    let mut needed_and_refused = 0usize;
    for (name, ops, refused) in scenes {
        for (i, cmd) in refused {
            match capability_of(&ops[*i]) {
                None => panic!(
                    "{name}: op {i} ({cmd}) was REFUSED but needs no capability -- \
                     an undeclared gap, which is the shape a silent skip takes \
                     once someone starts counting"
                ),
                Some(c) => assert!(
                    !supports(c),
                    "{name}: op {i} ({cmd}) was REFUSED, but this backend answers \
                     YES to {c:?} -- the stated answer is a claim the fixtures \
                     contradict"
                ),
            }
        }
        for (i, op) in ops.iter().enumerate() {
            if let Some(c) = capability_of(op) {
                if !supports(c) {
                    assert!(
                        refused.iter().any(|(j, _)| j == &i),
                        "{name}: op {i} needs {c:?}, this backend answers NO to it, \
                         and yet it EXECUTED -- a false no routes work to legacy \
                         for a reason that is not real"
                    );
                    needed_and_refused += 1;
                }
            }
        }
    }
    // A backend answering YES to everything makes the loops above vacuous in the
    // second direction; that is correct (there is nothing to refuse) and the
    // first direction still has teeth. Report the number so a reader can see
    // which case they are in rather than inferring it from a green.
    eprintln!(
        "capability cross-check: {} scenes, {total} ops, {needed_and_refused} \
         capability-refusals matched",
        scenes.len()
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::painter::corpus::SCENES;
    use crate::painter::recording::RecordingPainter;

    /// Decode every recorded scene once.
    fn scenes() -> Vec<(&'static str, Vec<Value>)> {
        SCENES
            .iter()
            .map(|(name, text)| {
                let v: Value = serde_json::from_str(text).expect("corpus scene must parse");
                (*name, v.as_array().expect("a scene is an array").clone())
            })
            .collect()
    }

    /// ⛔ THE DISPATCH ITSELF, EXECUTED NATIVELY. Before this, the shared loop
    /// ran only in a browser (Canvas2D) or only on Windows (D2D) — so on the
    /// machine most of this repo is written on, it was compile-verified only,
    /// and a decode arm that never fired was indistinguishable from one that
    /// worked. `RecordingPainter` refuses nothing, so every command must
    /// execute and the count must be the corpus's own.
    #[test]
    fn the_shared_dispatch_executes_every_recorded_command() {
        let mut executed = 0usize;
        let mut total = 0usize;
        for (name, ops) in scenes() {
            let mut p = RecordingPainter::new();
            let r = drive(&mut p, &ops);
            assert!(
                r.refused.is_empty(),
                "{name}: the recorder refused {:?} -- it materialises every call, \
                 so a refusal here is the DISPATCH failing to decode, not a \
                 backend limit",
                r.refused
            );
            assert_eq!(r.executed, ops.len(), "{name}: executed {} of {}", r.executed, ops.len());
            executed += r.executed;
            total += ops.len();
        }
        assert!(total >= 124, "the corpus shrank to {total} ops");
        assert_eq!(executed, total);
    }

    /// The recorder's stated answers, held against what driving the corpus did.
    /// It answers YES to everything and refuses nothing, so the two agree — and
    /// the arm below proves this comparison can fail.
    #[test]
    fn the_recorders_answers_match_what_the_corpus_measured() {
        let mut per_scene = Vec::new();
        for (name, ops) in scenes() {
            let mut p = RecordingPainter::new();
            let r = drive(&mut p, &ops);
            per_scene.push((name, ops, r.refused));
        }
        let p = RecordingPainter::new();
        assert_answers_match_the_corpus(&|c| p.supports(c), &per_scene);
    }

    /// ⛔ THE CROSS-CHECK MUST BE ABLE TO FAIL, AND IN BOTH DIRECTIONS.
    /// A backend that executes the whole corpus while CLAIMING it cannot do
    /// layers is a false no; one that refuses an op while claiming it can is a
    /// false yes. Both are caught here against the real corpus, so the arm that
    /// protects the live backends is itself driven.
    #[test]
    fn a_lying_backend_is_caught_in_both_directions() {
        let mut per_scene = Vec::new();
        for (name, ops) in scenes() {
            let mut p = RecordingPainter::new();
            let r = drive(&mut p, &ops);
            per_scene.push((name, ops, r.refused));
        }
        // FALSE NO: answers "no" to layers, yet executed all of them.
        let caught = std::panic::catch_unwind(|| {
            assert_answers_match_the_corpus(
                &|c| c != Capability::IsolatedLayers,
                &per_scene,
            );
        });
        assert!(caught.is_err(), "a false NO went undetected");

        // FALSE YES: a scene whose layer ops were refused, by a backend claiming
        // it supports them. Built from the corpus rather than invented: the
        // refusals are the real ops that need IsolatedLayers.
        let faked: Vec<(&str, Vec<Value>, Vec<(usize, String)>)> = per_scene
            .iter()
            .map(|(n, ops, _)| {
                let refused = ops
                    .iter()
                    .enumerate()
                    .filter(|(_, o)| capability_of(o) == Some(Capability::IsolatedLayers))
                    .map(|(i, o)| (i, o["cmd"].as_str().unwrap().to_string()))
                    .collect();
                (*n, ops.clone(), refused)
            })
            .collect();
        let caught = std::panic::catch_unwind(|| {
            assert_answers_match_the_corpus(&|_| true, &faked);
        });
        assert!(caught.is_err(), "a false YES went undetected");

        // ...and an UNDECLARED gap: a baseline op refused by a backend that
        // claims everything. This is the silent-skip shape, once counted.
        let baseline_refusal: Vec<(&str, Vec<Value>, Vec<(usize, String)>)> = per_scene
            .iter()
            .map(|(n, ops, _)| {
                let refused = ops
                    .iter()
                    .enumerate()
                    .find(|(_, o)| capability_of(o).is_none())
                    .map(|(i, o)| vec![(i, o["cmd"].as_str().unwrap().to_string())])
                    .unwrap_or_default();
                (*n, ops.clone(), refused)
            })
            .collect();
        let caught = std::panic::catch_unwind(|| {
            assert_answers_match_the_corpus(&|_| true, &baseline_refusal);
        });
        assert!(caught.is_err(), "an undeclared gap went undetected");
    }
}
