//! Unit-aware length parser / formatter.
//!
//! Companion to the `length_input` widget — see `UNIT_INPUTS.md` for
//! the spec these helpers implement. Mirrors:
//! - `workspace_interpreter/length.py` (Flask, Python apps)
//! - `jas_flask/static/js/app.js` (`parseLength` / `formatLength`)
//!
//! Keep all three implementations in lockstep on the conversion table
//! and rounding rules. The parity tests at the bottom of this file
//! pin the same edge cases the Python tests do.
//!
//! Canonical storage unit: `pt`. Every value committed to state, every
//! length attribute written to SVG, is a pt-valued `f64`.
//!
//! Supported units: `pt`, `px`, `in`, `mm`, `cm`, `pc`. Unit suffixes
//! parse case-insensitively; bare numbers are interpreted in the
//! widget's declared default unit.

/// Names of units accepted by `parse` and produced by `format`.
pub const SUPPORTED_UNITS: &[&str] = &["pt", "px", "in", "mm", "cm", "pc"];

/// Return the pt-equivalent of one of the named unit, or `None` when
/// the name is not in `SUPPORTED_UNITS` (case-insensitive comparison).
pub fn pt_per_unit(unit: &str) -> Option<f64> {
    match unit.to_ascii_lowercase().as_str() {
        "pt" => Some(1.0),
        // CSS reference 96 dpi: 1 px = 1/96 in, 1 pt = 1/72 in
        // ⇒ 1 px = 72/96 = 0.75 pt.
        "px" => Some(0.75),
        "in" => Some(72.0),
        "mm" => Some(72.0 / 25.4),
        "cm" => Some(720.0 / 25.4),
        "pc" => Some(12.0),
        _ => None,
    }
}

/// Parse a user-typed length string into a value in points.
///
/// Bare numbers are interpreted in `default_unit`. A unit suffix
/// (case-insensitive) overrides the default. Whitespace is tolerated
/// around / between the number and the unit. Returns `None` for
/// empty / whitespace-only input, syntactically malformed input, or
/// inputs carrying an unsupported unit. Per `UNIT_INPUTS.md` §Edge
/// cases — callers decide whether `None` means "commit null on a
/// nullable field" or "revert to prior value".
pub fn parse(input: &str, default_unit: &str) -> Option<f64> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }
    // Walk the trimmed string by characters: number then optional
    // letter-suffix unit, with optional whitespace between. Any
    // trailing non-whitespace garbage rejects.
    let mut chars = trimmed.char_indices().peekable();

    // Optional leading sign.
    let mut num_start = 0usize;
    let mut num_end = 0usize;
    if let Some(&(i, c)) = chars.peek() {
        if c == '-' || c == '+' {
            num_start = i;
            num_end = i + c.len_utf8();
            chars.next();
        }
    }

    let mut saw_digit_before_dot = false;
    let mut saw_dot = false;
    let mut saw_digit_after_dot = false;

    while let Some(&(i, c)) = chars.peek() {
        if c.is_ascii_digit() {
            num_end = i + c.len_utf8();
            if saw_dot {
                saw_digit_after_dot = true;
            } else {
                saw_digit_before_dot = true;
            }
            chars.next();
        } else if c == '.' && !saw_dot {
            num_end = i + c.len_utf8();
            saw_dot = true;
            chars.next();
        } else {
            break;
        }
    }

    // Reject lone `-` / `.` / `-.` (no digits at all).
    if !saw_digit_before_dot && !saw_digit_after_dot {
        return None;
    }
    let num_str = &trimmed[num_start..num_end];
    let value: f64 = num_str.parse().ok()?;

    // Skip whitespace between number and unit.
    while let Some(&(_, c)) = chars.peek() {
        if c.is_whitespace() {
            chars.next();
        } else {
            break;
        }
    }

    // Optional unit (alphabetic, ASCII).
    let unit_start = chars.peek().map(|&(i, _)| i);
    let mut unit_end = unit_start;
    while let Some(&(i, c)) = chars.peek() {
        if c.is_ascii_alphabetic() {
            unit_end = Some(i + c.len_utf8());
            chars.next();
        } else {
            break;
        }
    }

    // Trailing whitespace permitted; anything else is garbage.
    while let Some(&(_, c)) = chars.peek() {
        if c.is_whitespace() {
            chars.next();
        } else {
            return None;
        }
    }

    let unit_str = match (unit_start, unit_end) {
        (Some(s), Some(e)) if e > s => &trimmed[s..e],
        _ => default_unit,
    };
    let factor = pt_per_unit(unit_str)?;
    Some(value * factor)
}

/// Render a pt value as a display string in the named unit.
///
/// `None` formats as an empty string (used by nullable dash / gap
/// fields when no value is set). Trailing zeros and a stranded
/// trailing decimal point are trimmed. An unknown / unsupported
/// `unit` falls back to `pt` rather than producing a malformed
/// output.
pub fn format(pt: Option<f64>, unit: &str, precision: usize) -> String {
    let Some(pt) = pt else { return String::new(); };
    if !pt.is_finite() {
        return String::new();
    }
    let (display_unit, factor) = match pt_per_unit(unit) {
        Some(f) => (unit.to_ascii_lowercase(), f),
        None => ("pt".to_string(), 1.0),
    };
    let value = pt / factor;
    // Round to `precision` decimal places, half-away-from-zero — the
    // implicit behaviour of `format!("{:.N}")` plus a `+ 0.0` to
    // normalise -0.0 → 0.0 on the round.
    let rounded_text = format!("{:.*}", precision, value + 0.0);
    // Trim trailing zeros and a stranded trailing decimal point.
    let trimmed = if rounded_text.contains('.') {
        let s = rounded_text.trim_end_matches('0').trim_end_matches('.');
        s.to_string()
    } else {
        rounded_text
    };
    let trimmed = if trimmed == "-0" { "0".to_string() } else { trimmed };
    format!("{} {}", trimmed, display_unit)
}

// ── Tests ────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ─ Conversion table ──────────────────────────────────────────

    #[test]
    fn pt_per_unit_known() {
        assert_eq!(pt_per_unit("pt"), Some(1.0));
        assert_eq!(pt_per_unit("px"), Some(0.75));
        assert_eq!(pt_per_unit("in"), Some(72.0));
        assert!((pt_per_unit("mm").unwrap() - 72.0 / 25.4).abs() < 1e-12);
        assert!((pt_per_unit("cm").unwrap() - 720.0 / 25.4).abs() < 1e-12);
        assert_eq!(pt_per_unit("pc"), Some(12.0));
    }

    #[test]
    fn pt_per_unit_unknown_returns_none() {
        assert_eq!(pt_per_unit("dpi"), None);
        assert_eq!(pt_per_unit(""), None);
    }

    #[test]
    fn pt_per_unit_case_insensitive() {
        assert_eq!(pt_per_unit("PT"), Some(1.0));
        assert_eq!(pt_per_unit("In"), Some(72.0));
    }

    // ─ parse: bare number, default unit ──────────────────────────

    #[test]
    fn parse_bare_number_uses_default_unit() {
        assert_eq!(parse("12", "pt"), Some(12.0));
        assert_eq!(parse("12", "px"), Some(9.0));
        assert_eq!(parse("12", "in"), Some(864.0));
    }

    #[test]
    fn parse_bare_decimal() {
        assert_eq!(parse("12.5", "pt"), Some(12.5));
        assert_eq!(parse("0.5", "pt"), Some(0.5));
    }

    #[test]
    fn parse_leading_dot_decimal() {
        assert_eq!(parse(".5", "pt"), Some(0.5));
    }

    #[test]
    fn parse_trailing_dot_decimal() {
        assert_eq!(parse("5.", "pt"), Some(5.0));
    }

    #[test]
    fn parse_negative() {
        assert_eq!(parse("-3", "pt"), Some(-3.0));
        assert_eq!(parse("-3.5", "pt"), Some(-3.5));
        assert_eq!(parse("-.5", "pt"), Some(-0.5));
    }

    #[test]
    fn parse_zero() {
        assert_eq!(parse("0", "pt"), Some(0.0));
        assert_eq!(parse("0.0", "pt"), Some(0.0));
        assert_eq!(parse("-0", "pt"), Some(0.0));
    }

    // ─ parse: with unit suffix ───────────────────────────────────

    #[test]
    fn parse_with_pt_suffix() {
        assert_eq!(parse("12 pt", "pt"), Some(12.0));
        assert_eq!(parse("12pt", "pt"), Some(12.0));
        assert_eq!(parse("12  pt", "pt"), Some(12.0));
    }

    #[test]
    fn parse_with_px_suffix() {
        assert_eq!(parse("12 px", "pt"), Some(9.0));
        assert_eq!(parse("12px", "pt"), Some(9.0));
    }

    #[test]
    fn parse_with_in_suffix() {
        assert_eq!(parse("1 in", "pt"), Some(72.0));
        assert_eq!(parse("0.5 in", "pt"), Some(36.0));
    }

    #[test]
    fn parse_with_mm_suffix() {
        let got = parse("25.4 mm", "pt").unwrap();
        assert!((got - 72.0).abs() < 1e-9);
        let got = parse("5 mm", "pt").unwrap();
        assert!((got - 5.0 * 72.0 / 25.4).abs() < 1e-9);
    }

    #[test]
    fn parse_with_cm_suffix() {
        let got = parse("2.54 cm", "pt").unwrap();
        assert!((got - 72.0).abs() < 1e-9);
    }

    #[test]
    fn parse_with_pc_suffix() {
        assert_eq!(parse("1 pc", "pt"), Some(12.0));
        assert_eq!(parse("3 pc", "pt"), Some(36.0));
    }

    #[test]
    fn parse_case_insensitive_unit() {
        assert_eq!(parse("12 PT", "pt"), Some(12.0));
        assert_eq!(parse("12 Pt", "pt"), Some(12.0));
        assert_eq!(parse("12pT", "pt"), Some(12.0));
    }

    #[test]
    fn parse_unit_overrides_default() {
        assert_eq!(parse("12 px", "pt"), Some(9.0));
        // 12 pt regardless of widget default
        assert_eq!(parse("12 pt", "px"), Some(12.0));
    }

    // ─ parse: whitespace ─────────────────────────────────────────

    #[test]
    fn parse_strips_leading_whitespace() {
        assert_eq!(parse("  12", "pt"), Some(12.0));
        assert_eq!(parse("\t12 pt", "pt"), Some(12.0));
    }

    #[test]
    fn parse_strips_trailing_whitespace() {
        assert_eq!(parse("12  ", "pt"), Some(12.0));
        assert_eq!(parse("12 pt  ", "pt"), Some(12.0));
    }

    // ─ parse: rejection paths ────────────────────────────────────

    #[test]
    fn parse_empty_returns_none() {
        assert_eq!(parse("", "pt"), None);
        assert_eq!(parse("   ", "pt"), None);
    }

    #[test]
    fn parse_unit_only_returns_none() {
        assert_eq!(parse("pt", "pt"), None);
        assert_eq!(parse(" mm ", "pt"), None);
    }

    #[test]
    fn parse_unknown_unit_returns_none() {
        assert_eq!(parse("12 dpi", "pt"), None);
        assert_eq!(parse("12 ft", "pt"), None);
        assert_eq!(parse("12 foo", "pt"), None);
    }

    #[test]
    fn parse_extra_tokens_returns_none() {
        assert_eq!(parse("12 mm pt", "pt"), None);
        assert_eq!(parse("5 mm 3", "pt"), None);
        assert_eq!(parse("12pt5", "pt"), None);
    }

    #[test]
    fn parse_garbage_returns_none() {
        assert_eq!(parse("abc", "pt"), None);
        assert_eq!(parse("12.5.5", "pt"), None);
        assert_eq!(parse(".", "pt"), None);
        assert_eq!(parse("-", "pt"), None);
        assert_eq!(parse("-.", "pt"), None);
    }

    // ─ format ────────────────────────────────────────────────────

    #[test]
    fn format_integer_strips_decimal() {
        assert_eq!(format(Some(12.0), "pt", 2), "12 pt");
        assert_eq!(format(Some(0.0), "pt", 2), "0 pt");
        assert_eq!(format(Some(72.0), "in", 2), "1 in");
    }

    #[test]
    fn format_decimal() {
        assert_eq!(format(Some(12.5), "pt", 2), "12.5 pt");
        assert_eq!(format(Some(12.34), "pt", 2), "12.34 pt");
    }

    #[test]
    fn format_trims_trailing_zeros() {
        assert_eq!(format(Some(12.50), "pt", 2), "12.5 pt");
        assert_eq!(format(Some(12.500), "pt", 3), "12.5 pt");
        assert_eq!(format(Some(12.0), "pt", 4), "12 pt");
    }

    #[test]
    fn format_rounds_to_precision() {
        assert_eq!(format(Some(12.345), "pt", 2), "12.35 pt");
        assert_eq!(format(Some(12.344), "pt", 2), "12.34 pt");
    }

    #[test]
    fn format_converts_to_target_unit() {
        assert_eq!(format(Some(72.0), "in", 2), "1 in");
        // 1 pt ≈ 1.33 px
        assert_eq!(format(Some(1.0), "px", 2), "1.33 px");
    }

    #[test]
    fn format_mm() {
        assert_eq!(format(Some(72.0), "mm", 2), "25.4 mm");
    }

    #[test]
    fn format_negative() {
        assert_eq!(format(Some(-3.0), "pt", 2), "-3 pt");
        assert_eq!(format(Some(-3.5), "pt", 2), "-3.5 pt");
    }

    #[test]
    fn format_null_returns_empty() {
        assert_eq!(format(None, "pt", 2), "");
    }

    #[test]
    fn format_unknown_unit_falls_back_to_pt() {
        assert_eq!(format(Some(12.0), "dpi", 2), "12 pt");
    }

    // ─ round-trip ────────────────────────────────────────────────

    #[test]
    fn round_trip_format_then_parse() {
        for &pt in &[0.0_f64, 1.0, 12.0, 12.5, 72.0, 100.0, 0.75] {
            for unit in SUPPORTED_UNITS {
                let formatted = format(Some(pt), unit, 6);
                let back = parse(&formatted, unit).unwrap_or_else(|| {
                    panic!("round-trip parse failed for pt={pt} unit={unit} formatted={formatted:?}")
                });
                assert!(
                    (back - pt).abs() < 1e-3,
                    "round-trip diverged for pt={pt} unit={unit} formatted={formatted:?} back={back}",
                );
            }
        }
    }
}
