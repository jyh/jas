/// Selection → Character panel mirror.
///
/// When a Text / TextPath element is selected, the Character panel's
/// controls should reflect *that element's* attributes rather than
/// stale panel-local state. This file exposes the inverse of
/// `applyCharacterPanelToSelection`: pull the selection's character
/// attributes into the `character_panel` scope dict so the YAML
/// widgets bound to `panel.font_family` / `panel.all_caps` / etc
/// display the current element.
///
/// Mirrors the `build_live_panel_overrides` block in the Rust dock
/// panel. Called from `DockPanelView.buildPanelCtx`.

import Foundation

// MARK: - The field-scoped apply law

/// The character attributes ONE Character-panel field owns.
///
/// A panel edit must write only the group it touched and preserve every
/// other attribute from the element (see `applyCharacterPanelToSelection`).
/// Fields that move together stay in one group, and only where that is
/// forced:
///
/// - `.style` is one dropdown naming a `font_weight` + `font_style` PAIR;
///   there is no control that moves the weight without the style.
/// - `.case` is the All Caps / Small Caps pair, whose mutual exclusion can
///   only be expressed by writing `text_transform` and `font_variant`
///   together — turning All Caps ON must clear a small-caps variant.
/// - `.decoration` is the Underline / Strikethrough pair feeding ONE CSS
///   token list, which cannot be written a token at a time.
///
/// The two glyph scales are deliberately SEPARATE groups (as the Stroke
/// law's two arrowhead scales are), and `.fontSize` owns only the size —
/// never the leading, because Auto leading is an ABSENT `line-height` and
/// preserving it keeps Auto alive across a size change.
///
/// Mirrors the reference `CHARACTER_EDIT_GROUPS`
/// (`workspace_interpreter/character_law.py`), which states the table, and
/// the Rust `CharacterEditGroup`.
public enum CharacterEditGroup {
    case fontFamily
    case style
    case fontSize
    case leading
    case kerning
    case tracking
    case verticalScale
    case horizontalScale
    case baselineShift
    case rotation
    case textCase
    case decoration
    case language
    case aaMode

    /// Map a Character-panel field key to the group it owns. `nil` means the
    /// key owns no element attribute, so editing it writes nothing to the
    /// selection.
    ///
    /// Unlike the Stroke panel there is no flat-global spelling to
    /// normalize: every Character control binds `panel.<field>` only
    /// (`workspace/panels/character.yaml`).
    public static func fromField(_ key: String) -> CharacterEditGroup? {
        switch key {
        case "font_family": return .fontFamily
        case "style_name": return .style
        case "font_size": return .fontSize
        case "leading": return .leading
        case "kerning": return .kerning
        case "tracking": return .tracking
        case "vertical_scale": return .verticalScale
        case "horizontal_scale": return .horizontalScale
        // Three fields, one attribute: the toggles win over the number.
        case "baseline_shift", "superscript", "subscript": return .baselineShift
        case "character_rotation": return .rotation
        case "all_caps", "small_caps": return .textCase
        case "underline", "strikethrough": return .decoration
        case "language": return .language
        case "anti_aliasing": return .aaMode
        // The seven snap_* flags and the section-visibility flags are
        // UI-only state: toggling one must not push an undo step that
        // changes nothing.
        default: return nil
        }
    }
}

/// The character attributes a Character-panel edit can reach, lifted out of
/// a Text / TextPath element as a flat record. The two element types carry
/// the same sixteen fields; this is the shared shape the field-scoped law
/// operates on, so `characterWithGroup` can be a pure function the
/// conformance corpus drives directly. Names are the element's own (SVG /
/// CSS) names, not panel field names.
public struct CharacterAttrs: Equatable {
    public var fontFamily: String
    public var fontSize: Double
    public var fontWeight: String
    public var fontStyle: String
    public var textDecoration: String
    public var textTransform: String
    public var fontVariant: String
    public var baselineShift: String
    public var lineHeight: String
    public var letterSpacing: String
    public var xmlLang: String
    public var aaMode: String
    public var rotate: String
    public var horizontalScale: String
    public var verticalScale: String
    public var kerning: String

    public init(fontFamily: String, fontSize: Double, fontWeight: String,
                fontStyle: String, textDecoration: String,
                textTransform: String, fontVariant: String,
                baselineShift: String, lineHeight: String,
                letterSpacing: String, xmlLang: String, aaMode: String,
                rotate: String, horizontalScale: String,
                verticalScale: String, kerning: String) {
        self.fontFamily = fontFamily; self.fontSize = fontSize
        self.fontWeight = fontWeight; self.fontStyle = fontStyle
        self.textDecoration = textDecoration
        self.textTransform = textTransform; self.fontVariant = fontVariant
        self.baselineShift = baselineShift; self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing; self.xmlLang = xmlLang
        self.aaMode = aaMode; self.rotate = rotate
        self.horizontalScale = horizontalScale
        self.verticalScale = verticalScale; self.kerning = kerning
    }

    /// The character attributes of a Text / TextPath element, or `nil` for
    /// any other element kind.
    public init?(element: Element) {
        switch element {
        case .text(let t):
            self.init(fontFamily: t.fontFamily, fontSize: t.fontSize,
                      fontWeight: t.fontWeight, fontStyle: t.fontStyle,
                      textDecoration: t.textDecoration,
                      textTransform: t.textTransform,
                      fontVariant: t.fontVariant,
                      baselineShift: t.baselineShift, lineHeight: t.lineHeight,
                      letterSpacing: t.letterSpacing, xmlLang: t.xmlLang,
                      aaMode: t.aaMode, rotate: t.rotate,
                      horizontalScale: t.horizontalScale,
                      verticalScale: t.verticalScale, kerning: t.kerning)
        case .textPath(let tp):
            self.init(fontFamily: tp.fontFamily, fontSize: tp.fontSize,
                      fontWeight: tp.fontWeight, fontStyle: tp.fontStyle,
                      textDecoration: tp.textDecoration,
                      textTransform: tp.textTransform,
                      fontVariant: tp.fontVariant,
                      baselineShift: tp.baselineShift,
                      lineHeight: tp.lineHeight,
                      letterSpacing: tp.letterSpacing, xmlLang: tp.xmlLang,
                      aaMode: tp.aaMode, rotate: tp.rotate,
                      horizontalScale: tp.horizontalScale,
                      verticalScale: tp.verticalScale, kerning: tp.kerning)
        default:
            return nil
        }
    }

    /// The attribute dict `Controller.setSelectionTextAttributes` consumes.
    /// Every key is present, so the caller decides scope by choosing WHICH
    /// attributes to hand over — see `characterAttrsForGroup`.
    public var asAttrDict: [String: Any] {
        [
            "font_family": fontFamily,
            "font_size": NSNumber(value: fontSize),
            "font_weight": fontWeight,
            "font_style": fontStyle,
            "text_decoration": textDecoration,
            "text_transform": textTransform,
            "font_variant": fontVariant,
            "baseline_shift": baselineShift,
            "line_height": lineHeight,
            "letter_spacing": letterSpacing,
            "xml_lang": xmlLang,
            "aa_mode": aaMode,
            "rotate": rotate,
            "horizontal_scale": horizontalScale,
            "vertical_scale": verticalScale,
            "kerning": kerning,
        ]
    }
}

/// The element attribute keys each group writes. Used to narrow a full
/// attribute dict down to the edited group, and stated here (not inferred)
/// so it can be checked against the reference's `CHARACTER_GROUP_ATTRS`.
public func characterGroupAttrKeys(_ group: CharacterEditGroup) -> [String] {
    switch group {
    case .fontFamily: return ["font_family"]
    case .style: return ["font_weight", "font_style"]
    case .fontSize: return ["font_size"]
    case .leading: return ["line_height"]
    case .kerning: return ["kerning"]
    case .tracking: return ["letter_spacing"]
    case .verticalScale: return ["vertical_scale"]
    case .horizontalScale: return ["horizontal_scale"]
    case .baselineShift: return ["baseline_shift"]
    case .rotation: return ["rotate"]
    case .textCase: return ["text_transform", "font_variant"]
    case .decoration: return ["text_decoration"]
    case .language: return ["xml_lang"]
    case .aaMode: return ["aa_mode"]
    }
}

/// One Character-panel field, PANEL scope only — every Character control
/// binds `panel.<field>`, so there is no global fallback to resolve.
/// Returns `nil` when the field is absent, which sends the law to the panel
/// default the workspace declares.
func characterPanelField(_ store: StateStore, _ field: String) -> Any? {
    guard let v = store.getPanel("character_panel_content", field),
          !(v is NSNull) else { return nil }
    return v
}

/// The panel defaults `workspace/panels/character.yaml` declares — the value
/// the law reads when a field is absent from panel state. Stated here rather
/// than as scattered `?? 12.0` literals so the fallbacks can be checked
/// against the workspace bundle and against the reference's
/// `CHARACTER_PANEL_FIELDS`.
public let characterPanelDefaults: [String: Any] = [
    "font_family": "sans-serif", "style_name": "Regular",
    "font_size": 12.0, "kerning": "Auto", "tracking": 0.0,
    "vertical_scale": 100.0, "horizontal_scale": 100.0,
    "baseline_shift": 0.0, "character_rotation": 0.0,
    "all_caps": false, "small_caps": false,
    "superscript": false, "subscript": false,
    "underline": false, "strikethrough": false,
    "language": "en", "anti_aliasing": "Sharp",
    // `leading` is deliberately absent: no committed leading means the
    // LEADING group takes the element's own Auto value.
]

private func charStr(_ store: StateStore, _ field: String) -> String {
    if let s = characterPanelField(store, field) as? String { return s }
    return (characterPanelDefaults[field] as? String) ?? ""
}

private func charNum(_ store: StateStore, _ field: String) -> Double {
    switch characterPanelField(store, field) {
    case let n as NSNumber: return n.doubleValue
    case let d as Double: return d
    case let i as Int: return Double(i)
    default:
        return (characterPanelDefaults[field] as? Double) ?? 0.0
    }
}

private func charFlag(_ store: StateStore, _ field: String) -> Bool {
    if let b = characterPanelField(store, field) as? Bool { return b }
    return (characterPanelDefaults[field] as? Bool) ?? false
}

/// The element's `kerning` attribute for a Kerning combo entry. Named modes
/// pass through verbatim; a numeric entry is 1/1000 em and serialises to
/// `"{N}em"`. Empty / `"0"` / `"Auto"` all round-trip to an empty attribute,
/// since Auto is the element default. Mirrors the Rust `kerning_attr`.
public func kerningAttr(_ raw: String) -> String {
    let val = raw.trimmingCharacters(in: .whitespaces)
    switch val {
    case "", "0", "Auto": return ""
    case "Optical", "Metrics": return val
    default:
        guard let n = Double(val) else { return "" }
        return n == 0.0 ? "" : fmtNum(n / 1000.0) + "em"
    }
}

/// `base` with `group`'s attributes overwritten from the Character panel
/// state and every other attribute left exactly as it was.
///
/// Every derived value is computed against `base` where the element has a
/// say — notably the `.leading` group's Auto test, which compares the
/// panel's leading against the ELEMENT's `fontSize * 1.2` rather than the
/// panel's font size. The whole-rebuild law used the panel's, which was
/// harmless only because it rewrote the size in the same breath; under the
/// field-scoped law a leading edit must not consult a font-size field the
/// user did not touch.
///
/// Mirrors the Rust `character_with_group` and the reference
/// `character_with_group`.
public func characterWithGroup(
    _ base: CharacterAttrs, store: StateStore, group: CharacterEditGroup
) -> CharacterAttrs {
    var c = base
    switch group {
    case .fontFamily:
        c.fontFamily = charStr(store, "font_family")
    case .style:
        // Unknown style names leave BOTH halves of the pair alone rather
        // than guessing one.
        if let (fw, fst) = parseStyleName(charStr(store, "style_name")) {
            c.fontWeight = fw
            c.fontStyle = fst
        }
    case .fontSize:
        c.fontSize = charNum(store, "font_size")
    case .leading:
        // Auto (an ABSENT line-height) is 120% of the ELEMENT's font size.
        let auto = c.fontSize * 1.2
        if let leading = characterPanelField(store, "leading").flatMap(asDoubleValue),
           abs(leading - auto) > 1e-6 {
            c.lineHeight = fmtNum(leading) + "pt"
        } else {
            c.lineHeight = ""
        }
    case .kerning:
        c.kerning = kerningAttr(charStr(store, "kerning"))
    case .tracking:
        let tracking = charNum(store, "tracking")
        c.letterSpacing = tracking == 0.0 ? "" : fmtNum(tracking / 1000.0) + "em"
    case .verticalScale:
        let v = charNum(store, "vertical_scale")
        c.verticalScale = v == 100.0 ? "" : fmtNum(v)
    case .horizontalScale:
        let h = charNum(store, "horizontal_scale")
        c.horizontalScale = h == 100.0 ? "" : fmtNum(h)
    case .baselineShift:
        if charFlag(store, "superscript") {
            c.baselineShift = "super"
        } else if charFlag(store, "subscript") {
            c.baselineShift = "sub"
        } else {
            let bs = charNum(store, "baseline_shift")
            c.baselineShift = bs == 0.0 ? "" : fmtNum(bs) + "pt"
        }
    case .rotation:
        let rot = charNum(store, "character_rotation")
        c.rotate = rot == 0.0 ? "" : fmtNum(rot)
    case .textCase:
        let allCaps = charFlag(store, "all_caps")
        let smallCaps = charFlag(store, "small_caps")
        c.textTransform = allCaps ? "uppercase" : ""
        c.fontVariant = (smallCaps && !allCaps) ? "small-caps" : ""
    case .decoration:
        c.textDecoration = textDecorationFromFlags(
            underline: charFlag(store, "underline"),
            strikethrough: charFlag(store, "strikethrough"))
    case .language:
        c.xmlLang = charStr(store, "language")
    case .aaMode:
        let aa = charStr(store, "anti_aliasing")
        c.aaMode = (aa == "Sharp" || aa.isEmpty) ? "" : aa
    }
    return c
}

/// The attribute dict a `group` edit hands to
/// `Controller.setSelectionTextAttributes`: the group's keys only, so every
/// other attribute of the element is left untouched.
public func characterAttrsForGroup(
    _ base: CharacterAttrs, store: StateStore, group: CharacterEditGroup
) -> [String: Any] {
    let full = characterWithGroup(base, store: store, group: group).asAttrDict
    var out: [String: Any] = [:]
    for key in characterGroupAttrKeys(group) {
        out[key] = full[key]
    }
    return out
}

/// A panel override template narrowed to `group`: every field outside the
/// group is cleared to `nil` so `mergeTspanOverrides` leaves the range's
/// existing values alone.
///
/// Groups that own no tspan-level field (the glyph scales, kerning) yield a
/// template with nothing set — a range write for those attributes is not yet
/// expressible on a Tspan, and stamping the panel's OTHER attributes instead
/// is exactly what this law forbids. Mirrors the Rust
/// `CharacterEditGroup::restrict_tspan_overrides`.
public func restrictTspanOverrides(
    _ t: Tspan, to group: CharacterEditGroup
) -> Tspan {
    Tspan(
        id: t.id, content: t.content,
        baselineShift: group == .baselineShift ? t.baselineShift : nil,
        dx: t.dx,
        fontFamily: group == .fontFamily ? t.fontFamily : nil,
        fontSize: group == .fontSize ? t.fontSize : nil,
        fontStyle: group == .style ? t.fontStyle : nil,
        fontVariant: group == .textCase ? t.fontVariant : nil,
        fontWeight: group == .style ? t.fontWeight : nil,
        jasAaMode: group == .aaMode ? t.jasAaMode : nil,
        jasFractionalWidths: t.jasFractionalWidths,
        jasKerningMode: t.jasKerningMode,
        jasNoBreak: t.jasNoBreak,
        letterSpacing: group == .tracking ? t.letterSpacing : nil,
        lineHeight: group == .leading ? t.lineHeight : nil,
        rotate: group == .rotation ? t.rotate : nil,
        styleName: t.styleName,
        textDecoration: group == .decoration ? t.textDecoration : nil,
        textRendering: t.textRendering,
        textTransform: group == .textCase ? t.textTransform : nil,
        transform: t.transform,
        xmlLang: group == .language ? t.xmlLang : nil)
}

/// `(font_weight, font_style)` for a Style dropdown entry, or `nil` for an
/// unrecognised name — which leaves BOTH attributes alone rather than
/// guessing one. Inverse of `formatStyleName`.
public func parseStyleName(_ name: String) -> (String, String)? {
    switch name.trimmingCharacters(in: .whitespaces) {
    case "Regular": return ("normal", "normal")
    case "Italic": return ("normal", "italic")
    case "Bold": return ("bold", "normal")
    case "Bold Italic", "Italic Bold": return ("bold", "italic")
    default: return nil
    }
}

/// The CSS `text-decoration` token list for the two toggles, alphabetical so
/// equality never depends on which toggle the user hit first.
public func textDecorationFromFlags(underline: Bool, strikethrough: Bool) -> String {
    var parts: [String] = []
    if strikethrough { parts.append("line-through") }
    if underline { parts.append("underline") }
    return parts.joined(separator: " ")
}

/// A stored panel value as a Double, whatever numeric box it arrived in.
private func asDoubleValue(_ v: Any) -> Double? {
    switch v {
    case let n as NSNumber: return n.doubleValue
    case let d as Double: return d
    case let i as Int: return Double(i)
    default: return nil
    }
}

/// Read the first selected Text / TextPath element and derive the
/// Character-panel key/value overrides. Returns `nil` when no text
/// element is selected — caller falls back to the stored panel scope.
public func characterPanelLiveOverrides(model: Model) -> [String: Any]? {
    guard let first = model.document.selection.first else { return nil }
    let elem = model.document.getElement(first.path)
    let aRaw: TextAttrsLive
    let tspans: [Tspan]
    switch elem {
    case .text(let t):
        aRaw = TextAttrsLive(
            fontFamily: t.fontFamily, fontSize: t.fontSize,
            fontWeight: t.fontWeight, fontStyle: t.fontStyle,
            textDecoration: t.textDecoration,
            textTransform: t.textTransform, fontVariant: t.fontVariant,
            baselineShift: t.baselineShift, lineHeight: t.lineHeight,
            letterSpacing: t.letterSpacing, xmlLang: t.xmlLang,
            aaMode: t.aaMode, rotate: t.rotate,
            horizontalScale: t.horizontalScale, verticalScale: t.verticalScale,
            kerning: t.kerning)
        tspans = t.tspans
    case .textPath(let tp):
        aRaw = TextAttrsLive(
            fontFamily: tp.fontFamily, fontSize: tp.fontSize,
            fontWeight: tp.fontWeight, fontStyle: tp.fontStyle,
            textDecoration: tp.textDecoration,
            textTransform: tp.textTransform, fontVariant: tp.fontVariant,
            baselineShift: tp.baselineShift, lineHeight: tp.lineHeight,
            letterSpacing: tp.letterSpacing, xmlLang: tp.xmlLang,
            aaMode: tp.aaMode, rotate: tp.rotate,
            horizontalScale: tp.horizontalScale, verticalScale: tp.verticalScale,
            kerning: tp.kerning)
        tspans = tp.tspans
    default:
        return nil
    }

    // When an edit session has a range selection on the same element,
    // resolve each attribute against the tspans covering [lo, hi).
    // Uniform values across the range surface as the panel's display
    // value; non-uniform falls back to the element-level default so the
    // dropdown still shows something concrete.
    let a: TextAttrsLive = {
        guard let session = model.currentEditSession,
              session.hasSelection,
              session.path == first.path
        else { return aRaw }
        let (lo, hi) = session.selectionRange
        return TextAttrsLive(
            fontFamily:      uniformStringInRange(tspans, lo, hi, { $0.fontFamily }, aRaw.fontFamily),
            fontSize:        aRaw.fontSize,
            fontWeight:      uniformStringInRange(tspans, lo, hi, { $0.fontWeight }, aRaw.fontWeight),
            fontStyle:       uniformStringInRange(tspans, lo, hi, { $0.fontStyle }, aRaw.fontStyle),
            textDecoration:  uniformDecorationInRange(tspans, lo, hi, aRaw.textDecoration),
            textTransform:   uniformStringInRange(tspans, lo, hi, { $0.textTransform }, aRaw.textTransform),
            fontVariant:     uniformStringInRange(tspans, lo, hi, { $0.fontVariant }, aRaw.fontVariant),
            baselineShift:   uniformBaselineShiftInRange(tspans, lo, hi, aRaw.baselineShift),
            lineHeight:      aRaw.lineHeight,
            letterSpacing:   aRaw.letterSpacing,
            xmlLang:         uniformStringInRange(tspans, lo, hi, { $0.xmlLang }, aRaw.xmlLang),
            aaMode:          uniformStringInRange(tspans, lo, hi, { $0.jasAaMode }, aRaw.aaMode),
            rotate:          aRaw.rotate,
            horizontalScale: aRaw.horizontalScale,
            verticalScale:   aRaw.verticalScale,
            kerning:         aRaw.kerning)
    }()

    let (underline, strikethrough) = textDecorationFlags(a.textDecoration)
    // Numeric baseline-shift: only expose when super/sub isn't set.
    let bshiftPt: Double = (a.baselineShift == "super" || a.baselineShift == "sub")
        ? 0.0
        : (parsePt(a.baselineShift) ?? 0.0)
    // Leading: empty = Auto (120% of font_size).
    let leadingPt = a.lineHeight.isEmpty
        ? a.fontSize * 1.2
        : (parsePt(a.lineHeight) ?? a.fontSize * 1.2)
    // Tracking: parse "Nem" → N*1000 (panel stores 1/1000 em).
    let tracking = a.letterSpacing.isEmpty
        ? 0.0
        : (parseEmAsThousandths(a.letterSpacing) ?? 0.0)
    // Kerning combo_box display: named modes pass through verbatim;
    // numeric "Nem" converts to a plain "{N*1000}" decimal string.
    // Empty element attribute → "Auto" (spec default).
    let kerningDisplay: String
    switch a.kerning {
    case "": kerningDisplay = "Auto"
    case "Auto", "Optical", "Metrics": kerningDisplay = a.kerning
    default:
        if let n = parseEmAsThousandths(a.kerning) {
            kerningDisplay = fmtNum(n)
        } else {
            kerningDisplay = a.kerning
        }
    }
    let styleName = formatStyleName(weight: a.fontWeight, style: a.fontStyle)
    // Anti-aliasing: empty element field → panel default "Sharp".
    let aaDisplay = a.aaMode.isEmpty ? "Sharp" : a.aaMode
    let rotation = Double(a.rotate) ?? 0.0
    let hScale = Double(a.horizontalScale) ?? 100.0
    let vScale = Double(a.verticalScale) ?? 100.0

    return [
        "font_family": a.fontFamily,
        "font_size": a.fontSize,
        "style_name": styleName,
        "underline": underline,
        "strikethrough": strikethrough,
        "all_caps": a.textTransform == "uppercase",
        "small_caps": a.fontVariant == "small-caps",
        "superscript": a.baselineShift == "super",
        "subscript": a.baselineShift == "sub",
        "baseline_shift": bshiftPt,
        "leading": leadingPt,
        "tracking": tracking,
        "character_rotation": rotation,
        "horizontal_scale": hScale,
        "vertical_scale": vScale,
        "kerning": kerningDisplay,
        "language": a.xmlLang,
        "anti_aliasing": aaDisplay,
    ]
}

/// Whether the first selected Text / TextPath element has an empty
/// line_height attribute (i.e. leading is in Auto mode = 120% of font
/// size). Returns false when no text is selected. Used by the panel
/// commit path to keep leading tracking font_size while Auto remains
/// in effect.
public func characterElementHasAutoLeading(model: Model) -> Bool {
    guard let first = model.document.selection.first else { return false }
    switch model.document.getElement(first.path) {
    case .text(let t): return t.lineHeight.isEmpty
    case .textPath(let tp): return tp.lineHeight.isEmpty
    default: return false
    }
}

private struct TextAttrsLive {
    let fontFamily: String
    let fontSize: Double
    let fontWeight: String
    let fontStyle: String
    let textDecoration: String
    let textTransform: String
    let fontVariant: String
    let baselineShift: String
    let lineHeight: String
    let letterSpacing: String
    let xmlLang: String
    let aaMode: String
    let rotate: String
    let horizontalScale: String
    let verticalScale: String
    let kerning: String
}

/// Underline + strikethrough flags from a whitespace-split
/// `text-decoration`. "underline line-through", "line-through
/// underline", mixed-case all round-trip cleanly through the panel.
private func textDecorationFlags(_ td: String) -> (Bool, Bool) {
    var u = false, s = false
    for tok in td.split(separator: " ") {
        if tok == "underline" { u = true }
        if tok == "line-through" { s = true }
    }
    return (u, s)
}

/// "Nem" → N * 1000 (panel stores tracking / kerning in 1/1000 em).
private func parseEmAsThousandths(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let rest = t.hasSuffix("em") ? String(t.dropLast(2)) : t
    return Double(rest).map { $0 * 1000.0 }
}

/// Trim trailing zeros from a decimal render — integers have no
/// decimal point. Mirrors Rust's `fmt_num`.
private func fmtNum(_ n: Double) -> String {
    if n == n.rounded(.towardZero) { return String(Int(n)) }
    var s = String(format: "%.4f", n)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}

/// "Npt" / "N" → N. nil when unparseable (caller chooses a default).
private func parsePt(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let rest = t.hasSuffix("pt") ? String(t.dropLast(2)) : t
    return Double(rest)
}

/// Walk `tspans` over [lo, hi). For each tspan that overlaps the
/// range, take its override value (or the parent default when nil).
/// Return the common value when every covered tspan agrees;
/// otherwise return `parent` so the panel still shows a concrete
/// value rather than a blank or stale field.
private func uniformStringInRange(
    _ tspans: [Tspan], _ lo: Int, _ hi: Int,
    _ extract: (Tspan) -> String?, _ parent: String
) -> String {
    if lo >= hi { return parent }
    var seen: String? = nil
    var cursor = 0
    for t in tspans {
        let len = t.content.unicodeScalars.count
        let tStart = cursor
        let tEnd = cursor + len
        cursor = tEnd
        if max(lo, tStart) >= min(hi, tEnd) { continue }
        let val = extract(t) ?? parent
        if let s = seen {
            if s != val { return parent }
        } else {
            seen = val
        }
    }
    return seen ?? parent
}

/// text-decoration variant: tspan stores it as `[String]?` (sorted
/// tokens) rather than a single string, so adapt the comparison.
private func uniformDecorationInRange(
    _ tspans: [Tspan], _ lo: Int, _ hi: Int, _ parent: String
) -> String {
    if lo >= hi { return parent }
    let parentTokens = parent.split(separator: " ").map(String.init).sorted()
    var seen: [String]? = nil
    var cursor = 0
    for t in tspans {
        let len = t.content.unicodeScalars.count
        let tStart = cursor
        let tEnd = cursor + len
        cursor = tEnd
        if max(lo, tStart) >= min(hi, tEnd) { continue }
        let toks = t.textDecoration?.sorted() ?? parentTokens
        if let s = seen {
            if s != toks { return parent }
        } else {
            seen = toks
        }
    }
    return seen?.joined(separator: " ") ?? parent
}

/// baseline-shift variant: tspan stores it as `Double?` (pt) rather
/// than the element's "Npt" / "super" / "sub" string, so reformat to
/// match the parent's representation. When tspans disagree, fall
/// back to the element-level value.
private func uniformBaselineShiftInRange(
    _ tspans: [Tspan], _ lo: Int, _ hi: Int, _ parent: String
) -> String {
    if lo >= hi { return parent }
    var seen: Double? = nil
    var seenSet = false
    var cursor = 0
    for t in tspans {
        let len = t.content.unicodeScalars.count
        let tStart = cursor
        let tEnd = cursor + len
        cursor = tEnd
        if max(lo, tStart) >= min(hi, tEnd) { continue }
        let val = t.baselineShift
        if seenSet {
            if seen != val { return parent }
        } else {
            seen = val
            seenSet = true
        }
    }
    guard seenSet else { return parent }
    if let v = seen {
        if v == 0.0 { return "" }
        return fmtNum(v) + "pt"
    }
    return parent
}

/// Display the Style picker's current name from font_weight /
/// font_style. Matches the Rust `format_style_name` fallback
/// (unrecognised combos → "Regular") so the dropdown always shows
/// a concrete value.
private func formatStyleName(weight: String, style: String) -> String {
    let bold = weight == "bold" || (Int(weight).map { $0 >= 600 } ?? false)
    let italic = style == "italic" || style == "oblique"
    switch (bold, italic) {
    case (true, true): return "Bold Italic"
    case (true, false): return "Bold"
    case (false, true): return "Italic"
    case (false, false): return "Regular"
    }
}
