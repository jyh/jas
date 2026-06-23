/// Unit oracle for icon_button size resolution
/// (`Sources/Interpreter/YamlPanelBodyView.swift` →
/// `resolveIconButtonSize`).
///
/// Three rendering scopes must resolve distinct icon pixel sizes, to
/// match the OCaml app (the cross-language target):
///
///   * TOOLBAR slots carry `style.size: "{{theme.sizes.tool_button}}"`,
///     which resolves to the literal theme size 32. The size value is
///     a `{{...}}` template, so it must be resolved through the eval
///     context (the toolbar context carries `theme.sizes.tool_button`).
///   * FLYOUT (tool-alternates) items declare NO size; they get a
///     flyout-scoped default of 28 (passed by the non-modal dialog
///     body), matching OCaml's `nonmodal_icon_size := Some 28`.
///   * PANEL icon_buttons declare no size and get no flyout default, so
///     they keep the panel default of 20 — UNCHANGED by this work.

import Foundation
import Testing
@testable import JasLib

/// Build the same numeric `theme.sizes` context the toolbar uses, so a
/// `{{theme.sizes.tool_button}}` size template resolves to 32.
private func toolbarLikeContext() -> [String: Any] {
    let ws = WorkspaceData.load()
    let sizes: [String: Any] = {
        guard let t = ws?.theme(),
              let base = t["base"] as? [String: Any],
              let s = base["sizes"] as? [String: Any] else { return [:] }
        return s
    }()
    return ["theme": ["sizes": sizes] as [String: Any]]
}

@Test func toolbarSlotIconResolvesToThemeToolButton32() throws {
    let ctx = toolbarLikeContext()
    // Sanity: the bundle's theme.sizes.tool_button is 32.
    let tb = evaluate("theme.sizes.tool_button", context: ctx)
    guard case .number(let n) = tb else {
        Issue.record("theme.sizes.tool_button did not resolve to a number: \(tb)")
        return
    }
    #expect(n == 32, "bundle theme.sizes.tool_button should be 32, got \(n)")

    // A toolbar slot: style.size is the {{...}} template (verbatim from
    // the bundle). It must resolve through the context to 32.
    let style: [String: Any] = ["size": "{{theme.sizes.tool_button}}"]
    let size = resolveIconButtonSize(style: style, context: ctx, flyoutDefault: nil)
    #expect(size == 32, "toolbar slot icon should resolve to 32, got \(size)")
}

@Test func flyoutItemIconUsesFlyoutDefault28() {
    // Flyout (tool-alternates) item: no style.size at all. With a
    // flyout-scoped default of 28 it must resolve to 28, NOT the panel
    // default 20.
    let style: [String: Any] = ["width": "100%", "justify": "start",
                                "gap": 8, "padding": "4 8"]
    let size = resolveIconButtonSize(style: style, context: [:], flyoutDefault: 28)
    #expect(size == 28, "flyout item icon should use the 28 flyout default, got \(size)")
}

@Test func panelIconButtonKeepsDefault20() {
    // Panel icon_button: no style.size, no flyout default → panel
    // default 20. This is the case that must remain UNCHANGED.
    let size = resolveIconButtonSize(style: [:], context: [:], flyoutDefault: nil)
    #expect(size == 20, "panel icon_button should keep the 20 default, got \(size)")

    // A panel widget with an explicit small size (e.g. a 16pt dialog
    // glyph) must honor that literal, unaffected by any default.
    let small: [String: Any] = ["size": 16]
    #expect(resolveIconButtonSize(style: small, context: [:], flyoutDefault: nil) == 16)
    // And an explicit literal must override even a flyout default,
    // so adding size: to a shared YAML stays authoritative.
    #expect(resolveIconButtonSize(style: small, context: [:], flyoutDefault: 28) == 16)
}

@Test func numericAndPxStringSizesStillResolve() {
    // Double / Int literals (panel dialogs) pass through unchanged.
    #expect(resolveIconButtonSize(style: ["size": 24.0], context: [:], flyoutDefault: nil) == 24)
    #expect(resolveIconButtonSize(style: ["size": 18], context: [:], flyoutDefault: nil) == 18)
    // A "px"-suffixed string (length-style) still parses.
    #expect(resolveIconButtonSize(style: ["size": "22 px"], context: [:], flyoutDefault: nil) == 22)
}
