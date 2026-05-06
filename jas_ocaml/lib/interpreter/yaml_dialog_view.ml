(** YAML-interpreted dialog component for GTK3.

    Renders a modal dialog from workspace YAML definitions, reusing the
    existing element renderer for the content tree. *)

(** Dialog state. *)
type dialog_state = {
  id : string;
  state : (string * Yojson.Safe.t) list;
  params : (string * Yojson.Safe.t) list;
}

(** Read the live dialog state list (forwards to [Dialog_global]). *)
let current_dialog_state () : (string * Yojson.Safe.t) list =
  Dialog_global.read_state ()

(** Set [key] in the live dialog state. *)
let set_dialog_field (key : string) (value : Yojson.Safe.t) : unit =
  Dialog_global.set_field key value

(** Close the active dialog widget. *)
let close_current_dialog () : unit = Dialog_global.close ()

(** Build a fresh evaluation context against the live dialog state. *)
let current_dialog_ctx () : Yojson.Safe.t =
  !Dialog_global.current_build_ctx ()

(** Open a dialog by ID, initializing its state from the workspace
    definition. ``outer_scope`` exposes top-level keys (like
    ``active_document``) to init expressions. *)
let open_dialog ?(outer_scope : (string * Yojson.Safe.t) list = [])
    (dialog_id : string)
    (raw_params : (string * Yojson.Safe.t) list)
    (live_state : (string * Yojson.Safe.t) list) : dialog_state option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.dialog ws dialog_id with
    | None -> None
    | Some (`Assoc dlg_def) ->
      let defaults = match List.assoc_opt "state" dlg_def with
        | Some defs -> Effects.state_defaults defs
        | None -> []
      in
      let state_ctx = `Assoc (
        ("state", `Assoc live_state) :: outer_scope
      ) in
      let resolved_params = List.map (fun (k, v) ->
        let expr_str = match v with `String s -> s | _ -> "" in
        let result = Expr_eval.evaluate expr_str state_ctx in
        (k, Effects.value_to_json result)
      ) raw_params in
      let dialog_state = ref defaults in
      let init_ctx_for () : Yojson.Safe.t =
        `Assoc (
          ("state", `Assoc live_state) ::
          ("dialog", `Assoc !dialog_state) ::
          ("param", `Assoc resolved_params) ::
          outer_scope)
      in
      (match List.assoc_opt "init" dlg_def with
       | Some (`Assoc init_map) ->
         let deferred = ref [] in
         List.iter (fun (key, expr) ->
           let expr_str = match expr with `String s -> s | _ -> "" in
           if (try ignore (Str.search_forward
                             (Str.regexp_string "dialog.") expr_str 0); true
               with Not_found -> false) then
             deferred := (key, expr) :: !deferred
           else begin
             let result = Expr_eval.evaluate expr_str (init_ctx_for ()) in
             dialog_state := (key, Effects.value_to_json result) ::
               List.filter (fun (k, _) -> k <> key) !dialog_state
           end
         ) init_map;
         List.iter (fun (key, expr) ->
           let expr_str = match expr with `String s -> s | _ -> "" in
           let result = Expr_eval.evaluate expr_str (init_ctx_for ()) in
           dialog_state := (key, Effects.value_to_json result) ::
             List.filter (fun (k, _) -> k <> key) !dialog_state
         ) (List.rev !deferred)
       | _ -> ());
      Some {
        id = dialog_id;
        state = !dialog_state;
        params = resolved_params;
      }
    | _ -> None

(** Dispatch a YAML action by name (forwards to [Dialog_global]). *)
let dispatch_action = Dialog_global.dispatch_action

(** Show a YAML dialog as a GTK modal dialog. *)
let show_dialog ?(parent : GWindow.window option)
    ?(outer_scope : (string * Yojson.Safe.t) list = [])
    (ds : dialog_state) : unit =
  match Workspace_loader.load () with
  | None -> ()
  | Some ws ->
    match Workspace_loader.dialog ws ds.id with
    | Some (`Assoc dlg_def) ->
      let summary = match List.assoc_opt "summary" dlg_def with
        | Some (`String s) -> s
        | _ -> ds.id
      in
      let width = match List.assoc_opt "width" dlg_def with
        | Some (`Int w) -> w
        | _ -> 400
      in
      let dialog = GWindow.dialog
        ?parent
        ~title:summary
        ~width
        ~modal:true
        ~destroy_with_parent:true
        () in
      let vbox = dialog#vbox in
      let state_defaults = Workspace_loader.state_defaults ws in
      let icons = Workspace_loader.icons ws in
      let live_state = ref ds.state in
      Dialog_global.current_state := Some live_state;
      Dialog_global.current_id := Some ds.id;
      Dialog_global.current_outer_scope := outer_scope;
      Dialog_global.current_close := (fun () -> dialog#destroy ());
      Dialog_global.current_build_ctx := (fun () ->
        `Assoc (
          ("state", `Assoc state_defaults) ::
          ("dialog", `Assoc !live_state) ::
          ("param", `Assoc ds.params) ::
          ("icons", icons) ::
          outer_scope
        ));
      let ctx = !Dialog_global.current_build_ctx () in
      (match List.assoc_opt "content" dlg_def with
       | Some content ->
         Yaml_panel_view.render_element
           ~packing:(vbox#pack ~expand:false)
           ~ctx content
       | None -> ());
      dialog#show ();
      ignore (dialog#run ());
      (try dialog#destroy () with _ -> ());
      Dialog_global.current_state := None;
      Dialog_global.current_id := None;
      Dialog_global.current_outer_scope := [];
      Dialog_global.current_close := (fun () -> ());
      Dialog_global.current_build_ctx := (fun () -> `Assoc [])
    | _ -> ()
