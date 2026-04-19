import Foundation

/// Per-character-range formatting substructure for Text and TextPath.
///
/// Mirrors the Rust and Python Tspan types. See `TSPAN.md` at the
/// repository root for the language-agnostic design. All override
/// fields are `nil` to mean "inherit the parent element's effective
/// value"; explicit values override.
///
/// This is the minimal shape needed for canonical JSON parity with
/// Rust — the pure-function primitives (split, merge, split_range,
/// resolve_id) live in a later module when partial-tspan editing
/// lands on the Swift side.
public struct Tspan: Equatable {
    public let id: UInt32
    public let content: String
    public let baselineShift: Double?
    public let dx: Double?
    public let fontFamily: String?
    public let fontSize: Double?
    public let fontStyle: String?
    public let fontVariant: String?
    public let fontWeight: String?
    public let jasAaMode: String?
    public let jasFractionalWidths: Bool?
    public let jasKerningMode: String?
    public let jasNoBreak: Bool?
    /// Marks a tspan as a paragraph wrapper when set to `"paragraph"`.
    /// Wrapper tspans implicitly group subsequent content tspans (until
    /// the next wrapper) into one paragraph for the Paragraph panel.
    public let jasRole: String?
    // ── Paragraph attributes (Phase 3b panel-surface subset) ────
    // Per PARAGRAPH.md §SVG attribute mapping these live on the
    // paragraph wrapper tspan (jasRole == "paragraph"). Phase 3b
    // adds the five panel-surface attrs that the Paragraph panel
    // reads when populating its controls; the dialog attrs and the
    // remaining panel-surface space-before / space-after /
    // first-line-indent (CSS text-indent) land later.
    /// `jas:left-indent` — pt, unsigned. Effective on paragraph wrappers.
    public let jasLeftIndent: Double?
    /// `jas:right-indent` — pt, unsigned. Effective on paragraph wrappers.
    public let jasRightIndent: Double?
    /// `jas:hyphenate` — boolean master switch on the paragraph wrapper.
    public let jasHyphenate: Bool?
    /// `jas:hanging-punctuation` — boolean on the paragraph wrapper.
    public let jasHangingPunctuation: Bool?
    /// `jas:list-style` — single backing attr for both BULLETS_DROPDOWN
    /// and NUMBERED_LIST_DROPDOWN. Values: bullet-disc / bullet-open-circle
    /// / bullet-square / bullet-open-square / bullet-dash / bullet-check
    /// / num-decimal / num-lower-alpha / num-upper-alpha / num-lower-roman
    /// / num-upper-roman; absent = no marker.
    public let jasListStyle: String?
    // ── Phase 1b1: remaining panel-surface paragraph attrs ──────
    /// CSS `text-align` on the paragraph wrapper tspan.
    public let textAlign: String?
    /// CSS `text-align-last` on the paragraph wrapper tspan.
    public let textAlignLast: String?
    /// CSS `text-indent` — pt, signed (negative = hanging indent).
    public let textIndent: Double?
    /// `jas:space-before` — pt, unsigned.
    public let jasSpaceBefore: Double?
    /// `jas:space-after` — pt, unsigned.
    public let jasSpaceAfter: Double?
    // ── Phase 1b2 / 8: Justification dialog attrs ────────────
    public let jasWordSpacingMin: Double?
    public let jasWordSpacingDesired: Double?
    public let jasWordSpacingMax: Double?
    public let jasLetterSpacingMin: Double?
    public let jasLetterSpacingDesired: Double?
    public let jasLetterSpacingMax: Double?
    public let jasGlyphScalingMin: Double?
    public let jasGlyphScalingDesired: Double?
    public let jasGlyphScalingMax: Double?
    public let jasAutoLeading: Double?
    public let jasSingleWordJustify: String?
    public let letterSpacing: Double?
    public let lineHeight: Double?
    public let rotate: Double?
    public let styleName: String?
    /// Sorted-set of decoration members (`"underline"`, `"line-through"`).
    /// `nil` inherits the parent; `[]` is an explicit no-decoration
    /// override; writers sort members alphabetically.
    public let textDecoration: [String]?
    public let textRendering: String?
    public let textTransform: String?
    public let transform: Transform?
    public let xmlLang: String?

    public init(id: UInt32 = 0, content: String = "",
                baselineShift: Double? = nil, dx: Double? = nil,
                fontFamily: String? = nil, fontSize: Double? = nil,
                fontStyle: String? = nil, fontVariant: String? = nil,
                fontWeight: String? = nil,
                jasAaMode: String? = nil, jasFractionalWidths: Bool? = nil,
                jasKerningMode: String? = nil, jasNoBreak: Bool? = nil,
                jasRole: String? = nil,
                jasLeftIndent: Double? = nil, jasRightIndent: Double? = nil,
                jasHyphenate: Bool? = nil, jasHangingPunctuation: Bool? = nil,
                jasListStyle: String? = nil,
                textAlign: String? = nil, textAlignLast: String? = nil,
                textIndent: Double? = nil,
                jasSpaceBefore: Double? = nil, jasSpaceAfter: Double? = nil,
                jasWordSpacingMin: Double? = nil,
                jasWordSpacingDesired: Double? = nil,
                jasWordSpacingMax: Double? = nil,
                jasLetterSpacingMin: Double? = nil,
                jasLetterSpacingDesired: Double? = nil,
                jasLetterSpacingMax: Double? = nil,
                jasGlyphScalingMin: Double? = nil,
                jasGlyphScalingDesired: Double? = nil,
                jasGlyphScalingMax: Double? = nil,
                jasAutoLeading: Double? = nil,
                jasSingleWordJustify: String? = nil,
                letterSpacing: Double? = nil, lineHeight: Double? = nil,
                rotate: Double? = nil, styleName: String? = nil,
                textDecoration: [String]? = nil, textRendering: String? = nil,
                textTransform: String? = nil, transform: Transform? = nil,
                xmlLang: String? = nil) {
        self.id = id; self.content = content
        self.baselineShift = baselineShift; self.dx = dx
        self.fontFamily = fontFamily; self.fontSize = fontSize
        self.fontStyle = fontStyle; self.fontVariant = fontVariant
        self.fontWeight = fontWeight
        self.jasAaMode = jasAaMode; self.jasFractionalWidths = jasFractionalWidths
        self.jasKerningMode = jasKerningMode; self.jasNoBreak = jasNoBreak
        self.jasRole = jasRole
        self.jasLeftIndent = jasLeftIndent
        self.jasRightIndent = jasRightIndent
        self.jasHyphenate = jasHyphenate
        self.jasHangingPunctuation = jasHangingPunctuation
        self.jasListStyle = jasListStyle
        self.textAlign = textAlign
        self.textAlignLast = textAlignLast
        self.textIndent = textIndent
        self.jasSpaceBefore = jasSpaceBefore
        self.jasSpaceAfter = jasSpaceAfter
        self.jasWordSpacingMin = jasWordSpacingMin
        self.jasWordSpacingDesired = jasWordSpacingDesired
        self.jasWordSpacingMax = jasWordSpacingMax
        self.jasLetterSpacingMin = jasLetterSpacingMin
        self.jasLetterSpacingDesired = jasLetterSpacingDesired
        self.jasLetterSpacingMax = jasLetterSpacingMax
        self.jasGlyphScalingMin = jasGlyphScalingMin
        self.jasGlyphScalingDesired = jasGlyphScalingDesired
        self.jasGlyphScalingMax = jasGlyphScalingMax
        self.jasAutoLeading = jasAutoLeading
        self.jasSingleWordJustify = jasSingleWordJustify
        self.letterSpacing = letterSpacing; self.lineHeight = lineHeight
        self.rotate = rotate; self.styleName = styleName
        self.textDecoration = textDecoration; self.textRendering = textRendering
        self.textTransform = textTransform; self.transform = transform
        self.xmlLang = xmlLang
    }

    /// Default tspan: empty content, id 0, every override nil.
    public static func defaultTspan() -> Tspan { Tspan() }

    /// True if every override field is nil. A tspan with no
    /// overrides is purely content — it inherits everything from
    /// its parent element.
    public var hasNoOverrides: Bool {
        baselineShift == nil && dx == nil
            && fontFamily == nil && fontSize == nil
            && fontStyle == nil && fontVariant == nil && fontWeight == nil
            && jasAaMode == nil && jasFractionalWidths == nil
            && jasKerningMode == nil && jasNoBreak == nil
            && jasRole == nil
            && jasLeftIndent == nil && jasRightIndent == nil
            && jasHyphenate == nil && jasHangingPunctuation == nil
            && jasListStyle == nil
            && textAlign == nil && textAlignLast == nil
            && textIndent == nil
            && jasSpaceBefore == nil && jasSpaceAfter == nil
            && jasWordSpacingMin == nil && jasWordSpacingDesired == nil
            && jasWordSpacingMax == nil
            && jasLetterSpacingMin == nil && jasLetterSpacingDesired == nil
            && jasLetterSpacingMax == nil
            && jasGlyphScalingMin == nil && jasGlyphScalingDesired == nil
            && jasGlyphScalingMax == nil
            && jasAutoLeading == nil && jasSingleWordJustify == nil
            && letterSpacing == nil && lineHeight == nil
            && rotate == nil && styleName == nil
            && textDecoration == nil && textRendering == nil
            && textTransform == nil && transform == nil && xmlLang == nil
    }
}

/// Returns the concatenation of every tspan's content in reading order.
/// This is the derived `Text.content` / `TextPath.content` value.
public func concatTspanContent(_ tspans: [Tspan]) -> String {
    tspans.reduce(into: "") { $0 += $1.content }
}
