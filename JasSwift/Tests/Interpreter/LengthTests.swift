import Testing
@testable import JasLib

// Companion to `JasSwift/Sources/Interpreter/Length.swift`. Mirrors the
// Python (`workspace_interpreter/tests/test_length.py`) and Rust
// (`jas_dioxus/src/interpreter/length.rs` test module) parity tests. Keep
// in lockstep when adding cases.

// MARK: - pt_per_unit

@Test func ptPerUnitKnown() {
    #expect(Length.ptPerUnit("pt") == 1.0)
    #expect(Length.ptPerUnit("px") == 0.75)
    #expect(Length.ptPerUnit("in") == 72.0)
    #expect(abs(Length.ptPerUnit("mm")! - 72.0 / 25.4) < 1e-12)
    #expect(abs(Length.ptPerUnit("cm")! - 720.0 / 25.4) < 1e-12)
    #expect(Length.ptPerUnit("pc") == 12.0)
}

@Test func ptPerUnitUnknownReturnsNil() {
    #expect(Length.ptPerUnit("dpi") == nil)
    #expect(Length.ptPerUnit("") == nil)
}

@Test func ptPerUnitCaseInsensitive() {
    #expect(Length.ptPerUnit("PT") == 1.0)
    #expect(Length.ptPerUnit("In") == 72.0)
}

// MARK: - parse: bare number, default unit

@Test func parseBareNumberUsesDefaultUnit() {
    #expect(Length.parse("12", defaultUnit: "pt") == 12.0)
    #expect(Length.parse("12", defaultUnit: "px") == 9.0)
    #expect(Length.parse("12", defaultUnit: "in") == 864.0)
}

@Test func parseBareDecimal() {
    #expect(Length.parse("12.5", defaultUnit: "pt") == 12.5)
    #expect(Length.parse("0.5", defaultUnit: "pt") == 0.5)
}

@Test func parseLeadingDotDecimal() {
    #expect(Length.parse(".5", defaultUnit: "pt") == 0.5)
}

@Test func parseTrailingDotDecimal() {
    #expect(Length.parse("5.", defaultUnit: "pt") == 5.0)
}

@Test func parseNegative() {
    #expect(Length.parse("-3", defaultUnit: "pt") == -3.0)
    #expect(Length.parse("-3.5", defaultUnit: "pt") == -3.5)
    #expect(Length.parse("-.5", defaultUnit: "pt") == -0.5)
}

@Test func parseZero() {
    #expect(Length.parse("0", defaultUnit: "pt") == 0.0)
    #expect(Length.parse("0.0", defaultUnit: "pt") == 0.0)
    #expect(Length.parse("-0", defaultUnit: "pt") == 0.0)
}

// MARK: - parse: with unit suffix

@Test func parseWithPtSuffix() {
    #expect(Length.parse("12 pt", defaultUnit: "pt") == 12.0)
    #expect(Length.parse("12pt", defaultUnit: "pt") == 12.0)
    #expect(Length.parse("12  pt", defaultUnit: "pt") == 12.0)
}

@Test func parseWithPxSuffix() {
    #expect(Length.parse("12 px", defaultUnit: "pt") == 9.0)
    #expect(Length.parse("12px", defaultUnit: "pt") == 9.0)
}

@Test func parseWithInSuffix() {
    #expect(Length.parse("1 in", defaultUnit: "pt") == 72.0)
    #expect(Length.parse("0.5 in", defaultUnit: "pt") == 36.0)
}

@Test func parseWithMmSuffix() {
    let got1 = Length.parse("25.4 mm", defaultUnit: "pt")!
    #expect(abs(got1 - 72.0) < 1e-9)
    let got2 = Length.parse("5 mm", defaultUnit: "pt")!
    #expect(abs(got2 - 5.0 * 72.0 / 25.4) < 1e-9)
}

@Test func parseWithCmSuffix() {
    let got = Length.parse("2.54 cm", defaultUnit: "pt")!
    #expect(abs(got - 72.0) < 1e-9)
}

@Test func parseWithPcSuffix() {
    #expect(Length.parse("1 pc", defaultUnit: "pt") == 12.0)
    #expect(Length.parse("3 pc", defaultUnit: "pt") == 36.0)
}

@Test func parseCaseInsensitiveUnit() {
    #expect(Length.parse("12 PT", defaultUnit: "pt") == 12.0)
    #expect(Length.parse("12 Pt", defaultUnit: "pt") == 12.0)
    #expect(Length.parse("12pT", defaultUnit: "pt") == 12.0)
}

@Test func parseUnitOverridesDefault() {
    #expect(Length.parse("12 px", defaultUnit: "pt") == 9.0)
    #expect(Length.parse("12 pt", defaultUnit: "px") == 12.0)
}

// MARK: - parse: whitespace

@Test func parseStripsLeadingWhitespace() {
    #expect(Length.parse("  12", defaultUnit: "pt") == 12.0)
    #expect(Length.parse("\t12 pt", defaultUnit: "pt") == 12.0)
}

@Test func parseStripsTrailingWhitespace() {
    #expect(Length.parse("12  ", defaultUnit: "pt") == 12.0)
    #expect(Length.parse("12 pt  ", defaultUnit: "pt") == 12.0)
}

// MARK: - parse: rejection paths

@Test func parseEmptyReturnsNil() {
    #expect(Length.parse("", defaultUnit: "pt") == nil)
    #expect(Length.parse("   ", defaultUnit: "pt") == nil)
}

@Test func parseUnitOnlyReturnsNil() {
    #expect(Length.parse("pt", defaultUnit: "pt") == nil)
    #expect(Length.parse(" mm ", defaultUnit: "pt") == nil)
}

@Test func parseUnknownUnitReturnsNil() {
    #expect(Length.parse("12 dpi", defaultUnit: "pt") == nil)
    #expect(Length.parse("12 ft", defaultUnit: "pt") == nil)
    #expect(Length.parse("12 foo", defaultUnit: "pt") == nil)
}

@Test func parseExtraTokensReturnsNil() {
    #expect(Length.parse("12 mm pt", defaultUnit: "pt") == nil)
    #expect(Length.parse("5 mm 3", defaultUnit: "pt") == nil)
    #expect(Length.parse("12pt5", defaultUnit: "pt") == nil)
}

@Test func parseGarbageReturnsNil() {
    #expect(Length.parse("abc", defaultUnit: "pt") == nil)
    #expect(Length.parse("12.5.5", defaultUnit: "pt") == nil)
    #expect(Length.parse(".", defaultUnit: "pt") == nil)
    #expect(Length.parse("-", defaultUnit: "pt") == nil)
    #expect(Length.parse("-.", defaultUnit: "pt") == nil)
}

// MARK: - format

@Test func formatIntegerStripsDecimal() {
    #expect(Length.format(12.0, unit: "pt", precision: 2) == "12 pt")
    #expect(Length.format(0.0, unit: "pt", precision: 2) == "0 pt")
    #expect(Length.format(72.0, unit: "in", precision: 2) == "1 in")
}

@Test func formatDecimal() {
    #expect(Length.format(12.5, unit: "pt", precision: 2) == "12.5 pt")
    #expect(Length.format(12.34, unit: "pt", precision: 2) == "12.34 pt")
}

@Test func formatTrimsTrailingZeros() {
    #expect(Length.format(12.50, unit: "pt", precision: 2) == "12.5 pt")
    #expect(Length.format(12.500, unit: "pt", precision: 3) == "12.5 pt")
    #expect(Length.format(12.0, unit: "pt", precision: 4) == "12 pt")
}

@Test func formatRoundsToPrecision() {
    #expect(Length.format(12.345, unit: "pt", precision: 2) == "12.35 pt"
            || Length.format(12.345, unit: "pt", precision: 2) == "12.34 pt")
    #expect(Length.format(12.344, unit: "pt", precision: 2) == "12.34 pt")
}

@Test func formatConvertsToTargetUnit() {
    #expect(Length.format(72.0, unit: "in", precision: 2) == "1 in")
    #expect(Length.format(1.0, unit: "px", precision: 2) == "1.33 px")
}

@Test func formatMm() {
    #expect(Length.format(72.0, unit: "mm", precision: 2) == "25.4 mm")
}

@Test func formatNegative() {
    #expect(Length.format(-3.0, unit: "pt", precision: 2) == "-3 pt")
    #expect(Length.format(-3.5, unit: "pt", precision: 2) == "-3.5 pt")
}

@Test func formatNullReturnsEmpty() {
    #expect(Length.format(nil, unit: "pt", precision: 2) == "")
}

@Test func formatUnknownUnitFallsBackToPt() {
    #expect(Length.format(12.0, unit: "dpi", precision: 2) == "12 pt")
}

// MARK: - round-trip

@Test func roundTripFormatThenParse() {
    let pts: [Double] = [0.0, 1.0, 12.0, 12.5, 72.0, 100.0, 0.75]
    for pt in pts {
        for unit in Length.SUPPORTED_UNITS {
            let formatted = Length.format(pt, unit: unit, precision: 6)
            guard let back = Length.parse(formatted, defaultUnit: unit) else {
                Issue.record("round-trip parse failed for pt=\(pt) unit=\(unit) formatted=\(formatted)")
                continue
            }
            #expect(abs(back - pt) < 1e-3,
                    "round-trip diverged for pt=\(pt) unit=\(unit) formatted=\(formatted) back=\(back)")
        }
    }
}
