//! pen_spike measurement binary.
//!
//! On **Windows**: a raw Win32 `WM_POINTER` + wgpu ink-trail latency probe (see
//! [`win`]). On **any other host**: a stub — the measurement path is inherently
//! Win32, but the `pen_spike` library (ledger / stats / QPC / report) is
//! cross-platform and is exercised by `cargo test`.

#[cfg(windows)]
mod win;

#[cfg(windows)]
fn main() -> std::process::ExitCode {
    win::run()
}

#[cfg(not(windows))]
fn main() -> std::process::ExitCode {
    eprintln!(
        "pen_spike: the measurement binary is Windows-only (raw WM_POINTER + wgpu WARP)."
    );
    eprintln!(
        "The pen_spike library (latency ledger, QPC stats, CSV/JSON) is cross-platform —"
    );
    eprintln!("run `cargo test` on this host to exercise it.");
    std::process::ExitCode::from(2)
}
