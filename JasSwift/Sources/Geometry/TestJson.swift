import Foundation

/// Canonical Test JSON serialization for cross-language equivalence testing.
///
/// See `CROSS_LANGUAGE_TESTING.md` at the repository root for the full
/// specification.  Every semantic document value has exactly one JSON
/// string representation, so byte-for-byte comparison of the output is a
/// valid equivalence check.

// MARK: - Float formatting

/// Round to 4 decimal places, always include decimal point.
private func fmt(_ v: Double) -> String {
    let rounded = (v * 10000.0).rounded() / 10000.0
    if rounded == rounded.rounded(.towardZero) && rounded.truncatingRemainder(dividingBy: 1) == 0 {
        return String(format: "%.1f", rounded)
    }
    var s = String(format: "%.4f", rounded)
    // Strip trailing zeros but keep at least one digit after decimal.
    while s.hasSuffix("0") && !s.hasSuffix(".0") {
        s.removeLast()
    }
    return s
}

// MARK: - JSON builder with sorted keys

private class JsonObj {
    private var entries: [(String, String)] = []

    func str(_ key: String, _ v: String) {
        let escaped = v.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        entries.append((key, "\"\(escaped)\""))
    }

    func num(_ key: String, _ v: Double) {
        entries.append((key, fmt(v)))
    }

    func int(_ key: String, _ v: Int) {
        entries.append((key, "\(v)"))
    }

    func bool(_ key: String, _ v: Bool) {
        entries.append((key, v ? "true" : "false"))
    }

    func null(_ key: String) {
        entries.append((key, "null"))
    }

    /// Emit an empty string as null, otherwise as a JSON string.
    /// Matches the canonical-JSON rule that default / omitted
    /// attributes render as null.
    func emptyAsNull(_ key: String, _ v: String) {
        if v.isEmpty { null(key) } else { str(key, v) }
    }

    /// Emit `Some(v)` as a string, `None` as null.
    func optStr(_ key: String, _ v: String?) {
        if let v = v { str(key, v) } else { null(key) }
    }

    /// Emit `Some(v)` as a number, `None` as null.
    func optNum(_ key: String, _ v: Double?) {
        if let v = v { num(key, v) } else { null(key) }
    }

    /// Emit `Some(v)` as a bool, `None` as null.
    func optBool(_ key: String, _ v: Bool?) {
        if let v = v { bool(key, v) } else { null(key) }
    }

    func raw(_ key: String, _ json: String) {
        entries.append((key, json))
    }

    func build() -> String {
        entries.sort { $0.0 < $1.0 }
        let pairs = entries.map { "\"\($0.0)\":\($0.1)" }
        return "{\(pairs.joined(separator: ","))}"
    }
}

private func jsonArray(_ items: [String]) -> String {
    "[\(items.joined(separator: ","))]"
}

// MARK: - Type serializers

private func colorJson(_ c: Color) -> String {
    let o = JsonObj()
    switch c {
    case .rgb(let r, let g, let b, let a):
        o.num("a", a)
        o.num("b", b)
        o.num("g", g)
        o.num("r", r)
        o.str("space", "rgb")
    case .hsb(let h, let s, let b, let a):
        o.num("a", a)
        o.num("b", b)
        o.num("h", h)
        o.num("s", s)
        o.str("space", "hsb")
    case .cmyk(let c, let m, let y, let k, let a):
        o.num("a", a)
        o.num("c", c)
        o.num("k", k)
        o.num("m", m)
        o.str("space", "cmyk")
        o.num("y", y)
    }
    return o.build()
}

private func fillJson(_ fill: Fill?) -> String {
    guard let f = fill else { return "null" }
    let o = JsonObj()
    o.raw("color", colorJson(f.color))
    o.num("opacity", f.opacity)
    return o.build()
}

private func strokeJson(_ stroke: Stroke?) -> String {
    guard let s = stroke else { return "null" }
    let o = JsonObj()
    o.raw("color", colorJson(s.color))
    o.str("linecap", linecapStr(s.linecap))
    o.str("linejoin", linejoinStr(s.linejoin))
    o.num("opacity", s.opacity)
    o.num("width", s.width)
    return o.build()
}

private func linecapStr(_ lc: LineCap) -> String {
    switch lc {
    case .butt: "butt"
    case .round: "round"
    case .square: "square"
    }
}

private func linejoinStr(_ lj: LineJoin) -> String {
    switch lj {
    case .miter: "miter"
    case .round: "round"
    case .bevel: "bevel"
    }
}

private func transformJson(_ t: Transform?) -> String {
    guard let t = t else { return "null" }
    let o = JsonObj()
    o.num("a", t.a)
    o.num("b", t.b)
    o.num("c", t.c)
    o.num("d", t.d)
    o.num("e", t.e)
    o.num("f", t.f)
    return o.build()
}

private func visibilityStr(_ v: Visibility) -> String {
    switch v {
    case .invisible: "invisible"
    case .outline: "outline"
    case .preview: "preview"
    }
}

private func commonFields(_ o: JsonObj, _ opacity: Double, _ transform: Transform?,
                           _ locked: Bool, _ visibility: Visibility,
                           _ name: String? = nil, _ id: String? = nil) {
    o.bool("locked", locked)
    // User-visible name. Layer uses commonFieldsNoName since Layer.name
    // is its own required field (predates common.name).
    if let n = name, !n.isEmpty {
        o.str("name", n)
    } else {
        o.null("name")
    }
    // Stable id is additive: emit only when set, so id-less elements
    // serialize byte-identically to before (keys are sorted on output).
    if let id = id, !id.isEmpty {
        o.str("id", id)
    }
    o.num("opacity", opacity)
    o.raw("transform", transformJson(transform))
    o.str("visibility", visibilityStr(visibility))
}

/// commonFields variant that omits the optional name (Layer emits
/// its own required name field separately).
private func commonFieldsNoName(_ o: JsonObj, _ opacity: Double, _ transform: Transform?,
                                  _ locked: Bool, _ visibility: Visibility) {
    o.bool("locked", locked)
    o.num("opacity", opacity)
    o.raw("transform", transformJson(transform))
    o.str("visibility", visibilityStr(visibility))
}

private func pathCommandJson(_ cmd: PathCommand) -> String {
    let o = JsonObj()
    switch cmd {
    case .moveTo(let x, let y):
        o.str("cmd", "M")
        o.num("x", x)
        o.num("y", y)
    case .lineTo(let x, let y):
        o.str("cmd", "L")
        o.num("x", x)
        o.num("y", y)
    case .curveTo(let x1, let y1, let x2, let y2, let x, let y):
        o.str("cmd", "C")
        o.num("x", x)
        o.num("x1", x1)
        o.num("x2", x2)
        o.num("y", y)
        o.num("y1", y1)
        o.num("y2", y2)
    case .smoothCurveTo(let x2, let y2, let x, let y):
        o.str("cmd", "S")
        o.num("x", x)
        o.num("x2", x2)
        o.num("y", y)
        o.num("y2", y2)
    case .quadTo(let x1, let y1, let x, let y):
        o.str("cmd", "Q")
        o.num("x", x)
        o.num("x1", x1)
        o.num("y", y)
        o.num("y1", y1)
    case .smoothQuadTo(let x, let y):
        o.str("cmd", "T")
        o.num("x", x)
        o.num("y", y)
    case .arcTo(let rx, let ry, let rotation, let largeArc, let sweep, let x, let y):
        o.str("cmd", "A")
        o.bool("large_arc", largeArc)
        o.num("rx", rx)
        o.num("ry", ry)
        o.bool("sweep", sweep)
        o.num("x", x)
        o.num("x_rotation", rotation)
        o.num("y", y)
    case .closePath:
        o.str("cmd", "Z")
    }
    return o.build()
}

private func pointsJson(_ points: [(Double, Double)]) -> String {
    let items = points.map { "[\(fmt($0.0)),\(fmt($0.1))]" }
    return jsonArray(items)
}

// MARK: - Element serializer

/// Canonical JSON for the `text_decoration` element-wide field.
/// Stored as a String (space-separated tokens); emitted as a
/// sorted array for byte-stable output. `"none"` and empty both
/// serialize to `[]`.
private func textDecorationJson(_ td: String) -> String {
    var tokens = td.split(separator: " ", omittingEmptySubsequences: true)
                   .map { String($0) }
                   .filter { $0 != "none" }
    tokens.sort()
    let quoted = tokens.map { "\"\($0)\"" }
    return "[\(quoted.joined(separator: ","))]"
}

/// Canonical JSON for a single tspan. Mirrors the Rust emitter:
/// every override field is serialized as a sorted key with null
/// for inherit or the concrete value for an explicit override.
private func tspanJson(_ t: Tspan) -> String {
    let o = JsonObj()
    o.optNum("baseline_shift", t.baselineShift)
    o.str("content", t.content)
    o.optNum("dx", t.dx)
    o.optStr("font_family", t.fontFamily)
    o.optNum("font_size", t.fontSize)
    o.optStr("font_style", t.fontStyle)
    o.optStr("font_variant", t.fontVariant)
    o.optStr("font_weight", t.fontWeight)
    o.int("id", Int(t.id))
    o.optStr("jas_aa_mode", t.jasAaMode)
    o.optBool("jas_fractional_widths", t.jasFractionalWidths)
    o.optStr("jas_kerning_mode", t.jasKerningMode)
    o.optBool("jas_no_break", t.jasNoBreak)
    // jas_role intentionally omitted from cross-language test JSON
    // until the shared fixtures gain the field. Reader at parseTspan
    // tolerates absent jas_role and defaults to nil.
    o.optNum("letter_spacing", t.letterSpacing)
    o.optNum("line_height", t.lineHeight)
    o.optNum("rotate", t.rotate)
    o.optStr("style_name", t.styleName)
    if let decor = t.textDecoration {
        var sorted = decor
        sorted.sort()
        let quoted = sorted.map { "\"\($0)\"" }
        o.raw("text_decoration", "[\(quoted.joined(separator: ","))]")
    } else {
        o.null("text_decoration")
    }
    o.optStr("text_rendering", t.textRendering)
    o.optStr("text_transform", t.textTransform)
    o.raw("transform", transformJson(t.transform))
    o.optStr("xml_lang", t.xmlLang)
    return o.build()
}

package func elementJson(_ elem: Element) -> String {
    let o = JsonObj()
    switch elem {
    case .line(let e):
        o.str("type", "line")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility, e.name, e.id)
        o.raw("stroke", strokeJson(e.stroke))
        o.num("x1", e.x1)
        o.num("x2", e.x2)
        o.num("y1", e.y1)
        o.num("y2", e.y2)
    case .rect(let e):
        o.str("type", "rect")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility, e.name, e.id)
        o.raw("fill", fillJson(e.fill))
        o.num("height", e.height)
        o.num("rx", e.rx)
        o.num("ry", e.ry)
        o.raw("stroke", strokeJson(e.stroke))
        o.num("width", e.width)
        o.num("x", e.x)
        o.num("y", e.y)
    case .circle(let e):
        o.str("type", "circle")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility, e.name, e.id)
        o.num("cx", e.cx)
        o.num("cy", e.cy)
        o.raw("fill", fillJson(e.fill))
        o.num("r", e.r)
        o.raw("stroke", strokeJson(e.stroke))
    case .ellipse(let e):
        o.str("type", "ellipse")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility, e.name, e.id)
        o.num("cx", e.cx)
        o.num("cy", e.cy)
        o.raw("fill", fillJson(e.fill))
        o.num("rx", e.rx)
        o.num("ry", e.ry)
        o.raw("stroke", strokeJson(e.stroke))
    case .polyline(let e):
        o.str("type", "polyline")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility, e.name, e.id)
        o.raw("fill", fillJson(e.fill))
        o.raw("points", pointsJson(e.points))
        o.raw("stroke", strokeJson(e.stroke))
    case .polygon(let e):
        o.str("type", "polygon")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility, e.name, e.id)
        o.raw("fill", fillJson(e.fill))
        o.raw("points", pointsJson(e.points))
        o.raw("stroke", strokeJson(e.stroke))
    case .path(let e):
        o.str("type", "path")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility, e.name, e.id)
        let cmds = e.d.map { pathCommandJson($0) }
        o.raw("d", jsonArray(cmds))
        o.raw("fill", fillJson(e.fill))
        o.raw("stroke", strokeJson(e.stroke))
    case .text(let e):
        o.str("type", "text")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility, e.name, e.id)
        // Extended element-wide attribute slots. Still-null slots are
        // placeholders until Text grows per-element override fields
        // (see TSPAN.md Attribute Home).
        o.emptyAsNull("baseline_shift", e.baselineShift)
        o.null("dx")
        o.raw("fill", fillJson(e.fill))
        o.str("font_family", e.fontFamily)
        o.num("font_size", e.fontSize)
        o.str("font_style", e.fontStyle)
        o.emptyAsNull("font_variant", e.fontVariant)
        o.str("font_weight", e.fontWeight)
        o.num("height", e.height)
        o.emptyAsNull("horizontal_scale", e.horizontalScale)
        o.emptyAsNull("jas_aa_mode", e.aaMode)
        o.null("jas_fractional_widths")
        o.emptyAsNull("jas_kerning_mode", e.kerning)
        o.null("jas_no_break")
        o.emptyAsNull("letter_spacing", e.letterSpacing)
        o.emptyAsNull("line_height", e.lineHeight)
        o.emptyAsNull("rotate", e.rotate)
        o.raw("stroke", strokeJson(e.stroke))
        o.null("style_name")
        o.raw("text_decoration", textDecorationJson(e.textDecoration))
        o.null("text_rendering")
        o.emptyAsNull("text_transform", e.textTransform)
        // Per-tspan list (always non-empty).
        let tspans = e.tspans.map { tspanJson($0) }
        o.raw("tspans", jsonArray(tspans))
        o.emptyAsNull("vertical_scale", e.verticalScale)
        o.num("width", e.width)
        o.num("x", e.x)
        o.emptyAsNull("xml_lang", e.xmlLang)
        o.num("y", e.y)
    case .textPath(let e):
        o.str("type", "text_path")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility, e.name, e.id)
        o.emptyAsNull("baseline_shift", e.baselineShift)
        let cmds = e.d.map { pathCommandJson($0) }
        o.raw("d", jsonArray(cmds))
        o.null("dx")
        o.raw("fill", fillJson(e.fill))
        o.str("font_family", e.fontFamily)
        o.num("font_size", e.fontSize)
        o.str("font_style", e.fontStyle)
        o.emptyAsNull("font_variant", e.fontVariant)
        o.str("font_weight", e.fontWeight)
        o.emptyAsNull("horizontal_scale", e.horizontalScale)
        o.emptyAsNull("jas_aa_mode", e.aaMode)
        o.null("jas_fractional_widths")
        o.emptyAsNull("jas_kerning_mode", e.kerning)
        o.null("jas_no_break")
        o.emptyAsNull("letter_spacing", e.letterSpacing)
        o.emptyAsNull("line_height", e.lineHeight)
        o.emptyAsNull("rotate", e.rotate)
        o.num("start_offset", e.startOffset)
        o.raw("stroke", strokeJson(e.stroke))
        o.null("style_name")
        o.raw("text_decoration", textDecorationJson(e.textDecoration))
        o.null("text_rendering")
        o.emptyAsNull("text_transform", e.textTransform)
        let tspans = e.tspans.map { tspanJson($0) }
        o.raw("tspans", jsonArray(tspans))
        o.emptyAsNull("vertical_scale", e.verticalScale)
        o.emptyAsNull("xml_lang", e.xmlLang)
    case .group(let e):
        o.str("type", "group")
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility, e.name, e.id)
        let children = e.children.map { elementJson($0) }
        o.raw("children", jsonArray(children))
    case .layer(let e):
        o.str("type", "layer")
        // After Layer.name → common-name merge, Layer uses the same
        // nullable name path as every other element.
        commonFields(o, e.opacity, e.transform, e.locked, e.visibility, e.name, e.id)
        let children = e.children.map { elementJson($0) }
        o.raw("children", jsonArray(children))
    case .live(let v):
        o.str("type", "live")
        o.str("kind", v.kind)
        switch v {
        case .compoundShape(let cs):
            // `operation` was previously omitted (a round-trip bug, since
            // the reader had no live arm at all and trapped); now emitted
            // so compound shapes round-trip through test_json.
            o.str("operation", cs.operation.rawValue)
            // CompoundShape carries a stable id but no name field, so emit
            // id (only when set) while name stays nil — matching the
            // reference writer and Rust's common_attrs_no_name.
            commonFields(o, cs.opacity, cs.transform, cs.locked, cs.visibility, nil, cs.id)
            let children = cs.operands.map { elementJson($0) }
            o.raw("children", jsonArray(children))
        case .reference(let r):
            o.str("target", r.target.id)
            commonFields(o, r.opacity, r.transform, r.locked, r.visibility, nil, r.id)
            // fill/stroke are emitted only when set; in Phase 1 references
            // carry none (paint inheritance default / Fork F2), matching how
            // compound omits its own paint here. (The render CTM `transform` is
            // emitted as null by commonFields, matching the fixtures.)
            //
            // Symbols P4 (SYMBOLS.md §4 / Fork F2): the instance `transform`
            // field (distinct from the render CTM, which `commonFields` emits as
            // the `transform` key) is emitted as a separate `instance_transform`
            // key, and ONLY when set — omitting it when nil keeps existing
            // reference fixtures byte-identical.
            if let it = r.instanceTransform {
                o.raw("instance_transform", transformJson(it))
            }
        case .recorded(let rec):
            // RECORDED_ELEMENTS.md §8: a recorded element serializes its
            // common props (id only when set, name nil), plus the input ids
            // and the normalized recipe ops, canonicalized so the recorded
            // element serializes byte-identically across apps.
            commonFields(o, rec.opacity, rec.transform, rec.locked, rec.visibility, nil, rec.id)
            let inputs = rec.inputs.map { "\"\($0.id)\"" }
            o.raw("inputs", jsonArray(inputs))
            let ops = rec.ops.map { canonicalRecordedOp($0) }
            o.raw("ops", jsonArray(ops))
        case .generated(let gen):
            // CONCEPTS.md §6: a generated element serializes its common props,
            // the concept id, and the parameter values, canonicalized so it
            // serializes byte-identically across apps.
            commonFields(o, gen.opacity, gen.transform, gen.locked, gen.visibility, nil, gen.id)
            o.str("concept", gen.conceptId)
            o.raw("params", canonicalRecordedValue(gen.params))
        }
    }
    return o.build()
}

// MARK: - Selection serializer

private func selectionJson(_ sel: [ElementSelection]) -> String {
    var entries: [(path: [Int], json: String)] = sel.map { es in
        let o = JsonObj()
        switch es.kind {
        case .all:
            o.str("kind", "all")
        case .partial(let cps):
            let indices = cps.toArray().map { "\($0)" }
            o.raw("kind", "{\"partial\":[\(indices.joined(separator: ","))]}")
        }
        let path = es.path.map { "\($0)" }
        o.raw("path", "[\(path.joined(separator: ","))]")
        return (es.path, o.build())
    }
    // Sort by path lexicographically.
    entries.sort { a, b in
        for (ai, bi) in zip(a.path, b.path) {
            if ai != bi { return ai < bi }
        }
        return a.path.count < b.path.count
    }
    let items = entries.map { $0.json }
    return jsonArray(items)
}

// MARK: - Document serializer (public API)

// MARK: - Artboard serialization (ARTBOARDS.md cross-app contract, ART-441)

private func artboardJson(_ ab: Artboard) -> String {
    let o = JsonObj()
    o.str("id", ab.id)
    o.str("name", ab.name)
    o.num("x", ab.x)
    o.num("y", ab.y)
    o.num("width", ab.width)
    o.num("height", ab.height)
    o.str("fill", ab.fill.asCanonical)
    o.bool("show_center_mark", ab.showCenterMark)
    o.bool("show_cross_hairs", ab.showCrossHairs)
    o.bool("show_video_safe_areas", ab.showVideoSafeAreas)
    o.num("video_ruler_pixel_aspect_ratio", ab.videoRulerPixelAspectRatio)
    return o.build()
}

private func artboardsJson(_ artboards: [Artboard]) -> String {
    jsonArray(artboards.map(artboardJson))
}

private func artboardOptionsJson(_ opts: ArtboardOptions) -> String {
    let o = JsonObj()
    o.bool("fade_region_outside_artboard", opts.fadeRegionOutsideArtboard)
    o.bool("update_while_dragging", opts.updateWhileDragging)
    return o.build()
}

private func documentSetupJson(_ s: DocumentSetup) -> String {
    let o = JsonObj()
    o.num("bleed_bottom", s.bleedBottom)
    o.num("bleed_left", s.bleedLeft)
    o.num("bleed_right", s.bleedRight)
    o.num("bleed_top", s.bleedTop)
    o.bool("bleed_uniform", s.bleedUniform)
    o.bool("discard_white_overprint", s.discardWhiteOverprint)
    o.str("grid_color", s.gridColor)
    o.num("grid_size", s.gridSize)
    o.bool("highlight_substituted_glyphs", s.highlightSubstitutedGlyphs)
    o.str("paper_color", s.paperColor)
    o.bool("show_images_outline", s.showImagesOutline)
    o.bool("simulate_colored_paper", s.simulateColoredPaper)
    o.str("transparency_flattener_preset", s.transparencyFlattenerPreset.rawValue)
    return o.build()
}

private func advancedJson(_ a: Advanced) -> String {
    let o = JsonObj()
    o.str("overprint_flattener_preset", a.overprintFlattenerPreset.rawValue)
    o.bool("print_as_bitmap", a.printAsBitmap)
    return o.build()
}

private func colorManagementJson(_ c: ColorManagement) -> String {
    let o = JsonObj()
    o.str("color_handling", c.colorHandling.rawValue)
    o.str("document_profile", c.documentProfile)
    o.bool("preserve_rgb_numbers", c.preserveRgbNumbers)
    o.str("printer_profile", c.printerProfile)
    o.str("rendering_intent", c.renderingIntent.rawValue)
    return o.build()
}

private func graphicsJson(_ g: Graphics) -> String {
    let o = JsonObj()
    o.bool("compatible_gradient_printing", g.compatibleGradientPrinting)
    o.str("data_format", g.dataFormat.rawValue)
    o.num("flatness", g.flatness)
    o.str("font_download", g.fontDownload.rawValue)
    o.str("postscript_level", g.postscriptLevel.rawValue)
    o.num("raster_effects_resolution", g.rasterEffectsResolution)
    return o.build()
}

private func inkOverrideJson(_ ink: InkOverride) -> String {
    let o = JsonObj()
    o.num("angle", ink.angle)
    o.str("dot_shape", ink.dotShape.rawValue)
    o.num("frequency", ink.frequency)
    o.str("name", ink.name)
    o.bool("print", ink.print)
    return o.build()
}

private func inksJson(_ inks: [InkOverride]) -> String {
    let items = inks.map(inkOverrideJson)
    return jsonArray(items)
}

private func outputJson(_ out: Output) -> String {
    let o = JsonObj()
    o.bool("convert_spot_to_process", out.convertSpotToProcess)
    o.str("emulsion", out.emulsion.rawValue)
    o.str("image_polarity", out.imagePolarity.rawValue)
    o.raw("inks", inksJson(out.inks))
    o.str("mode", out.mode.rawValue)
    o.bool("overprint_black", out.overprintBlack)
    o.str("printer_resolution", out.printerResolution)
    return o.build()
}

private func marksAndBleedJson(_ m: MarksAndBleed) -> String {
    let o = JsonObj()
    o.bool("all_printer_marks", m.allPrinterMarks)
    o.num("bleed_bottom", m.bleedBottom)
    o.num("bleed_left", m.bleedLeft)
    o.num("bleed_right", m.bleedRight)
    o.num("bleed_top", m.bleedTop)
    o.bool("color_bars", m.colorBars)
    o.num("mark_offset", m.markOffset)
    o.bool("page_information", m.pageInformation)
    o.str("printer_mark_type", m.printerMarkType.rawValue)
    o.bool("registration_marks", m.registrationMarks)
    o.num("trim_mark_weight", m.trimMarkWeight)
    o.bool("trim_marks", m.trimMarks)
    o.bool("use_document_bleed", m.useDocumentBleed)
    return o.build()
}

private func printPreferencesJson(_ p: PrintPreferences) -> String {
    let o = JsonObj()
    o.raw("advanced", advancedJson(p.advanced))
    o.str("artboard_range", p.artboardRange)
    o.str("artboard_range_mode", p.artboardRangeMode.rawValue)
    o.bool("auto_rotate", p.autoRotate)
    o.bool("collate", p.collate)
    o.raw("color_management", colorManagementJson(p.colorManagement))
    o.int("copies", p.copies)
    o.num("custom_scale", p.customScale)
    o.raw("graphics", graphicsJson(p.graphics))
    o.bool("ignore_artboards", p.ignoreArtboards)
    o.raw("marks_and_bleed", marksAndBleedJson(p.marksAndBleed))
    o.num("media_height", p.mediaHeight)
    o.str("media_size", p.mediaSize.rawValue)
    o.num("media_width", p.mediaWidth)
    o.str("orientation", p.orientation.rawValue)
    o.raw("output", outputJson(p.output))
    o.num("placement_x", p.placementX)
    o.num("placement_y", p.placementY)
    o.str("preset_name", p.presetName)
    o.str("print_layers", p.printLayers.rawValue)
    if let pn = p.printerName {
        o.str("printer_name", pn)
    } else {
        o.raw("printer_name", "null")
    }
    o.bool("reverse_order", p.reverseOrder)
    o.str("scaling_mode", p.scalingMode.rawValue)
    o.bool("skip_blank_artboards", p.skipBlankArtboards)
    o.num("tile_overlap_h", p.tileOverlapH)
    o.num("tile_overlap_v", p.tileOverlapV)
    o.str("tile_range", p.tileRange)
    o.bool("transverse", p.transverse)
    return o.build()
}

/// Serialize a Document to canonical test JSON.
///
/// The output is a compact JSON string with sorted keys and normalized
/// floats, suitable for byte-for-byte cross-language comparison.
///
/// Artboards and artboard_options are **omitted** from the output when
/// they carry their defaults (empty list, default options) so the
/// byte-for-byte contract with legacy Python fixtures (which predate
/// the artboards feature) still holds. Native docs authored with
/// artboards or non-default options serialize them explicitly.
package func documentToTestJson(_ doc: Document) -> String {
    let layers = doc.layers.map { elementJson(.layer($0)) }
    let o = JsonObj()
    if doc.artboardOptions != .default {
        o.raw("artboard_options", artboardOptionsJson(doc.artboardOptions))
    }
    if !doc.artboards.isEmpty {
        o.raw("artboards", artboardsJson(doc.artboards))
    }
    if doc.documentSetup != .default {
        o.raw("document_setup", documentSetupJson(doc.documentSetup))
    }
    o.raw("layers", jsonArray(layers))
    if doc.printPreferences != .default {
        o.raw("print_preferences", printPreferencesJson(doc.printPreferences))
    }
    o.int("selected_layer", doc.selectedLayer)
    o.raw("selection", selectionJson(Array(doc.selection)))
    // Symbols (master store, SYMBOLS.md §5): emit only when non-empty so
    // existing fixtures stay byte-identical, mirroring print_preferences /
    // artboards. Masters are sorted by id (the §2 deterministic-order rule);
    // an id-less master sorts as the empty string.
    if !doc.symbols.isEmpty {
        o.raw("symbols", symbolsJson(doc.symbols))
    }
    return o.build()
}

/// Serialize the master store as a sorted-by-id JSON array of element JSON.
/// Sorting is on `id` (id-less masters sort as the empty string) so the output
/// is deterministic regardless of storage order (SYMBOLS.md §2).
private func symbolsJson(_ symbols: [Element]) -> String {
    let sorted = symbols.sorted { ($0.id ?? "") < ($1.id ?? "") }
    return jsonArray(sorted.map { elementJson($0) })
}

// MARK: - JSON → Document parser (inverse of documentToTestJson)

private func parseF(_ v: Any?) -> Double {
    if let n = v as? NSNumber { return n.doubleValue }
    return 0.0
}

private func parseColor(_ v: Any?) -> Color {
    guard let d = v as? [String: Any] else { return Color(r: 0, g: 0, b: 0, a: 1) }
    let space = d["space"] as? String ?? "rgb"
    switch space {
    case "hsb":
        return .hsb(h: parseF(d["h"]), s: parseF(d["s"]), b: parseF(d["b"]), a: parseF(d["a"]))
    case "cmyk":
        return .cmyk(c: parseF(d["c"]), m: parseF(d["m"]), y: parseF(d["y"]), k: parseF(d["k"]), a: parseF(d["a"]))
    default:
        return Color(r: parseF(d["r"]), g: parseF(d["g"]), b: parseF(d["b"]), a: parseF(d["a"]))
    }
}

private func parseFill(_ v: Any?) -> Fill? {
    guard let d = v as? [String: Any] else { return nil }
    let opacity = (d["opacity"] as? Double) ?? 1.0
    return Fill(color: parseColor(d["color"]), opacity: opacity)
}

private func parseStroke(_ v: Any?) -> Stroke? {
    guard let d = v as? [String: Any] else { return nil }
    let lc: LineCap
    switch d["linecap"] as? String ?? "butt" {
    case "round": lc = .round
    case "square": lc = .square
    default: lc = .butt
    }
    let lj: LineJoin
    switch d["linejoin"] as? String ?? "miter" {
    case "round": lj = .round
    case "bevel": lj = .bevel
    default: lj = .miter
    }
    let opacity = (d["opacity"] as? Double) ?? 1.0
    return Stroke(color: parseColor(d["color"]), width: parseF(d["width"]), linecap: lc, linejoin: lj, opacity: opacity)
}

private func parseTransform(_ v: Any?) -> Transform? {
    guard let d = v as? [String: Any] else { return nil }
    return Transform(a: parseF(d["a"]), b: parseF(d["b"]), c: parseF(d["c"]),
                     d: parseF(d["d"]), e: parseF(d["e"]), f: parseF(d["f"]))
}

private func parseVisibility(_ v: Any?) -> Visibility {
    switch v as? String ?? "preview" {
    case "invisible": return .invisible
    case "outline": return .outline
    default: return .preview
    }
}

private func parseCommon(_ d: [String: Any]) -> (Double, Transform?, Bool, Visibility, String?, String?) {
    (parseF(d["opacity"]),
     parseTransform(d["transform"]),
     d["locked"] as? Bool ?? false,
     parseVisibility(d["visibility"]),
     d["name"] as? String,
     d["id"] as? String)
}

private func parsePathCommands(_ v: Any?) -> [PathCommand] {
    guard let arr = v as? [[String: Any]] else { return [] }
    return arr.map { c in
        switch c["cmd"] as? String ?? "" {
        case "M": return .moveTo(parseF(c["x"]), parseF(c["y"]))
        case "L": return .lineTo(parseF(c["x"]), parseF(c["y"]))
        case "C": return .curveTo(x1: parseF(c["x1"]), y1: parseF(c["y1"]),
                                  x2: parseF(c["x2"]), y2: parseF(c["y2"]),
                                  x: parseF(c["x"]), y: parseF(c["y"]))
        case "S": return .smoothCurveTo(x2: parseF(c["x2"]), y2: parseF(c["y2"]),
                                        x: parseF(c["x"]), y: parseF(c["y"]))
        case "Q": return .quadTo(x1: parseF(c["x1"]), y1: parseF(c["y1"]),
                                 x: parseF(c["x"]), y: parseF(c["y"]))
        case "T": return .smoothQuadTo(parseF(c["x"]), parseF(c["y"]))
        case "A": return .arcTo(rx: parseF(c["rx"]), ry: parseF(c["ry"]),
                                rotation: parseF(c["x_rotation"]),
                                largeArc: c["large_arc"] as? Bool ?? false,
                                sweep: c["sweep"] as? Bool ?? false,
                                x: parseF(c["x"]), y: parseF(c["y"]))
        default: return .closePath
        }
    }
}

private func parsePoints(_ v: Any?) -> [(Double, Double)] {
    guard let arr = v as? [[Any]] else { return [] }
    return arr.map { p in
        (parseF(p[0]), parseF(p[1]))
    }
}

/// Parse the canonical-JSON `tspans` array, or fall back to the
/// legacy `content: String` shape and wrap it in a single default
/// tspan. Keeps older fixtures readable during the migration.
private func parseTspansOrLegacy(_ d: [String: Any]) -> [Tspan] {
    if let arr = d["tspans"] as? [[String: Any]] {
        return arr.map { parseTspan($0) }
    }
    let content = d["content"] as? String ?? ""
    return [Tspan(id: 0, content: content)]
}

/// Parse a single tspan dict from canonical JSON.
private func parseTspan(_ d: [String: Any]) -> Tspan {
    let decor: [String]?
    if let arr = d["text_decoration"] as? [Any] {
        decor = arr.compactMap { $0 as? String }
    } else {
        decor = nil
    }
    return Tspan(
        id: UInt32((d["id"] as? NSNumber)?.intValue ?? 0),
        content: d["content"] as? String ?? "",
        baselineShift: (d["baseline_shift"] as? NSNumber)?.doubleValue,
        dx: (d["dx"] as? NSNumber)?.doubleValue,
        fontFamily: d["font_family"] as? String,
        fontSize: (d["font_size"] as? NSNumber)?.doubleValue,
        fontStyle: d["font_style"] as? String,
        fontVariant: d["font_variant"] as? String,
        fontWeight: d["font_weight"] as? String,
        jasAaMode: d["jas_aa_mode"] as? String,
        jasFractionalWidths: d["jas_fractional_widths"] as? Bool,
        jasKerningMode: d["jas_kerning_mode"] as? String,
        jasNoBreak: d["jas_no_break"] as? Bool,
        jasRole: d["jas_role"] as? String,
        jasLeftIndent: (d["jas_left_indent"] as? NSNumber)?.doubleValue,
        jasRightIndent: (d["jas_right_indent"] as? NSNumber)?.doubleValue,
        jasHyphenate: d["jas_hyphenate"] as? Bool,
        jasHangingPunctuation: d["jas_hanging_punctuation"] as? Bool,
        jasListStyle: d["jas_list_style"] as? String,
        textAlign: d["text_align"] as? String,
        textAlignLast: d["text_align_last"] as? String,
        textIndent: (d["text_indent"] as? NSNumber)?.doubleValue,
        jasSpaceBefore: (d["jas_space_before"] as? NSNumber)?.doubleValue,
        jasSpaceAfter: (d["jas_space_after"] as? NSNumber)?.doubleValue,
        jasWordSpacingMin: (d["jas_word_spacing_min"] as? NSNumber)?.doubleValue,
        jasWordSpacingDesired: (d["jas_word_spacing_desired"] as? NSNumber)?.doubleValue,
        jasWordSpacingMax: (d["jas_word_spacing_max"] as? NSNumber)?.doubleValue,
        jasLetterSpacingMin: (d["jas_letter_spacing_min"] as? NSNumber)?.doubleValue,
        jasLetterSpacingDesired: (d["jas_letter_spacing_desired"] as? NSNumber)?.doubleValue,
        jasLetterSpacingMax: (d["jas_letter_spacing_max"] as? NSNumber)?.doubleValue,
        jasGlyphScalingMin: (d["jas_glyph_scaling_min"] as? NSNumber)?.doubleValue,
        jasGlyphScalingDesired: (d["jas_glyph_scaling_desired"] as? NSNumber)?.doubleValue,
        jasGlyphScalingMax: (d["jas_glyph_scaling_max"] as? NSNumber)?.doubleValue,
        jasAutoLeading: (d["jas_auto_leading"] as? NSNumber)?.doubleValue,
        jasSingleWordJustify: d["jas_single_word_justify"] as? String,
        jasHyphenateMinWord: (d["jas_hyphenate_min_word"] as? NSNumber)?.doubleValue,
        jasHyphenateMinBefore: (d["jas_hyphenate_min_before"] as? NSNumber)?.doubleValue,
        jasHyphenateMinAfter: (d["jas_hyphenate_min_after"] as? NSNumber)?.doubleValue,
        jasHyphenateLimit: (d["jas_hyphenate_limit"] as? NSNumber)?.doubleValue,
        jasHyphenateZone: (d["jas_hyphenate_zone"] as? NSNumber)?.doubleValue,
        jasHyphenateBias: (d["jas_hyphenate_bias"] as? NSNumber)?.doubleValue,
        jasHyphenateCapitalized: d["jas_hyphenate_capitalized"] as? Bool,
        letterSpacing: (d["letter_spacing"] as? NSNumber)?.doubleValue,
        lineHeight: (d["line_height"] as? NSNumber)?.doubleValue,
        rotate: (d["rotate"] as? NSNumber)?.doubleValue,
        styleName: d["style_name"] as? String,
        textDecoration: decor,
        textRendering: d["text_rendering"] as? String,
        textTransform: d["text_transform"] as? String,
        transform: nil,
        xmlLang: d["xml_lang"] as? String
    )
}

/// Accept the canonical text_decoration form (sorted array) or the
/// legacy CSS string, normalising to the space-separated CSS form
/// Swift's `Text.textDecoration: String` field stores.
private func parseTextDecorationField(_ v: Any?) -> String {
    if let arr = v as? [String] {
        return arr.joined(separator: " ")
    }
    if let s = v as? String { return s }
    return "none"
}

/// Parse a single recipe op dict ({op, params, targets}) back into a
/// PrimitiveOp. `params` is kept verbatim as [String: Any] (the same shape the
/// harness builds and replay reads); `targets` is a string array.
private func parseRecordedOp(_ d: [String: Any]) -> PrimitiveOp {
    let op = d["op"] as? String ?? ""
    let params = d["params"] as? [String: Any] ?? [:]
    let targets = (d["targets"] as? [Any] ?? []).compactMap { $0 as? String }
    return PrimitiveOp(op: op, params: params, targets: targets)
}

package func parseElement(_ v: Any?) -> Element {
    guard let d = v as? [String: Any] else { fatalError("Expected JSON object for element") }
    let typ = d["type"] as? String ?? ""
    let (opacity, transform, locked, visibility, name, id) = parseCommon(d)

    switch typ {
    case "line":
        return .line(Line(x1: parseF(d["x1"]), y1: parseF(d["y1"]),
                          x2: parseF(d["x2"]), y2: parseF(d["y2"]),
                          stroke: parseStroke(d["stroke"]),
                          opacity: opacity, transform: transform, locked: locked,
                          visibility: visibility, name: name, id: id))
    case "rect":
        return .rect(Rect(x: parseF(d["x"]), y: parseF(d["y"]),
                          width: parseF(d["width"]), height: parseF(d["height"]),
                          rx: parseF(d["rx"]), ry: parseF(d["ry"]),
                          fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                          opacity: opacity, transform: transform, locked: locked,
                          visibility: visibility, name: name, id: id))
    case "circle":
        return .circle(Circle(cx: parseF(d["cx"]), cy: parseF(d["cy"]), r: parseF(d["r"]),
                              fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                              opacity: opacity, transform: transform, locked: locked,
                              visibility: visibility, name: name, id: id))
    case "ellipse":
        return .ellipse(Ellipse(cx: parseF(d["cx"]), cy: parseF(d["cy"]),
                                rx: parseF(d["rx"]), ry: parseF(d["ry"]),
                                fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                                opacity: opacity, transform: transform, locked: locked,
                                visibility: visibility, name: name, id: id))
    case "polyline":
        return .polyline(Polyline(points: parsePoints(d["points"]),
                                  fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                                  opacity: opacity, transform: transform, locked: locked,
                                  visibility: visibility, name: name, id: id))
    case "polygon":
        return .polygon(Polygon(points: parsePoints(d["points"]),
                                fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                                opacity: opacity, transform: transform, locked: locked,
                                visibility: visibility, name: name, id: id))
    case "path":
        return .path(Path(d: parsePathCommands(d["d"]),
                          fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                          opacity: opacity, transform: transform, locked: locked,
                          visibility: visibility, name: name, id: id))
    case "text":
        let tspans = parseTspansOrLegacy(d)
        return .text(Text(x: parseF(d["x"]), y: parseF(d["y"]),
                          tspans: tspans,
                          fontFamily: d["font_family"] as? String ?? "sans-serif",
                          fontSize: parseF(d["font_size"]),
                          fontWeight: d["font_weight"] as? String ?? "normal",
                          fontStyle: d["font_style"] as? String ?? "normal",
                          textDecoration: parseTextDecorationField(d["text_decoration"]),
                          textTransform: d["text_transform"] as? String ?? "",
                          fontVariant: d["font_variant"] as? String ?? "",
                          baselineShift: d["baseline_shift"] as? String ?? "",
                          lineHeight: d["line_height"] as? String ?? "",
                          letterSpacing: d["letter_spacing"] as? String ?? "",
                          xmlLang: d["xml_lang"] as? String ?? "",
                          aaMode: d["jas_aa_mode"] as? String ?? "",
                          rotate: d["rotate"] as? String ?? "",
                          horizontalScale: d["horizontal_scale"] as? String ?? "",
                          verticalScale: d["vertical_scale"] as? String ?? "",
                          kerning: d["jas_kerning_mode"] as? String ?? "",
                          width: parseF(d["width"]), height: parseF(d["height"]),
                          fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                          opacity: opacity, transform: transform, locked: locked,
                          visibility: visibility, name: name, id: id))
    case "text_path":
        let tspans = parseTspansOrLegacy(d)
        return .textPath(TextPath(d: parsePathCommands(d["d"]),
                                  tspans: tspans,
                                  startOffset: parseF(d["start_offset"]),
                                  fontFamily: d["font_family"] as? String ?? "sans-serif",
                                  fontSize: parseF(d["font_size"]),
                                  fontWeight: d["font_weight"] as? String ?? "normal",
                                  fontStyle: d["font_style"] as? String ?? "normal",
                                  textDecoration: parseTextDecorationField(d["text_decoration"]),
                                  textTransform: d["text_transform"] as? String ?? "",
                                  fontVariant: d["font_variant"] as? String ?? "",
                                  baselineShift: d["baseline_shift"] as? String ?? "",
                                  lineHeight: d["line_height"] as? String ?? "",
                                  letterSpacing: d["letter_spacing"] as? String ?? "",
                                  xmlLang: d["xml_lang"] as? String ?? "",
                                  aaMode: d["jas_aa_mode"] as? String ?? "",
                                  rotate: d["rotate"] as? String ?? "",
                                  horizontalScale: d["horizontal_scale"] as? String ?? "",
                                  verticalScale: d["vertical_scale"] as? String ?? "",
                                  kerning: d["jas_kerning_mode"] as? String ?? "",
                                  fill: parseFill(d["fill"]), stroke: parseStroke(d["stroke"]),
                                  opacity: opacity, transform: transform, locked: locked,
                                  visibility: visibility, name: name, id: id))
    case "group":
        let children = (d["children"] as? [Any] ?? []).map { parseElement($0) }
        return .group(Group(children: children, opacity: opacity, transform: transform,
                            locked: locked, visibility: visibility, name: name, id: id))
    case "layer":
        let children = (d["children"] as? [Any] ?? []).map { parseElement($0) }
        // After Layer.name → common-name merge, Layer reads its name from
        // the same `name` JSON field as every other element (parsed into
        // the local `name` binding by parseCommon).
        return .layer(Layer(name: name, children: children, opacity: opacity, transform: transform,
                            locked: locked, visibility: visibility, id: id))
    case "live":
        let kind = d["kind"] as? String ?? ""
        switch kind {
        case "compound_shape":
            let operation = CompoundOperation(rawValue: d["operation"] as? String ?? "union") ?? .union
            let operands = (d["children"] as? [Any] ?? []).map { parseElement($0) }
            return .live(.compoundShape(CompoundShape(
                operation: operation, operands: operands, id: id,
                opacity: opacity, transform: transform,
                locked: locked, visibility: visibility)))
        case "reference":
            let target = ElementRef(d["target"] as? String ?? "")
            // Symbols P4: the instance `transform` field rides the
            // `instance_transform` key (absent ⇒ nil / null ⇒ nil).
            return .live(.reference(ReferenceElem(
                target: target,
                id: id,
                transform: transform,
                instanceTransform: parseTransform(d["instance_transform"]),
                opacity: opacity, locked: locked, visibility: visibility)))
        case "recorded":
            // RECORDED_ELEMENTS.md §8: read the input ids and the recipe ops
            // back into a RecordedElem. The recipe ops parse {op, params,
            // targets}; params is held as [String: Any] (the same shape the
            // harness builds), routed straight back into evaluate / replay.
            let inputs = (d["inputs"] as? [Any] ?? [])
                .compactMap { $0 as? String }
                .map { ElementRef($0) }
            let ops = (d["ops"] as? [[String: Any]] ?? []).map { parseRecordedOp($0) }
            return .live(.recorded(RecordedElem(
                ops: ops, inputs: inputs, id: id,
                transform: transform, opacity: opacity,
                locked: locked, visibility: visibility)))
        case "generated":
            // CONCEPTS.md §6: read the concept id + parameter values back into
            // a GeneratedElem.
            let conceptId = d["concept"] as? String ?? ""
            let params = d["params"] as? [String: Any] ?? [:]
            return .live(.generated(GeneratedElem(
                conceptId: conceptId, params: params, id: id,
                transform: transform, opacity: opacity,
                locked: locked, visibility: visibility)))
        default:
            fatalError("Unknown live kind: \(kind)")
        }
    default:
        fatalError("Unknown element type: \(typ)")
    }
}

private func parseSelection(_ v: Any?) -> Selection {
    guard let arr = v as? [[String: Any]] else { return [] }
    var sel: Selection = []
    for es in arr {
        let path = (es["path"] as? [Any] ?? []).map { ($0 as! NSNumber).intValue }
        let kind: SelectionKind
        if let s = es["kind"] as? String {
            kind = s == "all" ? .all : .all
        } else if let obj = es["kind"] as? [String: Any],
                  let partial = obj["partial"] as? [Any] {
            let cps = partial.map { ($0 as! NSNumber).intValue }
            kind = .partial(SortedCps(cps))
        } else {
            kind = .all
        }
        sel.insert(ElementSelection(path: path, kind: kind))
    }
    return sel
}

private func parseArtboard(_ v: [String: Any]) -> Artboard {
    let rawAspect = parseF(v["video_ruler_pixel_aspect_ratio"])
    return Artboard(
        id: (v["id"] as? String) ?? "",
        name: (v["name"] as? String) ?? "",
        x: parseF(v["x"]),
        y: parseF(v["y"]),
        width: parseF(v["width"]),
        height: parseF(v["height"]),
        fill: ArtboardFill.fromCanonical((v["fill"] as? String) ?? "transparent"),
        showCenterMark: (v["show_center_mark"] as? Bool) ?? false,
        showCrossHairs: (v["show_cross_hairs"] as? Bool) ?? false,
        showVideoSafeAreas: (v["show_video_safe_areas"] as? Bool) ?? false,
        videoRulerPixelAspectRatio: rawAspect == 0.0 ? 1.0 : rawAspect
    )
}

private func parseArtboards(_ v: Any?) -> [Artboard] {
    // Missing key → empty; load-time invariant repair happens at
    // the app layer, not here (matches Python / Rust contract).
    guard let arr = v as? [[String: Any]] else { return [] }
    return arr.map(parseArtboard)
}

private func parseArtboardOptions(_ v: Any?) -> ArtboardOptions {
    guard let d = v as? [String: Any] else { return .default }
    return ArtboardOptions(
        fadeRegionOutsideArtboard: (d["fade_region_outside_artboard"] as? Bool) ?? true,
        updateWhileDragging: (d["update_while_dragging"] as? Bool) ?? true
    )
}

private func parseDocumentSetup(_ v: Any?) -> DocumentSetup {
    guard let d = v as? [String: Any] else { return .default }
    let def = DocumentSetup.default
    return DocumentSetup(
        bleedTop: (d["bleed_top"] as? NSNumber)?.doubleValue ?? def.bleedTop,
        bleedRight: (d["bleed_right"] as? NSNumber)?.doubleValue ?? def.bleedRight,
        bleedBottom: (d["bleed_bottom"] as? NSNumber)?.doubleValue ?? def.bleedBottom,
        bleedLeft: (d["bleed_left"] as? NSNumber)?.doubleValue ?? def.bleedLeft,
        bleedUniform: (d["bleed_uniform"] as? Bool) ?? def.bleedUniform,
        showImagesOutline: (d["show_images_outline"] as? Bool) ?? def.showImagesOutline,
        highlightSubstitutedGlyphs: (d["highlight_substituted_glyphs"] as? Bool) ?? def.highlightSubstitutedGlyphs,
        gridSize: (d["grid_size"] as? NSNumber)?.doubleValue ?? def.gridSize,
        gridColor: (d["grid_color"] as? String) ?? def.gridColor,
        paperColor: (d["paper_color"] as? String) ?? def.paperColor,
        simulateColoredPaper: (d["simulate_colored_paper"] as? Bool) ?? def.simulateColoredPaper,
        transparencyFlattenerPreset: FlattenerPreset(rawValue: (d["transparency_flattener_preset"] as? String) ?? "") ?? def.transparencyFlattenerPreset,
        discardWhiteOverprint: (d["discard_white_overprint"] as? Bool) ?? def.discardWhiteOverprint
    )
}

private func parseAdvanced(_ v: Any?) -> Advanced {
    guard let d = v as? [String: Any] else { return .default }
    let def = Advanced.default
    return Advanced(
        printAsBitmap: (d["print_as_bitmap"] as? Bool) ?? def.printAsBitmap,
        overprintFlattenerPreset: FlattenerPreset(rawValue: (d["overprint_flattener_preset"] as? String) ?? "") ?? def.overprintFlattenerPreset
    )
}

private func parseColorManagement(_ v: Any?) -> ColorManagement {
    guard let d = v as? [String: Any] else { return .default }
    let def = ColorManagement.default
    return ColorManagement(
        documentProfile: (d["document_profile"] as? String) ?? def.documentProfile,
        colorHandling: ColorHandling(rawValue: (d["color_handling"] as? String) ?? "") ?? def.colorHandling,
        printerProfile: (d["printer_profile"] as? String) ?? def.printerProfile,
        renderingIntent: RenderingIntent(rawValue: (d["rendering_intent"] as? String) ?? "") ?? def.renderingIntent,
        preserveRgbNumbers: (d["preserve_rgb_numbers"] as? Bool) ?? def.preserveRgbNumbers
    )
}

private func parseGraphics(_ v: Any?) -> Graphics {
    guard let d = v as? [String: Any] else { return .default }
    let def = Graphics.default
    return Graphics(
        flatness: (d["flatness"] as? NSNumber)?.doubleValue ?? def.flatness,
        fontDownload: FontDownload(rawValue: (d["font_download"] as? String) ?? "") ?? def.fontDownload,
        postscriptLevel: PostScriptLevel(rawValue: (d["postscript_level"] as? String) ?? "") ?? def.postscriptLevel,
        dataFormat: DataFormat(rawValue: (d["data_format"] as? String) ?? "") ?? def.dataFormat,
        compatibleGradientPrinting: (d["compatible_gradient_printing"] as? Bool) ?? def.compatibleGradientPrinting,
        rasterEffectsResolution: (d["raster_effects_resolution"] as? NSNumber)?.doubleValue ?? def.rasterEffectsResolution
    )
}

private func parseInkOverride(_ v: Any?) -> InkOverride {
    guard let d = v as? [String: Any] else {
        return InkOverride(name: "")
    }
    return InkOverride(
        name: (d["name"] as? String) ?? "",
        print: (d["print"] as? Bool) ?? true,
        frequency: (d["frequency"] as? NSNumber)?.doubleValue ?? 75.0,
        angle: (d["angle"] as? NSNumber)?.doubleValue ?? 45.0,
        dotShape: DotShape(rawValue: (d["dot_shape"] as? String) ?? "") ?? .round
    )
}

private func parseOutput(_ v: Any?) -> Output {
    guard let d = v as? [String: Any] else { return .default }
    let def = Output.default
    let inks: [InkOverride] = {
        if let arr = d["inks"] as? [Any] {
            return arr.map { parseInkOverride($0) }
        }
        return def.inks
    }()
    return Output(
        mode: OutputMode(rawValue: (d["mode"] as? String) ?? "") ?? def.mode,
        emulsion: Emulsion(rawValue: (d["emulsion"] as? String) ?? "") ?? def.emulsion,
        imagePolarity: ImagePolarity(rawValue: (d["image_polarity"] as? String) ?? "") ?? def.imagePolarity,
        printerResolution: (d["printer_resolution"] as? String) ?? def.printerResolution,
        convertSpotToProcess: (d["convert_spot_to_process"] as? Bool) ?? def.convertSpotToProcess,
        overprintBlack: (d["overprint_black"] as? Bool) ?? def.overprintBlack,
        inks: inks
    )
}

private func parseMarksAndBleed(_ v: Any?) -> MarksAndBleed {
    guard let d = v as? [String: Any] else { return .default }
    let def = MarksAndBleed.default
    return MarksAndBleed(
        allPrinterMarks: (d["all_printer_marks"] as? Bool) ?? def.allPrinterMarks,
        trimMarks: (d["trim_marks"] as? Bool) ?? def.trimMarks,
        registrationMarks: (d["registration_marks"] as? Bool) ?? def.registrationMarks,
        colorBars: (d["color_bars"] as? Bool) ?? def.colorBars,
        pageInformation: (d["page_information"] as? Bool) ?? def.pageInformation,
        printerMarkType: PrinterMarkType(rawValue: (d["printer_mark_type"] as? String) ?? "") ?? def.printerMarkType,
        trimMarkWeight: (d["trim_mark_weight"] as? NSNumber)?.doubleValue ?? def.trimMarkWeight,
        markOffset: (d["mark_offset"] as? NSNumber)?.doubleValue ?? def.markOffset,
        useDocumentBleed: (d["use_document_bleed"] as? Bool) ?? def.useDocumentBleed,
        bleedTop: (d["bleed_top"] as? NSNumber)?.doubleValue ?? def.bleedTop,
        bleedRight: (d["bleed_right"] as? NSNumber)?.doubleValue ?? def.bleedRight,
        bleedBottom: (d["bleed_bottom"] as? NSNumber)?.doubleValue ?? def.bleedBottom,
        bleedLeft: (d["bleed_left"] as? NSNumber)?.doubleValue ?? def.bleedLeft
    )
}

private func parsePrintPreferences(_ v: Any?) -> PrintPreferences {
    guard let d = v as? [String: Any] else { return .default }
    let def = PrintPreferences.default
    let printer: String? = {
        if let s = d["printer_name"] as? String { return s }
        return nil
    }()
    return PrintPreferences(
        presetName: (d["preset_name"] as? String) ?? def.presetName,
        printerName: printer,
        copies: (d["copies"] as? NSNumber)?.intValue ?? def.copies,
        collate: (d["collate"] as? Bool) ?? def.collate,
        reverseOrder: (d["reverse_order"] as? Bool) ?? def.reverseOrder,
        artboardRangeMode: ArtboardRangeMode(rawValue: (d["artboard_range_mode"] as? String) ?? "") ?? def.artboardRangeMode,
        artboardRange: (d["artboard_range"] as? String) ?? def.artboardRange,
        ignoreArtboards: (d["ignore_artboards"] as? Bool) ?? def.ignoreArtboards,
        skipBlankArtboards: (d["skip_blank_artboards"] as? Bool) ?? def.skipBlankArtboards,
        mediaSize: MediaSize(rawValue: (d["media_size"] as? String) ?? "") ?? def.mediaSize,
        mediaWidth: (d["media_width"] as? NSNumber)?.doubleValue ?? def.mediaWidth,
        mediaHeight: (d["media_height"] as? NSNumber)?.doubleValue ?? def.mediaHeight,
        orientation: Orientation(rawValue: (d["orientation"] as? String) ?? "") ?? def.orientation,
        autoRotate: (d["auto_rotate"] as? Bool) ?? def.autoRotate,
        transverse: (d["transverse"] as? Bool) ?? def.transverse,
        printLayers: PrintLayers(rawValue: (d["print_layers"] as? String) ?? "") ?? def.printLayers,
        placementX: (d["placement_x"] as? NSNumber)?.doubleValue ?? def.placementX,
        placementY: (d["placement_y"] as? NSNumber)?.doubleValue ?? def.placementY,
        scalingMode: ScalingMode(rawValue: (d["scaling_mode"] as? String) ?? "") ?? def.scalingMode,
        customScale: (d["custom_scale"] as? NSNumber)?.doubleValue ?? def.customScale,
        tileOverlapH: (d["tile_overlap_h"] as? NSNumber)?.doubleValue ?? def.tileOverlapH,
        tileOverlapV: (d["tile_overlap_v"] as? NSNumber)?.doubleValue ?? def.tileOverlapV,
        tileRange: (d["tile_range"] as? String) ?? def.tileRange,
        marksAndBleed: parseMarksAndBleed(d["marks_and_bleed"]),
        output: parseOutput(d["output"]),
        graphics: parseGraphics(d["graphics"]),
        colorManagement: parseColorManagement(d["color_management"]),
        advanced: parseAdvanced(d["advanced"])
    )
}

/// Parse canonical test JSON into a Document.
///
/// This is the inverse of ``documentToTestJson(_:)``.
package func testJsonToDocument(_ json: String) -> Document {
    let data = json.data(using: .utf8)!
    let v = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    let layerValues = v["layers"] as? [Any] ?? []
    let layers: [Layer] = layerValues.map { lv in
        let elem = parseElement(lv)
        guard case .layer(let l) = elem else { fatalError("Expected layer element") }
        return l
    }
    let selectedLayer = (v["selected_layer"] as? NSNumber)?.intValue ?? 0
    let selection = parseSelection(v["selection"])
    let artboards = parseArtboards(v["artboards"])
    let artboardOptions = parseArtboardOptions(v["artboard_options"])
    let documentSetup = parseDocumentSetup(v["document_setup"])
    let printPreferences = parsePrintPreferences(v["print_preferences"])
    // Symbols (master store): absent key -> empty (legacy fixtures predate
    // symbols and stay byte-identical). Masters parse with the same
    // parseElement as layer content.
    let symbols: [Element] = (v["symbols"] as? [Any] ?? []).map { parseElement($0) }
    return dedupeElementIds(Document(
        rawLayers: layers,
        rawSymbols: symbols,
        rawSelectedLayer: selectedLayer,
        rawSelection: selection,
        rawArtboards: artboards,
        rawArtboardOptions: artboardOptions,
        rawDocumentSetup: documentSetup,
        rawPrintPreferences: printPreferences
    ))
}
