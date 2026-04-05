import Foundation

/// SVG/CSS length units.
public enum Unit: Equatable, Hashable, CaseIterable {
    /// Pixels (default, relative to viewing device)
    case px
    /// Points (1/72 inch)
    case pt
    /// Picas (12 points)
    case pc
    /// Inches
    case `in`
    /// Centimeters
    case cm
    /// Millimeters
    case mm
    /// Relative to font size
    case em
    /// Relative to root font size
    case rem
}

/// A numeric value paired with a unit of measurement.
public struct Measure: Equatable, Hashable {
    public let value: Double
    public let unit: Unit

    public init(_ value: Double, _ unit: Unit = .px) {
        self.value = value
        self.unit = unit
    }

    /// Convert to pixels (at 96 DPI).
    ///
    /// - Parameter fontSize: The reference font size in px, used for em/rem.
    public func toPx(fontSize: Double = 16.0) -> Double {
        switch unit {
        case .px: return value
        case .pt: return value * 96.0 / 72.0
        case .pc: return value * 96.0 / 72.0 * 12.0
        case .in: return value * 96.0
        case .cm: return value * 96.0 / 2.54
        case .mm: return value * 96.0 / 25.4
        case .em, .rem: return value * fontSize
        }
    }
}

/// Shorthand constructors.
public func px(_ value: Double) -> Measure { Measure(value, .px) }
public func pt(_ value: Double) -> Measure { Measure(value, .pt) }
