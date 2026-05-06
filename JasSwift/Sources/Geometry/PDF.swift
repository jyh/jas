// PDF emitter (PRINT.md §Phase 1B). Uses Core Graphics' PDF context
// (no PDFKit dependency needed for emit — PDFKit's APIs are oriented
// around displaying / annotating existing PDFs).
//
// Walks the document, emitting one page per artboard (or a single
// page covering the artboard union when print_preferences.ignoreArtboards
// is set). Per-page MediaBox = artboard rect. Element types covered:
// path (cubic + quad-as-cubic + arc-as-line fallback), rect, line,
// circle, ellipse, polyline, polygon, basic text (single-tspan
// concatenation, system font), groups, layers (transforms only).
// PrintLayers filter applied at layer boundaries; visiblePrintable
// currently collapses to visible until Layer.print lands.

import Foundation
import CoreGraphics
import AppKit

/// Strip a known filename extension and append `.pdf`. Falls back to
/// "Untitled.pdf" for empty / Untitled-N filenames.
public func pdfFilenameForModel(_ model: Model) -> String {
    let trimmed = model.filename.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.hasPrefix("Untitled-") {
        return "Untitled.pdf"
    }
    let url = URL(fileURLWithPath: trimmed)
    let stem = url.deletingPathExtension().lastPathComponent
    return "\(stem).pdf"
}

/// Apply a single field update to PrintPreferences, returning a new
/// instance. Returns nil for unknown fields or value-type mismatches
/// — the caller then leaves the document unchanged (matches the
/// defensive contract of doc.set_artboard_options_field). Internal
/// because `Value` is internal to the JasLib module.
func applyPrintPrefField(_ p: PrintPreferences, field: String, val: Value) -> PrintPreferences? {
    func num() -> Double? {
        if case .number(let n) = val { return n }
        return nil
    }
    func bool() -> Bool? {
        if case .bool(let b) = val { return b }
        return nil
    }
    func str() -> String? {
        if case .string(let s) = val { return s }
        return nil
    }
    switch field {
    case "preset_name":
        guard let s = str() else { return nil }
        return _withPref(p, presetName: s)
    case "printer_name":
        guard let s = str() else { return nil }
        return _withPref(p, printerName: s.isEmpty ? .some(nil) : .some(.some(s)))
    case "copies":
        guard let n = num() else { return nil }
        return _withPref(p, copies: max(0, Int(n)))
    case "collate":
        guard let b = bool() else { return nil }
        return _withPref(p, collate: b)
    case "reverse_order":
        guard let b = bool() else { return nil }
        return _withPref(p, reverseOrder: b)
    case "artboard_range_mode":
        guard let s = str(), let m = ArtboardRangeMode(rawValue: s) else { return nil }
        return _withPref(p, artboardRangeMode: m)
    case "artboard_range":
        guard let s = str() else { return nil }
        return _withPref(p, artboardRange: s)
    case "ignore_artboards":
        guard let b = bool() else { return nil }
        return _withPref(p, ignoreArtboards: b)
    case "skip_blank_artboards":
        guard let b = bool() else { return nil }
        return _withPref(p, skipBlankArtboards: b)
    case "media_size":
        guard let s = str(), let m = MediaSize(rawValue: s) else { return nil }
        return _withPref(p, mediaSize: m)
    case "media_width":
        guard let n = num() else { return nil }
        return _withPref(p, mediaWidth: n)
    case "media_height":
        guard let n = num() else { return nil }
        return _withPref(p, mediaHeight: n)
    case "orientation":
        guard let s = str(), let o = Orientation(rawValue: s) else { return nil }
        return _withPref(p, orientation: o)
    case "auto_rotate":
        guard let b = bool() else { return nil }
        return _withPref(p, autoRotate: b)
    case "transverse":
        guard let b = bool() else { return nil }
        return _withPref(p, transverse: b)
    case "print_layers":
        guard let s = str(), let pl = PrintLayers(rawValue: s) else { return nil }
        return _withPref(p, printLayers: pl)
    case "placement_x":
        guard let n = num() else { return nil }
        return _withPref(p, placementX: n)
    case "placement_y":
        guard let n = num() else { return nil }
        return _withPref(p, placementY: n)
    case "scaling_mode":
        guard let s = str(), let m = ScalingMode(rawValue: s) else { return nil }
        return _withPref(p, scalingMode: m)
    case "custom_scale":
        guard let n = num() else { return nil }
        return _withPref(p, customScale: n)
    case "tile_overlap_h":
        guard let n = num() else { return nil }
        return _withPref(p, tileOverlapH: n)
    case "tile_overlap_v":
        guard let n = num() else { return nil }
        return _withPref(p, tileOverlapV: n)
    case "tile_range":
        guard let s = str() else { return nil }
        return _withPref(p, tileRange: s)
    default:
        return nil
    }
}

/// PrintPreferences is immutable (`let` fields), so per-field updates
/// build a fresh instance. Each labelled-arg override is optional;
/// nil means "keep current". `printerName` uses Optional<Optional<>>
/// to distinguish "no override" from "set to nil".
private func _withPref(
    _ p: PrintPreferences,
    presetName: String? = nil,
    printerName: String?? = nil,
    copies: Int? = nil,
    collate: Bool? = nil,
    reverseOrder: Bool? = nil,
    artboardRangeMode: ArtboardRangeMode? = nil,
    artboardRange: String? = nil,
    ignoreArtboards: Bool? = nil,
    skipBlankArtboards: Bool? = nil,
    mediaSize: MediaSize? = nil,
    mediaWidth: Double? = nil,
    mediaHeight: Double? = nil,
    orientation: Orientation? = nil,
    autoRotate: Bool? = nil,
    transverse: Bool? = nil,
    printLayers: PrintLayers? = nil,
    placementX: Double? = nil,
    placementY: Double? = nil,
    scalingMode: ScalingMode? = nil,
    customScale: Double? = nil,
    tileOverlapH: Double? = nil,
    tileOverlapV: Double? = nil,
    tileRange: String? = nil,
    marksAndBleed: MarksAndBleed? = nil,
    output: Output? = nil,
    graphics: Graphics? = nil,
    colorManagement: ColorManagement? = nil,
    advanced: Advanced? = nil
) -> PrintPreferences {
    return PrintPreferences(
        presetName: presetName ?? p.presetName,
        printerName: printerName ?? p.printerName,
        copies: copies ?? p.copies,
        collate: collate ?? p.collate,
        reverseOrder: reverseOrder ?? p.reverseOrder,
        artboardRangeMode: artboardRangeMode ?? p.artboardRangeMode,
        artboardRange: artboardRange ?? p.artboardRange,
        ignoreArtboards: ignoreArtboards ?? p.ignoreArtboards,
        skipBlankArtboards: skipBlankArtboards ?? p.skipBlankArtboards,
        mediaSize: mediaSize ?? p.mediaSize,
        mediaWidth: mediaWidth ?? p.mediaWidth,
        mediaHeight: mediaHeight ?? p.mediaHeight,
        orientation: orientation ?? p.orientation,
        autoRotate: autoRotate ?? p.autoRotate,
        transverse: transverse ?? p.transverse,
        printLayers: printLayers ?? p.printLayers,
        placementX: placementX ?? p.placementX,
        placementY: placementY ?? p.placementY,
        scalingMode: scalingMode ?? p.scalingMode,
        customScale: customScale ?? p.customScale,
        tileOverlapH: tileOverlapH ?? p.tileOverlapH,
        tileOverlapV: tileOverlapV ?? p.tileOverlapV,
        tileRange: tileRange ?? p.tileRange,
        marksAndBleed: marksAndBleed ?? p.marksAndBleed,
        output: output ?? p.output,
        graphics: graphics ?? p.graphics,
        colorManagement: colorManagement ?? p.colorManagement,
        advanced: advanced ?? p.advanced
    )
}

/// Apply a single field update to PrintPreferences's MarksAndBleed
/// sub-record (PRINT.md §Phase 2). Returns nil for unknown fields or
/// value-type mismatches — caller leaves PrintPreferences unchanged.
func applyMarksAndBleedField(_ p: PrintPreferences, field: String, val: Value) -> PrintPreferences? {
    func num() -> Double? {
        if case .number(let n) = val { return n }
        return nil
    }
    func bool() -> Bool? {
        if case .bool(let b) = val { return b }
        return nil
    }
    func str() -> String? {
        if case .string(let s) = val { return s }
        return nil
    }
    let m = p.marksAndBleed
    let updated: MarksAndBleed
    switch field {
    case "all_printer_marks":
        guard let b = bool() else { return nil }
        updated = _withMab(m, allPrinterMarks: b)
    case "trim_marks":
        guard let b = bool() else { return nil }
        updated = _withMab(m, trimMarks: b)
    case "registration_marks":
        guard let b = bool() else { return nil }
        updated = _withMab(m, registrationMarks: b)
    case "color_bars":
        guard let b = bool() else { return nil }
        updated = _withMab(m, colorBars: b)
    case "page_information":
        guard let b = bool() else { return nil }
        updated = _withMab(m, pageInformation: b)
    case "printer_mark_type":
        guard let s = str(), let t = PrinterMarkType(rawValue: s) else { return nil }
        updated = _withMab(m, printerMarkType: t)
    case "trim_mark_weight":
        guard let n = num() else { return nil }
        updated = _withMab(m, trimMarkWeight: n)
    case "mark_offset":
        guard let n = num() else { return nil }
        updated = _withMab(m, markOffset: n)
    case "use_document_bleed":
        guard let b = bool() else { return nil }
        updated = _withMab(m, useDocumentBleed: b)
    case "bleed_top":
        guard let n = num() else { return nil }
        updated = _withMab(m, bleedTop: n)
    case "bleed_right":
        guard let n = num() else { return nil }
        updated = _withMab(m, bleedRight: n)
    case "bleed_bottom":
        guard let n = num() else { return nil }
        updated = _withMab(m, bleedBottom: n)
    case "bleed_left":
        guard let n = num() else { return nil }
        updated = _withMab(m, bleedLeft: n)
    default:
        return nil
    }
    return _withPref(p, marksAndBleed: updated)
}

private func _withMab(
    _ m: MarksAndBleed,
    allPrinterMarks: Bool? = nil,
    trimMarks: Bool? = nil,
    registrationMarks: Bool? = nil,
    colorBars: Bool? = nil,
    pageInformation: Bool? = nil,
    printerMarkType: PrinterMarkType? = nil,
    trimMarkWeight: Double? = nil,
    markOffset: Double? = nil,
    useDocumentBleed: Bool? = nil,
    bleedTop: Double? = nil,
    bleedRight: Double? = nil,
    bleedBottom: Double? = nil,
    bleedLeft: Double? = nil
) -> MarksAndBleed {
    return MarksAndBleed(
        allPrinterMarks: allPrinterMarks ?? m.allPrinterMarks,
        trimMarks: trimMarks ?? m.trimMarks,
        registrationMarks: registrationMarks ?? m.registrationMarks,
        colorBars: colorBars ?? m.colorBars,
        pageInformation: pageInformation ?? m.pageInformation,
        printerMarkType: printerMarkType ?? m.printerMarkType,
        trimMarkWeight: trimMarkWeight ?? m.trimMarkWeight,
        markOffset: markOffset ?? m.markOffset,
        useDocumentBleed: useDocumentBleed ?? m.useDocumentBleed,
        bleedTop: bleedTop ?? m.bleedTop,
        bleedRight: bleedRight ?? m.bleedRight,
        bleedBottom: bleedBottom ?? m.bleedBottom,
        bleedLeft: bleedLeft ?? m.bleedLeft
    )
}

/// Apply a single field update to PrintPreferences's Output sub-record
/// (PRINT.md §Phase 3). Returns nil for unknown fields or value-type
/// mismatches — caller leaves PrintPreferences unchanged.
func applyOutputField(_ p: PrintPreferences, field: String, val: Value) -> PrintPreferences? {
    func num() -> Double? {
        if case .number(let n) = val { return n }
        return nil
    }
    func bool() -> Bool? {
        if case .bool(let b) = val { return b }
        return nil
    }
    func str() -> String? {
        if case .string(let s) = val { return s }
        return nil
    }
    let _ = num
    let o = p.output
    let updated: Output
    switch field {
    case "mode":
        guard let s = str(), let m = OutputMode(rawValue: s) else { return nil }
        updated = _withOut(o, mode: m)
    case "emulsion":
        guard let s = str(), let e = Emulsion(rawValue: s) else { return nil }
        updated = _withOut(o, emulsion: e)
    case "image_polarity":
        guard let s = str(), let ip = ImagePolarity(rawValue: s) else { return nil }
        updated = _withOut(o, imagePolarity: ip)
    case "printer_resolution":
        guard let s = str() else { return nil }
        updated = _withOut(o, printerResolution: s)
    case "convert_spot_to_process":
        guard let b = bool() else { return nil }
        updated = _withOut(o, convertSpotToProcess: b)
    case "overprint_black":
        guard let b = bool() else { return nil }
        updated = _withOut(o, overprintBlack: b)
    default:
        return nil
    }
    return _withPref(p, output: updated)
}

/// Apply a single field update to one InkOverride row of the Output
/// sub-record. Out-of-range indices and unknown / mistyped fields
/// return nil so the document stays unchanged.
func applyOutputInkField(_ p: PrintPreferences, index: Int, field: String, val: Value) -> PrintPreferences? {
    func num() -> Double? {
        if case .number(let n) = val { return n }
        return nil
    }
    func bool() -> Bool? {
        if case .bool(let b) = val { return b }
        return nil
    }
    func str() -> String? {
        if case .string(let s) = val { return s }
        return nil
    }
    let inks = p.output.inks
    guard index >= 0, index < inks.count else { return nil }
    let ink = inks[index]
    let newInk: InkOverride
    switch field {
    case "name":
        guard let s = str() else { return nil }
        newInk = InkOverride(name: s, print: ink.print, frequency: ink.frequency, angle: ink.angle, dotShape: ink.dotShape)
    case "print":
        guard let b = bool() else { return nil }
        newInk = InkOverride(name: ink.name, print: b, frequency: ink.frequency, angle: ink.angle, dotShape: ink.dotShape)
    case "frequency":
        guard let n = num() else { return nil }
        newInk = InkOverride(name: ink.name, print: ink.print, frequency: n, angle: ink.angle, dotShape: ink.dotShape)
    case "angle":
        guard let n = num() else { return nil }
        newInk = InkOverride(name: ink.name, print: ink.print, frequency: ink.frequency, angle: n, dotShape: ink.dotShape)
    case "dot_shape":
        guard let s = str(), let ds = DotShape(rawValue: s) else { return nil }
        newInk = InkOverride(name: ink.name, print: ink.print, frequency: ink.frequency, angle: ink.angle, dotShape: ds)
    default:
        return nil
    }
    var newInks = inks
    newInks[index] = newInk
    let newOutput = _withOut(p.output, inks: newInks)
    return _withPref(p, output: newOutput)
}

private func _withOut(
    _ o: Output,
    mode: OutputMode? = nil,
    emulsion: Emulsion? = nil,
    imagePolarity: ImagePolarity? = nil,
    printerResolution: String? = nil,
    convertSpotToProcess: Bool? = nil,
    overprintBlack: Bool? = nil,
    inks: [InkOverride]? = nil
) -> Output {
    return Output(
        mode: mode ?? o.mode,
        emulsion: emulsion ?? o.emulsion,
        imagePolarity: imagePolarity ?? o.imagePolarity,
        printerResolution: printerResolution ?? o.printerResolution,
        convertSpotToProcess: convertSpotToProcess ?? o.convertSpotToProcess,
        overprintBlack: overprintBlack ?? o.overprintBlack,
        inks: inks ?? o.inks
    )
}

/// Apply a single field update to PrintPreferences's Graphics
/// sub-record (PRINT.md §Phase 4). Returns nil for unknown fields or
/// value-type mismatches — caller leaves PrintPreferences unchanged.
func applyGraphicsField(_ p: PrintPreferences, field: String, val: Value) -> PrintPreferences? {
    func num() -> Double? {
        if case .number(let n) = val { return n }
        return nil
    }
    func bool() -> Bool? {
        if case .bool(let b) = val { return b }
        return nil
    }
    func str() -> String? {
        if case .string(let s) = val { return s }
        return nil
    }
    let g = p.graphics
    let updated: Graphics
    switch field {
    case "flatness":
        guard let n = num() else { return nil }
        updated = _withGfx(g, flatness: n)
    case "font_download":
        guard let s = str(), let f = FontDownload(rawValue: s) else { return nil }
        updated = _withGfx(g, fontDownload: f)
    case "postscript_level":
        guard let s = str(), let pl = PostScriptLevel(rawValue: s) else { return nil }
        updated = _withGfx(g, postscriptLevel: pl)
    case "data_format":
        guard let s = str(), let df = DataFormat(rawValue: s) else { return nil }
        updated = _withGfx(g, dataFormat: df)
    case "compatible_gradient_printing":
        guard let b = bool() else { return nil }
        updated = _withGfx(g, compatibleGradientPrinting: b)
    case "raster_effects_resolution":
        guard let n = num() else { return nil }
        updated = _withGfx(g, rasterEffectsResolution: n)
    default:
        return nil
    }
    return _withPref(p, graphics: updated)
}

private func _withGfx(
    _ g: Graphics,
    flatness: Double? = nil,
    fontDownload: FontDownload? = nil,
    postscriptLevel: PostScriptLevel? = nil,
    dataFormat: DataFormat? = nil,
    compatibleGradientPrinting: Bool? = nil,
    rasterEffectsResolution: Double? = nil
) -> Graphics {
    return Graphics(
        flatness: flatness ?? g.flatness,
        fontDownload: fontDownload ?? g.fontDownload,
        postscriptLevel: postscriptLevel ?? g.postscriptLevel,
        dataFormat: dataFormat ?? g.dataFormat,
        compatibleGradientPrinting: compatibleGradientPrinting ?? g.compatibleGradientPrinting,
        rasterEffectsResolution: rasterEffectsResolution ?? g.rasterEffectsResolution
    )
}

/// Apply a single field update to PrintPreferences's ColorManagement
/// sub-record (PRINT.md §Phase 5). Returns nil for unknown fields or
/// value-type mismatches — caller leaves PrintPreferences unchanged.
func applyColorManagementField(_ p: PrintPreferences, field: String, val: Value) -> PrintPreferences? {
    func bool() -> Bool? {
        if case .bool(let b) = val { return b }
        return nil
    }
    func str() -> String? {
        if case .string(let s) = val { return s }
        return nil
    }
    let c = p.colorManagement
    let updated: ColorManagement
    switch field {
    case "document_profile":
        guard let s = str() else { return nil }
        updated = _withCm(c, documentProfile: s)
    case "color_handling":
        guard let s = str(), let ch = ColorHandling(rawValue: s) else { return nil }
        updated = _withCm(c, colorHandling: ch)
    case "printer_profile":
        guard let s = str() else { return nil }
        updated = _withCm(c, printerProfile: s)
    case "rendering_intent":
        guard let s = str(), let ri = RenderingIntent(rawValue: s) else { return nil }
        updated = _withCm(c, renderingIntent: ri)
    case "preserve_rgb_numbers":
        guard let b = bool() else { return nil }
        updated = _withCm(c, preserveRgbNumbers: b)
    default:
        return nil
    }
    return _withPref(p, colorManagement: updated)
}

private func _withCm(
    _ c: ColorManagement,
    documentProfile: String? = nil,
    colorHandling: ColorHandling? = nil,
    printerProfile: String? = nil,
    renderingIntent: RenderingIntent? = nil,
    preserveRgbNumbers: Bool? = nil
) -> ColorManagement {
    return ColorManagement(
        documentProfile: documentProfile ?? c.documentProfile,
        colorHandling: colorHandling ?? c.colorHandling,
        printerProfile: printerProfile ?? c.printerProfile,
        renderingIntent: renderingIntent ?? c.renderingIntent,
        preserveRgbNumbers: preserveRgbNumbers ?? c.preserveRgbNumbers
    )
}

/// Apply a single field update to PrintPreferences's Advanced
/// sub-record (PRINT.md §Phase 6). Returns nil for unknown fields or
/// value-type mismatches.
func applyAdvancedField(_ p: PrintPreferences, field: String, val: Value) -> PrintPreferences? {
    func bool() -> Bool? {
        if case .bool(let b) = val { return b }
        return nil
    }
    func str() -> String? {
        if case .string(let s) = val { return s }
        return nil
    }
    let a = p.advanced
    let updated: Advanced
    switch field {
    case "print_as_bitmap":
        guard let b = bool() else { return nil }
        updated = Advanced(printAsBitmap: b, overprintFlattenerPreset: a.overprintFlattenerPreset)
    case "overprint_flattener_preset":
        guard let s = str(), let preset = FlattenerPreset(rawValue: s) else { return nil }
        updated = Advanced(printAsBitmap: a.printAsBitmap, overprintFlattenerPreset: preset)
    default:
        return nil
    }
    return _withPref(p, advanced: updated)
}

/// DocumentSetup is immutable (`let` fields), so per-field updates
/// build a fresh instance preserving everything else. Each labelled-
/// arg override is optional; nil means "keep current".
func _withDocSetup(
    _ s: DocumentSetup,
    bleedTop: Double? = nil,
    bleedRight: Double? = nil,
    bleedBottom: Double? = nil,
    bleedLeft: Double? = nil,
    bleedUniform: Bool? = nil,
    showImagesOutline: Bool? = nil,
    highlightSubstitutedGlyphs: Bool? = nil,
    gridSize: Double? = nil,
    gridColor: String? = nil,
    paperColor: String? = nil,
    simulateColoredPaper: Bool? = nil,
    transparencyFlattenerPreset: FlattenerPreset? = nil,
    discardWhiteOverprint: Bool? = nil
) -> DocumentSetup {
    return DocumentSetup(
        bleedTop: bleedTop ?? s.bleedTop,
        bleedRight: bleedRight ?? s.bleedRight,
        bleedBottom: bleedBottom ?? s.bleedBottom,
        bleedLeft: bleedLeft ?? s.bleedLeft,
        bleedUniform: bleedUniform ?? s.bleedUniform,
        showImagesOutline: showImagesOutline ?? s.showImagesOutline,
        highlightSubstitutedGlyphs: highlightSubstitutedGlyphs ?? s.highlightSubstitutedGlyphs,
        gridSize: gridSize ?? s.gridSize,
        gridColor: gridColor ?? s.gridColor,
        paperColor: paperColor ?? s.paperColor,
        simulateColoredPaper: simulateColoredPaper ?? s.simulateColoredPaper,
        transparencyFlattenerPreset: transparencyFlattenerPreset ?? s.transparencyFlattenerPreset,
        discardWhiteOverprint: discardWhiteOverprint ?? s.discardWhiteOverprint
    )
}

/// Convert a document to PDF bytes.
public func documentToPdf(_ doc: Document) -> Data {
    let pages = collectPages(doc)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
        return Data()
    }
    // Use the first page's mediaBox as the default; per-page mediaBox
    // is set on each beginPDFPage call.
    var defaultMediaBox = pages.first?.mediaBox ?? CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultMediaBox, nil) else {
        return Data()
    }
    for page in pages {
        var box = page.mediaBox
        let pageInfo: CFDictionary = [
            kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
        ] as CFDictionary
        ctx.beginPDFPage(pageInfo)
        drawPage(ctx, doc, page)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return data as Data
}

private struct Page {
    let mediaBox: CGRect
    let srcX: Double
    let srcY: Double
    let srcW: Double
    let srcH: Double
    /// Where the trim rect sits inside the (possibly bleed-extended)
    /// MediaBox. (0, 0) when no bleed/marks are active.
    let trimXOff: Double
    let trimYOff: Double
    /// PRINT.md §Phase 3: when set, this page is one channel of a
    /// separations job and ``separationLabel`` is the ink name. v1
    /// renders the artwork the same way Composite mode does and
    /// stamps the label as a small page-info string; per-ink
    /// channel extraction is a deferred follow-up.
    let separationLabel: String?
}

// MARK: - Marks-and-Bleed PDF geometry (PRINT.md §Phase 2)

/// Length of each trim mark line in points. Per PRINT.md §Phase 2
/// the mark itself is short and sits outside the trim by mark_offset.
private let trimMarkLength: Double = 12.0
/// Outer radius of the registration mark cross-in-circle.
private let regMarkRadius: Double = 4.0
/// Side length of one CMYK / RGB / grey color-bar swatch.
private let colorBarSwatch: Double = 10.0

/// Effective bleed for a print pass: per-print overrides on
/// MarksAndBleed when use_document_bleed is false, otherwise the
/// document-level DocumentSetup bleed.
private func activeBleed(_ doc: Document) -> (Double, Double, Double, Double) {
    let m = doc.printPreferences.marksAndBleed
    if m.useDocumentBleed {
        let d = doc.documentSetup
        return (d.bleedTop, d.bleedRight, d.bleedBottom, d.bleedLeft)
    }
    return (m.bleedTop, m.bleedRight, m.bleedBottom, m.bleedLeft)
}

/// Extra space between the trim rect and the MediaBox edge needed to
/// hold the marks. Zero when no mark category is enabled, so the
/// MediaBox stays trim-snug for users who turn marks off.
private func markGutter(_ m: MarksAndBleed) -> Double {
    let any = m.allPrinterMarks || m.trimMarks || m.registrationMarks
        || m.colorBars || m.pageInformation
    return any ? m.markOffset + trimMarkLength + 2.0 : 0.0
}

private func collectPages(_ doc: Document) -> [Page] {
    let (bt, br, bb, bl) = activeBleed(doc)
    let g = markGutter(doc.printPreferences.marksAndBleed)
    let trimXOff = bl + g
    let trimYOff = bb + g
    let extraW = bl + br + 2.0 * g
    let extraH = bt + bb + 2.0 * g

    let base: [Page]
    if doc.printPreferences.ignoreArtboards || doc.artboards.isEmpty {
        let (x, y, w, h): (Double, Double, Double, Double)
        if doc.artboards.isEmpty {
            (x, y, w, h) = (0, 0, 612, 792)
        } else {
            (x, y, w, h) = artboardBoundsUnion(doc.artboards)
        }
        base = [Page(
            mediaBox: CGRect(x: 0, y: 0, width: w + extraW, height: h + extraH),
            srcX: x, srcY: y, srcW: w, srcH: h,
            trimXOff: trimXOff, trimYOff: trimYOff,
            separationLabel: nil)]
    } else {
        base = doc.artboards.map { ab in
            Page(
                mediaBox: CGRect(x: 0, y: 0, width: ab.width + extraW, height: ab.height + extraH),
                srcX: ab.x, srcY: ab.y, srcW: ab.width, srcH: ab.height,
                trimXOff: trimXOff, trimYOff: trimYOff,
                separationLabel: nil)
        }
    }
    return expandForSeparations(doc, base)
}

/// In Composite mode, returns ``base`` unchanged. In Separations mode
/// (PRINT.md §Phase 3), expands each base page into one copy per
/// enabled ink in artboard-major order. When Separations mode is
/// chosen but no inks are enabled, falls through to the composite
/// pages so the user still gets a PDF instead of an empty file.
private func expandForSeparations(_ doc: Document, _ base: [Page]) -> [Page] {
    let out = doc.printPreferences.output
    guard out.mode == .separations else { return base }
    let enabled = out.inks.filter(\.print)
    guard !enabled.isEmpty else { return base }
    var expanded: [Page] = []
    expanded.reserveCapacity(base.count * enabled.count)
    for page in base {
        for ink in enabled {
            expanded.append(Page(
                mediaBox: page.mediaBox,
                srcX: page.srcX, srcY: page.srcY,
                srcW: page.srcW, srcH: page.srcH,
                trimXOff: page.trimXOff, trimYOff: page.trimYOff,
                separationLabel: ink.name))
        }
    }
    return expanded
}

private func artboardBoundsUnion(_ abs: [Artboard]) -> (Double, Double, Double, Double) {
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    for ab in abs {
        minX = min(minX, ab.x)
        minY = min(minY, ab.y)
        maxX = max(maxX, ab.x + ab.width)
        maxY = max(maxY, ab.y + ab.height)
    }
    return (minX, minY, maxX - minX, maxY - minY)
}

// MARK: - Per-page draw

private func drawPage(_ ctx: CGContext, _ doc: Document, _ page: Page) {
    ctx.saveGState()
    // Phase 4: path-flattening tolerance. CGContext.setFlatness
    // matches the PDF ``i`` operator semantically, but stays inside
    // the saveGState scope so it doesn't leak between pages. Default
    // 1.0 = PDF default; setting it explicitly here is a no-op for
    // unchanged docs but propagates user choices on Composite + on
    // every separations page.
    let flatness = doc.printPreferences.graphics.flatness
    if abs(flatness - 1.0) > .ulpOfOne {
        ctx.setFlatness(CGFloat(min(max(flatness, 0.0), 100.0)))
    }
    // Phase 5: rendering intent. CGContext.setRenderingIntent
    // matches the PDF ``ri`` operator. Stays inside the saveGState
    // scope so it doesn't leak between pages. Default
    // RelativeColorimetric matches PDF 1.7 §11.6.5.8 default; emit
    // only when non-default to keep output byte-equivalent.
    let intent = doc.printPreferences.colorManagement.renderingIntent
    if intent != .relativeColorimetric {
        let cgIntent: CGColorRenderingIntent = {
            switch intent {
            case .perceptual: return .perceptual
            case .relativeColorimetric: return .relativeColorimetric
            case .saturation: return .saturation
            case .absoluteColorimetric: return .absoluteColorimetric
            }
        }()
        ctx.setRenderingIntent(cgIntent)
    }
    // Position the trim rect inside the (possibly bleed-extended)
    // MediaBox. PDF is y-up, internal model is y-down. Flip the page
    // CTM and translate so document-space (page.srcX, page.srcY)
    // lands at the trim origin. User placement and scaling apply in
    // page space (post-flip).
    if page.trimXOff != 0 || page.trimYOff != 0 {
        ctx.translateBy(x: CGFloat(page.trimXOff), y: CGFloat(page.trimYOff))
    }
    ctx.translateBy(x: 0, y: page.srcH)
    ctx.scaleBy(x: 1, y: -1)
    let (sx, sy) = scalingPair(doc)
    let (px, py) = (doc.printPreferences.placementX, doc.printPreferences.placementY)
    if px != 0 || py != 0 {
        ctx.translateBy(x: CGFloat(px), y: CGFloat(py))
    }
    if sx != 1 || sy != 1 {
        ctx.scaleBy(x: CGFloat(sx), y: CGFloat(sy))
    }
    if page.srcX != 0 || page.srcY != 0 {
        ctx.translateBy(x: CGFloat(-page.srcX), y: CGFloat(-page.srcY))
    }
    for layer in doc.layers {
        emitElement(ctx, .layer(layer), filter: doc.printPreferences.printLayers)
    }
    ctx.restoreGState()

    // Marks render in PDF native coordinates (y-up, bottom-left
    // origin), aligned to the trim rect inside the MediaBox.
    emitMarks(ctx, doc, page)
    // Separations label (PRINT.md §Phase 3): stamp the ink name on
    // each separations page so the printer / user can tell channels
    // apart. Placed at the bottom-right of the trim rect to avoid
    // colliding with the page-info string at the bottom-left.
    if let name = page.separationLabel {
        emitSeparationLabel(ctx, page, name)
    }
}

private func emitSeparationLabel(_ ctx: CGContext, _ page: Page, _ name: String) {
    let labelX = page.trimXOff + page.srcW - 80
    let labelY = page.trimYOff - 14
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Helvetica", size: 6) ?? NSFont.systemFont(ofSize: 6),
        .foregroundColor: NSColor.black,
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: name, attributes: attrs))
    ctx.saveGState()
    ctx.textPosition = CGPoint(x: labelX, y: labelY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

private func emitMarks(_ ctx: CGContext, _ doc: Document, _ page: Page) {
    let m = doc.printPreferences.marksAndBleed
    if !m.allPrinterMarks && !m.trimMarks && !m.registrationMarks
        && !m.colorBars && !m.pageInformation {
        return
    }
    let (tx, ty) = (page.trimXOff, page.trimYOff)
    let (tw, th) = (page.srcW, page.srcH)
    if m.allPrinterMarks || m.trimMarks {
        emitTrimMarks(ctx, tx: tx, ty: ty, tw: tw, th: th, weight: m.trimMarkWeight, off: m.markOffset)
    }
    if m.allPrinterMarks || m.registrationMarks {
        emitRegistrationMarks(ctx, tx: tx, ty: ty, tw: tw, th: th, off: m.markOffset)
    }
    if m.allPrinterMarks || m.colorBars {
        emitColorBars(ctx, tx: tx, ty: ty, tw: tw, th: th, off: m.markOffset)
    }
    if m.allPrinterMarks || m.pageInformation {
        emitPageInfo(ctx, tx: tx, ty: ty)
    }
}

private func emitTrimMarks(
    _ ctx: CGContext, tx: Double, ty: Double, tw: Double, th: Double,
    weight: Double, off: Double
) {
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.setLineWidth(CGFloat(weight))
    let len = trimMarkLength
    // Eight short strokes, two per corner.
    let segs: [(Double, Double, Double, Double)] = [
        (tx - off - len, ty,            tx - off,       ty),            // BL horizontal
        (tx,             ty - off - len, tx,            ty - off),      // BL vertical
        (tx + tw + off,  ty,            tx + tw + off + len, ty),       // BR horizontal
        (tx + tw,        ty - off - len, tx + tw,       ty - off),      // BR vertical
        (tx - off - len, ty + th,       tx - off,       ty + th),       // TL horizontal
        (tx,             ty + th + off, tx,            ty + th + off + len), // TL vertical
        (tx + tw + off,  ty + th,       tx + tw + off + len, ty + th),  // TR horizontal
        (tx + tw,        ty + th + off, tx + tw,       ty + th + off + len), // TR vertical
    ]
    for (x1, y1, x2, y2) in segs {
        ctx.move(to: CGPoint(x: x1, y: y1))
        ctx.addLine(to: CGPoint(x: x2, y: y2))
    }
    ctx.strokePath()
    ctx.restoreGState()
}

private func emitRegistrationMarks(
    _ ctx: CGContext, tx: Double, ty: Double, tw: Double, th: Double,
    off: Double
) {
    let r = regMarkRadius
    let centers: [(Double, Double)] = [
        (tx + tw / 2, ty - off - r),       // bottom mid
        (tx + tw + off + r, ty + th / 2),  // right mid
        (tx + tw / 2, ty + th + off + r),  // top mid
        (tx - off - r, ty + th / 2),       // left mid
    ]
    for (cx, cy) in centers {
        emitRegMark(ctx, cx: cx, cy: cy, r: r)
    }
}

private func emitRegMark(_ ctx: CGContext, cx: Double, cy: Double, r: Double) {
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.setLineWidth(0.25)
    ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    ctx.move(to: CGPoint(x: cx - r, y: cy))
    ctx.addLine(to: CGPoint(x: cx + r, y: cy))
    ctx.move(to: CGPoint(x: cx, y: cy - r))
    ctx.addLine(to: CGPoint(x: cx, y: cy + r))
    ctx.strokePath()
    ctx.restoreGState()
}

private func emitColorBars(
    _ ctx: CGContext, tx: Double, ty: Double, tw: Double, th: Double,
    off: Double
) {
    let s = colorBarSwatch
    let swatches: [(Double, Double, Double)] = [
        (0, 1, 1),    // C
        (1, 0, 1),    // M
        (1, 1, 0),    // Y
        (0, 0, 0),    // K
        (1, 0, 0),    // R
        (0, 1, 0),    // G
        (0, 0, 1),    // B
        (0.5, 0.5, 0.5), // grey
    ]
    let baseX = tx
    let baseY = ty + th + off + trimMarkLength + 2.0
    for (i, (r, g, b)) in swatches.enumerated() {
        let x = baseX + Double(i) * s
        if x + s > tx + tw { break }
        ctx.saveGState()
        ctx.setFillColor(CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1))
        ctx.fill(CGRect(x: x, y: baseY, width: s, height: s))
        ctx.restoreGState()
    }
}

private func emitPageInfo(_ ctx: CGContext, tx: Double, ty: Double) {
    // Phase-2 placeholder: a small label at the bottom-left margin.
    // Renderer-specific font metric work is deferred.
    let str = "Jas — page" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont(name: "Helvetica", size: 6) ?? NSFont.systemFont(ofSize: 6),
        .foregroundColor: NSColor.black,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: str as String, attributes: attrs))
    ctx.saveGState()
    ctx.textPosition = CGPoint(x: tx, y: ty - trimMarkLength - 8)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

private func scalingPair(_ doc: Document) -> (Double, Double) {
    switch doc.printPreferences.scalingMode {
    case .doNotScale, .fitToPage: return (1, 1)
    case .custom:
        let s = doc.printPreferences.customScale / 100.0
        return (s, s)
    }
}

// MARK: - Element walk

private func layerPassesFilter(_ layer: Layer, _ filter: PrintLayers) -> Bool {
    switch filter {
    case .all: return true
    case .visible, .visiblePrintable:
        return layer.visibility != .invisible
    }
}

private func emitElement(_ ctx: CGContext, _ el: Element, filter: PrintLayers) {
    if el.visibility == .invisible { return }
    switch el {
    case .layer(let l):
        if !layerPassesFilter(l, filter) { return }
        ctx.saveGState()
        applyTransform(ctx, l.transform)
        for child in l.children {
            emitElement(ctx, child, filter: filter)
        }
        ctx.restoreGState()
    case .group(let g):
        ctx.saveGState()
        applyTransform(ctx, g.transform)
        for child in g.children {
            emitElement(ctx, child, filter: filter)
        }
        ctx.restoreGState()
    case .rect(let r):
        emitPaint(ctx, fill: r.fill, stroke: r.stroke, transform: r.transform) {
            ctx.addRect(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
        }
    case .line(let l):
        emitStrokeOnly(ctx, stroke: l.stroke, transform: l.transform) {
            ctx.move(to: CGPoint(x: l.x1, y: l.y1))
            ctx.addLine(to: CGPoint(x: l.x2, y: l.y2))
        }
    case .circle(let c):
        emitPaint(ctx, fill: c.fill, stroke: c.stroke, transform: c.transform) {
            ctx.addEllipse(in: CGRect(x: c.cx - c.r, y: c.cy - c.r, width: 2 * c.r, height: 2 * c.r))
        }
    case .ellipse(let e):
        emitPaint(ctx, fill: e.fill, stroke: e.stroke, transform: e.transform) {
            ctx.addEllipse(in: CGRect(x: e.cx - e.rx, y: e.cy - e.ry, width: 2 * e.rx, height: 2 * e.ry))
        }
    case .polyline(let p):
        emitPaint(ctx, fill: p.fill, stroke: p.stroke, transform: p.transform) {
            addPolyline(ctx, p.points, close: false)
        }
    case .polygon(let p):
        emitPaint(ctx, fill: p.fill, stroke: p.stroke, transform: p.transform) {
            addPolyline(ctx, p.points, close: true)
        }
    case .path(let p):
        emitPaint(ctx, fill: p.fill, stroke: p.stroke, transform: p.transform) {
            addPathCommands(ctx, p.d)
        }
    case .text(let t):
        emitText(ctx, t)
    case .textPath, .live:
        // Phase 1B deferral.
        break
    }
}

private func applyTransform(_ ctx: CGContext, _ t: Transform?) {
    guard let t = t else { return }
    ctx.concatenate(CGAffineTransform(a: CGFloat(t.a), b: CGFloat(t.b),
                                       c: CGFloat(t.c), d: CGFloat(t.d),
                                       tx: CGFloat(t.e), ty: CGFloat(t.f)))
}

private func emitPaint(
    _ ctx: CGContext,
    fill: Fill?, stroke: Stroke?, transform: Transform?,
    addGeom: () -> Void
) {
    if fill == nil && stroke == nil { return }
    ctx.saveGState()
    applyTransform(ctx, transform)
    addGeom()
    if let f = fill {
        let (r, g, b, a) = f.color.toRgba()
        ctx.setFillColor(CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a * f.opacity)))
    }
    if let s = stroke {
        let (r, g, b, a) = s.color.toRgba()
        ctx.setStrokeColor(CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a * s.opacity)))
        ctx.setLineWidth(CGFloat(s.width))
    }
    let mode: CGPathDrawingMode
    switch (fill != nil, stroke != nil) {
    case (true, true):  mode = .fillStroke
    case (true, false): mode = .fill
    case (false, true): mode = .stroke
    default:            mode = .fill
    }
    ctx.drawPath(using: mode)
    ctx.restoreGState()
}

private func emitStrokeOnly(
    _ ctx: CGContext,
    stroke: Stroke?, transform: Transform?,
    addGeom: () -> Void
) {
    guard let s = stroke else { return }
    ctx.saveGState()
    applyTransform(ctx, transform)
    addGeom()
    let (r, g, b, a) = s.color.toRgba()
    ctx.setStrokeColor(CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a * s.opacity)))
    ctx.setLineWidth(CGFloat(s.width))
    ctx.strokePath()
    ctx.restoreGState()
}

private func addPolyline(_ ctx: CGContext, _ points: [(Double, Double)], close: Bool) {
    guard !points.isEmpty else { return }
    ctx.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for p in points.dropFirst() {
        ctx.addLine(to: CGPoint(x: p.0, y: p.1))
    }
    if close { ctx.closePath() }
}

private func addPathCommands(_ ctx: CGContext, _ commands: [PathCommand]) {
    var cur: (Double, Double) = (0, 0)
    var prevCubicCp: (Double, Double)? = nil
    var prevQuadCp: (Double, Double)? = nil
    for cmd in commands {
        switch cmd {
        case .moveTo(let x, let y):
            ctx.move(to: CGPoint(x: x, y: y))
            cur = (x, y); prevCubicCp = nil; prevQuadCp = nil
        case .lineTo(let x, let y):
            ctx.addLine(to: CGPoint(x: x, y: y))
            cur = (x, y); prevCubicCp = nil; prevQuadCp = nil
        case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
            ctx.addCurve(to: CGPoint(x: x, y: y),
                         control1: CGPoint(x: x1, y: y1),
                         control2: CGPoint(x: x2, y: y2))
            cur = (x, y); prevCubicCp = (x2, y2); prevQuadCp = nil
        case .smoothCurveTo(let x2, let y2, let x, let y):
            let (x1, y1): (Double, Double) = {
                if let p = prevCubicCp { return (2 * cur.0 - p.0, 2 * cur.1 - p.1) }
                return cur
            }()
            ctx.addCurve(to: CGPoint(x: x, y: y),
                         control1: CGPoint(x: x1, y: y1),
                         control2: CGPoint(x: x2, y: y2))
            cur = (x, y); prevCubicCp = (x2, y2); prevQuadCp = nil
        case .quadTo(let x1, let y1, let x, let y):
            ctx.addQuadCurve(to: CGPoint(x: x, y: y),
                             control: CGPoint(x: x1, y: y1))
            cur = (x, y); prevCubicCp = nil; prevQuadCp = (x1, y1)
        case .smoothQuadTo(let x, let y):
            let qCtrl: (Double, Double) = {
                if let p = prevQuadCp { return (2 * cur.0 - p.0, 2 * cur.1 - p.1) }
                return cur
            }()
            ctx.addQuadCurve(to: CGPoint(x: x, y: y),
                             control: CGPoint(x: qCtrl.0, y: qCtrl.1))
            cur = (x, y); prevCubicCp = nil; prevQuadCp = qCtrl
        case .arcTo(_, _, _, _, _, let x, let y):
            // Phase 1B deferral: arc-as-line fallback. Real arc
            // flattening is part of the arc-extrema gap backlog.
            ctx.addLine(to: CGPoint(x: x, y: y))
            cur = (x, y); prevCubicCp = nil; prevQuadCp = nil
        case .closePath:
            ctx.closePath()
            prevCubicCp = nil; prevQuadCp = nil
        }
    }
}

private func emitText(_ ctx: CGContext, _ t: Text) {
    let s = t.tspans.map(\.content).joined()
    if s.isEmpty { return }
    let (r, g, b, a) = (t.fill?.color ?? Color.black).toRgba()
    let fillAlpha = (t.fill?.opacity ?? 1.0) * a
    let font = NSFont(name: t.fontFamily, size: CGFloat(t.fontSize))
        ?? NSFont.systemFont(ofSize: CGFloat(t.fontSize))
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(red: CGFloat(r), green: CGFloat(g),
                                  blue: CGFloat(b), alpha: CGFloat(fillAlpha)),
    ]
    let attr = NSAttributedString(string: s, attributes: attrs)
    ctx.saveGState()
    applyTransform(ctx, t.transform)
    // The page CTM has Y flipped; re-flip locally so the text reads
    // right-side up. Anchor at the text origin (t.x, t.y).
    ctx.translateBy(x: CGFloat(t.x), y: CGFloat(t.y))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    attr.draw(at: CGPoint(x: 0, y: 0))
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
}
