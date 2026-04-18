(** Reactive state store for the workspace interpreter.

    Manages global state, panel-scoped state, and dialog-scoped state.
    Port of workspace_interpreter/state_store.py. *)

type prop_def = {
  prop_get : string option;   (** getter expression *)
  prop_set : string option;   (** setter expression (should evaluate to a lambda) *)
}

(** Callback invoked on a panel-state write: (key, new_value). *)
type panel_subscriber = string -> Yojson.Safe.t -> unit

type t = {
  mutable state : (string * Yojson.Safe.t) list;
  mutable panels : (string * (string * Yojson.Safe.t) list) list;
  mutable active_panel : string option;
  mutable dialog : (string * Yojson.Safe.t) list;
  mutable dialog_id : string option;
  mutable dialog_params : (string * Yojson.Safe.t) list option;
  mutable dialog_props : (string * prop_def) list;
  mutable panel_subscribers : (string * panel_subscriber list) list;
}

let create ?(defaults = []) () : t =
  { state = defaults;
    panels = [];
    active_panel = None;
    dialog = [];
    dialog_id = None;
    dialog_params = None;
    dialog_props = [];
    panel_subscribers = [] }

(* ── Global state ─────────────────────────────────────── *)

let get (store : t) (key : string) : Yojson.Safe.t =
  match List.assoc_opt key store.state with
  | Some v -> v
  | None -> `Null

let set (store : t) (key : string) (value : Yojson.Safe.t) : unit =
  store.state <- (key, value) :: List.filter (fun (k, _) -> k <> key) store.state

let get_all (store : t) : (string * Yojson.Safe.t) list =
  store.state

(* ── Panel state ──────────────────────────────────────── *)

let init_panel (store : t) (panel_id : string) (defaults : (string * Yojson.Safe.t) list) : unit =
  store.panels <- (panel_id, defaults) :: List.filter (fun (k, _) -> k <> panel_id) store.panels

let get_panel (store : t) (panel_id : string) (key : string) : Yojson.Safe.t =
  match List.assoc_opt panel_id store.panels with
  | Some scope -> (match List.assoc_opt key scope with Some v -> v | None -> `Null)
  | None -> `Null

let _notify_panel (store : t) (panel_id : string) (key : string) (value : Yojson.Safe.t) : unit =
  match List.assoc_opt panel_id store.panel_subscribers with
  | Some subs -> List.iter (fun sub -> sub key value) subs
  | None -> ()

let set_panel (store : t) (panel_id : string) (key : string) (value : Yojson.Safe.t) : unit =
  match List.assoc_opt panel_id store.panels with
  | Some scope ->
    let new_scope = (key, value) :: List.filter (fun (k, _) -> k <> key) scope in
    store.panels <- (panel_id, new_scope) :: List.filter (fun (k, _) -> k <> panel_id) store.panels;
    _notify_panel store panel_id key value
  | None -> ()

(** Subscribe to panel state changes. The callback receives the
    (key, new_value) pair after every successful [set_panel] on
    [panel_id]. Mirrors Python's [StateStore.subscribe_panel]. *)
let subscribe_panel (store : t) (panel_id : string) (callback : panel_subscriber) : unit =
  let existing = match List.assoc_opt panel_id store.panel_subscribers with
    | Some subs -> subs
    | None -> [] in
  store.panel_subscribers <-
    (panel_id, callback :: existing)
    :: List.filter (fun (k, _) -> k <> panel_id) store.panel_subscribers

let set_active_panel (store : t) (panel_id : string option) : unit =
  store.active_panel <- panel_id

let get_active_panel_id (store : t) : string option =
  store.active_panel

let get_active_panel_state (store : t) : (string * Yojson.Safe.t) list =
  match store.active_panel with
  | Some pid -> (match List.assoc_opt pid store.panels with Some s -> s | None -> [])
  | None -> []

let destroy_panel (store : t) (panel_id : string) : unit =
  store.panels <- List.filter (fun (k, _) -> k <> panel_id) store.panels;
  if store.active_panel = Some panel_id then store.active_panel <- None

(* ── Dialog state ─────────────────────────────────────── *)

let init_dialog (store : t) (dialog_id : string)
    (defaults : (string * Yojson.Safe.t) list)
    ?params ?(props = []) () : unit =
  store.dialog_id <- Some dialog_id;
  store.dialog <- defaults;
  store.dialog_params <- params;
  store.dialog_props <- props

let get_dialog (store : t) (key : string) : Yojson.Safe.t option =
  match store.dialog_id with
  | None -> None
  | Some _ ->
    (match List.assoc_opt key store.dialog_props with
     | Some prop when prop.prop_get <> None ->
       (* Evaluate getter expression against sibling dialog state as bare names *)
       let get_expr = match prop.prop_get with Some e -> e | None -> "" in
       let local_ctx = `Assoc store.dialog in
       let result = Expr_eval.evaluate get_expr local_ctx in
       Some (Expr_eval.value_to_json result)
     | _ -> List.assoc_opt key store.dialog)

let set_dialog (store : t) (key : string) (value : Yojson.Safe.t) : unit =
  match store.dialog_id with
  | None -> ()
  | Some _ ->
    (match List.assoc_opt key store.dialog_props with
     | Some prop when prop.prop_set <> None ->
       (* Evaluate setter as a lambda expression, then apply with the value *)
       let set_expr = match prop.prop_set with Some e -> e | None -> "" in
       let local_ctx = `Assoc store.dialog in
       let store_cb target v =
         store.dialog <- (target, Expr_eval.value_to_json v)
           :: List.filter (fun (k, _) -> k <> target) store.dialog
       in
       let setter_val = Expr_eval.evaluate ~store_cb set_expr local_ctx in
       (match setter_val with
        | Expr_eval.Closure (params, body, captured_env) ->
          if List.length params = 1 then begin
            let param_name = List.hd params in
            let arg_val = Expr_eval.value_of_json value in
            let call_env = (param_name, arg_val) :: captured_env in
            ignore (Expr_eval.eval_node ~local_env:call_env ~store_cb body local_ctx)
          end
        | _ -> ())
     | Some prop when prop.prop_get <> None ->
       ()  (* read-only — ignore writes *)
     | _ ->
       store.dialog <- (key, value) :: List.filter (fun (k, _) -> k <> key) store.dialog)

let get_dialog_state (store : t) : (string * Yojson.Safe.t) list =
  store.dialog

let get_dialog_id (store : t) : string option =
  store.dialog_id

let get_dialog_params (store : t) : (string * Yojson.Safe.t) list option =
  store.dialog_params

let close_dialog (store : t) : unit =
  store.dialog_id <- None;
  store.dialog <- [];
  store.dialog_params <- None;
  store.dialog_props <- []

(* ── Context for expression evaluation ────────────────── *)

let eval_context ?(extra = []) (store : t) : Yojson.Safe.t =
  let state_obj = `Assoc store.state in
  let panel_obj =
    match store.active_panel with
    | Some pid ->
      (match List.assoc_opt pid store.panels with
       | Some scope -> `Assoc scope
       | None -> `Assoc [])
    | None -> `Assoc []
  in
  let base = [("state", state_obj); ("panel", panel_obj)] in
  let with_dialog =
    match store.dialog_id with
    | Some _ ->
      let dlg = ("dialog", `Assoc store.dialog) in
      let params =
        match store.dialog_params with
        | Some p -> [("param", `Assoc p)]
        | None -> []
      in
      base @ [dlg] @ params
    | None -> base
  in
  (* extra overrides store defaults: put extra first so List.assoc_opt
     returns caller-supplied values (e.g. panel.layers_panel_selection
     from panel_menu.dispatch_yaml_action) rather than the empty store
     default. *)
  let merged = extra @ with_dialog in
  `Assoc merged
