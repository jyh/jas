//! Widget commit rules: the pure part of "the user typed this into a widget,
//! what gets written to state".
//!
//! Lives outside `renderer` (which is `feature = "web"` only) so the same
//! functions the running app uses are reachable from the native
//! `algorithm_roundtrip` binary, i.e. gateable against JasSwift by
//! `scripts/cross_language_algorithms.py --algo number_commit`
//! (`test_fixtures/algorithms/number_commit.json`).

/// The value a `number_input` commit writes, or `None` to leave state
/// UNCHANGED.
///
/// Accept the text only if it is a number by the live reference's rule, then
/// clamp to the bounds the widget's YAML DECLARES. `None` means the reference
/// would have refused the write (`type_mismatch`), so nothing is written —
/// where this port previously wrote `parse().unwrap_or(0.0)`, turning "abc" and
/// a cleared field into a committed 0.
pub fn number_input_commit(text: &str, min: Option<f64>, max: Option<f64>) -> Option<f64> {
    parse_numeric_string(text).map(|v| clamp_to_declared(v, min, max))
}

/// A numeric string by the live reference's grammar — `^-?\d+(\.\d+)?$`
/// (`workspace_interpreter/schema.py`'s `_NUMBER_STR_RE`, applied by
/// `coerce_value` for a `type: number` field) — parsed to `f64`; `None` if the
/// string is not of that form.
///
/// Deliberately NARROWER than `str::parse::<f64>`, which also accepts `1e10`,
/// `+5`, `.5`, `12.`, `inf` and `NaN`. Those are what a number-typed field
/// REJECTS in the reference, and JasSwift's `coerceValue` already rejected them
/// via the same grammar; parsing them here is how a typed `inf` reached the
/// clamp (and a typed `NaN` reached `serde_json`, which stores a non-finite
/// number as `null`).
///
/// The digit test is ASCII. The reference's `\d` is Python's Unicode-aware one
/// and `float()` accepts Unicode decimal digits, so `float("\u{661}\u{662}")`
/// is 12.0 there; both active ports answer `None` for that string, because
/// Rust's and Swift's float parsers are ASCII-only. That difference is real,
/// it is NOT gated by the corpus, and it is banked as such — do not read this
/// function as claiming full agreement with the reference on non-ASCII input.
pub fn parse_numeric_string(s: &str) -> Option<f64> {
    let body = s.strip_prefix('-').unwrap_or(s);
    let (int_part, frac_part) = match body.split_once('.') {
        Some((i, f)) => (i, Some(f)),
        None => (body, None),
    };
    let all_digits = |t: &str| !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit());
    if !all_digits(int_part) {
        return None;
    }
    if let Some(f) = frac_part {
        if !all_digits(f) {
            return None;
        }
    }
    s.parse::<f64>().ok()
}

/// Clamp a widget commit to the bounds its YAML DECLARES, leaving an
/// undeclared bound alone (Tracking is signed and declares neither).
///
/// One function rather than an inline pair of `if`s at each call site because
/// the call sites disagreed: the panel branch of `render_number_input`
/// clamped and the dialog branch did not, so typing 150 into the Color Picker's
/// `c` field (declared `max: 100`) committed 100 in JasSwift — whose
/// `renderNumberInput` clamps on commit — and 150 here, and that 150 then
/// reached `cmyk()`. Risk R9's widget half, transcripts/CORPUS_CENSUS.md §7.
pub fn clamp_to_declared(v: f64, min: Option<f64>, max: Option<f64>) -> f64 {
    let mut v = v;
    if let Some(lo) = min {
        if v < lo {
            v = lo;
        }
    }
    if let Some(hi) = max {
        if v > hi {
            v = hi;
        }
    }
    v
}
