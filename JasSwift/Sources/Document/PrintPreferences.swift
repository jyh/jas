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
        tileRange: String = ""
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
