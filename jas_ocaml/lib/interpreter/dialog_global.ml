(** Cross-module refs surfacing the active YAML dialog to widget
    renderers.

    Lives in its own module to break what would otherwise be a cycle
    between [Yaml_panel_view] (the renderer that wires write-backs)
    and [Yaml_dialog_view] (the dialog host that owns the live state).
    Both modules depend on this one; this module depends on nothing
    beyond Yojson. *)

(** The live dialog state — widget callbacks mutate the inner list,
    OK / Done / Print buttons re-resolve their params against it.
    [None] when no dialog is open. *)
let current_state : (string * Yojson.Safe.t) list ref option ref = ref None

(** The active dialog id (e.g. ``"document_setup"``). [None] when no
    dialog is open. Used for diagnostic / panel-id-style routing. *)
let current_id : string option ref = ref None

(** Outer-scope keys (e.g. ``active_document``) merged into render-time
    bind expressions and into action-dispatch contexts. *)
let current_outer_scope : (string * Yojson.Safe.t) list ref = ref []

(** Dismiss the active dialog widget. Called by ``close_dialog`` /
    ``dismiss_dialog`` action effects. *)
let current_close : (unit -> unit) ref = ref (fun () -> ())

(** Build a fresh evaluation ctx against the live dialog state. The
    closure is set by [Yaml_dialog_view.show_dialog] before rendering;
    widget action callbacks call it at click time so resolved params
    reflect typed-in values rather than the render-time snapshot. *)
let current_build_ctx : (unit -> Yojson.Safe.t) ref =
  ref (fun () -> `Assoc [])

(** Read the live dialog state list. *)
let read_state () : (string * Yojson.Safe.t) list =
  match !current_state with
  | Some r -> !r
  | None -> []

(** Set [key] in the live dialog state. No-op when no dialog is open. *)
let set_field (key : string) (value : Yojson.Safe.t) : unit =
  match !current_state with
  | Some r ->
    r := (key, value) :: List.filter (fun (k, _) -> k <> key) !r
  | None -> ()

(** Close the active dialog widget. *)
let close () : unit = !current_close ()

(** Build the platform_effects table for a dialog action dispatch.
    Combines the controller-driven tool effects (snapshot,
    doc.set_*_field, etc.) with the dialog-specific close handler. *)
let _platform_effects_for (ctrl : Controller.controller)
    (close_widget : unit -> unit) :
    (string * Effects.platform_effect) list =
  let snapshot_h : Effects.platform_effect = fun _ _ _ ->
    ctrl#model#snapshot; `Null in
  let close_dialog_h : Effects.platform_effect = fun _ _ _ ->
    close_widget (); `Null in
  ("snapshot", snapshot_h)
  :: ("close_dialog", close_dialog_h)
  :: Yaml_tool_effects.build ctrl

(** Read a Yojson value from the current dialog state list. *)
let _read_dialog_field (key : string) : Yojson.Safe.t =
  match List.assoc_opt key (read_state ()) with
  | Some v -> v
  | None -> `Null

let _bool_opt v =
  match v with `Bool b -> Some b | _ -> None
let _float_opt v =
  match v with
  | `Float f -> Some f
  | `Int n -> Some (float_of_int n)
  | _ -> None
let _string_opt v =
  match v with `String s -> Some s | _ -> None

(** Read the current Hyphenation-dialog state into the values record
    consumed by [Effects.apply_hyphenation_dialog_to_selection]. *)
let _hyphenation_values () : Effects.hyphenation_dialog_values =
  Effects.{
    hyphenate = _bool_opt (_read_dialog_field "hyphenate");
    min_word = _float_opt (_read_dialog_field "hyphenate_min_word");
    min_before = _float_opt (_read_dialog_field "hyphenate_min_before");
    min_after = _float_opt (_read_dialog_field "hyphenate_min_after");
    limit = _float_opt (_read_dialog_field "hyphenate_limit");
    zone = _float_opt (_read_dialog_field "hyphenate_zone");
    bias = _float_opt (_read_dialog_field "hyphenate_bias");
    capitalized = _bool_opt (_read_dialog_field "hyphenate_capitalized");
  }

(** Apply the Paragraph panel's open store to a dialog-driven write.
    The Paragraph panel store is registered in [Panel_menu] under
    ``"paragraph_panel_content"``; missing means no Paragraph panel
    is open and the master mirror is silently skipped. *)
let _paragraph_panel_store () : State_store.t option =
  Panel_menu.lookup_panel_store "paragraph_panel_content"

(** Read the current Justification-dialog state into the values
    record consumed by [Effects.apply_justification_dialog_to_selection]. *)
let _justification_values () : Effects.justification_dialog_values =
  Effects.{
    word_spacing_min = _float_opt (_read_dialog_field "word_spacing_min");
    word_spacing_desired = _float_opt (_read_dialog_field "word_spacing_desired");
    word_spacing_max = _float_opt (_read_dialog_field "word_spacing_max");
    letter_spacing_min = _float_opt (_read_dialog_field "letter_spacing_min");
    letter_spacing_desired = _float_opt (_read_dialog_field "letter_spacing_desired");
    letter_spacing_max = _float_opt (_read_dialog_field "letter_spacing_max");
    glyph_scaling_min = _float_opt (_read_dialog_field "glyph_scaling_min");
    glyph_scaling_desired = _float_opt (_read_dialog_field "glyph_scaling_desired");
    glyph_scaling_max = _float_opt (_read_dialog_field "glyph_scaling_max");
    auto_leading = _float_opt (_read_dialog_field "auto_leading");
    single_word_justify = _string_opt (_read_dialog_field "single_word_justify");
  }

(** Native intercept run BEFORE the YAML effects for an
    [<id>_confirm] dialog action. Reads the live dialog state and
    invokes the matching apply function. Without this, the YAML
    confirm action only runs [close_dialog] and the user's edits
    are silently dropped. *)
let _maybe_intercept_confirm (action_name : string)
    (ctrl : Controller.controller) : unit =
  match action_name with
  | "paragraph_hyphenation_confirm" ->
    let values = _hyphenation_values () in
    let store = match _paragraph_panel_store () with
      | Some s -> s
      | None -> State_store.create () in
    Effects.apply_hyphenation_dialog_to_selection store ctrl values
  | "paragraph_justification_confirm" ->
    Effects.apply_justification_dialog_to_selection ctrl (_justification_values ())
  | _ -> ()

(** Dispatch a YAML action by name with the given resolved params.
    ``dismiss_dialog`` is special-cased to dismiss the dialog widget
    without running effects. All other action names look up the
    action in workspace, build a context with [param] set, and run
    the effects through [Effects.run_effects]. *)
let dispatch_action (action_name : string)
    (params : (string * Yojson.Safe.t) list)
    (ctrl : Controller.controller option)
    (close_widget : unit -> unit) : unit =
  if action_name = "dismiss_dialog" then close_widget ()
  else
    match ctrl, Workspace_loader.load () with
    | Some c, Some ws ->
      _maybe_intercept_confirm action_name c;
      (match Workspace_loader.json_member "actions" ws.data with
       | Some (`Assoc all_actions) ->
         (match List.assoc_opt action_name all_actions with
          | Some (`Assoc act) ->
            (match List.assoc_opt "effects" act with
             | Some (`List effects) ->
               let pe = _platform_effects_for c close_widget in
               let ctx = [
                 ("param", `Assoc params);
                 ("active_document", Active_document_view.build (Some c#model));
               ] in
               let store = State_store.create () in
               Effects.run_effects ~platform_effects:pe effects ctx store
             | _ -> ())
          | _ -> ())
       | _ -> ())
    | _ -> ()
