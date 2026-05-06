// Per-document Print dialog state (PRINT.md §Phase 1B). Remembers
// the last-used choices in the General tab so reopening Print
// restores them. Later phases extend with sub-records for marks,
// output, graphics, color management, advanced.
//
// `PrintPreset` is the workspace-level named saved configuration of
// the same fields. Phase 1 ships exactly one built-in `[Default]`;
// save / load / delete is deferred (PRINT.md §Phase 7+).

import Foundation

public enum ArtboardRangeMode: String, Equatable, Hashable, CaseIterable {
    case all
    case range
}

public enum MediaSize: String, Equatable, Hashable, CaseIterable {
    case definedByDriver = "defined_by_driver"
    case letter
    case legal
    case tabloid
    case a3
    case a4
    case a5
    case custom
}

public enum Orientation: String, Equatable, Hashable, CaseIterable {
    case portrait
    case landscape
}

public enum PrintLayers: String, Equatable, Hashable, CaseIterable {
    /// Visible & Printable: honor both `layer.visibility != .invisible`
    /// AND a future `Layer.print` flag. Until that flag lands this
    /// collapses to `.visible`.
    case visiblePrintable = "visible_printable"
    case visible
    case all
}

public enum ScalingMode: String, Equatable, Hashable, CaseIterable {
    case doNotScale = "do_not_scale"
    case fitToPage = "fit_to_page"
    case custom
}

/// Two cultural variants of printer's marks. ``roman`` ships the
/// standard Western trim/registration marks; ``japanese`` swaps in
/// the kasen-style marks used by Japanese commercial print shops.
/// Phase 2 stores the choice but the renderer only differentiates in
/// a follow-up — the on-disk shape is stable now.
public enum PrinterMarkType: String, Equatable, Hashable, CaseIterable {
    case roman
    case japanese
}

/// Output mode (PRINT.md §Phase 3): Composite renders the document
/// as one PDF page per artboard (Phase 1B behavior); Separations
/// renders one page per enabled ink in ``Output.inks``.
public enum OutputMode: String, Equatable, Hashable, CaseIterable {
    case composite
    case separations
}

/// Film emulsion side (PRINT.md §Phase 3). For PDF output this
/// has no rendering effect, but the on-disk shape is stable.
public enum Emulsion: String, Equatable, Hashable, CaseIterable {
    case upRight = "up_right"
    case downRight = "down_right"
}

/// PDF page polarity (PRINT.md §Phase 3). Negative inverts the final
/// rasterized output; for PDF this is recorded but not applied.
public enum ImagePolarity: String, Equatable, Hashable, CaseIterable {
    case positive
    case negative
}

/// Halftone dot shape for an ``InkOverride`` row (PRINT.md §Phase 3).
/// Phase 3 stores the choice; halftone screen rendering itself is a
/// Phase 7+ deferral.
public enum DotShape: String, Equatable, Hashable, CaseIterable {
    case round
    case square
    case ellipse
    case diamond
    case line
    case cross
    case euclidean
}

/// One row in the per-ink overrides table (PRINT.md §Phase 3 Output).
public struct InkOverride: Equatable, Hashable {
    public let name: String
    public let print: Bool
    public let frequency: Double
    public let angle: Double
    public let dotShape: DotShape

    public init(name: String, print: Bool = true, frequency: Double = 75.0,
                angle: Double = 45.0, dotShape: DotShape = .round) {
        self.name = name
        self.print = print
        self.frequency = frequency
        self.angle = angle
        self.dotShape = dotShape
    }

    /// The default ink list shipped with a fresh PrintPreferences:
    /// the four CMYK process inks at standard Western screen angles.
    public static let processCmykDefaults: [InkOverride] = [
        InkOverride(name: "Process Cyan",    frequency: 75, angle: 105),
        InkOverride(name: "Process Magenta", frequency: 75, angle:  75),
        InkOverride(name: "Process Yellow",  frequency: 75, angle:  90),
        InkOverride(name: "Process Black",   frequency: 75, angle:  45),
    ]
}

/// Output sub-record on PrintPreferences (PRINT.md §Phase 3). The
/// Output tab edits these 1:1; in Separations mode the PDF emitter
/// produces one page per enabled InkOverride instead of one page
/// per artboard.
public struct Output: Equatable, Hashable {
    public let mode: OutputMode
    public let emulsion: Emulsion
    public let imagePolarity: ImagePolarity
    public let printerResolution: String
    public let convertSpotToProcess: Bool
    public let overprintBlack: Bool
    public let inks: [InkOverride]

    public init(
        mode: OutputMode = .composite,
        emulsion: Emulsion = .upRight,
        imagePolarity: ImagePolarity = .positive,
        printerResolution: String = "75 lpi / 600 dpi",
        convertSpotToProcess: Bool = false,
        overprintBlack: Bool = false,
        inks: [InkOverride] = InkOverride.processCmykDefaults
    ) {
        self.mode = mode
        self.emulsion = emulsion
        self.imagePolarity = imagePolarity
        self.printerResolution = printerResolution
        self.convertSpotToProcess = convertSpotToProcess
        self.overprintBlack = overprintBlack
        self.inks = inks
    }

    public static let `default` = Output()
}

/// Marks-and-bleed sub-record on PrintPreferences (PRINT.md §Phase 2).
/// The Marks tab exposes these 1:1 as widgets; the PDF renderer
/// extends each page by the active bleed and overlays mark geometry
/// around the trim rect.
///
/// ``useDocumentBleed`` controls whether bleeds come from the
/// document-level ``DocumentSetup`` or from the per-print
/// ``bleed*`` overrides on this struct. Defaulting to true keeps
/// document and print in lockstep until the user opts out.
public struct MarksAndBleed: Equatable, Hashable {
    public let allPrinterMarks: Bool
    public let trimMarks: Bool
    public let registrationMarks: Bool
    public let colorBars: Bool
    public let pageInformation: Bool
    public let printerMarkType: PrinterMarkType
    public let trimMarkWeight: Double
    public let markOffset: Double
    public let useDocumentBleed: Bool
    public let bleedTop: Double
    public let bleedRight: Double
    public let bleedBottom: Double
    public let bleedLeft: Double

    public init(
        allPrinterMarks: Bool = false,
        trimMarks: Bool = false,
        registrationMarks: Bool = false,
        colorBars: Bool = false,
        pageInformation: Bool = false,
        printerMarkType: PrinterMarkType = .roman,
        trimMarkWeight: Double = 0.25,
        markOffset: Double = 6.0,
        useDocumentBleed: Bool = true,
        bleedTop: Double = 0,
        bleedRight: Double = 0,
        bleedBottom: Double = 0,
        bleedLeft: Double = 0
    ) {
        self.allPrinterMarks = allPrinterMarks
        self.trimMarks = trimMarks
        self.registrationMarks = registrationMarks
        self.colorBars = colorBars
        self.pageInformation = pageInformation
        self.printerMarkType = printerMarkType
        self.trimMarkWeight = trimMarkWeight
        self.markOffset = markOffset
        self.useDocumentBleed = useDocumentBleed
        self.bleedTop = bleedTop
        self.bleedRight = bleedRight
        self.bleedBottom = bleedBottom
        self.bleedLeft = bleedLeft
    }

    public static let `default` = MarksAndBleed()
}

public struct PrintPreferences: Equatable, Hashable {
    public let presetName: String
    public let printerName: String?
    public let copies: Int
    public let collate: Bool
    public let reverseOrder: Bool
    public let artboardRangeMode: ArtboardRangeMode
    public let artboardRange: String
    public let ignoreArtboards: Bool
    public let skipBlankArtboards: Bool
    public let mediaSize: MediaSize
    public let mediaWidth: Double
    public let mediaHeight: Double
    public let orientation: Orientation
    public let autoRotate: Bool
    public let transverse: Bool
    public let printLayers: PrintLayers
    public let placementX: Double
    public let placementY: Double
    public let scalingMode: ScalingMode
    public let customScale: Double
    /// Reserved for Phase 7 tiling. Stored now so the on-disk shape
    /// is stable across phases.
    public let tileOverlapH: Double
    public let tileOverlapV: Double
    public let tileRange: String
    /// Marks-and-bleed sub-record (PRINT.md §Phase 2).
    public let marksAndBleed: MarksAndBleed
    /// Output sub-record (PRINT.md §Phase 3).
    public let output: Output

    public init(
        presetName: String = "[Default]",
        printerName: String? = nil,
        copies: Int = 1,
        collate: Bool = false,
        reverseOrder: Bool = false,
        artboardRangeMode: ArtboardRangeMode = .all,
        artboardRange: String = "",
        ignoreArtboards: Bool = false,
        skipBlankArtboards: Bool = false,
        mediaSize: MediaSize = .definedByDriver,
        mediaWidth: Double = 612,
        mediaHeight: Double = 792,
        orientation: Orientation = .portrait,
        autoRotate: Bool = true,
        transverse: Bool = false,
        printLayers: PrintLayers = .visiblePrintable,
        placementX: Double = 0,
        placementY: Double = 0,
        scalingMode: ScalingMode = .doNotScale,
        customScale: Double = 100.0,
        tileOverlapH: Double = 0,
        tileOverlapV: Double = 0,
        tileRange: String = "",
        marksAndBleed: MarksAndBleed = .default,
        output: Output = .default
    ) {
        self.presetName = presetName
        self.printerName = printerName
        self.copies = copies
        self.collate = collate
        self.reverseOrder = reverseOrder
        self.artboardRangeMode = artboardRangeMode
        self.artboardRange = artboardRange
        self.ignoreArtboards = ignoreArtboards
        self.skipBlankArtboards = skipBlankArtboards
        self.mediaSize = mediaSize
        self.mediaWidth = mediaWidth
        self.mediaHeight = mediaHeight
        self.orientation = orientation
        self.autoRotate = autoRotate
        self.transverse = transverse
        self.printLayers = printLayers
        self.placementX = placementX
        self.placementY = placementY
        self.scalingMode = scalingMode
        self.customScale = customScale
        self.tileOverlapH = tileOverlapH
        self.tileOverlapV = tileOverlapV
        self.tileRange = tileRange
        self.marksAndBleed = marksAndBleed
        self.output = output
    }

    public static let `default` = PrintPreferences()
}

/// Workspace-level named saved configuration. Phase 1 ships only the
/// built-in `[Default]`; save / load / delete is deferred (PRINT.md
/// §Phase 7+).
public struct PrintPreset: Equatable, Hashable {
    public let name: String
    public let preferences: PrintPreferences

    public init(name: String, preferences: PrintPreferences) {
        self.name = name
        self.preferences = preferences
    }

    /// The single built-in preset. Name is bracketed so user presets
    /// can never collide with it.
    public static let defaultPreset = PrintPreset(
        name: "[Default]",
        preferences: .default
    )
}
