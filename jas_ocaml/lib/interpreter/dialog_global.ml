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
