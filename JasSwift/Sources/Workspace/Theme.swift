// Theme.swift — Centralized appearance theming for the vector illustration application.

import AppKit

// MARK: - Theme

/// A resolved appearance theme with all UI colors.
public struct Theme {
    public let windowBg: NSColor
    public let paneBg: NSColor
    public let paneBgDark: NSColor
    public let titleBarBg: NSColor
    public let titleBarText: NSColor
    public let border: NSColor
    public let text: NSColor
    public let textDim: NSColor
    public let textBody: NSColor
    public let textHint: NSColor
    public let textButton: NSColor
    public let tabActive: NSColor
    public let tabInactive: NSColor
    public let buttonChecked: NSColor
    public let accent: NSColor
    public let snapPreview: NSColor
    public let handleHover: NSColor
    public let paneShadow: NSColor
}

// MARK: - Predefined Appearances

/// Available appearance names and labels.
public struct AppearanceEntry {
    public let name: String
    public let label: String
}

/// All predefined appearances.
public let predefinedAppearances: [AppearanceEntry] = [
    AppearanceEntry(name: "dark_gray", label: "Dark Gray"),
    AppearanceEntry(name: "medium_gray", label: "Medium Gray"),
    AppearanceEntry(name: "light_gray", label: "Light Gray"),
]

/// Default appearance name.
public let defaultAppearanceName = "dark_gray"

/// Resolve an appearance by name.
public func resolveAppearance(_ name: String) -> Theme {
    switch name {
    case "medium_gray":
        return Theme(
            windowBg: NSColor(hex: "#484848"),
            paneBg: NSColor(hex: "#565656"),
            paneBgDark: NSColor(hex: "#4d4d4d"),
            titleBarBg: NSColor(hex: "#404040"),
            titleBarText: NSColor(hex: "#e0e0e0"),
            border: NSColor(hex: "#6a6a6a"),
            text: NSColor(hex: "#dddddd"),
            textDim: NSColor(hex: "#aaaaaa"),
            textBody: NSColor(hex: "#bbbbbb"),
            textHint: NSColor(hex: "#888888"),
            textButton: NSColor(hex: "#999999"),
            tabActive: NSColor(hex: "#606060"),
            tabInactive: NSColor(hex: "#505050"),
            buttonChecked: NSColor(hex: "#686868"),
            accent: NSColor(hex: "#5a9ee6"),
            snapPreview: NSColor(red: 90/255, green: 158/255, blue: 230/255, alpha: 200/255),
            handleHover: NSColor(red: 90/255, green: 158/255, blue: 230/255, alpha: 0.5),
            paneShadow: NSColor(white: 0, alpha: 0.25)
        )
    case "light_gray":
        return Theme(
            windowBg: NSColor(hex: "#ececec"),
            paneBg: NSColor(hex: "#f0f0f0"),
            paneBgDark: NSColor(hex: "#e6e6e6"),
            titleBarBg: NSColor(hex: "#e0e0e0"),
            titleBarText: NSColor(hex: "#1d1d1f"),
            border: NSColor(hex: "#d1d1d1"),
            text: NSColor(hex: "#1d1d1f"),
            textDim: NSColor(hex: "#86868b"),
            textBody: NSColor(hex: "#3d3d3f"),
            textHint: NSColor(hex: "#aeaeb2"),
            textButton: NSColor(hex: "#6e6e73"),
            tabActive: NSColor(hex: "#ffffff"),
            tabInactive: NSColor(hex: "#e8e8e8"),
            buttonChecked: NSColor(hex: "#d4d4d8"),
            accent: NSColor(hex: "#007aff"),
            snapPreview: NSColor(red: 0/255, green: 122/255, blue: 255/255, alpha: 180/255),
            handleHover: NSColor(red: 0/255, green: 122/255, blue: 255/255, alpha: 0.3),
            paneShadow: NSColor(white: 0, alpha: 0.08)
        )
    default: // dark_gray
        return Theme(
            windowBg: NSColor(hex: "#2e2e2e"),
            paneBg: NSColor(hex: "#3c3c3c"),
            paneBgDark: NSColor(hex: "#333333"),
            titleBarBg: NSColor(hex: "#2a2a2a"),
            titleBarText: NSColor(hex: "#d9d9d9"),
            border: NSColor(hex: "#555555"),
            text: NSColor(hex: "#cccccc"),
            textDim: NSColor(hex: "#999999"),
            textBody: NSColor(hex: "#aaaaaa"),
            textHint: NSColor(hex: "#777777"),
            textButton: NSColor(hex: "#888888"),
            tabActive: NSColor(hex: "#4a4a4a"),
            tabInactive: NSColor(hex: "#353535"),
            buttonChecked: NSColor(hex: "#505050"),
            accent: NSColor(hex: "#4a90d9"),
            snapPreview: NSColor(red: 50/255, green: 120/255, blue: 220/255, alpha: 200/255),
            handleHover: NSColor(red: 74/255, green: 144/255, blue: 217/255, alpha: 0.5),
            paneShadow: NSColor(white: 0, alpha: 0.3)
        )
    }
}

// MARK: - NSColor hex initializer

extension NSColor {
    /// Create an NSColor from a hex string like "#3c3c3c" or "3c3c3c".
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
