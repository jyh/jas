//! Capture/replay recorder (Arc 1 S2) — a fixture WRITER at the existing
//! conformance seams, emitting the EXISTING corpus shapes.
//!
//! v1 records at four seams and emits a downloadable "recording" JSON that
//! `scripts/ingest_recording.py` converts into registered corpus fixtures:
//!
//!   * GESTURE — the CanvasTool pointer seam (`on_press`/`on_move`/
//!     `on_release`), emitted in the `test_fixtures/gestures/` case shape.
//!   * ACTION — the `dispatch_action` seam, emitted in the
//!     `test_fixtures/actions/` case shape.
//!   * KEY — the `resolve_key` chord seam, emitted in the
//!     `test_fixtures/keys/` group shape.
//!   * JOURNAL — the committed-Transaction journal, emitted in the
//!     `test_fixtures/operations/` txns-form.
//!
//! Determinism laws (frozen in the Arc 1 blueprint):
//!   (a) every pointer event is converted SCREEN->DOC at write time using
//!       the model's live view AT THAT EVENT (mid-gesture pan/zoom safe);
//!       fixture event x/y are doc coords under an identity view, exactly
//!       the corpus convention;
//!   (b) floats are canonicalized to the corpus format (4-decimal round);
//!   (c) the recorder mints NO ids (draw commits mint none; op ids ride
//!       value-in-op).
//!
//! Segmentation law: one tool per gesture case; a tool switch, an action
//! dispatch, a history nav, or an app-state change ENDS the current case
//! and the next pointer event starts a new one (with a fresh setup
//! snapshot).
//!
//! See RECORDER.md at the repository root for activation, the record-stop
//! fidelity check, the ingest flow, and the v1 boundaries.

pub mod core;
