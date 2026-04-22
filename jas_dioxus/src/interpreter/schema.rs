//! Schema table for workspace state fields.
//!
//! Mirrors the field definitions in `workspace/state.yaml` for the
//! schema-driven `set:` effect. Each field has a declared type, nullability
//! flag, and writable flag. The engine validates and coerces set: values
//! before dispatching to AppState setters.

use serde_json;

// ---------------------------------------------------------------------------
// Types

#[derive(Debug, Clone, PartialEq)]
pub enum FieldType {
    Bool,
    Number,
    String,
    Color,
    Enum(&'static [&'static str]),
    List,
    Object,
}

#[derive(Debug, Clone)]
pub struct SchemaEntry {
    pub field_type: FieldType,
    pub nullable: bool,
    pub writable: bool,
}

impl SchemaEntry {
    const fn new(field_type: FieldType, nullable: bool, writable: bool) -> Self {
        Self { field_type, nullable, writable }
    }
}

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub level: &'static str, // "warning" or "error"
    pub key: std::string::String,
    pub reason: &'static str,
}

impl Diagnostic {
    pub fn warning(key: impl Into<std::string::String>, reason: &'static str) -> Self {
        Self { level: "warning", key: key.into(), reason }
    }
    pub fn error(key: impl Into<std::string::String>, reason: &'static str) -> Self {
        Self { level: "error", key: key.into(), reason }
    }
}

// ---------------------------------------------------------------------------
// Schema — mirrors workspace/state.yaml

const ACTIVE_TOOL_VALUES: &[&str] = &[
    "selection", "partial_selection", "interior_selection",
    "pen", "add_anchor", "delete_anchor", "anchor_point",
    "pencil", "path_eraser", "smooth",
    "type", "type_on_path",
    "line", "rect", "rounded_rect", "polygon", "star", "lasso",
];

const STROKE_CAP_VALUES: &[&str] = &["butt", "round", "square"];
const STROKE_JOIN_VALUES: &[&str] = &["miter", "round", "bevel"];
const STROKE_ALIGN_VALUES: &[&str] = &["center", "inside", "outside"];
const STROKE_ARROWHEAD_VALUES: &[&str] = &[
    "none", "simple_arrow", "open_arrow", "closed_arrow", "stealth_arrow",
    "barbed_arrow", "half_arrow_upper", "half_arrow_lower",
    "circle", "open_circle", "square", "open_square",
    "diamond", "open_diamond", "slash",
];
const STROKE_ARROW_ALIGN_VALUES: &[&str] = &["tip_at_end", "center_at_end"];
const STROKE_PROFILE_VALUES: &[&str] = &[
    "uniform", "taper_both", "taper_start", "taper_end", "bulge", "pinch",
];
const GRADIENT_TYPE_VALUES: &[&str] = &["linear", "radial", "freeform"];
const GRADIENT_METHOD_VALUES: &[&str] = &["classic", "smooth", "points", "lines"];
const GRADIENT_STROKE_SUB_MODE_VALUES: &[&str] = &["within", "along", "across"];

/// Look up the schema entry for a global `state:` field by name.
///
/// Returns `None` for keys not declared in `workspace/state.yaml` (unknown key).
pub fn get_entry(key: &str) -> Option<SchemaEntry> {
    use FieldType::*;
    match key {
        "active_tool" => Some(SchemaEntry::new(Enum(ACTIVE_TOOL_VALUES), false, true)),
        "fill_color" => Some(SchemaEntry::new(Color, true, true)),
        "stroke_color" => Some(SchemaEntry::new(Color, true, true)),
        "stroke_width" => Some(SchemaEntry::new(Number, false, true)),
        "stroke_cap" => Some(SchemaEntry::new(Enum(STROKE_CAP_VALUES), false, true)),
        "stroke_join" => Some(SchemaEntry::new(Enum(STROKE_JOIN_VALUES), false, true)),
        "stroke_miter_limit" => Some(SchemaEntry::new(Number, false, true)),
        "stroke_align" => Some(SchemaEntry::new(Enum(STROKE_ALIGN_VALUES), false, true)),
        "stroke_dashed" => Some(SchemaEntry::new(Bool, false, true)),
        "stroke_dash_1" => Some(SchemaEntry::new(Number, false, true)),
        "stroke_gap_1" => Some(SchemaEntry::new(Number, false, true)),
        "stroke_dash_2" => Some(SchemaEntry::new(Number, true, true)),
        "stroke_gap_2" => Some(SchemaEntry::new(Number, true, true)),
        "stroke_dash_3" => Some(SchemaEntry::new(Number, true, true)),
        "stroke_gap_3" => Some(SchemaEntry::new(Number, true, true)),
        "stroke_start_arrowhead" => Some(SchemaEntry::new(Enum(STROKE_ARROWHEAD_VALUES), false, true)),
        "stroke_end_arrowhead" => Some(SchemaEntry::new(Enum(STROKE_ARROWHEAD_VALUES), false, true)),
        "stroke_start_arrowhead_scale" => Some(SchemaEntry::new(Number, false, true)),
        "stroke_end_arrowhead_scale" => Some(SchemaEntry::new(Number, false, true)),
        "stroke_link_arrowhead_scale" => Some(SchemaEntry::new(Bool, false, true)),
        "stroke_arrow_align" => Some(SchemaEntry::new(Enum(STROKE_ARROW_ALIGN_VALUES), false, true)),
        "stroke_profile" => Some(SchemaEntry::new(Enum(STROKE_PROFILE_VALUES), false, true)),
        "stroke_profile_flipped" => Some(SchemaEntry::new(Bool, false, true)),
        // Gradient panel state keys (Phase 5 follow-up).
        "gradient_type" => Some(SchemaEntry::new(Enum(GRADIENT_TYPE_VALUES), false, true)),
        "gradient_angle" => Some(SchemaEntry::new(Number, false, true)),
        "gradient_aspect_ratio" => Some(SchemaEntry::new(Number, false, true)),
        "gradient_method" => Some(SchemaEntry::new(Enum(GRADIENT_METHOD_VALUES), false, true)),
        "gradient_dither" => Some(SchemaEntry::new(Bool, false, true)),
        "gradient_stroke_sub_mode" => Some(SchemaEntry::new(Enum(GRADIENT_STROKE_SUB_MODE_VALUES), false, true)),
        "fill_on_top" => Some(SchemaEntry::new(Bool, false, true)),
        "toolbar_visible" => Some(SchemaEntry::new(Bool, false, true)),
        "canvas_visible" => Some(SchemaEntry::new(Bool, false, true)),
        "dock_visible" => Some(SchemaEntry::new(Bool, false, true)),
        "canvas_maximized" => Some(SchemaEntry::new(Bool, false, true)),
        "dock_collapsed" => Some(SchemaEntry::new(Bool, false, true)),
        "active_tab" => Some(SchemaEntry::new(Number, false, true)),
        "tab_count" => Some(SchemaEntry::new(Number, false, true)),
        // Internal — writable: false
        "_drag_pane" => Some(SchemaEntry::new(String, true, false)),
        "_drag_offset_x" => Some(SchemaEntry::new(Number, false, false)),
        "_drag_offset_y" => Some(SchemaEntry::new(Number, false, false)),
        "_resize_pane" => Some(SchemaEntry::new(String, true, false)),
        "_resize_edge" => Some(SchemaEntry::new(String, true, false)),
        "_resize_start_x" => Some(SchemaEntry::new(Number, false, false)),
        "_resize_start_y" => Some(SchemaEntry::new(Number, false, false)),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Coercion

/// Coerce a JSON value to match the schema entry's declared type.
///
/// Returns `Ok(coerced)` on success; `Err(reason)` on failure.
pub fn coerce_value(
    val: &serde_json::Value,
    entry: &SchemaEntry,
) -> Result<serde_json::Value, &'static str> {
    if val.is_null() {
        return if entry.nullable {
            Ok(serde_json::Value::Null)
        } else {
            Err("null_on_non_nullable")
        };
    }

    match &entry.field_type {
        FieldType::Bool => {
            if let Some(b) = val.as_bool() {
                return Ok(serde_json::json!(b));
            }
            if let Some(s) = val.as_str() {
                if s == "true" { return Ok(serde_json::json!(true)); }
                if s == "false" { return Ok(serde_json::json!(false)); }
            }
            Err("type_mismatch")
        }
        FieldType::Number => {
            // Reject JSON booleans (they'd otherwise pass as_f64 in serde_json)
            if val.is_boolean() { return Err("type_mismatch"); }
            if let Some(n) = val.as_f64() {
                return Ok(serde_json::json!(n));
            }
            if let Some(s) = val.as_str() {
                if let Ok(n) = s.parse::<f64>() {
                    return Ok(serde_json::json!(n));
                }
            }
            Err("type_mismatch")
        }
        FieldType::String => {
            if let Some(s) = val.as_str() {
                return Ok(serde_json::json!(s));
            }
            Err("type_mismatch")
        }
        FieldType::Color => {
            if let Some(s) = val.as_str() {
                if is_hex_color(s) {
                    return Ok(serde_json::json!(s));
                }
            }
            Err("type_mismatch")
        }
        FieldType::Enum(allowed) => {
            if let Some(s) = val.as_str() {
                if allowed.contains(&s) {
                    return Ok(serde_json::json!(s));
                }
            }
            Err("enum_value_not_in_values")
        }
        FieldType::List => {
            if val.is_array() {
                return Ok(val.clone());
            }
            Err("type_mismatch")
        }
        FieldType::Object => {
            if val.is_object() {
                return Ok(val.clone());
            }
            Err("type_mismatch")
        }
    }
}

fn is_hex_color(s: &str) -> bool {
    let s = s.strip_prefix('#').unwrap_or(s);
    s.len() == 6 && s.chars().all(|c| c.is_ascii_hexdigit())
}

// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // --- coerce_value: bool ---

    #[test]
    fn coerce_bool_from_json_bool() {
        let entry = get_entry("fill_on_top").unwrap();
        assert_eq!(coerce_value(&json!(false), &entry).unwrap(), json!(false));
        assert_eq!(coerce_value(&json!(true), &entry).unwrap(), json!(true));
    }

    #[test]
    fn coerce_bool_from_string() {
        let entry = get_entry("fill_on_top").unwrap();
        assert_eq!(coerce_value(&json!("true"), &entry).unwrap(), json!(true));
        assert_eq!(coerce_value(&json!("false"), &entry).unwrap(), json!(false));
    }

    #[test]
    fn coerce_bool_rejects_invalid() {
        let entry = get_entry("fill_on_top").unwrap();
        assert!(coerce_value(&json!("yes"), &entry).is_err());
        assert!(coerce_value(&json!(1), &entry).is_err());
    }

    // --- coerce_value: number ---

    #[test]
    fn coerce_number_from_json_number() {
        let entry = get_entry("stroke_width").unwrap();
        assert_eq!(coerce_value(&json!(3.5), &entry).unwrap(), json!(3.5));
    }

    #[test]
    fn coerce_number_from_string() {
        let entry = get_entry("stroke_width").unwrap();
        assert_eq!(coerce_value(&json!("2.5"), &entry).unwrap(), json!(2.5));
    }

    #[test]
    fn coerce_number_rejects_bool() {
        let entry = get_entry("stroke_width").unwrap();
        assert_eq!(coerce_value(&json!(true), &entry).unwrap_err(), "type_mismatch");
    }

    // --- coerce_value: color ---

    #[test]
    fn coerce_color_valid_hex() {
        let entry = get_entry("fill_color").unwrap();
        assert_eq!(coerce_value(&json!("#ff0000"), &entry).unwrap(), json!("#ff0000"));
    }

    #[test]
    fn coerce_color_null_nullable() {
        let entry = get_entry("fill_color").unwrap();
        assert_eq!(coerce_value(&serde_json::Value::Null, &entry).unwrap(), serde_json::Value::Null);
    }

    #[test]
    fn coerce_color_rejects_invalid_hex() {
        let entry = get_entry("fill_color").unwrap();
        assert!(coerce_value(&json!("red"), &entry).is_err());
        assert!(coerce_value(&json!("#gg0000"), &entry).is_err());
    }

    // --- coerce_value: enum ---

    #[test]
    fn coerce_enum_valid() {
        let entry = get_entry("stroke_cap").unwrap();
        assert_eq!(coerce_value(&json!("round"), &entry).unwrap(), json!("round"));
    }

    #[test]
    fn coerce_enum_invalid() {
        let entry = get_entry("stroke_cap").unwrap();
        assert_eq!(
            coerce_value(&json!("triangle"), &entry).unwrap_err(),
            "enum_value_not_in_values",
        );
    }

    // --- null on non-nullable ---

    #[test]
    fn null_on_non_nullable_is_error() {
        let entry = get_entry("stroke_width").unwrap();
        assert_eq!(
            coerce_value(&serde_json::Value::Null, &entry).unwrap_err(),
            "null_on_non_nullable",
        );
    }

    // --- writable flag ---

    #[test]
    fn drag_pane_is_not_writable() {
        let entry = get_entry("_drag_pane").unwrap();
        assert!(!entry.writable);
    }

    #[test]
    fn fill_color_is_writable() {
        let entry = get_entry("fill_color").unwrap();
        assert!(entry.writable);
    }

    // --- unknown key ---

    #[test]
    fn unknown_key_returns_none() {
        assert!(get_entry("nonexistent_field").is_none());
    }
}
