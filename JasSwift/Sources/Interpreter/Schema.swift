/// Schema loader for workspace state fields.
///
/// Mirrors the field definitions in `workspace/state.yaml` for the
/// schema-driven `set:` effect. Port of workspace_interpreter/schema.py.

import Foundation

// MARK: - Types

enum FieldType: Equatable {
    case bool
    case number
    case string
    case color
    case enumType([String])
    case list
    case object

    static func == (lhs: FieldType, rhs: FieldType) -> Bool {
        switch (lhs, rhs) {
        case (.bool, .bool), (.number, .number), (.string, .string),
             (.color, .color), (.list, .list), (.object, .object):
            return true
        case (.enumType(let a), .enumType(let b)):
            return a == b
        default:
            return false
        }
    }
}

struct SchemaEntry {
    let fieldType: FieldType
    let nullable: Bool
    let writable: Bool
}

struct Diagnostic {
    let level: String   // "warning" or "error"
    let key: String
    let reason: String
}

// MARK: - Schema table

private let activeToolValues = [
    "selection", "partial_selection", "interior_selection",
    "pen", "add_anchor", "delete_anchor", "anchor_point",
    "pencil", "path_eraser", "smooth",
    "type", "type_on_path",
    "line", "rect", "rounded_rect", "polygon", "star", "lasso",
]
private let strokeCapValues = ["butt", "round", "square"]
private let strokeJoinValues = ["miter", "round", "bevel"]
private let strokeAlignValues = ["center", "inside", "outside"]
private let strokeArrowheadValues = [
    "none", "simple_arrow", "open_arrow", "closed_arrow", "stealth_arrow",
    "barbed_arrow", "half_arrow_upper", "half_arrow_lower",
    "circle", "open_circle", "square", "open_square",
    "diamond", "open_diamond", "slash",
]
private let strokeArrowAlignValues = ["tip_at_end", "center_at_end"]
private let strokeProfileValues = [
    "uniform", "taper_both", "taper_start", "taper_end", "bulge", "pinch",
]

/// Look up the schema entry for a global `state:` field by name.
func getSchemaEntry(_ key: String) -> SchemaEntry? {
    switch key {
    case "active_tool":
        return SchemaEntry(fieldType: .enumType(activeToolValues), nullable: false, writable: true)
    case "fill_color":
        return SchemaEntry(fieldType: .color, nullable: true, writable: true)
    case "stroke_color":
        return SchemaEntry(fieldType: .color, nullable: true, writable: true)
    case "stroke_width":
        return SchemaEntry(fieldType: .number, nullable: false, writable: true)
    case "stroke_cap":
        return SchemaEntry(fieldType: .enumType(strokeCapValues), nullable: false, writable: true)
    case "stroke_join":
        return SchemaEntry(fieldType: .enumType(strokeJoinValues), nullable: false, writable: true)
    case "stroke_miter_limit":
        return SchemaEntry(fieldType: .number, nullable: false, writable: true)
    case "stroke_align":
        return SchemaEntry(fieldType: .enumType(strokeAlignValues), nullable: false, writable: true)
    case "stroke_dashed":
        return SchemaEntry(fieldType: .bool, nullable: false, writable: true)
    case "stroke_dash_1", "stroke_gap_1":
        return SchemaEntry(fieldType: .number, nullable: false, writable: true)
    case "stroke_dash_2", "stroke_gap_2", "stroke_dash_3", "stroke_gap_3":
        return SchemaEntry(fieldType: .number, nullable: true, writable: true)
    case "stroke_start_arrowhead", "stroke_end_arrowhead":
        return SchemaEntry(fieldType: .enumType(strokeArrowheadValues), nullable: false, writable: true)
    case "stroke_start_arrowhead_scale", "stroke_end_arrowhead_scale":
        return SchemaEntry(fieldType: .number, nullable: false, writable: true)
    case "stroke_link_arrowhead_scale":
        return SchemaEntry(fieldType: .bool, nullable: false, writable: true)
    case "stroke_arrow_align":
        return SchemaEntry(fieldType: .enumType(strokeArrowAlignValues), nullable: false, writable: true)
    case "stroke_profile":
        return SchemaEntry(fieldType: .enumType(strokeProfileValues), nullable: false, writable: true)
    case "stroke_profile_flipped":
        return SchemaEntry(fieldType: .bool, nullable: false, writable: true)
    case "fill_on_top", "toolbar_visible", "canvas_visible", "dock_visible",
         "canvas_maximized", "dock_collapsed":
        return SchemaEntry(fieldType: .bool, nullable: false, writable: true)
    case "active_tab", "tab_count":
        return SchemaEntry(fieldType: .number, nullable: false, writable: true)
    // Internal — writable: false
    case "_drag_pane", "_resize_pane", "_resize_edge":
        return SchemaEntry(fieldType: .string, nullable: true, writable: false)
    case "_drag_offset_x", "_drag_offset_y", "_resize_start_x", "_resize_start_y":
        return SchemaEntry(fieldType: .number, nullable: false, writable: false)
    default:
        return nil
    }
}

// MARK: - Coercion

private let hexColorRegex = try! NSRegularExpression(pattern: "^#[0-9a-fA-F]{6}$")

private func isHexColor(_ s: String) -> Bool {
    let range = NSRange(s.startIndex..., in: s)
    return hexColorRegex.firstMatch(in: s, range: range) != nil
}

private let numberStringRegex = try! NSRegularExpression(pattern: "^-?\\d+(\\.\\d+)?$")

private func isNumberString(_ s: String) -> Bool {
    let range = NSRange(s.startIndex..., in: s)
    return numberStringRegex.firstMatch(in: s, range: range) != nil
}

/// Coerce a value from the state bag to match the schema entry's declared type.
///
/// Returns the coerced value (Any?) and an optional error reason string.
/// On success, errorReason is nil.
func coerceValue(_ value: Any?, entry: SchemaEntry) -> (Any?, String?) {
    if value == nil || value is NSNull {
        if entry.nullable { return (nil, nil) }
        return (nil, "null_on_non_nullable")
    }

    switch entry.fieldType {
    case .bool:
        if let b = value as? Bool { return (b, nil) }
        if let s = value as? String {
            if s == "true" { return (true, nil) }
            if s == "false" { return (false, nil) }
        }
        return (nil, "type_mismatch")

    case .number:
        // Reject Bool before trying numeric coercion
        if value is Bool { return (nil, "type_mismatch") }
        if let n = value as? Double { return (n, nil) }
        if let n = value as? Int { return (Double(n), nil) }
        if let n = value as? NSNumber {
            if !(value is Bool) { return (n.doubleValue, nil) }
        }
        if let s = value as? String, isNumberString(s), let n = Double(s) {
            return (n, nil)
        }
        return (nil, "type_mismatch")

    case .string:
        if let s = value as? String { return (s, nil) }
        return (nil, "type_mismatch")

    case .color:
        if let s = value as? String, isHexColor(s) { return (s, nil) }
        return (nil, "type_mismatch")

    case .enumType(let allowed):
        if let s = value as? String, allowed.contains(s) { return (s, nil) }
        return (nil, "enum_value_not_in_values")

    case .list:
        if let arr = value as? [Any] { return (arr, nil) }
        return (nil, "type_mismatch")

    case .object:
        if let dict = value as? [String: Any] { return (dict, nil) }
        return (nil, "type_mismatch")
    }
}

// MARK: - Schema-driven set:

/// Apply a schema-driven `set:` effect from already-evaluated values.
///
/// `setMap` values are native Swift types (not expression strings).
/// Coercion and scope resolution happen here; expression evaluation
/// is the caller's responsibility.
func applySetSchemadriven(
    _ setMap: [String: Any],
    store: StateStore,
    diagnostics: inout [Diagnostic],
    activePanel: String? = nil
) {
    let resolvedPanel = activePanel ?? store.getActivePanelId()
    var pending: [(String, String, Any?)] = []  // (scope, field, value)

    for (key, value) in setMap {
        let resolved = resolveKey(key, activePanel: resolvedPanel, store: store)
        switch resolved {
        case .notFound:
            diagnostics.append(Diagnostic(level: "warning", key: key, reason: "unknown_key"))
        case .ambiguous:
            diagnostics.append(Diagnostic(level: "error", key: key, reason: "ambiguous_key"))
        case .found(let scope, let fieldName, let entry):
            if !entry.writable {
                diagnostics.append(Diagnostic(level: "warning", key: key, reason: "field_not_writable"))
                continue
            }
            let (coerced, error) = coerceValue(value, entry: entry)
            if let reason = error {
                diagnostics.append(Diagnostic(level: "error", key: key, reason: reason))
            } else {
                pending.append((scope, fieldName, coerced))
            }
        }
    }

    // Apply all successful writes as a batch
    for (scope, fieldName, value) in pending {
        if scope == "state" {
            store.set(fieldName, value)
        } else {
            let panelId = String(scope.dropFirst("panel:".count))
            store.setPanel(panelId, fieldName, value)
        }
    }
}

// MARK: - Key resolution (mirrors SET_EFFECT.md §4)

private enum ResolvedKey {
    case notFound
    case ambiguous
    case found(scope: String, fieldName: String, entry: SchemaEntry)
}

private func resolveKey(_ key: String, activePanel: String?, store: StateStore) -> ResolvedKey {
    if key.contains(".") {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        let prefix = parts[0]
        let rest = parts[1]
        let panelId = prefix == "panel" ? activePanel : prefix
        guard let pid = panelId else { return .notFound }
        // Panel fields are validated via the store's panel state schema.
        // For now, accept any key that exists in the panel's state.
        _ = store.getPanel(pid, rest)  // panel exists?
        // Use global schema for panel fields too (same type system)
        if let entry = getSchemaEntry(rest) {
            return .found(scope: "panel:\(pid)", fieldName: rest, entry: entry)
        }
        return .notFound
    }

    // Bare key: resolve against the global schema.
    //
    // Shadowing note: since Swift/Python/OCaml use a flat global schema
    // (no per-panel schemas), bare keys found in the global schema
    // always resolve to state scope, regardless of the active panel.
    if let entry = getSchemaEntry(key) {
        return .found(scope: "state", fieldName: key, entry: entry)
    }
    return .notFound
}
