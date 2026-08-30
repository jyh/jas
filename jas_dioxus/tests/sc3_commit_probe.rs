//! **C3 — the commit interaction, PROBED on the existing surface.**
//!
//! Authorized as a RECON PROBE on work already built, under a no-build fence:
//! measure the commit on what exists, and if it turns out to need construction
//! to be measurable — as C2 did — **stop and report that** rather than building
//! the apply path to obtain a number. S-C.3 stays unopened; a result that argues
//! for opening it is a finding to report, not a licence to continue into it.
//!
//! # What C3 is
//!
//! §3.2: *commit a colour* — the apply path. `actions.yaml`'s `set_active_color`
//! is its named form: set the active attribute's colour AND push it to the front
//! of `recent_colors` (dedup, max 10). It is what a swatch click, a slider
//! RELEASE, a hex Enter and a colour-bar pointer-up all dispatch.
//!
//! # Why the answer here is a refusal and not a number
//!
//! Every arm below is paired with a POSITIVE CONTROL on the same channel, so a
//! refusal cannot be confused with a channel that was never alive. That is the
//! whole method: the interesting output of this file is *"the channel works, and
//! it will not carry this"*, which is a different claim from *"nothing
//! happened"*.
//!
//! ⛔ And the demonstrable half: after every attempt, `panel.recent_colors` is
//! **still empty**. A commit that had occurred would have pushed. The vacuity
//! guard runs the other way here — the probe must show that the thing did NOT
//! happen, so it asserts a state that a successful commit would have changed.

use std::sync::Mutex;

use jas_dioxus::ffi::{
    jas_bind_values, jas_dispatch_event, jas_engine_free, jas_engine_new, jas_free,
    jas_instr_counters_json, jas_instr_reset, jas_last_error_json, jas_panel_event,
    JasBytes, JasEngine, JasStatus,
};

const COLOUR: &str = "color_panel_content";

static SERIAL: Mutex<()> = Mutex::new(());

fn take(b: JasBytes) -> String {
    if b.ptr.is_null() {
        return String::new();
    }
    let s = unsafe { std::slice::from_raw_parts(b.ptr, b.len) };
    let out = String::from_utf8(s.to_vec()).unwrap();
    unsafe { jas_free(b) };
    out
}

/// The only way to read the counters in this binary — the same construction
/// `sc2_tick_protocol` uses, and for the same reason: a test that did not
/// serialise cannot obtain a reading at all, so it cannot forget to.
fn measure<R>(f: impl FnOnce() -> R) -> (R, serde_json::Value) {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    jas_instr_reset();
    let r = f();
    let dump: serde_json::Value =
        serde_json::from_str(&take(jas_instr_counters_json())).expect("counter dump is JSON");
    (r, dump)
}

fn serialised<R>(f: impl FnOnce() -> R) -> R {
    let _g = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
    f()
}

fn rows(e: *mut JasEngine) -> serde_json::Value {
    serde_json::from_str(&take(unsafe {
        jas_bind_values(e, COLOUR.as_ptr(), COLOUR.len())
    }))
    .unwrap()
}

/// What the first recent-colour slot displays. **The commit's own evidence**:
/// `set_active_color` pushes to the front of `recent_colors`, so this moves if
/// and only if a commit happened.
fn first_recent(e: *mut JasEngine) -> String {
    rows(e)
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == "cp_recent_0")
        .expect("the first recent slot")["value"]
        .as_str()
        .unwrap()
        .to_string()
}

fn panel_event(e: *mut JasEngine, ev: &str) -> (String, String) {
    let reply =
        take(unsafe { jas_panel_event(e, COLOUR.as_ptr(), COLOUR.len(), ev.as_ptr(), ev.len()) });
    let err = take(unsafe { jas_last_error_json(e) });
    (reply, err)
}

// ---------------------------------------------------------------------------
// The controls — both channels are alive
// ---------------------------------------------------------------------------

/// CONTROL A: the panel-event channel carries a value edit. Without this, every
/// refusal below would be indistinguishable from a dead extern.
#[test]
fn control_the_panel_event_channel_is_alive() {
    serialised(|| {
        let e = jas_engine_new();
        let _ = rows(e); // enrol the panel
        let (reply, _) = panel_event(e, r#"{"widget":"cp_h","key":"bind.value","value":210}"#);
        let changed: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert!(
            !changed.as_array().unwrap().is_empty(),
            "the value channel must carry a value edit"
        );
        unsafe { jas_engine_free(e) };
    });
}

/// CONTROL B: the op channel accepts a real document verb. Without this, an
/// `UnknownVerb` below would be indistinguishable from a broken dispatcher.
#[test]
fn control_the_op_channel_is_alive() {
    serialised(|| {
        let e = jas_engine_new();
        let op = r#"{"op":"create_artboard","id":"sc3ab001"}"#;
        assert_eq!(
            unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) },
            JasStatus::Ok,
            "the op channel must accept a document verb"
        );
        unsafe { jas_engine_free(e) };
    });
}

// ---------------------------------------------------------------------------
// The probe
// ---------------------------------------------------------------------------

/// ⛔ **ARM 1 — the op channel does not know the commit.** `set_active_color` is
/// a PANEL ACTION (`actions.yaml`), not one of `op_apply`'s document verbs, and
/// `op_apply` contains **zero** occurrences of `recent_colors`.
#[test]
fn the_commit_verb_is_not_in_the_document_vocabulary() {
    serialised(|| {
        let e = jas_engine_new();
        let before = first_recent(e);

        for op in [
            r##"{"op":"set_active_color","color":"#000000"}"##,
            r##"{"op":"set_active_color","params":{"color":"#000000"}}"##,
        ] {
            let st = unsafe { jas_dispatch_event(e, op.as_ptr(), op.len()) };
            assert_eq!(st, JasStatus::UnknownVerb, "op_apply must not know {op}");
            let err = take(unsafe { jas_last_error_json(e) });
            assert!(err.contains("\"class\":\"UnknownVerb\""), "{err}");
        }

        // The demonstrable half: nothing was committed.
        assert_eq!(first_recent(e), before, "recent_colors must not have moved");
        unsafe { jas_engine_free(e) };
    });
}

/// ⛔ **ARM 2 — the panel-event channel carries VALUES, not ACTIONS.**
///
/// The swatch that commits black declares `behavior: click -> set_active_color`.
/// Its only binding is `bind.color`, a LITERAL `"#000000"` — a value to display,
/// not a target to write. The event shape has no action verb at all: it names a
/// widget and a bound key, and a `click` is neither.
#[test]
fn the_panel_event_channel_has_no_action_half() {
    serialised(|| {
        let e = jas_engine_new();
        let _ = rows(e);
        let before = first_recent(e);

        for ev in [
            // The commit the swatch declares, addressed every way the existing
            // event shape allows.
            r##"{"widget":"cp_black_swatch","key":"bind.value","value":"#000000"}"##,
            r##"{"widget":"cp_black_swatch","key":"bind.color","value":"#000000"}"##,
            r#"{"widget":"cp_black_swatch","key":"click"}"#,
            // And the hex field's Enter, which `actions.yaml` also names as a
            // commit point. It writes the colour and does NOT push.
            r#"{"widget":"cp_hex","key":"behavior","value":"commit"}"#,
        ] {
            let (reply, err) = panel_event(e, ev);
            assert!(
                reply.is_empty() || reply == "[]",
                "no commit may be accepted: {ev} -> {reply}"
            );
            assert!(
                err.contains("MissingTarget") || err.contains("BadParamType"),
                "the refusal must be explicit: {ev} -> {err}"
            );
        }

        assert_eq!(first_recent(e), before, "recent_colors must not have moved");
        unsafe { jas_engine_free(e) };
    });
}

/// ⚠️ **ARM 3 — and the write path that DOES work is not a commit.**
///
/// A `bind.value` edit on the hex field changes the colour, which is half of
/// `set_active_color`. It does not push to `recent_colors`, which is the other
/// half and the half that distinguishes C3 from C2. **So the closest thing the
/// surface can do is a C2 tick wearing a commit's clothes**, and reporting its
/// cost as C3 would be reporting the interaction this spike did not perform.
#[test]
fn the_nearest_reachable_interaction_is_a_tick_not_a_commit() {
    let ((before, after, colour_moved), c) = measure(|| {
        let e = jas_engine_new();
        let _ = rows(e);
        let before = first_recent(e);
        let hex_before = current_hex(e);

        let (reply, _) = panel_event(e, r#"{"widget":"cp_hex","key":"bind.value","value":"00ff80"}"#);
        let changed: serde_json::Value = serde_json::from_str(&reply).unwrap_or(serde_json::json!([]));
        assert!(!changed.as_array().unwrap().is_empty(), "the hex write must land");

        let out = (before, first_recent(e), current_hex(e) != hex_before);
        unsafe { jas_engine_free(e) };
        out
    });

    assert!(colour_moved, "the colour half of a commit DID happen");
    assert_eq!(before, after, "and the recent_colors half did NOT");
    // Crossings are real, so the refusal above is not an artifact of a dead
    // boundary: this interaction crossed.
    assert!(c["crossings"].as_i64().unwrap() > 0, "the probe crossed the boundary");
}

fn current_hex(e: *mut JasEngine) -> String {
    rows(e)
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == "cp_hex" && r["key"] == "bind.value")
        .expect("the hex field's row")["value"]
        .as_str()
        .unwrap()
        .to_string()
}
