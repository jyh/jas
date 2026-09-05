//! Panel menu item types.

/// A menu item in a panel's hamburger menu.
#[derive(Debug, Clone, PartialEq)]
pub enum PanelMenuItem {
    /// A plain action: label, command string, optional shortcut hint.
    Action {
        label: &'static str,
        command: &'static str,
        shortcut: &'static str,
    },
    /// A toggle (checkbox) item.
    Toggle {
        label: &'static str,
        command: &'static str,
    },
    /// A radio-group item; items sharing the same `group` are mutually exclusive.
    Radio {
        label: &'static str,
        command: &'static str,
        group: &'static str,
    },
    /// Horizontal separator line.
    Separator,
}

impl PanelMenuItem {
    /// The command an item dispatches, or `None` for a separator.
    /// Lets per-panel tests probe menu content without naming the
    /// `Action/Toggle/Radio` variants (which count against the
    /// genericity metric).
    pub fn command(&self) -> Option<&str> {
        match self {
            PanelMenuItem::Action { command, .. }
            | PanelMenuItem::Toggle { command, .. }
            | PanelMenuItem::Radio { command, .. } => Some(command),
            PanelMenuItem::Separator => None,
        }
    }

    /// The display label of an item, or `None` for a separator.
    pub fn label(&self) -> Option<&str> {
        match self {
            PanelMenuItem::Action { label, .. }
            | PanelMenuItem::Toggle { label, .. }
            | PanelMenuItem::Radio { label, .. } => Some(label),
            PanelMenuItem::Separator => None,
        }
    }

    /// Whether this item is a separator.
    pub fn is_separator(&self) -> bool {
        matches!(self, PanelMenuItem::Separator)
    }
}

/// Build a panel's hamburger menu from the compiled workspace bundle
/// (the panel YAML `menu:` array) rather than a hand-written native list.
/// The YAML is the single source of truth (review #15); this reader is
/// what each panel's `menu_items()` now delegates to.
///
/// PanelMenuItem keeps its `&'static str` fields so the renderer and the
/// `matches!(.., command: "x")` panel tests stay unchanged. We therefore
/// leak the small, finite, app-lifetime menu strings once per panel and
/// cache the built list, keeping the leak bounded and repeat opens cheap.
pub fn menu_items_from_yaml(content_id: &str) -> Vec<PanelMenuItem> {
    static CACHE: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<String, Vec<PanelMenuItem>>>,
    > = std::sync::OnceLock::new();
    let cache = CACHE.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()));
    let mut guard = cache.lock().unwrap();
    if let Some(items) = guard.get(content_id) {
        return items.clone();
    }
    let items = build_menu_items(content_id);
    guard.insert(content_id.to_string(), items.clone());
    items
}

fn build_menu_items(content_id: &str) -> Vec<PanelMenuItem> {
    let leak = |s: &str| -> &'static str { Box::leak(s.to_string().into_boxed_str()) };
    let Some(ws) = crate::interpreter::workspace::Workspace::load() else {
        return Vec::new();
    };
    let menu = ws.panel_menu(content_id);

    // A radio group is a set of menu entries that share the same `action`
    // (e.g. every "set_color_panel_mode" item, or every
    // "set_swatch_thumbnail_size" item). The YAML doesn't carry an explicit
    // `group:` key — sameness of the action *is* the grouping — so we count
    // action occurrences to tell a one-off checkbox (Toggle) apart from a
    // member of a mutually-exclusive set (Radio).
    let mut action_counts: std::collections::HashMap<&str, usize> =
        std::collections::HashMap::new();
    for e in &menu {
        if let Some(action) = e.as_object().and_then(|o| o.get("action")).and_then(|a| a.as_str()) {
            *action_counts.entry(action).or_insert(0) += 1;
        }
    }

    menu.iter()
        .filter_map(|e| {
            // A bare `separator` YAML item compiles to the JSON string "separator".
            if e.as_str() == Some("separator") {
                return Some(PanelMenuItem::Separator);
            }
            let obj = e.as_object()?;
            let label = leak(obj.get("label")?.as_str()?);
            let action = obj.get("action").and_then(|a| a.as_str());
            // A menu entry is a radio-group member when its `action` recurs
            // across the menu (the YAML expresses grouping by action sameness,
            // not an explicit `group:` key).
            let is_radio_member =
                action.map(|a| action_counts.get(a).copied().unwrap_or(0) > 1).unwrap_or(false);

            // Radio members share one action, so we fold their `params` values
            // into the command (`set_color_panel_mode:grayscale`,
            // `set_swatch_thumbnail_size:small`) to keep them distinguishable
            // when the menu view dispatches the bare command with no params.
            // Every other entry keeps its action verbatim — folding params
            // there would corrupt single-action commands like
            // `close_panel` (params: { panel: color }).
            let command: &str = if is_radio_member {
                leak(&command_with_params(obj))
            } else {
                leak(action.unwrap_or(""))
            };

            // A `checked:` / `checked_when:` expression marks a stateful item:
            // a radio-group member, or a standalone checkbox (Toggle). The
            // radio group key is the action name.
            let has_checked = obj.contains_key("checked") || obj.contains_key("checked_when");
            Some(if has_checked && is_radio_member {
                PanelMenuItem::Radio { label, command, group: leak(action.unwrap_or("")) }
            } else if has_checked {
                PanelMenuItem::Toggle { label, command }
            } else {
                // Plain actions, dynamic submenus (`type: submenu`, which carry
                // an explicit `action:` so the menu view's special-case host
                // — keyed on the command — fires), and disabled placeholders
                // (no `action:`, gated off by the panel's `is_enabled`) all
                // surface as Action.
                PanelMenuItem::Action { label, command, shortcut: "" }
            })
        })
        .collect()
}

/// Build the runtime command for a menu entry: the `action` string with any
/// `params` values appended as `:value` segments (in the compiled JSON's
/// param order). Entries with no action produce an empty command (disabled
/// placeholders). This lets several radio members share one YAML `action`
/// yet dispatch to distinct native commands without threading params through
/// the menu view.
fn command_with_params(obj: &serde_json::Map<String, serde_json::Value>) -> String {
    let action = obj.get("action").and_then(|a| a.as_str()).unwrap_or("");
    let mut cmd = action.to_string();
    if let Some(params) = obj.get("params").and_then(|p| p.as_object()) {
        for v in params.values() {
            let seg = match v {
                serde_json::Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            cmd.push(':');
            cmd.push_str(&seg);
        }
    }
    cmd
}

/// The panel CONTENT id a YAML `panel:` reference names.
///
/// Actions name panels by their short kind (`panel: brushes`) while every panel
/// map in the bundle — and therefore `panel_state_defaults`, the panel-menu
/// lookup and this app's generic panel-state table — is keyed by the content id
/// (`brushes_panel_content`). Appending the suffix when the caller passes the
/// short form is the same rule the reference's `StateStore` and JasSwift's
/// `StateStore` apply at their boundary (`panel_content_id` /
/// `panelContentId`), so a write lands in the bucket the YAML's `panel.<key>`
/// reads from in every interpreter. An id that already carries the suffix
/// passes through, which is what lets a fixture address a panel by one
/// unambiguous spelling — and `panel_state_writes.json`'s `write_as` field
/// is where the SHORT spelling is driven through all three.
pub fn panel_content_id(raw: &str) -> String {
    if raw.ends_with("_panel_content") {
        raw.to_string()
    } else {
        format!("{raw}_panel_content")
    }
}

/// Recover the `(action, params)` a panel-menu entry declares from the runtime
/// command the menu view dispatches.
///
/// `build_menu_items` FOLDS a radio member's params into its command
/// (`set_brush_view_mode:list`) so several rows can share one YAML action and
/// still dispatch distinctly. Something has to unfold it again, and doing it
/// here — by finding the entry the fold came from and returning its declared
/// `params` map verbatim — means a panel's dispatch does not have to restate
/// the panel's own parameter names in native code. `brushes_panel::dispatch`
/// used to hand the FOLDED string to `dispatch_action` with an empty params
/// map: no action of that name existed, so every Brushes menu row was a silent
/// no-op, and `param.view_mode` would have been null even if one had.
pub fn action_and_params(
    content_id: &str,
    cmd: &str,
) -> Option<(String, serde_json::Map<String, serde_json::Value>)> {
    let entry = menu_entry(content_id, cmd)?;
    let action = entry.get("action").and_then(|a| a.as_str())?.to_string();
    let params = entry
        .get("params")
        .and_then(|p| p.as_object())
        .cloned()
        .unwrap_or_default();
    Some((action, params))
}

/// The bundle menu entry whose runtime command is `cmd`, matched with the SAME
/// fold `build_menu_items` applies (`command_with_params` for radio members,
/// the bare action otherwise), so a caller holding a `PanelMenuItem`'s command
/// can always find its own entry.
fn menu_entry(
    content_id: &str,
    cmd: &str,
) -> Option<serde_json::Map<String, serde_json::Value>> {
    if cmd.is_empty() {
        return None;
    }
    let ws = crate::interpreter::workspace::Workspace::load()?;
    let menu = ws.panel_menu(content_id);
    let mut action_counts: std::collections::HashMap<&str, usize> =
        std::collections::HashMap::new();
    for e in &menu {
        if let Some(action) = e.as_object().and_then(|o| o.get("action")).and_then(|a| a.as_str()) {
            *action_counts.entry(action).or_insert(0) += 1;
        }
    }
    for e in &menu {
        let obj = match e.as_object() {
            Some(o) => o,
            None => continue,
        };
        let action = obj.get("action").and_then(|a| a.as_str());
        let is_radio_member =
            action.map(|a| action_counts.get(a).copied().unwrap_or(0) > 1).unwrap_or(false);
        let entry_cmd: String = if is_radio_member {
            command_with_params(obj)
        } else {
            action.unwrap_or("").to_string()
        };
        if entry_cmd == cmd {
            return Some(obj.clone());
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Generic panel-menu CHECKED state
// ---------------------------------------------------------------------------

/// The `checked_when:` (or `checked:`) predicate of the panel-menu entry whose
/// runtime command is `cmd`, or `None` when there is no such entry or it
/// declares no predicate.
///
/// The command is matched with the SAME fold `build_menu_items` applies
/// (`command_with_params` for radio members, the bare action otherwise), so a
/// caller holding a `PanelMenuItem`'s command can always find its own entry.
///
/// Both spellings are read because the panel-menu vocabulary uses both:
/// `workspace/panels/{brushes,color,opacity,stroke,swatches}.yaml` write
/// `checked_when:`, while `{align,character,paragraph}.yaml` write `checked:`.
/// `build_menu_items` above already reads both to decide Toggle vs Radio, so
/// reading only one here would leave three panels' check marks dead — the
/// exact defect this path exists to close. No expression feature is added:
/// the two keys carry the same grammar and are evaluated the same way.
pub fn checked_expr(content_id: &str, cmd: &str) -> Option<String> {
    let entry = menu_entry(content_id, cmd)?;
    entry
        .get("checked_when")
        .or_else(|| entry.get("checked"))
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
}

/// Whether the panel-menu entry for `cmd` is checked, evaluating its bundle
/// predicate against `ctx` through the SHARED menu-state evaluator.
///
/// An entry with no predicate — and a command that names no entry — is not
/// checked, matching `menu_state`'s `checked: null` for an item with no
/// `checked_when`.
pub fn is_checked_from_yaml(content_id: &str, cmd: &str, ctx: &serde_json::Value) -> bool {
    match checked_expr(content_id, cmd) {
        Some(expr) => crate::interpreter::menu_state::eval_bool(&expr, ctx),
        None => false,
    }
}

// ---------------------------------------------------------------------------
// Generic panel-menu ENABLED state
// ---------------------------------------------------------------------------

/// The `enabled_when:` predicate of the panel-menu entry whose runtime command
/// is `cmd`, or `None` when there is no such entry or it declares none.
///
/// Matched with the SAME fold `build_menu_items` applies, exactly as
/// `checked_expr` is. One spelling only: the panel-menu vocabulary writes
/// `enabled_when:` everywhere (the menubar's word too), and the only static
/// `disabled: true` in a panel menu sits on a row with no `action:` and so no
/// command to look up.
pub fn enabled_expr(content_id: &str, cmd: &str) -> Option<String> {
    let entry = menu_entry(content_id, cmd)?;
    entry
        .get("enabled_when")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
}

/// Whether the panel-menu entry for `cmd` is enabled, evaluating its bundle
/// predicate against `ctx` through the SHARED menu-state evaluator.
///
/// An entry with no predicate — and a command that names no entry — is
/// enabled, matching `menu_state`'s `enabled: true` default for an item with
/// no `enabled_when`. Before this the answer came from two native hooks
/// (`color_panel::is_enabled`, `swatches_panel::is_enabled`) that restated in
/// Rust two rules the YAML already states, and `true` for the other forty-odd
/// rows, which were therefore never evaluated live in EITHER active port.
pub fn is_enabled_from_yaml(content_id: &str, cmd: &str, ctx: &serde_json::Value) -> bool {
    match enabled_expr(content_id, cmd) {
        Some(expr) => crate::interpreter::menu_state::eval_bool(&expr, ctx),
        None => true,
    }
}

/// Build the expression context a panel's menu predicates are evaluated
/// against: the panel's own state table as `panel`, the `preferences` tier the
/// bundle ships, the live `state` scope, the `active_document` view and the
/// OPACITY.md selection predicates at top level — the namespaces the bundle's
/// panel-menu `enabled_when` / `checked_when` rows read, censused by
/// `panels::tests::every_panel_menu_predicate_read_is_published_to_the_menu_context`.
///
/// The last three are the SAME builders the panel BODY renders against
/// (`dock_panel`'s eval map), so a predicate reads one fact one way whether it
/// sits in the hamburger menu or in a widget's `bind:`. Until they were added
/// the menu context published `panel` and `preferences` alone, and every
/// `enabled_when` naming `state.`, `active_document.` or `selection_has_mask`
/// read null — invisible while `panel_is_enabled` never consulted the YAML.
///
/// `panel` starts from the bundle's declared state defaults for the panel and
/// is then overlaid with whatever this app holds LIVE for that panel. That
/// overlay is the whole of what the fourteen deleted per-panel `is_checked`
/// hooks used to encode, written once and named per panel instead of fourteen
/// times as native `match cmd` arms — jas_dioxus keeps its panel state in typed
/// `AppState` slots rather than a generic panel store, so something has to
/// publish those slots into the `panel` namespace, and this is that one place.
///
/// The scope is built in three layers, weakest first: the bundle's declared
/// `state:` defaults, then whatever the GENERIC per-panel table
/// (`AppState::panel_state`) holds for this panel, then the typed `AppState`
/// slots `live_panel_state` publishes. The generic layer is the reference's
/// `StateStore` panel scope and JasSwift's shared panel store, in this app; the
/// typed layer wins over it because for the five keys that have both, the typed
/// slot is what this app's panel BODY renders from and what a native panel
/// dispatch writes — and `apply_typed_panel_slot` routes the declared write
/// there rather than into the table, so the two never disagree.
///
/// A panel with neither contributes nothing and evaluates against the bundle
/// defaults, which is now the correct answer for a panel nobody has touched
/// rather than, as it was, the only answer a panel could ever give.
pub fn panel_menu_ctx(
    content_id: &str,
    st: &crate::workspace::app_state::AppState,
) -> serde_json::Value {
    use serde_json::Value as J;
    let mut panel: serde_json::Map<String, J> = crate::interpreter::workspace::Workspace::load()
        .map(|ws| ws.panel_state_defaults(content_id).into_iter().collect())
        .unwrap_or_default();
    if let Some(stored) = st.panel_state.get(content_id) {
        for (k, v) in stored {
            panel.insert(k.clone(), v.clone());
        }
    }
    for (k, v) in live_panel_state(content_id, st) {
        panel.insert(k, v);
    }
    let preferences = crate::interpreter::workspace::Workspace::load()
        .and_then(|ws| ws.data().get("preferences").cloned())
        .unwrap_or(J::Null);
    let state = crate::workspace::dock_panel::build_live_state_map(st);
    let active_document = crate::interpreter::renderer::build_active_document_view(st);
    let mut ctx = serde_json::Map::new();
    ctx.insert("panel".into(), J::Object(panel));
    ctx.insert("preferences".into(), preferences);
    ctx.insert("state".into(), J::Object(state));
    ctx.insert("active_document".into(), active_document);
    // `selection_has_mask` and its siblings sit at TOP level, as the body's
    // eval map places them, so `enabled_when: "!selection_has_mask"` reads the
    // same key from both surfaces.
    for (k, v) in crate::workspace::dock_panel::build_selection_predicates(st) {
        ctx.insert(k, v);
    }
    J::Object(ctx)
}

/// The `(content_id, key)` pairs a panel-named `set_panel_state` write is
/// routed into a TYPED `AppState` slot for, rather than into the generic
/// per-panel table.
///
/// This is the write-side twin of `live_panel_state`: that function says where
/// this app READS a declared panel key from, this one says where it WRITES one
/// to, and a key claimed here and unpublished there is a write no reader can
/// see. `panels::tests::every_typed_write_target_is_published_to_the_menu_context`
/// holds the two together.
pub fn typed_panel_slot_keys() -> Vec<(&'static str, &'static str)> {
    vec![
        ("color_panel_content", "mode"),
        ("swatches_panel_content", "thumbnail_size"),
        ("symbols_panel_content", "selected_symbol"),
        ("concepts_panel_content", "selected_concept"),
        ("layers_panel_content", "type_filter"),
    ]
}

/// The live `panel.*` values this app holds for `content_id`, keyed exactly as
/// the panel's YAML state table declares them.
///
/// Each arm replaces one deleted native `is_checked` hook, and is a statement
/// about STORAGE (where this app keeps the value) rather than about menus — the
/// predicate that reads it stays in the YAML.
fn live_panel_state(
    content_id: &str,
    st: &crate::workspace::app_state::AppState,
) -> Vec<(String, serde_json::Value)> {
    use serde_json::Value as J;
    let s = |v: &str| J::String(v.to_string());
    let b = J::Bool;
    let pairs: Vec<(&str, J)> = match content_id {
        "color_panel_content" => vec![("mode", s(st.color_panel_mode.slug()))],
        "stroke_panel_content" => vec![
            ("cap", s(&st.stroke_panel.cap)),
            ("join", s(&st.stroke_panel.join)),
        ],
        "swatches_panel_content" => vec![
            ("thumbnail_size", s(&st.swatches_panel.thumbnail_size)),
            // `panel.selected_swatches.length > 0` gates Duplicate / Delete
            // Swatch — the rule `swatches_panel::is_enabled` restated natively
            // until the generic path read this slot.
            (
                "selected_swatches",
                J::Array(st.swatches_panel.selected_swatches.iter().map(|&i| J::from(i)).collect()),
            ),
        ],
        "opacity_panel_content" => vec![
            ("thumbnails_hidden", b(st.opacity_panel.thumbnails_hidden)),
            ("options_shown", b(st.opacity_panel.options_shown)),
            ("new_masks_clipping", b(st.opacity_panel.new_masks_clipping)),
            ("new_masks_inverted", b(st.opacity_panel.new_masks_inverted)),
        ],
        "character_panel_content" => vec![
            ("snap_to_glyph_visible", b(st.character_panel.snap_to_glyph_visible)),
            ("all_caps", b(st.character_panel.all_caps)),
            ("small_caps", b(st.character_panel.small_caps)),
            ("superscript", b(st.character_panel.superscript)),
            ("subscript", b(st.character_panel.subscript)),
        ],
        "paragraph_panel_content" => {
            vec![("hanging_punctuation", b(st.paragraph_panel.hanging_punctuation))]
        }
        "align_panel_content" => vec![
            ("use_preview_bounds", b(st.align_panel.use_preview_bounds)),
            ("align_to", s(st.align_panel.align_to.as_str())),
        ],
        "properties_panel_content" => {
            vec![("prop_constrain", b(st.properties_constrain))]
        }
        // The three below carry no `checked_when` today. They are here because
        // they are WRITE targets (`typed_panel_slot_keys`), and a write whose
        // value is an expression over the panel's own scope — as
        // `solo_layers_type_filter`'s is — has to be able to read that scope
        // back. Publishing them is what makes the read and the write agree.
        "symbols_panel_content" => vec![(
            "selected_symbol",
            st.symbols_selected.clone().map(J::String).unwrap_or(J::Null),
        )],
        "concepts_panel_content" => vec![(
            "selected_concept",
            st.concepts_selected.clone().map(J::String).unwrap_or(J::Null),
        )],
        "layers_panel_content" => {
            // A HashSet has no order and the bundle's only expression that
            // indexes this list guards on `length == 1`
            // (`solo_layers_type_filter`), so any order answers the same; sorted
            // so the published scope is at least deterministic.
            let mut types: Vec<String> = st.layers_type_filter.iter().cloned().collect();
            types.sort();
            vec![
                ("type_filter", J::Array(types.into_iter().map(J::String).collect())),
                ("search_query", s(&st.layers_search_query)),
                // The TREE selection, as the `__path__` markers the Group B
                // actions iterate (`panel.layers_panel_selection`) and the
                // keyboard rows index (`[0]`). The ONE name for it since
                // 2026-09-05; the declared default is `[]`, so without this
                // arm the scope would carry an empty list for any selection.
                (
                    "layers_panel_selection",
                    J::Array(
                        st.layers_panel_selection
                            .iter()
                            .map(|p| serde_json::json!({
                                "__path__": p.iter().map(|&i| i as u64).collect::<Vec<_>>()
                            }))
                            .collect(),
                    ),
                ),
                // "Exit Isolation Mode" reads `panel.isolation_stack.length`;
                // "Collect in New Layer" wants it EMPTY. Each entry is a path
                // of child indices, published as the YAML's list-of-lists.
                (
                    "isolation_stack",
                    J::Array(
                        st.layers_isolation_stack
                            .iter()
                            .map(|p| J::Array(p.iter().map(|&i| J::from(i)).collect()))
                            .collect(),
                    ),
                ),
            ]
        }
        _ => vec![],
    };
    pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Actions name a panel by its short kind (`panel: brushes`); every panel
    /// map in the bundle is keyed by the content id. The two spellings have to
    /// address ONE bucket, and the rule is JasSwift's: append the suffix when
    /// it is absent, pass an id that already carries it through.
    #[test]
    fn panel_content_id_normalises_both_spellings() {
        assert_eq!(panel_content_id("brushes"), "brushes_panel_content");
        assert_eq!(panel_content_id("brushes_panel_content"), "brushes_panel_content");
        assert_eq!(panel_content_id("swatches"), "swatches_panel_content");
    }

    /// The unfold `brushes_panel::dispatch` needs: a folded radio command back
    /// into the action the row declares AND the params it declares, so
    /// `param.view_mode` resolves. A non-radio row keeps its bare action and
    /// whatever params it declares (Brush Options carries `mode:`).
    #[test]
    fn action_and_params_unfolds_a_folded_radio_command() {
        let (action, params) =
            action_and_params("brushes_panel_content", "set_brush_view_mode:list")
                .expect("List View is a menu row");
        assert_eq!(action, "set_brush_view_mode");
        assert_eq!(params.get("view_mode").and_then(|v| v.as_str()), Some("list"));

        let (action, params) =
            action_and_params("brushes_panel_content", "set_brush_thumbnail_size:large")
                .expect("Large Thumbnail View is a menu row");
        assert_eq!(action, "set_brush_thumbnail_size");
        assert_eq!(params.get("size").and_then(|v| v.as_str()), Some("large"));

        // A single-action row is NOT folded, so its command is the bare action
        // and its params come along untouched.
        let (action, params) =
            action_and_params("brushes_panel_content", "toggle_brush_library_persistent")
                .expect("Make Persistent is a menu row");
        assert_eq!(action, "toggle_brush_library_persistent");
        assert!(params.is_empty());

        // A command that names no row (and the empty command a disabled
        // placeholder carries) resolves to nothing rather than to a wrong row.
        assert!(action_and_params("brushes_panel_content", "no_such_command").is_none());
        assert!(action_and_params("brushes_panel_content", "").is_none());
    }

    #[test]
    fn menu_items_from_yaml_reads_boolean_panel() {
        // The builder reads workspace/panels/boolean.yaml's `menu:` from the
        // compiled bundle and maps it to PanelMenuItem (7 actions + 3 separators).
        let items = menu_items_from_yaml("boolean_panel_content");
        assert!(
            items.iter().any(|i| matches!(
                i,
                PanelMenuItem::Action { command: "make_compound_shape", .. }
            )),
            "boolean menu should contain make_compound_shape; got {items:?}"
        );
        assert!(items.iter().any(|i| matches!(
            i,
            PanelMenuItem::Action { command: "close_panel", .. }
        )));
        assert_eq!(
            items.iter().filter(|i| matches!(i, PanelMenuItem::Separator)).count(),
            3
        );
        assert_eq!(items.len(), 10);
    }

    #[test]
    fn color_radio_members_fold_params_into_command() {
        // The Color panel's five mode rows all share `action:
        // set_color_panel_mode`, so the builder treats them as a radio
        // group and folds each `params.mode` value into the command,
        // keeping them distinguishable for the no-params menu dispatch.
        let items = menu_items_from_yaml("color_panel_content");
        let radios: Vec<(&str, &str)> = items.iter().filter_map(|i| match i {
            PanelMenuItem::Radio { command, group, .. } => Some((*command, *group)),
            _ => None,
        }).collect();
        assert!(radios.contains(&("set_color_panel_mode:grayscale", "set_color_panel_mode")));
        assert!(radios.contains(&("set_color_panel_mode:rgb", "set_color_panel_mode")));
        assert!(radios.contains(&("set_color_panel_mode:web_safe_rgb", "set_color_panel_mode")));
        // Plain actions keep their action verbatim (no param folding).
        assert!(items.iter().any(|i| matches!(
            i, PanelMenuItem::Action { command: "invert_active_color", .. })));
        // close_panel keeps its action even though the YAML carries
        // `params: { panel: color }`.
        assert!(items.iter().any(|i| matches!(
            i, PanelMenuItem::Action { command: "close_panel", .. })));
    }

    #[test]
    fn swatches_submenu_becomes_open_library_action() {
        // The dynamic "Open Swatch Library" submenu entry has an explicit
        // `action: open_swatch_library` in the YAML so the menu view's
        // submenu host (keyed on that command) still fires.
        let items = menu_items_from_yaml("swatches_panel_content");
        assert!(items.iter().any(|i| matches!(
            i, PanelMenuItem::Action { command: "open_swatch_library", .. })),
            "swatches menu should expose open_swatch_library host; got {items:?}");
        // Thumbnail-size rows are a radio group with folded params.
        let radios: Vec<&str> = items.iter().filter_map(|i| match i {
            PanelMenuItem::Radio { command, .. } => Some(*command),
            _ => None,
        }).collect();
        assert!(radios.contains(&"set_swatch_thumbnail_size:small"));
        assert!(radios.contains(&"set_swatch_thumbnail_size:large"));
    }

    #[test]
    fn standalone_checkbox_is_toggle_not_radio() {
        // The Align panel has a single `toggle_use_preview_bounds` checkbox;
        // its action does not recur, so it is a Toggle, not a Radio.
        let items = menu_items_from_yaml("align_panel_content");
        assert!(items.iter().any(|i| matches!(
            i, PanelMenuItem::Toggle { command: "toggle_use_preview_bounds", .. })));
    }

    #[test]
    fn action_item_construction() {
        let item = PanelMenuItem::Action {
            label: "Close",
            command: "close_panel",
            shortcut: "",
        };
        assert_eq!(item, PanelMenuItem::Action {
            label: "Close",
            command: "close_panel",
            shortcut: "",
        });
    }

    #[test]
    fn toggle_item_construction() {
        let item = PanelMenuItem::Toggle {
            label: "Show Options",
            command: "toggle_options",
        };
        assert!(matches!(item, PanelMenuItem::Toggle { .. }));
    }

    #[test]
    fn radio_item_construction() {
        let item = PanelMenuItem::Radio {
            label: "RGB",
            command: "set_rgb",
            group: "color_mode",
        };
        assert!(matches!(item, PanelMenuItem::Radio { group: "color_mode", .. }));
    }

    #[test]
    fn separator_equality() {
        assert_eq!(PanelMenuItem::Separator, PanelMenuItem::Separator);
    }
}
