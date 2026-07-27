/// Widget commit rules: the pure part of "the user typed this into a widget,
/// what gets written to state".
///
/// Mirror of jas_dioxus `src/interpreter/widget_commit.rs`; gated against it by
/// `scripts/cross_language_algorithms.py --algo number_commit`
/// (`test_fixtures/algorithms/number_commit.json`).
import Foundation

/// A numeric string by the live reference's grammar — `^-?\d+(\.\d+)?$`
/// (`workspace_interpreter/schema.py`'s `_NUMBER_STR_RE`, applied by
/// `coerce_value` for a `type: number` field) — parsed to `Double`; nil if the
/// string is not of that form.
///
/// `Schema.swift`'s `coerceValue` has always applied exactly this pair (this
/// regex, then `Double(_:)`); it lives here so the `number_input` widget commits
/// through the SAME grammar instead of `Int(_:)`, which dropped every decimal.
public func numericStringValue(_ s: String) -> Double? {
    let range = NSRange(s.startIndex..., in: s)
    guard numericStringRegex.firstMatch(in: s, range: range) != nil else { return nil }
    return Double(s)
}

private let numericStringRegex = try! NSRegularExpression(pattern: "^-?\\d+(\\.\\d+)?$")

/// The value a `number_input` commit writes, or nil to leave state UNCHANGED.
///
/// Accept the text only if `numericStringValue` accepts it, then clamp to the
/// bounds the widget's YAML DECLARES. nil means the reference would have refused
/// the write (`type_mismatch`), so nothing is written.
public func numberInputCommit(text: String, min minVal: Double?, max maxVal: Double?) -> Double? {
    guard let parsed = numericStringValue(text) else { return nil }
    return clampToDeclared(parsed, min: minVal, max: maxVal)
}

/// Clamp a widget commit to the bounds its YAML DECLARES, leaving an
/// undeclared bound alone — Character's Tracking field is signed and declares
/// neither, and `renderNumberInput` used to substitute 0 for an absent `min:`,
/// so a typed -50 committed -50 in jas_dioxus and 0 here.
public func clampToDeclared(_ v: Double, min minVal: Double?, max maxVal: Double?) -> Double {
    var v = v
    if let lo = minVal, v < lo { v = lo }
    if let hi = maxVal, v > hi { v = hi }
    return v
}
