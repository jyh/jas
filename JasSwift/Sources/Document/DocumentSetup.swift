// Per-document settings edited from the Document Setup dialog
// (PRINT.md §Phase 1A). Bleed values are in points and represent the
// amount of artwork that extends past each artboard edge for trim
// tolerance during commercial printing.

import Foundation

public struct DocumentSetup: Equatable, Hashable {
    public let bleedTop: Double
    public let bleedRight: Double
    public let bleedBottom: Double
    public let bleedLeft: Double
    /// Chain-link state for the bleed inputs in the dialog. When true,
    /// editing any one side propagates to all four. Persisted because
    /// the user expects the chain to stay where they left it across
    /// sessions.
    public let bleedUniform: Bool
    /// Render image elements as their bounding outline rather than
    /// rasterized content (canvas display only; export ignores this).
    public let showImagesOutline: Bool
    /// Tint glyphs that were rendered with a substituted font so the
    /// user can spot missing-font cases.
    public let highlightSubstitutedGlyphs: Bool

    public init(
        bleedTop: Double = 0,
        bleedRight: Double = 0,
        bleedBottom: Double = 0,
        bleedLeft: Double = 0,
        bleedUniform: Bool = true,
        showImagesOutline: Bool = false,
        highlightSubstitutedGlyphs: Bool = false
    ) {
        self.bleedTop = bleedTop
        self.bleedRight = bleedRight
        self.bleedBottom = bleedBottom
        self.bleedLeft = bleedLeft
        self.bleedUniform = bleedUniform
        self.showImagesOutline = showImagesOutline
        self.highlightSubstitutedGlyphs = highlightSubstitutedGlyphs
    }

    public static let `default` = DocumentSetup()

    /// Compute the on-canvas bleed guide rectangle for one artboard,
    /// in document points: `(x, y, w, h)` extended outward from the
    /// artboard by the per-side bleed values. Returns `nil` when all
    /// four bleeds are zero.
    public func bleedRect(forArtboard ab: Artboard) -> (Double, Double, Double, Double)? {
        if bleedTop == 0 && bleedRight == 0 && bleedBottom == 0 && bleedLeft == 0 {
            return nil
        }
        return (
            ab.x - bleedLeft,
            ab.y - bleedTop,
            ab.width + bleedLeft + bleedRight,
            ab.height + bleedTop + bleedBottom
        )
    }
}
