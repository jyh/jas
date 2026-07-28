import Foundation

/// Merge an action's DECLARED param defaults underneath a caller's params.
///
/// `workspace/actions.yaml` may declare a param schema:
///
/// ```yaml
///   zoom_in:
///     params:
///       anchor_x: { type: number, default: -1 }
///       anchor_y: { type: number, default: -1 }
/// ```
///
/// A caller that omits `anchor_x` means "use the declared default", not "pass
/// nothing". Without this merge, `param.anchor_x` has no ctx entry, the
/// expression evaluator yields null, `evalNumber` coerces null to 0, and the
/// effect reads 0 — a value the workspace never declared and which is silently
/// WRONG rather than inert. That is exactly what happened to `zoom_in` /
/// `zoom_out` from the keyboard and the menu: the declared `-1` sentinel that
/// means "anchor at the viewport centre" never reached `doc.zoom.apply`, so the
/// zoom anchored at the document origin's screen position instead of at what
/// the artist was looking at (RULED 2026-07-27, transcripts/ZOOM_TOOL.md
/// "the DEFAULT ZOOM ANCHOR is the viewport centre").
///
/// Precedence: a key the caller SUPPLIED always wins, including when the value
/// it supplied is `NSNull` — an explicit null is a real argument and the
/// declared default must not overwrite it. Only an ABSENT key takes the
/// default. (`params` is `[String: Any]`, so absence is `index(forKey:) ==
/// nil`, not `== nil` on the subscript: a stored `NSNull` is present.)
///
/// A declaration whose value is not a mapping is taken as the default itself
/// (`foo: 3` is read as `foo: { default: 3 }`), and a mapping with no
/// `default` key contributes nothing — an undeclared-default param stays
/// absent, so a `param.x == null` guard in the YAML still sees null.
///
/// Mirrors the merge in Rust's `renderer::dispatch_action`
/// (jas_dioxus/src/interpreter/renderer.rs), which is the port this behaviour
/// is being brought into agreement with. As of 2026-07-27 exactly three of the
/// 236 actions declare param defaults — `zoom_in`, `zoom_out` and
/// `artboards_panel_select` — so the blast radius is those three verbs.
func mergeDeclaredParamDefaults(
    _ params: [String: Any], actionDef: [String: Any]
) -> [String: Any] {
    guard let declared = actionDef["params"] as? [String: Any] else { return params }
    var merged = params
    for (name, spec) in declared {
        if merged.index(forKey: name) != nil { continue }
        if let specMap = spec as? [String: Any] {
            if let def = specMap["default"] { merged[name] = def }
        } else {
            merged[name] = spec
        }
    }
    return merged
}
