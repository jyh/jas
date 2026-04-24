(** Reactive state store for the workspace interpreter.

    Manages global state, panel-scoped state, and dialog-scoped state.
    Port of workspace_interpreter/state_store.py. *)

type prop_def = {
  prop_get : string option;   (** getter expression *)
  prop_set : string option;   (** setter expression (should evaluate to a lambda) *)
}

(** Callback invoked on a panel-state write: (key, new_value). *)
type panel_subscriber = string -> Yojson.Safe.t -> unit

(** Callback invoked on a global-state write: (key, new_value). *)
type global_subscriber = string -> Yojson.Safe.t -> unit

type t = {
  mutable state : (string * Yojson.Safe.t) list;
  mutable panels : (string * (string * Yojson.Safe.t) list) list;
  mutable active_panel : string option;
  (** Tool-scoped state parallels [panels] but is keyed by tool id.
      YAML tool handlers read/write via [$tool.<id>.<key>]; the
      [set] effect routes those targets here via the scope-routed
      set in [Effects]. Populated by [Yaml_tool] when a tool
      registers with its declared state defaults. *)
  mutable tools : (string * (string * Yojson.Safe.t) list) list;
  mutable dialog : (string * Yojson.Safe.t) list;
  mutable dialog_id : string option;
  mutable dialog_params : (string * Yojson.Safe.t) list option;
  mutable dialog_props : (string * prop_def) list;
  (** Captured original values of state keys named in the open
      dialog's preview_targets. Restored on close_dialog (via the
      close_dialog effect) unless first cleared by the
      clear_dialog_snapshot effect (used by OK actions). *)
  mutable dialog_snapshot : (string * Yojson.Safe.t) list option;
  mutable panel_subscribers : (string * panel_subscriber list) list;
  mutable global_subscribers : global_subscriber list;
  (** Workspace-loaded reference data (swatch_libraries,
      brush_libraries, etc.). Mirrors the JS-side `data` namespace
      and the Rust StateStore.data field. Mutated by the brush.*
      effect handlers. *)
  mutable data : Yojson.Safe.t;
}

let create ?(defaults = []) () : t =
  { state = defaults;
    panels = [];
    active_panel = None;
    tools = [];
    dialog = [];
    dialog_id = None;
    dialog_params = None;
    dialog_props = [];
    dialog_snapshot = None;
    panel_subscribers = [];
    global_subscribers = [];
    data = `Assoc [] }

(* ── Global state ─────────────────────────────────────── *)

let get (store : t) (key : string) : Yojson.Safe.t =
  match List.assoc_opt key store.state with
  | Some v -> v
  | None -> `Null

let set (store : t) (key : string) (value : Yojson.Safe.t) : unit =
  store.state <- (key, value) :: List.filter (fun (k, _) -> k <> key) store.state;
  List.iter (fun sub -> sub key value) store.global_subscribers

let subscribe_global (store : t) (callback : global_subscriber) : unit =
  store.global_subscribers <- callback :: store.global_subscribers

(* ── Data namespace ─────────────────────────────────── *)

let set_data (store : t) (data : Yojson.Safe.t) : unit =
  store.data <- data

let get_data (store : t) : Yojson.Safe.t =
  store.data

(* Strip optional "data." prefix and split on '.'. *)
let split_data_path (raw : string) : string list =
  let path =
    if String.length raw >= 5 && String.sub raw 0 5 = "data."
    then String.sub raw 5 (String.length raw - 5)
    else raw
  in
  if path = "" then [] else String.split_on_char '.' path

let rec get_path (json : Yojson.Safe.t) (segs : string list) : Yojson.Safe.t =
  match segs, json with
  | [], _ -> json
  | seg :: rest, `Assoc fields ->
    (match List.assoc_opt seg fields with
     | Some v -> get_path v rest
     | None -> `Null)
  | _ -> `Null

let get_data_path (store : t) (raw_path : string) : Yojson.Safe.t =
  get_path store.data (split_data_path raw_path)

let rec set_path (json : Yojson.Safe.t) (segs : string list) (value : Yojson.Safe.t)
  : Yojson.Safe.t =
  match segs with
  | [] -> value
  | seg :: rest ->
    let fields = match json with `Assoc fs -> fs | _ -> [] in
    let inner = match List.assoc_opt seg fields with
      | Some v -> v
      | None -> `Assoc []
    in
    let new_inner = set_path inner rest value in
    let other = List.filter (fun (k, _) -> k <> seg) fields in
    `Assoc ((seg, new_inner) :: other)

let set_data_path (store : t) (raw_path : string) (value : Yojson.Safe.t) : unit =
  let segs = split_data_path raw_path in
  if segs = [] then store.data <- value
  else store.data <- set_path store.data segs value

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

(* ── Tool state ───────────────────────────────────────── *)

let init_tool (store : t) (tool_id : string)
    (defaults : (string * Yojson.Safe.t) list) : unit =
  store.tools <- (tool_id, defaults) :: List.filter (fun (k, _) -> k <> tool_id) store.tools

let has_tool (store : t) (tool_id : string) : bool =
  List.mem_assoc tool_id store.tools

let get_tool (store : t) (tool_id : string) (key : string) : Yojson.Safe.t =
  match List.assoc_opt tool_id store.tools with
  | Some scope -> (match List.assoc_opt key scope with Some v -> v | None -> `Null)
  | None -> `Null

let set_tool (store : t) (tool_id : string) (key : string) (value : Yojson.Safe.t) : unit =
  (* Create the tool namespace on first write — matches Rust/Swift
     set_tool behavior so callers that didn't explicitly init_tool
     still work. *)
  let scope = match List.assoc_opt tool_id store.tools with
    | Some s -> s
    | None -> []
  in
  let new_scope = (key, value) :: List.filter (fun (k, _) -> k <> key) scope in
  store.tools <- (tool_id, new_scope) :: List.filter (fun (k, _) -> k <> tool_id) store.tools

let get_tool_state (store : t) (tool_id : string) : (string * Yojson.Safe.t) list =
  match List.assoc_opt tool_id store.tools with Some s -> s | None -> []

let destroy_tool (store : t) (tool_id : string) : unit =
  store.tools <- List.filter (fun (k, _) -> k <> tool_id) store.tools

(** Return all tool scopes (for tests / inspection). *)
let get_tool_scopes (store : t) : (string * (string * Yojson.Safe.t) list) list =
  store.tools

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

(** Capture the current value of every state key referenced by a
    dialog's preview_targets. Phase 0 supports only top-level state
    keys (no dots in the path); deep paths are silently skipped and
    will land alongside their first real consumer in Phase 8/9.
    [targets] is a list of [(dialog_state_key, state_key)] pairs. *)
let capture_dialog_snapshot (store : t)
    (targets : (string * string) list) : unit =
  let snap = List.filter_map (fun (_dlg_key, state_key) ->
    if String.contains state_key '.' then None
    else Some (state_key, get store state_key)
  ) targets in
  store.dialog_snapshot <- Some snap

let get_dialog_snapshot (store : t) : (string * Yojson.Safe.t) list option =
  store.dialog_snapshot

let clear_dialog_snapshot (store : t) : unit =
  store.dialog_snapshot <- None

let has_dialog_snapshot (store : t) : bool =
  store.dialog_snapshot <> None

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
  (* Tool scope — one nested dict per registered tool. Expressions
     read as [tool.<id>.<key>]. Populated by [Yaml_tool]. *)
  let tool_obj =
    `Assoc (List.map (fun (id, scope) -> (id, `Assoc scope)) store.tools)
  in
  let base = [("state", state_obj); ("panel", panel_obj);
              ("tool", tool_obj)] in
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
