(** Reactive state store for the workspace interpreter.

    Manages global state, panel-scoped state, and dialog-scoped state.
    Port of workspace_interpreter/state_store.py. *)

type t = {
  mutable state : (string * Yojson.Safe.t) list;
  mutable panels : (string * (string * Yojson.Safe.t) list) list;
  mutable active_panel : string option;
  mutable dialog : (string * Yojson.Safe.t) list;
  mutable dialog_id : string option;
  mutable dialog_params : (string * Yojson.Safe.t) list option;
}

let create ?(defaults = []) () : t =
  { state = defaults;
    panels = [];
    active_panel = None;
    dialog = [];
    dialog_id = None;
    dialog_params = None }

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

let set_panel (store : t) (panel_id : string) (key : string) (value : Yojson.Safe.t) : unit =
  match List.assoc_opt panel_id store.panels with
  | Some scope ->
    let new_scope = (key, value) :: List.filter (fun (k, _) -> k <> key) scope in
    store.panels <- (panel_id, new_scope) :: List.filter (fun (k, _) -> k <> panel_id) store.panels
  | None -> ()

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
    ?params () : unit =
  store.dialog_id <- Some dialog_id;
  store.dialog <- defaults;
  store.dialog_params <- params

let get_dialog (store : t) (key : string) : Yojson.Safe.t option =
  match store.dialog_id with
  | None -> None
  | Some _ -> List.assoc_opt key store.dialog

let set_dialog (store : t) (key : string) (value : Yojson.Safe.t) : unit =
  match store.dialog_id with
  | None -> ()
  | Some _ ->
    store.dialog <- (key, value) :: List.filter (fun (k, _) -> k <> key) store.dialog

let get_dialog_state (store : t) : (string * Yojson.Safe.t) list =
  store.dialog

let get_dialog_id (store : t) : string option =
  store.dialog_id

let get_dialog_params (store : t) : (string * Yojson.Safe.t) list option =
  store.dialog_params

let close_dialog (store : t) : unit =
  store.dialog_id <- None;
  store.dialog <- [];
  store.dialog_params <- None

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
  let merged = with_dialog @ extra in
  `Assoc merged
