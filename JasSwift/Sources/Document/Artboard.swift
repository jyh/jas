import Foundation

/// Artboards: print-page regions attached to the document root.
///
/// See `transcripts/ARTBOARDS.md` for the full specification. In
/// summary, every document has at least one artboard; `Artboard`
/// carries position, size, fill, display toggles, and a stable
/// 8-char base36 `id`. The 1-based `number` shown in the panel is
/// derived from list position, not stored.
///
/// Serialization format matches Python + Rust exactly (cross-app
/// contract, ART-441):
///
/// ```text
/// {
///   "id": "abc12345",
///   "name": "Artboard 1",
///   "x": 0, "y": 0,
///   "width": 612, "height": 792,
///   "fill": "transparent",  // or a "#rrggbb" hex
///   "show_center_mark": false,
///   "show_cross_hairs": false,
///   "show_video_safe_areas": false,
///   "video_ruler_pixel_aspect_ratio": 1.0
/// }
/// ```

// MARK: - ArtboardFill

/// The `fill` property is a sum type: either `.transparent` or an
/// opaque color literal. The string form (`"transparent"` or
/// `"#rrggbb"`) is the canonical serialization.
public enum ArtboardFill: Equatable, Hashable {
    case transparent
    case color(String)

    public var asCanonical: String {
        switch self {
        case .transparent: return "transparent"
        case .color(let hex): return hex
        }
    }

    public static func fromCanonical(_ s: String) -> ArtboardFill {
        if s == "transparent" {
            return .transparent
        }
        return .color(s)
    }
}

// MARK: - Artboard

public struct Artboard: Equatable, Hashable {
    public let id: String
    public let name: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let fill: ArtboardFill
    public let showCenterMark: Bool
    public let showCrossHairs: Bool
    public let showVideoSafeAreas: Bool
    public let videoRulerPixelAspectRatio: Double

    public init(
        id: String,
        name: String = "Artboard 1",
        x: Double = 0,
        y: Double = 0,
        width: Double = 612,
        height: Double = 792,
        fill: ArtboardFill = .transparent,
        showCenterMark: Bool = false,
        showCrossHairs: Bool = false,
        showVideoSafeAreas: Bool = false,
        videoRulerPixelAspectRatio: Double = 1.0
    ) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.fill = fill
        self.showCenterMark = showCenterMark
        self.showCrossHairs = showCrossHairs
        self.showVideoSafeAreas = showVideoSafeAreas
        self.videoRulerPixelAspectRatio = videoRulerPixelAspectRatio
    }

    /// Canonical default: Letter 612×792 at origin, transparent fill,
    /// all display toggles off. The `id` argument comes from the
    /// id generator (seeded in tests; platform-sourced in production).
    public static func defaultWithId(_ id: String) -> Artboard {
        Artboard(id: id)
    }

    /// Copy the artboard with the given field changes (builder shim —
    /// Document is immutable-by-convention).
    public func with(
        name: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        fill: ArtboardFill? = nil,
        showCenterMark: Bool? = nil,
        showCrossHairs: Bool? = nil,
        showVideoSafeAreas: Bool? = nil,
        videoRulerPixelAspectRatio: Double? = nil
    ) -> Artboard {
        Artboard(
            id: self.id,
            name: name ?? self.name,
            x: x ?? self.x,
            y: y ?? self.y,
            width: width ?? self.width,
            height: height ?? self.height,
            fill: fill ?? self.fill,
            showCenterMark: showCenterMark ?? self.showCenterMark,
            showCrossHairs: showCrossHairs ?? self.showCrossHairs,
            showVideoSafeAreas: showVideoSafeAreas ?? self.showVideoSafeAreas,
            videoRulerPixelAspectRatio: videoRulerPixelAspectRatio ?? self.videoRulerPixelAspectRatio
        )
    }
}

// MARK: - ArtboardOptions

/// Document-global artboard toggles. Both default to on.
public struct ArtboardOptions: Equatable, Hashable {
    public let fadeRegionOutsideArtboard: Bool
    public let updateWhileDragging: Bool

    public init(
        fadeRegionOutsideArtboard: Bool = true,
        updateWhileDragging: Bool = true
    ) {
        self.fadeRegionOutsideArtboard = fadeRegionOutsideArtboard
        self.updateWhileDragging = updateWhileDragging
    }

    public static let `default` = ArtboardOptions()
}

// MARK: - Id generation

private let artboardIdAlphabet: [Character] = Array("0123456789abcdefghijklmnopqrstuvwxyz")
private let artboardIdLength = 8

/// Mint a fresh 8-char base36 id. Pass a seeded RNG for deterministic
/// tests; default uses `SystemRandomNumberGenerator`.
public func generateArtboardId<RNG: RandomNumberGenerator>(
    using rng: inout RNG
) -> String {
    var chars = ""
    for _ in 0..<artboardIdLength {
        let idx = Int.random(in: 0..<artboardIdAlphabet.count, using: &rng)
        chars.append(artboardIdAlphabet[idx])
    }
    return chars
}

/// Non-generic wrapper that taps a system RNG each call.
public func generateArtboardId() -> String {
    var rng = SystemRandomNumberGenerator()
    return generateArtboardId(using: &rng)
}

// MARK: - Default-name rule

/// Match a name against the default `Artboard N` pattern and return
/// N on success. Case-sensitive, exactly one space between
/// `Artboard` and the digits (ARTBOARDS.md §Numbering and naming).
private func parseDefaultName(_ name: String) -> Int? {
    let prefix = "Artboard "
    guard name.hasPrefix(prefix) else { return nil }
    let rest = String(name.dropFirst(prefix.count))
    guard !rest.isEmpty else { return nil }
    guard let first = rest.first, first.isASCII, first.isNumber else { return nil }
    guard rest.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int(rest)
}

/// Pick the next unused `Artboard N` name. Smallest N not used by
/// any default-pattern name.
public func nextArtboardName(_ artboards: [Artboard]) -> String {
    var used: Set<Int> = []
    for a in artboards {
        if let n = parseDefaultName(a.name) {
            used.insert(n)
        }
    }
    var n = 1
    while used.contains(n) { n += 1 }
    return "Artboard \(n)"
}

// MARK: - At-least-one-artboard invariant

/// Return a list that enforces `artboards.count >= 1`, minting a
/// default artboard with the supplied id when the input is empty.
/// `didRepair` is populated so the caller can emit the log line.
public func ensureArtboardsInvariant(
    _ artboards: [Artboard],
    idGenerator: () -> String = generateArtboardId
) -> (artboards: [Artboard], didRepair: Bool) {
    if !artboards.isEmpty {
        return (artboards, false)
    }
    return ([Artboard.defaultWithId(idGenerator())], true)
}
