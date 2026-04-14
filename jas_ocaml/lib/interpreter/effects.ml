(** Effects interpreter for the workspace YAML schema.

    Executes effect lists from actions and behaviors. Each effect is a
    JSON object with a single key identifying the effect type.
    Port of workspace_interpreter/effects.py. *)

let eval_expr (expr : Yojson.Safe.t) (store : State_store.t)
    (ctx : (string * Yojson.Safe.t) list) : Expr_eval.value =
  let expr_str = match expr with
    | `String s -> s
    | `Int n -> string_of_int n
    | `Float f -> string_of_float f
    | _ -> ""
  in
  let eval_ctx = State_store.eval_context ~extra:ctx store in
  Expr_eval.evaluate expr_str eval_ctx

let value_to_json (v : Expr_eval.value) : Yojson.Safe.t =
  match v with
  | Null -> `Null
  | Bool b -> `Bool b
  | Number n ->
    if n = Float.of_int (Float.to_int n) then `Int (Float.to_int n)
    else `Float n
  | Str s -> `String s
  | Color c -> `String c
  | List l -> `List l

(** Extract default values from a dialog state definition. *)
let state_defaults (state_defs : Yojson.Safe.t) : (string * Yojson.Safe.t) list =
  match state_defs with
  | `Assoc pairs ->
    List.filter_map (fun (key, defn) ->
      match defn with
      | `Assoc d ->
        (match List.assoc_opt "default" d with
         | Some v -> Some (key, v)
         | None -> Some (key, `Null))
      | _ -> Some (key, defn)
    ) pairs
  | _ -> []

(** Execute a list of effects.

    [actions] and [dialogs] default to [`Null] if not provided. *)
let rec run_effects_inner
    (effects : Yojson.Safe.t list)
    (ctx : (string * Yojson.Safe.t) list)
    (store : State_store.t)
    (actions : Yojson.Safe.t) (dialogs : Yojson.Safe.t) : unit =
  List.iter (function
    | `Assoc _ as eff -> run_one eff ctx store actions dialogs
    | _ -> ()
  ) effects

and run_one (eff : Yojson.Safe.t) (ctx : (string * Yojson.Safe.t) list)
    (store : State_store.t)
    (actions : Yojson.Safe.t) (dialogs : Yojson.Safe.t) : unit =
  let mem key = Workspace_loader.json_member key eff in

  (* set: { key: expr, ... } *)
  (match mem "set" with
   | Some (`Assoc pairs) ->
     List.iter (fun (key, expr) ->
       let value = eval_expr expr store ctx in
       State_store.set store key (value_to_json value)
     ) pairs;
     ()
   | _ ->

  (* toggle: state_key *)
  match mem "toggle" with
  | Some (`String key) ->
    let current = match State_store.get store key with `Bool b -> b | _ -> false in
    State_store.set store key (`Bool (not current))
  | _ ->

  (* swap: [key_a, key_b] *)
  match mem "swap" with
  | Some (`List [`String a; `String b]) ->
    let va = State_store.get store a in
    let vb = State_store.get store b in
    State_store.set store a vb;
    State_store.set store b va
  | _ ->

  (* increment: { key, by } *)
  match mem "increment" with
  | Some (`Assoc inc) ->
    let key = (match List.assoc_opt "key" inc with Some (`String k) -> k | _ -> "") in
    let by = (match List.assoc_opt "by" inc with Some (`Int n) -> Float.of_int n | Some (`Float f) -> f | _ -> 1.0) in
    let current = (match State_store.get store key with `Int n -> Float.of_int n | `Float f -> f | _ -> 0.0) in
    State_store.set store key (`Float (current +. by))
  | _ ->

  (* decrement: { key, by } *)
  match mem "decrement" with
  | Some (`Assoc dec) ->
    let key = (match List.assoc_opt "key" dec with Some (`String k) -> k | _ -> "") in
    let by = (match List.assoc_opt "by" dec with Some (`Int n) -> Float.of_int n | Some (`Float f) -> f | _ -> 1.0) in
    let current = (match State_store.get store key with `Int n -> Float.of_int n | `Float f -> f | _ -> 0.0) in
    State_store.set store key (`Float (current -. by))
  | _ ->

  (* if: { condition, then, else } *)
  match mem "if" with
  | Some (`Assoc cond) ->
    let cond_expr = (match List.assoc_opt "condition" cond with Some (`String s) -> s | _ -> "false") in
    let eval_ctx = State_store.eval_context ~extra:ctx store in
    let result = Expr_eval.evaluate cond_expr eval_ctx in
    if Expr_eval.to_bool result then
      (match List.assoc_opt "then" cond with
       | Some (`List then_effects) ->
         run_effects_inner then_effects ctx store actions dialogs
       | _ -> ())
    else
      (match List.assoc_opt "else" cond with
       | Some (`List else_effects) ->
         run_effects_inner else_effects ctx store actions dialogs
       | _ -> ())
  | _ ->

  (* set_panel_state: { key, value, panel? } *)
  match mem "set_panel_state" with
  | Some (`Assoc sps) ->
    let key = (match List.assoc_opt "key" sps with Some (`String k) -> k | _ -> "") in
    let value_expr = (match List.assoc_opt "value" sps with Some v -> v | _ -> `String "null") in
    let value = eval_expr value_expr store ctx in
    let panel_id = match List.assoc_opt "panel" sps with
      | Some (`String p) -> Some p
      | _ -> State_store.get_active_panel_id store
    in
    (match panel_id with
     | Some pid -> State_store.set_panel store pid key (value_to_json value)
     | None -> ())
  | _ ->

  (* dispatch: action_name or { action, params } *)
  match mem "dispatch" with
  | Some dispatch ->
    let action_name, params = match dispatch with
      | `String s -> (s, [])
      | `Assoc d ->
        let name = (match List.assoc_opt "action" d with Some (`String s) -> s | _ -> "") in
        let p = (match List.assoc_opt "params" d with Some (`Assoc p) -> p | _ -> []) in
        (name, p)
      | _ -> ("", [])
    in
    (match actions with
     | `Assoc actions_map ->
       (match List.assoc_opt action_name actions_map with
        | Some (`Assoc action_def) ->
          let action_effects = (match List.assoc_opt "effects" action_def with Some (`List e) -> e | _ -> []) in
          let dispatch_ctx =
            if params = [] then ctx
            else
              let resolved = List.map (fun (k, v) ->
                let value = eval_expr v store ctx in
                (k, value_to_json value)
              ) params in
              ("param", `Assoc resolved) :: List.filter (fun (k, _) -> k <> "param") ctx
          in
          run_effects_inner action_effects dispatch_ctx store actions dialogs
        | _ -> ())
     | _ -> ())
  | _ ->

  (* open_dialog: { id, params } *)
  match mem "open_dialog" with
  | Some od ->
    let dlg_id = match od with
      | `Assoc d -> (match List.assoc_opt "id" d with Some (`String s) -> s | _ -> "")
      | `String s -> s
      | _ -> ""
    in
    let raw_params = match od with
      | `Assoc d -> (match List.assoc_opt "params" d with Some (`Assoc p) -> p | _ -> [])
      | _ -> []
    in
    (match dialogs with
     | `Assoc dialogs_map ->
       (match List.assoc_opt dlg_id dialogs_map with
        | Some (`Assoc dlg_def) ->
          (* Extract state defaults *)
          let defaults = match List.assoc_opt "state" dlg_def with
            | Some defs -> state_defaults defs
            | None -> []
          in
          (* Resolve params *)
          let resolved_params = List.map (fun (k, v) ->
            let value = eval_expr v store ctx in
            (k, value_to_json value)
          ) raw_params in
          (* Init dialog *)
          let params_opt = if resolved_params = [] then None else Some resolved_params in
          State_store.init_dialog store dlg_id defaults ?params:params_opt ();
          (* Evaluate init expressions (two-pass for dict order independence) *)
          (match List.assoc_opt "init" dlg_def with
           | Some (`Assoc init_map) ->
             let deferred = ref [] in
             List.iter (fun (key, expr) ->
               let expr_str = (match expr with `String s -> s | _ -> "") in
               if (try ignore (Str.search_forward (Str.regexp_string "dialog.") expr_str 0); true
                   with Not_found -> false) then
                 deferred := (key, expr) :: !deferred
               else begin
                 let value = eval_expr expr store ctx in
                 State_store.set_dialog store key (value_to_json value)
               end
             ) init_map;
             List.iter (fun (key, expr) ->
               let value = eval_expr expr store ctx in
               State_store.set_dialog store key (value_to_json value)
             ) (List.rev !deferred)
           | _ -> ())
        | _ -> ())
     | _ -> ())
  | _ ->

  (* close_dialog: null or dialog_id *)
  match mem "close_dialog" with
  | Some _ -> State_store.close_dialog store
  | None ->

  (* start_timer: { id, delay_ms, effects } *)
  match mem "start_timer" with
  | Some (`Assoc st) ->
    let timer_id = (match List.assoc_opt "id" st with Some (`String s) -> s | _ -> "") in
    let delay_ms = (match List.assoc_opt "delay_ms" st with Some (`Int n) -> n | _ -> 250) in
    let nested = (match List.assoc_opt "effects" st with Some (`List e) -> e | _ -> []) in
    Timer_manager.start_timer timer_id delay_ms (fun () ->
      run_effects_inner nested ctx store actions dialogs
    )
  | _ ->

  (* cancel_timer: id *)
  match mem "cancel_timer" with
  | Some (`String id) -> Timer_manager.cancel_timer id
  | _ ->

  (* log: message (no-op) *)
  match mem "log" with
  | Some _ -> ()
  | None -> ())

let run_effects
    ?(actions : Yojson.Safe.t = `Null)
    ?(dialogs : Yojson.Safe.t = `Null)
    (effects : Yojson.Safe.t list)
    (ctx : (string * Yojson.Safe.t) list)
    (store : State_store.t) : unit =
  run_effects_inner effects ctx store actions dialogs
