/// SVG opacity normalizer.
///
/// Extracts color alpha into fill/stroke opacity (multiplicative),
/// then sets color alpha to 1.0.  This ensures that element
/// transparency is expressed through opacity attributes rather than
/// color alpha channels.

public func normalizeDocument(_ doc: Document) -> Document {
    Document(
        layers: doc.layers.map { normalizeLayer($0) },
        // Masters get the same opacity normalization as layer content.
        symbols: doc.symbols.map { normalizeElement($0) },
        selectedLayer: doc.selectedLayer,
        selection: doc.selection,
        artboards: doc.artboards,
        artboardOptions: doc.artboardOptions,
        documentSetup: doc.documentSetup,
        printPreferences: doc.printPreferences
    )
}

/// Enforce the unique-id invariant after import (REFERENCE_GRAPH.md §2.5):
/// walk the document in canonical pre-order; the FIRST element to use a given
/// id keeps it, and every later element carrying the same id has its id
/// cleared to nil (first-pre-order-wins). Element ids are then unique within
/// the document, so the live-reference index never collides. A no-op on a
/// document whose ids are already unique (the normal case) — well-formed
/// documents round-trip unchanged; only ill-formed (e.g. foreign-SVG)
/// duplicates are normalized. Called by every document reader. Mirrors the
/// reference implementation's `dedupe_element_ids`.
///
/// The walk descends into the operands a live `CompoundShape` OWNS as well as
/// into group/layer children: an operand is a real element carrying its own
/// `common.id`, so it is part of the one document-wide id space the invariant
/// speaks about.
public func dedupeElementIds(_ doc: Document) -> Document {
    var seen = Set<String>()
    let layers: [Layer] = doc.layers.map { layer in
        // Walk each top-level layer as an Element so the same pre-order
        // visitor handles the layer's own id and its descendants.
        let walked = dedupeIdsWalk(.layer(layer), &seen)
        guard case .layer(let l) = walked else {
            fatalError("dedupeElementIds: layer walk returned a non-layer element")
        }
        return l
    }
    // The id space spans layers + symbols (SYMBOLS.md §6): the master store is
    // part of the same pre-order walk so a master id can never collide with a
    // layer-element id. Layers walk first (first-pre-order-wins), then symbols.
    let symbols: [Element] = doc.symbols.map { dedupeIdsWalk($0, &seen) }
    return doc.replacing(layers: layers, symbols: symbols)
}

/// Pre-order id-dedupe visitor: visit `elem` (parent) before its children,
/// depth-first, children in order. The first element to use an id keeps it;
/// a later element carrying an already-seen id has its id cleared to nil.
/// Recurses into Group/Layer children, and into the operands a live
/// `CompoundShape` OWNS — an operand is a real element carrying its own
/// `common.id`, so it is part of the one document-wide id space the invariant
/// speaks about. The live switch is EXHAUSTIVE over all four `LiveVariant`
/// arms: only `compoundShape` owns child elements; `reference`, `recorded`
/// and `generated` name their inputs by id and own none. Written exhaustively
/// so a future payload that gains owned children forces the decision again
/// rather than silently going unwalked. Twin of Rust `dedupe_ids_walk`.
private func dedupeIdsWalk(_ elem: Element, _ seen: inout Set<String>) -> Element {
    var out = elem
    if let id = elem.id {
        // `insert` returns inserted=false when the id was already present —
        // that marks this as a later duplicate, so clear it.
        if !seen.insert(id).inserted {
            out = elem.withId(nil)
        }
    }
    switch out {
    case .group(let g):
        return .group(g.withChildren(g.children.map { dedupeIdsWalk($0, &seen) }))
    case .layer(let l):
        return .layer(l.withChildren(l.children.map { dedupeIdsWalk($0, &seen) }))
    case .live(let v):
        switch v {
        case .compoundShape(var cs):
            cs.operands = cs.operands.map { dedupeIdsWalk($0, &seen) }
            return .live(.compoundShape(cs))
        case .reference, .recorded, .generated:
            return out
        }
    default:
        return out
    }
}

private func normalizeFill(_ fill: Fill) -> Fill {
    Fill(color: fill.color.withAlpha(1.0), opacity: fill.opacity * fill.color.alpha)
}

private func normalizeStroke(_ stroke: Stroke) -> Stroke {
    // Preserve every Stroke field — only the color alpha is folded
    // into opacity. Earlier versions of this function dropped
    // dashPattern / miterLimit / align / arrows / dashAlignAnchors,
    // silently losing them on every SVG round-trip.
    Stroke(color: stroke.color.withAlpha(1.0), width: stroke.width,
           linecap: stroke.linecap, linejoin: stroke.linejoin,
           miterLimit: stroke.miterLimit, align: stroke.align,
           dashPattern: stroke.dashPattern,
           dashAlignAnchors: stroke.dashAlignAnchors,
           startArrow: stroke.startArrow, endArrow: stroke.endArrow,
           startArrowScale: stroke.startArrowScale,
           endArrowScale: stroke.endArrowScale,
           arrowAlign: stroke.arrowAlign,
           opacity: stroke.opacity * stroke.color.alpha)
}

private func normalizeElement(_ elem: Element) -> Element {
    switch elem {
    case .line(let e):
        return .line(Line(x1: e.x1, y1: e.y1, x2: e.x2, y2: e.y2,
                          stroke: e.stroke.map(normalizeStroke), widthPoints: e.widthPoints,
                          opacity: e.opacity, transform: e.transform,
                          locked: e.locked, visibility: e.visibility, name: e.name, id: e.id))
    case .rect(let e):
        return .rect(Rect(x: e.x, y: e.y, width: e.width, height: e.height,
                           rx: e.rx, ry: e.ry,
                           fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                           opacity: e.opacity, transform: e.transform,
                           locked: e.locked, visibility: e.visibility, name: e.name, id: e.id))
    case .ellipse(let e):
        return .ellipse(Ellipse(cx: e.cx, cy: e.cy, rx: e.rx, ry: e.ry,
                                fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                                opacity: e.opacity, transform: e.transform,
                                locked: e.locked, visibility: e.visibility, name: e.name, id: e.id))
    case .polyline(let e):
        return .polyline(Polyline(points: e.points,
                                  fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                                  opacity: e.opacity, transform: e.transform,
                                  locked: e.locked, visibility: e.visibility, name: e.name, id: e.id))
    case .polygon(let e):
        return .polygon(Polygon(points: e.points,
                                fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                                opacity: e.opacity, transform: e.transform,
                                locked: e.locked, visibility: e.visibility, name: e.name, id: e.id))
    case .path(let e):
        // `toolOrigin` is forwarded because this rebuild dropped it, and the
        // drop was invisible: it is not a key of the canonical test JSON, so
        // the only thing that reads it is the Blob Brush merge. Every path
        // opened from a file therefore reached the tool untagged, and a sweep
        // over an imported blob started a NEW element where Rust unioned into
        // the existing one. Pinned by test_fixtures/gestures/blob_import_merge.
        //
        // Deliberately narrow: this arm still omits blendMode, mask,
        // strokeBrush / strokeBrushOverrides ARE forwarded as of BRUSHSAVE
        // (2026-08-05): this arm's own note said forwarding them "would be an
        // unpinned change ... reported for a ruling rather than smuggled in",
        // and the condition it named is now met — the SVG codec carries them
        // and `roundtripPathKeepsItsStrokeBrushAndWidthProfile` pins the round
        // trip in both ports. Without the forward, a brushed path imported
        // correctly and then lost its brush HERE, one call later.
        //
        // fillGradient / strokeGradient stay omitted, and stay declared: the
        // SVG writer does not carry them either (codec_field_survival records
        // both as DROPPED for svg), so forwarding them alone would still be
        // unpinned. They wait on the gradients-as-paint amendment.
        return .path(Path(d: e.d,
                          fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                          widthPoints: e.widthPoints,
                          opacity: e.opacity, transform: e.transform,
                          locked: e.locked, visibility: e.visibility,
                          strokeBrush: e.strokeBrush,
                          strokeBrushOverrides: e.strokeBrushOverrides,
                          toolOrigin: e.toolOrigin,
                          name: e.name, id: e.id,
                          fillRule: e.fillRule))
    case .text(let e):
        // Pass the tspans tuple through so multi-tspan text
        // survives normalisation. The content-init would collapse
        // into a single flat tspan and drop any per-range overrides.
        return .text(Text(x: e.x, y: e.y, tspans: e.tspans,
                          fontFamily: e.fontFamily, fontSize: e.fontSize,
                          fontWeight: e.fontWeight, fontStyle: e.fontStyle,
                          textDecoration: e.textDecoration,
                          textTransform: e.textTransform, fontVariant: e.fontVariant,
                          baselineShift: e.baselineShift, lineHeight: e.lineHeight,
                          letterSpacing: e.letterSpacing, xmlLang: e.xmlLang,
                          aaMode: e.aaMode, rotate: e.rotate,
                          horizontalScale: e.horizontalScale, verticalScale: e.verticalScale,
                          kerning: e.kerning,
                          width: e.width, height: e.height,
                          fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                          opacity: e.opacity, transform: e.transform,
                          locked: e.locked, visibility: e.visibility, name: e.name, id: e.id))
    case .textPath(let e):
        return .textPath(TextPath(d: e.d, tspans: e.tspans, startOffset: e.startOffset,
                                  fontFamily: e.fontFamily, fontSize: e.fontSize,
                                  fontWeight: e.fontWeight, fontStyle: e.fontStyle,
                                  textDecoration: e.textDecoration,
                                  textTransform: e.textTransform, fontVariant: e.fontVariant,
                                  baselineShift: e.baselineShift, lineHeight: e.lineHeight,
                                  letterSpacing: e.letterSpacing, xmlLang: e.xmlLang,
                                  aaMode: e.aaMode, rotate: e.rotate,
                                  horizontalScale: e.horizontalScale, verticalScale: e.verticalScale,
                                  kerning: e.kerning,
                                  fill: e.fill.map(normalizeFill), stroke: e.stroke.map(normalizeStroke),
                                  opacity: e.opacity, transform: e.transform,
                                  locked: e.locked, visibility: e.visibility, name: e.name, id: e.id))
    // Group and Layer carry no color of their own, so normalize touches
    // ONLY their children. Clone-then-mutate, not a rebuild: the memberwise
    // rebuild this replaced named 7 of 11 fields and therefore dropped
    // `blendMode`, `mask`, `isolatedBlending` and `knockoutGroup` from every
    // group and every layer on the way in (the Swift copy-site omission
    // class). Gated by `CopySiteOmissionTests`.
    case .group(let g):
        return .group(g.withChildren(g.children.map(normalizeElement)))
    case .layer(let l):
        return .layer(l.withChildren(l.children.map(normalizeElement)))
    case .live(let v):
        // Phase 1: pass through unchanged. Phase 2 will recursively
        // normalize operands and fill / stroke like Group does.
        return .live(v)
    }
}

/// Same clone-then-mutate rule as the `.layer` arm above, and for the same
/// reason — see its note.
private func normalizeLayer(_ layer: Layer) -> Layer {
    layer.withChildren(layer.children.map(normalizeElement))
}
