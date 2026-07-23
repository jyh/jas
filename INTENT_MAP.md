# INTENT_MAP -- the reachable-intent map (action seam)

> **GENERATED FILE -- do not edit by hand.** Regenerate with
> `python scripts/gen_intent_map.py`; drift is gated in CI by
> `scripts/check_intent_map.sh`. Machine form: `intent_map.json`.

## Scope -- read this first

**This map covers the ACTION seam (`dispatch_action`) ONLY**: the
236 actions in the workspace bundle's `actions` map, plus the
bundle's declared `native_intercepts`. It is the machine enumeration
of which actions journal through `op_apply` (the enumeration
OP_LOG.md's actions.yaml<->op_apply unification prose refers to).

**45 `doc.*` effect verbs -- including every DRAWING verb**
(`doc.add_element`, `doc.add_path_from_buffer`,
`doc.add_path_from_anchor_buffer`, the blob-brush / paintbrush
commit verbs, ...) -- **are reachable only from tool/panel/dialog
YAML and are NOT in this map. An AI tool schema derived from this
map alone would omit drawing entirely.** The full outside-the-seam
verb list is in `intent_map.json` under
`summary.doc_verbs_outside_action_seam`.

## Classes

| class | definition |
|---|---|
| `journaling` | reaches at least one doc.* verb that journals through op_apply (unconditional, or param-gated with a literal `journal: true` at the call site) |
| `tool-lifecycle` | select_tool ONLY: the action itself is a bare `set: {active_tool}`, but tool activation runs the outgoing tool's on_leave, which MAY journal (pen.yaml conditionally emits doc.snapshot + doc.add_path_from_anchor_buffer to commit an in-progress path). Annotation class -- classified statically, never executed |
| `native-intercept` | declared in the bundle's native_intercepts list; the native app handles it before/instead of YAML effects (no actions-map effect tree to classify) |
| `view` | reaches doc.* verbs, all of them zoom/pan view-state writes; never touches the document or the journal |
| `preview` | the dialog preview channel: reaches only the out-of-band preview-snapshot verbs (doc.preview.*) plus a param-gated transform apply WITHOUT `journal: true`; document changes ride the preview snapshot, never the journal |
| `doc-direct` | reaches doc.* verbs that write the document (or bind document values) WITHOUT journaling through op_apply -- e.g. doc.set direct field writes |
| `ui-state` | no doc.* verb reachable: state/panel/layout/dialog/log-only effect trees |

## Summary

| class | actions |
|---|---|
| `doc-direct` | 3 |
| `journaling` | 24 |
| `native-intercept` | 1 |
| `preview` | 3 |
| `tool-lifecycle` | 1 |
| `ui-state` | 199 |
| `view` | 6 |
| **total** | **237** |

(The bundle's `actions` map has 236 entries; `native-intercept` entries
come additively from `native_intercepts`.)

## Journaling actions (24)

| action | doc.* verbs reached |
|---|---|
| `apply_brush_to_selection` | `doc.set_attr_on_selection`, `doc.snapshot` |
| `artboard_options_confirm` | `doc.set_artboard_field`, `doc.set_artboard_options_field` |
| `collect_in_new_layer` | `doc.wrap_in_layer` |
| `confirm_artboard_rename` | `doc.set_artboard_field` |
| `delete_artboard_from_dialog` | `doc.delete_artboard_by_id` |
| `delete_artboards` | `doc.delete_artboard_by_id` |
| `delete_layer_orphan_confirm_ok` | `doc.delete_at` |
| `delete_layer_selection` | `doc.delete_at` |
| `document_setup_confirm` | `doc.set_document_setup_field` |
| `duplicate_artboards` | `doc.duplicate_artboard` |
| `duplicate_layer_selection` | `doc.clone_at`, `doc.insert_after` |
| `flatten_artwork` | `doc.unpack_group_at` |
| `layer_options_confirm` | `doc.create_layer`, `doc.insert_at`, `doc.set` |
| `move_artboard_down` | `doc.move_artboards_down` |
| `move_artboard_up` | `doc.move_artboards_up` |
| `new_artboard` | `doc.create_artboard` |
| `new_group` | `doc.wrap_in_group` |
| `new_layer` | `doc.create_layer`, `doc.insert_at` |
| `print_dialog_done` | `doc.set_advanced_field`, `doc.set_color_management_field`, `doc.set_graphics_field`, `doc.set_marks_and_bleed_field`, `doc.set_output_field`, `doc.set_output_ink_field`, `doc.set_print_preferences_field` |
| `print_dialog_print` | `doc.set_advanced_field`, `doc.set_color_management_field`, `doc.set_graphics_field`, `doc.set_marks_and_bleed_field`, `doc.set_output_field`, `doc.set_output_ink_field`, `doc.set_print_preferences_field` |
| `remove_brush_from_selection` | `doc.set_attr_on_selection`, `doc.snapshot` |
| `rotate_options_confirm` | `doc.preview.clear`, `doc.preview.restore`, `doc.rotate.apply` (`doc.rotate.apply` journal:true) |
| `scale_options_confirm` | `doc.preview.clear`, `doc.preview.restore`, `doc.scale.apply` (`doc.scale.apply` journal:true) |
| `shear_options_confirm` | `doc.preview.clear`, `doc.preview.restore`, `doc.shear.apply` (`doc.shear.apply` journal:true) |

## Preview actions (3)

| action | doc.* verbs reached |
|---|---|
| `rotate_options_preview` | `doc.preview.restore`, `doc.rotate.apply` (`doc.rotate.apply` journal:absent/false) |
| `scale_options_preview` | `doc.preview.restore`, `doc.scale.apply` (`doc.scale.apply` journal:absent/false) |
| `shear_options_preview` | `doc.preview.restore`, `doc.shear.apply` (`doc.shear.apply` journal:absent/false) |

## View actions (6)

| action | doc.* verbs reached |
|---|---|
| `fit_active_artboard` | `doc.zoom.fit_rect` |
| `fit_all_artboards` | `doc.zoom.fit_all_artboards` |
| `fit_in_window` | `doc.zoom.fit_elements` |
| `zoom_in` | `doc.zoom.apply` |
| `zoom_out` | `doc.zoom.apply` |
| `zoom_to_actual_size` | `doc.zoom.set` |

## Doc-direct actions (3)

| action | doc.* verbs reached |
|---|---|
| `toggle_all_layers_lock` | `doc.set` |
| `toggle_all_layers_outline` | `doc.set` |
| `toggle_all_layers_visibility` | `doc.set` |

## Tool-lifecycle (1)

- `select_tool` -- select_tool ONLY: the action itself is a bare `set: {active_tool}`, but tool activation runs the outgoing tool's on_leave, which MAY journal (pen.yaml conditionally emits doc.snapshot + doc.add_path_from_anchor_buffer to commit an in-progress path). Annotation class -- classified statically, never executed.

## Native-intercept (1)

- `export_to_pdf` -- declared in native_intercepts; no actions-map entry -- handled natively.

## UI-state actions (199)

No `doc.*` verb reachable (state/panel/layout/dialog/log-only trees):

`add_used_colors`, `align_bottom`, `align_horizontal_center`, `align_left`,
`align_right`, `align_top`, `align_vertical_center`, `apply_artboard_preset`,
`apply_brush_changes_to_strokes`, `apply_concept_operation`, `artboards_panel_select`, `artboards_select_all`,
`blob_brush_tool_options_confirm`, `blob_brush_tool_options_reset`, `boolean_crop`, `boolean_divide`,
`boolean_exclude`, `boolean_exclude_compound`, `boolean_intersection`, `boolean_intersection_compound`,
`boolean_merge`, `boolean_options_confirm`, `boolean_subtract_back`, `boolean_subtract_front`,
`boolean_subtract_front_compound`, `boolean_trim`, `boolean_union`, `boolean_union_compound`,
`brush_options_confirm`, `cancel_artboard_rename`, `cancel_rename`, `close_panel`,
`close_tab`, `close_without_saving`, `collapse_dock`, `complement_active_color`,
`concepts_panel_select`, `confirm_rename`, `convert_to_artboards`, `copy`,
`cut`, `cut_orphan_confirm_ok`, `cycle_element_visibility`, `delete_brush`,
`delete_empty_artboards`, `delete_orphan_confirm_ok`, `delete_selection`, `delete_swatch`,
`delete_symbol_action`, `delete_symbol_orphan_confirm_ok`, `delete_workspace`, `dismiss_dialog`,
`distribute_bottom`, `distribute_horizontal_center`, `distribute_horizontal_spacing`, `distribute_left`,
`distribute_right`, `distribute_top`, `distribute_vertical_center`, `distribute_vertical_spacing`,
`document_setup_toggle_bleed_uniform`, `duplicate_brush`, `duplicate_swatch`, `enter_isolation_mode`,
`exit_isolation_mode`, `exit_isolation_to_level`, `expand_compound_shape`, `expand_dock`,
`eyedropper_tool_options_confirm`, `eyedropper_tool_options_reset`, `flip_stroke_profile`, `group`,
`hide_selection`, `invert_active_color`, `layers_element_select`, `layers_nav_down`,
`layers_nav_left`, `layers_nav_right`, `layers_nav_up`, `layers_panel_select`,
`layers_select_all`, `lock`, `make_compound_shape`, `make_instance`,
`maximize_canvas`, `new_document`, `new_swatch`, `new_symbol`,
`noop`, `open_artboard_options`, `open_boolean_options`, `open_brush_libraries_menu`,
`open_brush_options`, `open_color_picker`, `open_document_setup`, `open_file`,
`open_layer_options`, `open_paragraph_hyphenation`, `open_paragraph_justification`, `open_print_dialog`,
`open_swatch_options`, `paintbrush_tool_options_confirm`, `paintbrush_tool_options_reset`, `paragraph_hyphenation_confirm`,
`paragraph_justification_confirm`, `paste`, `paste_in_place`, `place_concept_instance`,
`place_instance`, `promote_to_concept`, `quit`, `rearrange_artboards`,
`redo`, `release_compound_shape`, `remove_tab`, `rename_artboard`,
`rename_element`, `repeat_boolean_operation`, `reset_align_panel`, `reset_artboards_panel`,
`reset_boolean_panel`, `reset_fill_stroke`, `reset_magic_wand_panel`, `reset_paragraph_panel`,
`reset_stroke_profile`, `reset_workspace`, `restore_canvas`, `revert`,
`revert_workspace`, `rotate_options_reset`, `save`, `save_all_and_close`,
`save_and_close`, `save_appearance_as`, `save_appearance_confirm`, `save_as`,
`save_brush_library`, `save_swatch_library`, `save_swatch_library_confirm`, `save_workspace_as`,
`save_workspace_confirm`, `scale_options_reset`, `scroll_to_selected`, `select_all`,
`select_all_unused_brushes`, `select_all_unused_swatches`, `set_active_color`, `set_active_color_none`,
`set_align_to`, `set_arrow_align`, `set_artboard_fill_preset`, `set_artboard_reference_point`,
`set_brush_thumbnail_size`, `set_brush_view_mode`, `set_color_panel_mode`, `set_concept_param`,
`set_fill_none`, `set_fill_type_gradient`, `set_fill_type_solid`, `set_layers_search`,
`set_stroke_align`, `set_stroke_cap`, `set_stroke_join`, `set_stroke_none`,
`set_stroke_profile`, `set_swatch_thumbnail_size`, `shear_options_reset`, `show_all`,
`show_panel`, `solo_element_visibility`, `sort_brushes_by_name`, `sort_swatches_by_name`,
`swap_arrowheads`, `swap_fill_stroke`, `swatch_options_confirm`, `switch_appearance`,
`switch_workspace`, `symbols_panel_select`, `tile_panes`, `toggle_artboard_chain_link`,
`toggle_artboard_orientation`, `toggle_brush_category`, `toggle_brush_library_persistent`, `toggle_canvas_maximize`,
`toggle_dashed_line`, `toggle_dock_collapse`, `toggle_element_lock`, `toggle_element_twirl`,
`toggle_fill_on_top`, `toggle_hanging_punctuation`, `toggle_layers_type_filter`, `toggle_link_arrowhead_scale`,
`toggle_pane`, `toggle_panel`, `toggle_use_preview_bounds`, `undo`,
`ungroup`, `ungroup_all`, `unlock_all`

## Verb -> journaling evidence table

Derived by reading the Rust reference dispatchers. File aliases:
`effects.rs` = `jas_dioxus/src/interpreter/effects.rs`,
`renderer.rs` = `jas_dioxus/src/interpreter/renderer.rs`,
`op_apply.rs` = `jas_dioxus/src/document/op_apply.rs`. Line numbers
are as of authoring (2026-07-22, post `five-port-parity`).

| doc.* verb | journals | op | reachable from actions | evidence |
|---|---|---|---|---|
| `doc.copy_selection` | always | `copy_selection` | no (tool YAML only) | effects.rs:948-961; op_apply.rs:1397 |
| `doc.create_artboard` | always | `create_artboard` | yes | renderer.rs:3100-3136; op_apply.rs:1863 |
| `doc.delete_artboard_by_id` | always | `delete_artboard_by_id` | yes | renderer.rs:3150-3159; op_apply.rs:1832 |
| `doc.delete_at` | always | `delete_at` | yes | renderer.rs:3440-3463; op_apply.rs:1554 |
| `doc.delete_selection` | always | `delete_selection` | no (tool YAML only) | renderer.rs:3508-3513; op_apply.rs:1564 |
| `doc.duplicate_artboard` | always | `duplicate_artboard` | yes | renderer.rs:3176-3229; op_apply.rs:1876 |
| `doc.insert_after` | always | `insert_after` | yes | renderer.rs:3545-3564; op_apply.rs:1571 |
| `doc.insert_at` | always | `insert_at` | yes | renderer.rs:3675-3706; op_apply.rs:1578 |
| `doc.move_artboards_down` | always | `move_artboards_down` | yes | renderer.rs:3390-3396; op_apply.rs:1849 |
| `doc.move_artboards_up` | always | `move_artboards_up` | yes | renderer.rs:3378-3384; op_apply.rs:1842 |
| `doc.select_in_rect` | always (selection-only / non-undoable: op_apply records it only into an ALREADY-OPEN transaction and never opens one (op_apply.rs:1329-1336), so a bare marquee stays journal-neutral) | `select_rect` | no (tool YAML only) | effects.rs:987-1013; op_apply.rs:1380 |
| `doc.set_advanced_field` | always | `set_advanced_field` | yes | renderer.rs:3326-3367; op_apply.rs:1775 (PRINT_CONFIG_VERBS) |
| `doc.set_artboard_field` | always | `set_artboard_field` | yes | renderer.rs:3241-3265; op_apply.rs:1802 |
| `doc.set_artboard_options_field` | always | `set_artboard_options_field` | yes | renderer.rs:3273-3290; op_apply.rs:1817 |
| `doc.set_attr_on_selection` | always | `set_attr_on_selection` | yes | effects.rs:901-946; op_apply.rs:1676 |
| `doc.set_color_management_field` | always | `set_color_management_field` | yes | renderer.rs:3326-3367; op_apply.rs:1775 (PRINT_CONFIG_VERBS) |
| `doc.set_document_setup_field` | always | `set_document_setup_field` | yes | renderer.rs:3326-3367; op_apply.rs:1775 (PRINT_CONFIG_VERBS) |
| `doc.set_graphics_field` | always | `set_graphics_field` | yes | renderer.rs:3326-3367; op_apply.rs:1775 (PRINT_CONFIG_VERBS) |
| `doc.set_marks_and_bleed_field` | always | `set_marks_and_bleed_field` | yes | renderer.rs:3326-3367; op_apply.rs:1775 (PRINT_CONFIG_VERBS) |
| `doc.set_output_field` | always | `set_output_field` | yes | renderer.rs:3326-3367; op_apply.rs:1775 (PRINT_CONFIG_VERBS) |
| `doc.set_output_ink_field` | always | `set_output_ink_field` | yes | renderer.rs:3326-3367; op_apply.rs:1775 (PRINT_CONFIG_VERBS) |
| `doc.set_print_preferences_field` | always | `set_print_preferences_field` | yes | renderer.rs:3326-3367; op_apply.rs:1775 (PRINT_CONFIG_VERBS) |
| `doc.translate_selection` | always | `move_selection` | no (tool YAML only) | effects.rs:767-785; op_apply.rs:1394 |
| `doc.unpack_group_at` | always | `unpack_group_at` | yes | renderer.rs:3576-3587; op_apply.rs:1632 |
| `doc.wrap_in_group` | always | `wrap_in_group` | yes | renderer.rs:3642-3664; op_apply.rs:1601 |
| `doc.wrap_in_layer` | always | `wrap_in_layer` | yes | renderer.rs:3599-3631; op_apply.rs:1615 |
| `doc.rotate.apply` | param-gated | `rotate_transform` | yes | effects.rs:1658-1683 (gate at :1678); op_apply.rs:1725 |
| `doc.scale.apply` | param-gated | `scale_transform` | yes | effects.rs:1619-1656 (gate at :1651); op_apply.rs:1710 |
| `doc.shear.apply` | param-gated | `shear_transform` | yes | effects.rs:1685-1717 (gate at :1711); op_apply.rs:1735 |
| `doc.clone_at` | never (pure ctx binder: clones an element into scope, no mutation) | -- | yes | renderer.rs:3516-3534 |
| `doc.create_layer` | never (pure ctx binder: deterministic Layer factory bound via `as:`; the subsequent doc.insert_at journals) | -- | yes | renderer.rs:3401-3430 |
| `doc.preview.clear` | never (out-of-band preview-snapshot channel (OP_LOG.md par.8)) | -- | yes | effects.rs:709-714 |
| `doc.preview.restore` | never (out-of-band preview-snapshot channel (OP_LOG.md par.8)) | -- | yes | effects.rs:703-708 |
| `doc.set` | never (direct per-field document write via apply_doc_set_field; not routed through op_apply, so it records no op) | -- | yes | renderer.rs:3709-3728 |
| `doc.snapshot` | never (transaction management: begin_txn only; snapshot/undo/redo manage the journal cursor and are never journaled as ops) | -- | yes | effects.rs:682-684; op_apply.rs:1300-1314 |
| `doc.zoom.apply` | never (view state only (zoom/pan)) | -- | yes | effects.rs:1719-1768 |
| `doc.zoom.fit_all_artboards` | never (view state only (zoom/pan)) | -- | yes | effects.rs:1935-1956 |
| `doc.zoom.fit_elements` | never (view state only (zoom/pan)) | -- | yes | effects.rs:1914-1933 |
| `doc.zoom.fit_rect` | never (view state only (zoom/pan)) | -- | yes | effects.rs:1869-1881 |
| `doc.zoom.set` | never (view state only (zoom/pan)) | -- | yes | effects.rs:1770-1795 |

## Caveats

- **Static classification of the YAML bundle.** Several actions are
  `log`-stubs in YAML whose real behavior lives in native code:
  `dispatch_action` natively intercepts the symbol/concept actions
  (`new_symbol`, `place_instance`, `delete_symbol_action`,
  `delete_symbol_orphan_confirm_ok`, `place_concept_instance`,
  `set_concept_param`, `apply_concept_operation`,
  `promote_to_concept` -- renderer.rs:549-1010), several of which
  journal real ops through `op_apply` natively; and the menu/keyboard
  fast paths handle `cut`/`copy`/`paste`/`delete_selection` natively
  (journaling `delete_selection` via `journal_delete_selection`,
  op_apply.rs:1276). Those actions classify as `ui-state` here
  because their YAML effect trees reach no `doc.*` verb; the class
  describes the YAML seam, not the native behavior behind it.
- **`doc.select_in_rect`** routes through `op_apply` but records only
  into an already-open transaction and never opens one
  (op_apply.rs:1329-1336): selection is non-undoable serialized
  state, so a bare marquee stays journal-neutral.
- **`doc.snapshot`** is transaction management (`begin_txn`), not an
  op; history-navigation verbs are never journaled
  (op_apply.rs:1294-1314).
- **Dispatch chains are followed** (`cut` -> `copy` +
  `delete_selection`, `save` -> `save_as`, ...), transitively and
  cycle-safe; `action:` keys inside created-element `behavior` blocks
  are event bindings, not dispatch-time effects, and are not
  followed.
