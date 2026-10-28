# INTENT_MAP -- the reachable-intent map (action seam)

> **GENERATED FILE -- do not edit by hand.** Regenerate with
> `python scripts/gen_intent_map.py`; drift is gated in CI by
> `scripts/check_intent_map.sh`. Machine form: `intent_map.json`.

## Scope -- read this first

**This map covers the ACTION seam (`dispatch_action`) ONLY**: the
244 actions in the workspace bundle's `actions` map, plus the
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
| `doc-direct` | 5 |
| `journaling` | 53 |
| `native-intercept` | 1 |
| `preview` | 3 |
| `tool-lifecycle` | 1 |
| `ui-state` | 176 |
| `view` | 6 |
| **total** | **245** |

(The bundle's `actions` map has 244 entries; `native-intercept` entries
come additively from `native_intercepts`.)

## Journaling actions (53)

| action | doc.* verbs reached |
|---|---|
| `apply_brush_to_selection` | `doc.set_attr_on_selection`, `doc.snapshot` |
| `apply_concept_operation` | `doc.apply_concept_operation` |
| `artboard_options_confirm` | `doc.set_artboard_field`, `doc.set_artboard_options_field` |
| `collect_in_new_layer` | `doc.wrap_in_layer` |
| `confirm_artboard_rename` | `doc.set_artboard_field` |
| `confirm_rename` | `doc.op` |
| `cut` | `doc.op` -> dispatches `copy`, `delete_selection` |
| `cycle_element_visibility` | `doc.op` |
| `delete_artboard_from_dialog` | `doc.delete_artboard_by_id` |
| `delete_artboards` | `doc.delete_artboard_by_id` |
| `delete_empty_artboards` | `doc.delete_artboard_by_id` |
| `delete_layer_orphan_confirm_ok` | `doc.delete_at` |
| `delete_layer_selection` | `doc.delete_at` |
| `delete_selection` | `doc.op` |
| `delete_symbol_action` | `doc.delete_symbol` |
| `delete_symbol_orphan_confirm_ok` | `doc.delete_symbol` |
| `document_setup_confirm` | `doc.set_document_setup_field` |
| `duplicate_artboards` | `doc.duplicate_artboard` |
| `duplicate_layer_selection` | `doc.clone_at`, `doc.insert_after` |
| `flatten_artwork` | `doc.unpack_group_at` |
| `group` | `doc.op` |
| `hide_selection` | `doc.op` |
| `layer_options_confirm` | `doc.create_layer`, `doc.insert_at`, `doc.set` |
| `lock` | `doc.op` |
| `make_instance` | `doc.make_instance` |
| `move_artboard_down` | `doc.move_artboards_down` |
| `move_artboard_up` | `doc.move_artboards_up` |
| `new_artboard` | `doc.create_artboard` |
| `new_group` | `doc.wrap_in_group` |
| `new_layer` | `doc.create_layer`, `doc.insert_at` |
| `new_symbol` | `doc.new_symbol` |
| `nudge_selection` | `doc.snapshot`, `doc.translate_selection` |
| `paste` | `doc.paste` |
| `paste_in_place` | `doc.paste` |
| `paste_preserving_layers` | `doc.paste` |
| `place_concept_instance` | `doc.place_concept_instance` |
| `place_instance` | `doc.place_instance` |
| `print_dialog_done` | `doc.set_advanced_field`, `doc.set_color_management_field`, `doc.set_graphics_field`, `doc.set_marks_and_bleed_field`, `doc.set_output_field`, `doc.set_output_ink_field`, `doc.set_print_preferences_field` |
| `print_dialog_print` | `doc.set_advanced_field`, `doc.set_color_management_field`, `doc.set_graphics_field`, `doc.set_marks_and_bleed_field`, `doc.set_output_field`, `doc.set_output_ink_field`, `doc.set_print_preferences_field` |
| `promote_to_concept` | `doc.promote_to_concept` |
| `remove_brush_from_selection` | `doc.set_attr_on_selection`, `doc.snapshot` |
| `rotate_options_confirm` | `doc.preview.clear`, `doc.preview.restore`, `doc.rotate.apply` (`doc.rotate.apply` journal:true) |
| `scale_options_confirm` | `doc.preview.clear`, `doc.preview.restore`, `doc.scale.apply` (`doc.scale.apply` journal:true) |
| `select_all` | `doc.op` |
| `set_concept_param` | `doc.set_concept_param` |
| `set_fill_type_gradient` | `doc.promote_to_gradient` |
| `set_fill_type_solid` | `doc.demote_to_solid` |
| `shear_options_confirm` | `doc.preview.clear`, `doc.preview.restore`, `doc.shear.apply` (`doc.shear.apply` journal:true) |
| `show_all` | `doc.op` |
| `toggle_element_lock` | `doc.op` |
| `ungroup` | `doc.op` |
| `ungroup_all` | `doc.op` |
| `unlock_all` | `doc.op` |

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

## Doc-direct actions (5)

| action | doc.* verbs reached |
|---|---|
| `redo` | `doc.op` |
| `toggle_all_layers_lock` | `doc.set` |
| `toggle_all_layers_outline` | `doc.set` |
| `toggle_all_layers_visibility` | `doc.set` |
| `undo` | `doc.op` |

## Tool-lifecycle (1)

- `select_tool` -- select_tool ONLY: the action itself is a bare `set: {active_tool}`, but tool activation runs the outgoing tool's on_leave, which MAY journal (pen.yaml conditionally emits doc.snapshot + doc.add_path_from_anchor_buffer to commit an in-progress path). Annotation class -- classified statically, never executed.

## Native-intercept (1)

- `export_to_pdf` -- declared in native_intercepts; no actions-map entry -- handled natively.

## UI-state actions (176)

No `doc.*` verb reachable (state/panel/layout/dialog/log-only trees):

`add_used_colors`, `align_bottom`, `align_horizontal_center`, `align_left`,
`align_right`, `align_top`, `align_vertical_center`, `apply_artboard_preset`,
`apply_brush_changes_to_strokes`, `artboards_panel_select`, `artboards_select_all`, `blob_brush_tool_options_confirm`,
`blob_brush_tool_options_reset`, `boolean_crop`, `boolean_divide`, `boolean_exclude`,
`boolean_exclude_compound`, `boolean_intersection`, `boolean_intersection_compound`, `boolean_merge`,
`boolean_options_confirm`, `boolean_subtract_back`, `boolean_subtract_front`, `boolean_subtract_front_compound`,
`boolean_trim`, `boolean_union`, `boolean_union_compound`, `brush_options_confirm`,
`cancel_artboard_rename`, `cancel_rename`, `clear_layers_type_filter`, `close_panel`,
`close_tab`, `close_window`, `close_without_saving`, `collapse_dock`,
`complement_active_color`, `concepts_panel_select`, `convert_to_artboards`, `copy`,
`cut_orphan_confirm_ok`, `delete_brush`, `delete_orphan_confirm_ok`, `delete_swatch`,
`delete_workspace`, `discard_and_close_tab`, `dismiss_dialog`, `distribute_bottom`,
`distribute_horizontal_center`, `distribute_horizontal_spacing`, `distribute_left`, `distribute_right`,
`distribute_top`, `distribute_vertical_center`, `distribute_vertical_spacing`, `document_setup_toggle_bleed_uniform`,
`duplicate_brush`, `duplicate_swatch`, `enter_isolation_mode`, `exit_isolation_mode`,
`exit_isolation_to_level`, `expand_compound_shape`, `expand_dock`, `eyedropper_tool_options_confirm`,
`eyedropper_tool_options_reset`, `flip_stroke_profile`, `invert_active_color`, `layers_element_select`,
`layers_nav_down`, `layers_nav_left`, `layers_nav_right`, `layers_nav_up`,
`layers_panel_select`, `layers_select_all`, `make_compound_shape`, `maximize_canvas`,
`new_document`, `new_swatch`, `noop`, `open_artboard_options`,
`open_boolean_options`, `open_brush_libraries_menu`, `open_brush_options`, `open_color_picker`,
`open_document_setup`, `open_file`, `open_layer_options`, `open_paragraph_hyphenation`,
`open_paragraph_justification`, `open_print_dialog`, `open_swatch_options`, `paintbrush_tool_options_confirm`,
`paintbrush_tool_options_reset`, `paragraph_hyphenation_confirm`, `paragraph_justification_confirm`, `quit`,
`rearrange_artboards`, `release_compound_shape`, `release_transform`, `remove_tab`,
`rename_artboard`, `rename_element`, `repeat_boolean_operation`, `reset_align_panel`,
`reset_artboards_panel`, `reset_boolean_panel`, `reset_fill_stroke`, `reset_magic_wand_panel`,
`reset_paragraph_panel`, `reset_stroke_profile`, `reset_workspace`, `restore_canvas`,
`revert`, `revert_workspace`, `rotate_options_reset`, `save`,
`save_all_and_close`, `save_all_then_close`, `save_and_close`, `save_appearance_as`,
`save_appearance_confirm`, `save_as`, `save_brush_library`, `save_swatch_library`,
`save_swatch_library_confirm`, `save_workspace_as`, `save_workspace_confirm`, `scale_options_reset`,
`scroll_to_selected`, `select_all_unused_brushes`, `select_all_unused_swatches`, `set_active_color`,
`set_active_color_none`, `set_align_to`, `set_arrow_align`, `set_artboard_fill_preset`,
`set_artboard_reference_point`, `set_brush_thumbnail_size`, `set_brush_view_mode`, `set_color_panel_mode`,
`set_fill_none`, `set_layers_search`, `set_stroke_align`, `set_stroke_cap`,
`set_stroke_join`, `set_stroke_none`, `set_stroke_profile`, `set_swatch_thumbnail_size`,
`shear_options_reset`, `show_panel`, `solo_element_visibility`, `solo_layers_type_filter`,
`sort_brushes_by_name`, `sort_swatches_by_name`, `swap_arrowheads`, `swap_fill_stroke`,
`swatch_options_confirm`, `switch_appearance`, `switch_workspace`, `symbols_panel_select`,
`tile_panes`, `toggle_artboard_chain_link`, `toggle_artboard_orientation`, `toggle_brush_category`,
`toggle_brush_library_persistent`, `toggle_canvas_maximize`, `toggle_dashed_line`, `toggle_dock_collapse`,
`toggle_element_twirl`, `toggle_fill_on_top`, `toggle_hanging_punctuation`, `toggle_layers_type_filter`,
`toggle_link_arrowhead_scale`, `toggle_pane`, `toggle_panel`, `toggle_use_preview_bounds`

## Verb -> journaling evidence table

Derived by reading the Rust reference dispatchers. Each citation is a
file under `jas_dioxus/src` (named by its unique basename) and the
dispatch arm's own literal. The generator finds every literal in its
file or refuses to write, so a citation cannot go stale silently; and
none carries a line number, so a moved arm needs no regeneration.

| doc.* verb | journals | op | reachable from actions | evidence |
|---|---|---|---|---|
| `doc.apply_concept_operation` | always | `apply_concept_operation` | yes | effects.rs `"doc.apply_concept_operation" =>`; op_apply.rs `"apply_concept_operation" =>` |
| `doc.copy_selection` | always | `copy_selection` | no (tool YAML only) | effects.rs `"doc.copy_selection" =>`; op_apply.rs `"copy_selection" =>` |
| `doc.create_artboard` | always | `create_artboard` | yes | artboard_effects.rs `"doc.create_artboard" =>`; op_apply.rs `"create_artboard" =>` |
| `doc.delete_artboard_by_id` | always | `delete_artboard_by_id` | yes | artboard_effects.rs `"doc.delete_artboard_by_id" =>`; op_apply.rs `"delete_artboard_by_id" =>` |
| `doc.delete_at` | always | `delete_at` | yes | layer_doc_effects.rs `"doc.delete_at" =>`; op_apply.rs `"delete_at" =>` |
| `doc.delete_selection` | always | `delete_selection` | no (tool YAML only) | effects.rs `"doc.delete_selection" =>`; op_apply.rs `"delete_selection" =>` |
| `doc.delete_symbol` | always | `delete_symbol` | yes | effects.rs `"doc.delete_symbol" =>`; op_apply.rs `"delete_symbol" =>` |
| `doc.demote_to_solid` | always | `demote_to_solid` | yes | effects.rs `"doc.demote_to_solid" =>`; op_apply.rs `"demote_to_solid" =>` |
| `doc.duplicate_artboard` | always | `duplicate_artboard` | yes | artboard_effects.rs `"doc.duplicate_artboard" =>`; op_apply.rs `"duplicate_artboard" =>` |
| `doc.insert_after` | always | `insert_after` | yes | layer_doc_effects.rs `"doc.insert_after" =>`; op_apply.rs `"insert_after" =>` |
| `doc.insert_at` | always | `insert_at` | yes | layer_doc_effects.rs `"doc.insert_at" =>`; op_apply.rs `"insert_at" =>` |
| `doc.make_instance` | always | `create_reference + move_selection` | yes | effects.rs `"doc.make_instance" =>`; op_apply.rs `"create_reference" =>` |
| `doc.move_artboards_down` | always | `move_artboards_down` | yes | artboard_effects.rs `"doc.move_artboards_up" \| "doc.move_artboards_down" =>`; op_apply.rs `"move_artboards_down" =>` |
| `doc.move_artboards_up` | always | `move_artboards_up` | yes | artboard_effects.rs `"doc.move_artboards_up" \| "doc.move_artboards_down" =>`; op_apply.rs `"move_artboards_up" =>` |
| `doc.new_symbol` | always | `make_symbol` | yes | effects.rs `"doc.new_symbol" =>`; op_apply.rs `"make_symbol" =>` |
| `doc.op` | always (a selection-only op (`select_all`) is journal-neutral as `doc.select_in_rect` is: op_apply opens no transaction for it (op_apply.rs:1878 is_selection_only_verb)) | `(the call site's op)` | yes | effects.rs `"doc.op" =>`; op_apply.rs `pub fn op_apply(` |
| `doc.paste` | always (an empty or unreadable clipboard journals nothing: the law self-brackets through edit_document only when it pastes) | `paste` | yes | effects.rs `"doc.paste" =>`; op_apply.rs `"paste" =>` |
| `doc.place_concept_instance` | always | `place_concept_instance` | yes | effects.rs `"doc.place_concept_instance" =>`; op_apply.rs `"place_concept_instance" =>` |
| `doc.place_instance` | always | `place_instance` | yes | effects.rs `"doc.place_instance" =>`; op_apply.rs `"place_instance" =>` |
| `doc.promote_to_concept` | always | `promote_to_concept` | yes | effects.rs `"doc.promote_to_concept" =>`; op_apply.rs `"promote_to_concept" =>` |
| `doc.promote_to_gradient` | always | `promote_to_gradient` | yes | effects.rs `"doc.promote_to_gradient" =>`; op_apply.rs `"promote_to_gradient" =>` |
| `doc.select_in_rect` | always (selection-only / non-undoable: op_apply records it only into an ALREADY-OPEN transaction and never opens one (op_apply.rs:1329-1336), so a bare marquee stays journal-neutral) | `select_rect` | no (tool YAML only) | effects.rs `"doc.select_in_rect" =>`; op_apply.rs `"select_rect" =>` |
| `doc.set_advanced_field` | always | `set_advanced_field` | yes | effects.rs `("doc.set_advanced_field", "set_advanced_field")`; op_apply.rs `v if PRINT_CONFIG_VERBS.contains(&v) =>` |
| `doc.set_artboard_field` | always | `set_artboard_field` | yes | artboard_effects.rs `"doc.set_artboard_field" =>`; op_apply.rs `"set_artboard_field" =>` |
| `doc.set_artboard_options_field` | always | `set_artboard_options_field` | yes | artboard_effects.rs `"doc.set_artboard_options_field" =>`; op_apply.rs `"set_artboard_options_field" =>` |
| `doc.set_attr_on_selection` | always | `set_attr_on_selection` | yes | effects.rs `"doc.set_attr_on_selection" =>`; op_apply.rs `"set_attr_on_selection" =>` |
| `doc.set_color_management_field` | always | `set_color_management_field` | yes | effects.rs `("doc.set_color_management_field", "set_color_management_field")`; op_apply.rs `v if PRINT_CONFIG_VERBS.contains(&v) =>` |
| `doc.set_concept_param` | always | `set_concept_param` | yes | effects.rs `"doc.set_concept_param" =>`; op_apply.rs `"set_concept_param" =>` |
| `doc.set_document_setup_field` | always | `set_document_setup_field` | yes | effects.rs `("doc.set_document_setup_field", "set_document_setup_field")`; op_apply.rs `v if PRINT_CONFIG_VERBS.contains(&v) =>` |
| `doc.set_graphics_field` | always | `set_graphics_field` | yes | effects.rs `("doc.set_graphics_field", "set_graphics_field")`; op_apply.rs `v if PRINT_CONFIG_VERBS.contains(&v) =>` |
| `doc.set_marks_and_bleed_field` | always | `set_marks_and_bleed_field` | yes | effects.rs `("doc.set_marks_and_bleed_field", "set_marks_and_bleed_field")`; op_apply.rs `v if PRINT_CONFIG_VERBS.contains(&v) =>` |
| `doc.set_output_field` | always | `set_output_field` | yes | effects.rs `("doc.set_output_field", "set_output_field")`; op_apply.rs `v if PRINT_CONFIG_VERBS.contains(&v) =>` |
| `doc.set_output_ink_field` | always | `set_output_ink_field` | yes | effects.rs `("doc.set_output_ink_field", "set_output_ink_field")`; op_apply.rs `v if PRINT_CONFIG_VERBS.contains(&v) =>` |
| `doc.set_print_preferences_field` | always | `set_print_preferences_field` | yes | effects.rs `("doc.set_print_preferences_field", "set_print_preferences_field")`; op_apply.rs `v if PRINT_CONFIG_VERBS.contains(&v) =>` |
| `doc.translate_selection` | always | `move_selection` | yes | effects.rs `"doc.translate_selection" =>`; op_apply.rs `"move_selection" =>` |
| `doc.unpack_group_at` | always | `unpack_group_at` | yes | layer_doc_effects.rs `"doc.unpack_group_at" =>`; op_apply.rs `"unpack_group_at" =>` |
| `doc.wrap_in_group` | always | `wrap_in_group` | yes | layer_doc_effects.rs `"doc.wrap_in_layer" \| "doc.wrap_in_group" =>`; op_apply.rs `"wrap_in_group" =>` |
| `doc.wrap_in_layer` | always | `wrap_in_layer` | yes | layer_doc_effects.rs `"doc.wrap_in_layer" \| "doc.wrap_in_group" =>`; op_apply.rs `"wrap_in_layer" =>` |
| `doc.rotate.apply` | param-gated | `rotate_transform` | yes | effects.rs `"doc.rotate.apply" =>`; op_apply.rs `"rotate_transform" =>` |
| `doc.scale.apply` | param-gated | `scale_transform` | yes | effects.rs `"doc.scale.apply" =>`; op_apply.rs `"scale_transform" =>` |
| `doc.shear.apply` | param-gated | `shear_transform` | yes | effects.rs `"doc.shear.apply" =>`; op_apply.rs `"shear_transform" =>` |
| `doc.clone_at` | never (pure ctx binder: clones an element into scope, no mutation) | -- | yes | layer_doc_effects.rs `"doc.clone_at" \| "doc.delete_at" =>` |
| `doc.create_layer` | never (pure ctx binder: deterministic Layer factory bound via `as:`; the subsequent doc.insert_at journals) | -- | yes | layer_doc_effects.rs `"doc.create_layer" =>` |
| `doc.preview.clear` | never (out-of-band preview-snapshot channel (OP_LOG.md par.8)) | -- | yes | effects.rs `"doc.preview.clear" =>` |
| `doc.preview.restore` | never (out-of-band preview-snapshot channel (OP_LOG.md par.8)) | -- | yes | effects.rs `"doc.preview.restore" =>` |
| `doc.set` | never (direct per-field document write via layer_doc_effects::set_field; not routed through op_apply, so it records no op) | -- | yes | layer_doc_effects.rs `"doc.set" =>` |
| `doc.snapshot` | never (transaction management: begin_txn only; snapshot/undo/redo manage the journal cursor and are never journaled as ops) | -- | yes | effects.rs `"doc.snapshot" =>`; op_apply.rs `"snapshot" =>` |
| `doc.zoom.apply` | never (view state only (zoom/pan)) | -- | yes | effects.rs `"doc.zoom.apply" =>` |
| `doc.zoom.fit_all_artboards` | never (view state only (zoom/pan)) | -- | yes | effects.rs `"doc.zoom.fit_all_artboards" =>` |
| `doc.zoom.fit_elements` | never (view state only (zoom/pan)) | -- | yes | effects.rs `"doc.zoom.fit_elements" =>` |
| `doc.zoom.fit_rect` | never (view state only (zoom/pan)) | -- | yes | effects.rs `"doc.zoom.fit_rect" =>` |
| `doc.zoom.set` | never (view state only (zoom/pan)) | -- | yes | effects.rs `"doc.zoom.set" =>` |

## Caveats

- **Static classification of the YAML bundle.** Several actions are
  `log`-stubs in YAML whose real behavior lives in native code:
  `copy`/`paste` are handled natively by
  each app's clipboard route. Those actions classify as `ui-state` here
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
