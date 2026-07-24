//! pen_spike — Arc 2 prototype #2: pen-latency measurement *plumbing*.
//!
//! Ratified pen pipeline (council #3): raw `WM_POINTER`, a dedicated input
//! thread eventually, and sub-20 ms motion-to-photon on real iron. This crate is
//! the PLUMBING phase: it builds and unit-tests the measurement apparatus. The
//! MEASURED runs (an interactive desktop session, later the Wacom over USB
//! passthrough) are a human desk-sitting and are out of this phase's scope.
//!
//! # Split
//!
//! * This **library** is pure, platform-independent logic: a QPC latency ledger
//!   ([`ledger`]), microsecond stats ([`stats`]), tick conversion ([`qpc`]), and
//!   the JSON/CSV report writers ([`report`]). It compiles and `cargo test`s on
//!   ANY host, including the Mac — the frequency and every timestamp are data.
//! * The **binary** (`src/main.rs`) is Windows-only: raw Win32 `WM_POINTER`
//!   input plus a minimal wgpu ink trail, feeding this ledger. On non-Windows it
//!   is a stub that points you at `cargo test`.
//!
//! # What the ledger measures (and does not)
//!
//! The four instants captured per event bracket the **app-internal** path:
//! hardware timestamp -> handler receipt -> encode start -> present submitted.
//! That is a strict *lower bound* on true motion-to-photon latency: it excludes
//! compositor, scan-out, and panel response, which need real hardware and a
//! high-speed camera to measure. The ratified verdict line labels the
//! app-internal figure as a LOWER BOUND for exactly this reason.

pub mod ledger;
pub mod qpc;
pub mod report;
pub mod stats;
