(** YAML-interpreted dialog component for GTK3.

    Renders a modal dialog from workspace YAML definitions, reusing the
    existing element renderer for the content tree. *)

(** Dialog state. *)
type dialog_state = {
  id : string;
  state : (string * Yojson.Safe.t) list;
  params : (string * Yojson.Safe.t) list;
}

(** Open a dialog by ID, initializing its state from the workspace definition.
    Returns [Some dialog_state] on success, [None] if dialog not found. *)
let open_dialog (dialog_id : string)
    (raw_params : (string * Yojson.Safe.t) list)
    (live_state : (string * Yojson.Safe.t) list) : dialog_state option =
  match Workspace_loader.load () with
  | None -> None
  | Some ws ->
    match Workspace_loader.dialog ws dialog_id with
    | None -> None
    | Some (`Assoc dlg_def) ->
      (* Extract state defaults *)
      let defaults = match List.assoc_opt "state" dlg_def with
        | Some defs -> Effects.state_defaults defs
        | None -> []
      in
      (* Resolve param expressions *)
      let state_ctx = `Assoc [("state", `Assoc live_state)] in
      let resolved_params = List.map (fun (k, v) ->
        let expr_str = match v with `String s -> s | _ -> "" in
        let result = Expr_eval.evaluate expr_str state_ctx in
        (k, Effects.value_to_json result)
      ) raw_params in
      (* Init dialog state *)
      let dialog_state = ref defaults in
      (* Evaluate init expressions (two-pass) *)
      (match List.assoc_opt "init" dlg_def with
       | Some (`Assoc init_map) ->
         let deferred = ref [] in
         List.iter (fun (key, expr) ->
           let expr_str = match expr with `String s -> s | _ -> "" in
           if (try ignore (Str.search_forward (Str.regexp_string "dialog.") expr_str 0); true
               with Not_found -> false) then
             deferred := (key, expr) :: !deferred
           else begin
             let init_ctx = `Assoc [
               ("state", `Assoc live_state);
               ("dialog", `Assoc !dialog_state);
               ("param", `Assoc resolved_params);
             ] in
             let result = Expr_eval.evaluate expr_str init_ctx in
             dialog_state := (key, Effects.value_to_json result) ::
               List.filter (fun (k, _) -> k <> key) !dialog_state
           end
         ) init_map;
         List.iter (fun (key, expr) ->
           let expr_str = match expr with `String s -> s | _ -> "" in
           let init_ctx = `Assoc [
             ("state", `Assoc live_state);
             ("dialog", `Assoc !dialog_state);
             ("param", `Assoc resolved_params);
           ] in
           let result = Expr_eval.evaluate expr_str init_ctx in
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

(** Show a YAML dialog as a GTK modal dialog.
    Renders the dialog content using [Yaml_panel_view.render_element]. *)
let show_dialog ?(parent : GWindow.window option) (ds : dialog_state) : unit =
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
      (* Build eval context *)
      let state_defaults = Workspace_loader.state_defaults ws in
      let icons = Workspace_loader.icons ws in
      let ctx = `Assoc [
        ("state", `Assoc state_defaults);
        ("dialog", `Assoc ds.state);
        ("param", `Assoc ds.params);
        ("icons", icons);
      ] in
      (* Render dialog content *)
      (match List.assoc_opt "content" dlg_def with
       | Some content ->
         Yaml_panel_view.render_element
           ~packing:(vbox#pack ~expand:false)
           ~ctx content
       | None -> ());
      (* Show and run *)
      dialog#show ();
      ignore (dialog#run ());
      dialog#destroy ()
    | _ -> ()
