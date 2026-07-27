/// Float-to-integer conversions that behave the way jas_dioxus's `as` casts do.
///
/// Rust's `as` from a floating-point value to an integer SATURATES: out of range
/// clamps to the target's min/max, and NaN becomes 0 (defined behaviour since
/// Rust 1.45). Swift's `Int(_:)` / `UInt8(_:)` from a floating-point value are
/// PRECONDITION FAILURES on out of range, NaN, or infinity. So the same
/// arithmetic is a clamped value in jas_dioxus and a crash here — risk R9,
/// transcripts/CORPUS_CENSUS.md §7.
///
/// Where a value has a documented range, CLAMP THE INPUT instead (see
/// `clampChannel` in Interpreter/ColorUtil.swift, and the reasoning there for
/// why input-clamping and not output-saturation is the rule for the colour
/// primitives). These functions are for the other case: a conversion that
/// mirrors a Rust `as` cast with no range to appeal to, where the two ports must
/// agree on the same saturated answer.
///
/// Every "Rust yields X" below was observed by running the cast, not recalled.
import Foundation

/// Rust's `v as i64`: truncate toward zero, saturate at both bounds, NaN to 0.
///
/// `Int` is 64-bit on the platforms this app targets, so `Int` and `i64` have
/// the same bounds. Note `Double` cannot represent `i64::MAX` exactly — the
/// nearest Double is 2^63, which is OUT of range — so the comparison below is
/// against 2^63 and 2^63 saturates to `Int.max`, which is what Rust does too.
func saturatingInt(_ v: Double) -> Int {
    if v.isNaN { return 0 }                       // Rust: 0
    if v >= 9_223_372_036_854_775_808.0 { return Int.max }  // 2^63; Rust: i64::MAX
    if v <= -9_223_372_036_854_775_808.0 { return Int.min } // Rust: i64::MIN
    return Int(v)
}

/// The integer value of `v` if it has one, else nil — a guard that runs BEFORE
/// any conversion.
///
/// Three copies of `if n == Double(Int(n)) { return Int(n) }` and three of
/// `if n == n.rounded(.towardZero) { … Int(n) }` were written as if the
/// predicate protected the cast, but Swift evaluates the inner conversion
/// first, so `.number(inf)` / `.number(NaN)` / `.number(1e30)` trapped at the
/// guard itself. Rust's counterparts either do no conversion (`value_to_json`)
/// or saturate and then compare, which makes their predicate FALSE for exactly
/// these inputs — so returning nil here is what agrees with them.
func intIfIntegral(_ v: Double) -> Int? {
    guard v.isFinite else { return nil }
    guard v > -9_223_372_036_854_775_809.0, v < 9_223_372_036_854_775_808.0 else {
        return nil
    }
    guard v == v.rounded(.towardZero) else { return nil }
    return Int(v)
}

/// Rust's `(v as i64).max(0) as u32`: the conversion `PrintPreferences.copies`
/// and other `u32` document fields go through in jas_dioxus.
///
/// The result is returned as `Int` because this port declares those fields
/// `Int`. Note the second cast TRUNCATES rather than saturating: Rust's `as`
/// only saturates FLOAT-to-integer, and `i64 as u32` keeps the low 32 bits. I
/// ran it — `(1e10 as i64).max(0) as u32` is 1410065408, not u32::MAX — so
/// clamping to 4294967295 here would have been a NEW divergence rather than a
/// mirror. `+inf` does reach u32::MAX, because the low 32 bits of i64::MAX are
/// all ones.
func saturatingUInt32AsInt(_ v: Double) -> Int {
    let i = max(0, saturatingInt(v))
    return Int(UInt32(truncatingIfNeeded: i))
}
