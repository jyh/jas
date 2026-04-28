/// Unit-aware length parser / formatter.
///
/// Companion to the `length_input` widget — see `UNIT_INPUTS.md` for the
/// spec these helpers implement. Mirrors:
/// - `workspace_interpreter/length.py` (Flask, Python apps)
/// - `jas_dioxus/src/interpreter/length.rs`
/// - `jas_flask/static/js/app.js` (`parseLength` / `formatLength`)
///
/// Keep all four implementations in lockstep on the conversion table and
/// rounding rules. The parity tests under `JasSwift/Tests/Interpreter/`
/// pin the same edge cases.
///
/// Canonical storage unit: `pt`. Every value committed to state, every
/// length attribute written to SVG, is a pt-valued `Double`.
///
/// Supported units: `pt`, `px`, `in`, `mm`, `cm`, `pc`. Unit suffixes
/// parse case-insensitively; bare numbers are interpreted in the
/// widget's declared default unit.

import Foundation

public enum Length {

    /// Names of units accepted by `parse` and produced by `format`.
    public static let SUPPORTED_UNITS: [String] = ["pt", "px", "in", "mm", "cm", "pc"]

    /// Return the pt-equivalent of one of the named units, or `nil` when
    /// the name is not in `SUPPORTED_UNITS` (case-insensitive).
    public static func ptPerUnit(_ unit: String) -> Double? {
        switch unit.lowercased() {
        case "pt": return 1.0
        // CSS reference 96 dpi: 1 px = 1/96 in, 1 pt = 1/72 in
        // ⇒ 1 px = 72/96 = 0.75 pt.
        case "px": return 0.75
        case "in": return 72.0
        case "mm": return 72.0 / 25.4
        case "cm": return 720.0 / 25.4
        case "pc": return 12.0
        default: return nil
        }
    }

    /// Parse a user-typed length string into a value in points.
    ///
    /// Bare numbers are interpreted in `defaultUnit`. A unit suffix
    /// (case-insensitive) overrides the default. Whitespace is tolerated
    /// around / between the number and the unit. Returns `nil` for
    /// empty / whitespace-only input, syntactically malformed input, or
    /// inputs carrying an unsupported unit. Per `UNIT_INPUTS.md` §Edge
    /// cases — callers decide whether `nil` means "commit null on a
    /// nullable field" or "revert to prior value".
    public static func parse(_ input: String, defaultUnit: String) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        let chars = Array(trimmed)
        var i = 0

        // Optional leading sign.
        let numStart = i
        if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }

        var sawDigitBeforeDot = false
        var sawDot = false
        var sawDigitAfterDot = false
        while i < chars.count {
            let c = chars[i]
            if c.isASCII && c.isNumber {
                if sawDot { sawDigitAfterDot = true } else { sawDigitBeforeDot = true }
                i += 1
            } else if c == "." && !sawDot {
                sawDot = true
                i += 1
            } else {
                break
            }
        }

        // Reject lone `-` / `.` / `-.` (no digits at all).
        if !sawDigitBeforeDot && !sawDigitAfterDot { return nil }
        let numEnd = i
        let numStr = String(chars[numStart..<numEnd])
        guard let value = Double(numStr) else { return nil }

        // Skip whitespace between number and unit.
        while i < chars.count, chars[i].isWhitespace { i += 1 }

        // Optional unit (alphabetic, ASCII).
        let unitStart = i
        while i < chars.count, chars[i].isLetter, chars[i].isASCII { i += 1 }
        let unitEnd = i

        // Trailing whitespace permitted; anything else is garbage.
        while i < chars.count {
            if chars[i].isWhitespace { i += 1 } else { return nil }
        }

        let unitStr: String
        if unitEnd > unitStart {
            unitStr = String(chars[unitStart..<unitEnd])
        } else {
            unitStr = defaultUnit
        }
        guard let factor = ptPerUnit(unitStr) else { return nil }
        return value * factor
    }

    /// Render a pt value as a display string in the named unit.
    ///
    /// `nil` formats as an empty string (used by nullable dash / gap
    /// fields when no value is set). Trailing zeros and a stranded
    /// trailing decimal point are trimmed. An unknown / unsupported
    /// `unit` falls back to `pt` rather than producing a malformed
    /// output.
    public static func format(_ pt: Double?, unit: String, precision: Int) -> String {
        guard let pt = pt, pt.isFinite else { return "" }
        let displayUnit: String
        let factor: Double
        if let f = ptPerUnit(unit) {
            displayUnit = unit.lowercased()
            factor = f
        } else {
            displayUnit = "pt"
            factor = 1.0
        }
        let value = pt / factor
        // Format with `precision` decimal places. Add `+ 0.0` to
        // normalise `-0.0` → `0.0` on the round.
        let formatted = String(format: "%.\(precision)f", value + 0.0)
        let trimmed: String
        if formatted.contains(".") {
            var s = formatted
            while s.last == "0" { s.removeLast() }
            if s.last == "." { s.removeLast() }
            trimmed = s
        } else {
            trimmed = formatted
        }
        let final = trimmed == "-0" ? "0" : trimmed
        return "\(final) \(displayUnit)"
    }
}
