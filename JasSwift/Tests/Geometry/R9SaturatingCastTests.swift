import Foundation
import Testing
@testable import JasLib

/// Risk R9 (transcripts/CORPUS_CENSUS.md §7): Rust's `as` casts from a float to
/// an integer SATURATE, while Swift's `UInt8(_:)` / `Int(_:)` from a float are
/// precondition failures on an out-of-range or non-finite value. The same
/// arithmetic is therefore a clamped value in jas_dioxus and a CRASH here.
///
/// Every case below is a value jas_dioxus already handles. The Rust behaviour
/// in each comment was OBSERVED by running the cast, not recalled.
struct R9ColourChainTests {

    // MARK: - Color.toRgba / hsbToRgbComponents

    /// `hsbToRgbComponents` did `Int(floor(h / 60.0)) % 6`, which traps for a
    /// non-finite hue. Rust's `(h / 60.0).floor() as u32 % 6` yields 0 and then
    /// carries NaN into two of the three components. Neither answer is a
    /// colour, so both ports now sanitise a non-finite hue to 0 — the one
    /// answer they can spell identically.
    ///
    /// The live producer is Panels/ColorBarView.swift's `draw`, whose
    /// `360.0 * x / width` is 0/0 at zero width.
    @Test func nonFiniteHueIsTreatedAsZero() {
        let (r, g, b, a) = Color.hsb(h: .nan, s: 1.0, b: 0.8, a: 1.0).toRgba()
        #expect(r == 0.8)
        #expect(g == 0.0)
        #expect(b == 0.0)
        #expect(a == 1.0)
        // Infinity takes the same road: `(inf % 360 + 360) % 360` is NaN.
        let (r2, g2, b2, _) = Color.hsb(h: .infinity, s: 1.0, b: 0.8, a: 1.0).toRgba()
        #expect(r2 == 0.8)
        #expect(g2 == 0.0)
        #expect(b2 == 0.0)
    }

    /// A finite out-of-range hue still wraps — the guard must not swallow it.
    @Test func finiteHueStillWraps() {
        let (r, g, b, _) = Color.hsb(h: 480.0, s: 1.0, b: 1.0, a: 1.0).toRgba()
        let (r2, g2, b2, _) = Color.hsb(h: 120.0, s: 1.0, b: 1.0, a: 1.0).toRgba()
        #expect(r == r2)
        #expect(g == g2)
        #expect(b == b2)
    }

    // MARK: - Color.toHex

    /// `toHex`'s `max(0, min(255, Int(round(r * 255))))` had a correct OUTER
    /// clamp and a trapping INNER cast — confirmed-instance-2's shape. For a
    /// FINITE out-of-range component the clamp and Rust's saturation already
    /// agreed; only NaN / ±infinity diverged (Rust: NaN → 0, +inf → 255).
    @Test func toHexSaturatesNonFiniteComponents() {
        #expect(Color.rgb(r: .nan, g: 0.0, b: 0.0, a: 1.0).toHex() == "000000")
        #expect(Color.rgb(r: .infinity, g: 0.0, b: 0.0, a: 1.0).toHex() == "ff0000")
        #expect(Color.rgb(r: -.infinity, g: 1.0, b: 0.0, a: 1.0).toHex() == "00ff00")
    }

    /// Finite out-of-range components were already right; pinned so a rewrite
    /// of the clamp cannot quietly change them.
    @Test func toHexClampsFiniteOutOfRange() {
        #expect(Color.rgb(r: 2.0, g: 0.0, b: -1.0, a: 1.0).toHex() == "ff0000")
    }

    /// A NaN hue must reach hex as a colour, not as a crash.
    @Test func toHexOfNonFiniteHue() {
        #expect(Color.hsb(h: .nan, s: 1.0, b: 0.8, a: 1.0).toHex() == "cc0000")
    }

    // MARK: - SVG serialisation

    /// `colorStr` had NO clamp at all, so an out-of-range component was written
    /// out VERBATIM: `rgb(510,0,0)`, which is not valid CSS colour syntax,
    /// where jas_dioxus's `as u8` writes `rgb(255,0,0)`. This is the one row in
    /// the class that produces a WRONG FILE rather than a crash, and it needs
    /// no exotic input — Svg's own reader parses `rgb()` components with
    /// `Int(String)` and divides by 255 unclamped, so opening
    /// `fill="rgb(999,0,0)"` and saving it back was enough.
    @Test func svgFillClampsOutOfRangeComponents() {
        let doc = Document(layers: [Layer(children: [
            .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                       fill: Fill(color: Color.rgb(r: 2.0, g: 0.0, b: 0.0, a: 1.0))))
        ])])
        let svg = documentToSvg(doc)
        #expect(svg.contains("rgb(255,0,0)"), "expected a clamped component, got:\n\(svg)")
        #expect(!svg.contains("rgb(510,0,0)"))
    }

    /// The same writer must not trap on a non-finite component.
    @Test func svgFillSaturatesNonFiniteComponents() {
        let doc = Document(layers: [Layer(children: [
            .rect(Rect(x: 0, y: 0, width: 72, height: 72,
                       fill: Fill(color: Color.rgb(r: .nan, g: 1.0, b: 0.0, a: 1.0))))
        ])])
        let svg = documentToSvg(doc)
        #expect(svg.contains("rgb(0,255,0)"), "expected NaN → 0, got:\n\(svg)")
    }

    // MARK: - The shared conversion rules themselves

    @Test func clampChannelMapsNaNToTheLowBound() {
        #expect(clampChannel(.nan, 0.0, 100.0) == 0.0)
        #expect(clampChannel(150.0, 0.0, 100.0) == 100.0)
        #expect(clampChannel(-50.0, 0.0, 100.0) == 0.0)
        #expect(clampChannel(.infinity, 0.0, 360.0) == 360.0)
        #expect(clampChannel(-.infinity, 0.0, 360.0) == 0.0)
        #expect(clampChannel(42.5, 0.0, 100.0) == 42.5)
    }

    /// `saturatingUInt8` must equal Rust's `v as u8` for every shape of input.
    /// The Rust column was observed by running the cast.
    @Test func saturatingUInt8MatchesRustAsU8() {
        #expect(saturatingUInt8(.nan) == 0)          // Rust: 0
        #expect(saturatingUInt8(.infinity) == 255)   // Rust: 255
        #expect(saturatingUInt8(-.infinity) == 0)    // Rust: 0
        #expect(saturatingUInt8(1e19) == 255)        // Rust: 255 (exceeds i64)
        #expect(saturatingUInt8(-510.0) == 0)        // Rust: 0
        #expect(saturatingUInt8(300.0) == 255)       // Rust: 255
        #expect(saturatingUInt8(5.9) == 5)           // Rust: 5 (truncates)
        #expect(saturatingUInt8(0.0) == 0)
        #expect(saturatingUInt8(255.0) == 255)
    }
}

/// Risk R9, the non-colour sites: a Rust `as` cast has no range to appeal to, so
/// the two ports must agree on the same SATURATED answer instead. Each Rust
/// column below was observed by running the cast.
struct R9SaturatingConversionTests {

    // MARK: - The rules themselves

    @Test func saturatingIntMatchesRustAsI64() {
        #expect(saturatingInt(.nan) == 0)                    // Rust: 0
        #expect(saturatingInt(.infinity) == Int.max)         // Rust: i64::MAX
        #expect(saturatingInt(-.infinity) == Int.min)        // Rust: i64::MIN
        #expect(saturatingInt(1e30) == Int.max)              // Rust: i64::MAX
        #expect(saturatingInt(9_223_372_036_854_775_808.0) == Int.max)  // 2^63
        #expect(saturatingInt(5.9) == 5)                     // Rust: 5
        #expect(saturatingInt(-5.9) == -5)                   // Rust: -5
        #expect(saturatingInt(0.0) == 0)
    }

    @Test func saturatingUInt32MatchesRustCopiesCast() {
        // Rust: `(n as i64).max(0) as u32`.
        #expect(saturatingUInt32AsInt(.nan) == 0)             // Rust: 0
        #expect(saturatingUInt32AsInt(.infinity) == 4_294_967_295)
        #expect(saturatingUInt32AsInt(1e10) == 4_294_967_295)
        #expect(saturatingUInt32AsInt(-5.0) == 0)
        #expect(saturatingUInt32AsInt(3.0) == 3)
    }

    // MARK: - Print preferences

    /// `copies` was `max(0, Int(n))` — confirmed-instance-2's shape, outer clamp
    /// over a trapping inner cast — against Rust's `(n as i64).max(0) as u32`.
    /// It is reachable with no GUI at all: OpApply feeds this function a
    /// RESOLVED op-payload literal with no range vetting, so an op carrying a
    /// non-finite `copies` crashed replay here and clamped there. The widget
    /// route is `pr_copies`, which declares `min: 1` and no `max`.
    @Test func printCopiesSaturatesLikeRust() {
        let p = PrintPreferences()
        #expect(applyPrintPrefField(p, field: "copies", val: .number(.nan))?.copies == 0)
        #expect(applyPrintPrefField(p, field: "copies", val: .number(.infinity))?.copies
                    == 4_294_967_295)
        // The u32 ceiling is the parity point: this stored 10000000000 here.
        #expect(applyPrintPrefField(p, field: "copies", val: .number(1e10))?.copies
                    == 4_294_967_295)
        #expect(applyPrintPrefField(p, field: "copies", val: .number(-5))?.copies == 0)
        #expect(applyPrintPrefField(p, field: "copies", val: .number(3))?.copies == 3)
    }
}

/// Risk R9, the "guard does not protect the cast" family. Each of these sites
/// LOOKS guarded — `n == n.rounded(.towardZero)`, `n == Double(Int(n))`,
/// `n >= 0` — but Swift evaluates the inner conversion first, or the predicate
/// is true for ±infinity, so the trap is reached anyway. The Rust twin of each
/// either saturates or does no conversion at all.
struct R9GuardedCastTests {

    @Test func intIfIntegralRejectsWhatItCannotConvert() {
        #expect(intIfIntegral(3.0) == 3)
        #expect(intIfIntegral(-3.0) == -3)
        #expect(intIfIntegral(0.0) == 0)
        #expect(intIfIntegral(3.5) == nil)
        #expect(intIfIntegral(.nan) == nil)
        #expect(intIfIntegral(.infinity) == nil)
        #expect(intIfIntegral(-.infinity) == nil)
        // 1e30 IS integral, but it is outside Int — Rust's to_string_coerce
        // takes its float branch for exactly this value, because the saturated
        // round-trip `(1e30 as i64) as f64` does not compare equal.
        #expect(intIfIntegral(1e30) == nil)
        #expect(intIfIntegral(9_223_372_036_854_775_808.0) == nil)  // 2^63
    }

    /// `Value.toAny()`'s `if n == Double(Int(n))` evaluated the trapping cast
    /// inside its own guard. Rust's nearest twin (`value_to_json`) performs NO
    /// integer conversion at all, so it cannot fail.
    @Test func valueToAnyDoesNotTrapOnNonFinite() {
        #expect(Value.number(3.0).toAny() as? Int == 3)
        #expect(Value.number(3.5).toAny() as? Double == 3.5)
        #expect((Value.number(.infinity).toAny() as? Double)?.isInfinite == true)
        #expect((Value.number(.nan).toAny() as? Double)?.isNaN == true)
        #expect(Value.number(1e30).toAny() as? Double == 1e30)
    }

    /// `fmtNum` / `_fmtNum` / `_fmtDouble` all test `n == n.trunc()` and then
    /// cast. That predicate is TRUE for ±infinity and for every integral value
    /// at or above 2^63, so the guard admits exactly what the cast cannot take.
    /// Rust's `fmt_num` (workspace/app_state.rs) and `fmt_f64`
    /// (geometry/tspan.rs) both saturate to i64::MAX there and print it.
    @Test func fmtNumSaturatesLikeRust() {
        #expect(fmtNum(3.0) == "3")
        #expect(fmtNum(2.5) == "2.5")
        #expect(fmtNum(.infinity) == "9223372036854775807")   // Rust: i64::MAX
        #expect(fmtNum(-.infinity) == "-9223372036854775808")
        #expect(fmtNum(1e30) == "9223372036854775807")
    }

    @Test func fmtNumEffectsCopySaturatesLikeRust() {
        #expect(_fmtNum(3.0) == "3")
        #expect(_fmtNum(2.5) == "2.5")
        #expect(_fmtNum(.infinity) == "9223372036854775807")
        #expect(_fmtNum(1e30) == "9223372036854775807")
    }

    @Test func fmtDoubleSaturatesLikeRust() {
        #expect(_fmtDouble(3.0) == "3")
        #expect(_fmtDouble(2.5) == "2.5")
        #expect(_fmtDouble(.infinity) == "9223372036854775807")
        #expect(_fmtDouble(1e30) == "9223372036854775807")
    }

    /// `path()` / `path_child()` guard `n >= 0`, which rejects NaN in both ports
    /// but ADMITS +infinity. Rust pushes `n as usize` = usize::MAX; this port
    /// trapped. The saturated sentinels differ in magnitude (Int.max here,
    /// usize::MAX there) because the two ports' index types differ, but both
    /// exceed any container length, so a lookup through either misses.
    @Test func pathBuiltinsDoNotTrapOnHugeIndex() {
        let v = evaluate("path(10000000000000000000)", context: [:])
        guard case .path(let idx) = v else {
            Issue.record("expected a path, got \(v)")
            return
        }
        #expect(idx == [Int.max])
        let c = evaluate("path_child(path(0), 10000000000000000000)", context: [:])
        guard case .path(let idx2) = c else {
            Issue.record("expected a path, got \(c)")
            return
        }
        #expect(idx2 == [0, Int.max])
        // The ordinary case is untouched.
        #expect(evaluate("path(1, 2)", context: [:]) == .path([1, 2]))
    }

    /// The parser's integer-index-after-a-dot segment (`list.0`) formatted the
    /// literal with `Int(n)`; Rust's `format!("{}", n as i64)` saturates. Both
    /// now produce the same segment name, which resolves to nothing.
    @Test func parserDotIndexDoesNotTrapOnHugeLiteral() {
        #expect(evaluate("state.10000000000000000000", context: ["state": ["x": 1]])
                    == .null)
    }

    /// `resolveDim`'s two `Int(f)` branches take a Double parsed from a YAML
    /// dimension string; Rust's `f as i64` saturates. `Double("nan")` and
    /// `Double("1e400")` both succeed, so a hand-authored `width: "nan"` was a
    /// crash here and a number there.
    @Test func resolveDimDoesNotTrapOnNonFiniteString() {
        #expect(PanelLayout.resolveDim("nan", 100) == 0)
        #expect(PanelLayout.resolveDim("1e400", 100) == Int.max)
        #expect(PanelLayout.resolveDim("50%", 200) == 100)
        #expect(PanelLayout.resolveDim("42", 200) == 42)
        #expect(PanelLayout.resolveDim("12.7", 200) == 12)
    }
}
