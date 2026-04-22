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
  | Path indices ->
    `Assoc [("__path__", `List (List.map (fun i -> `Int i) indices))]
  | Closure _ -> `Null

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

(** Platform-specific effect handler: (effect_value, ctx, store) -> return value.
    Registered by the calling app (e.g. panel_menu wires snapshot/doc.set
    to the active Model). Key is the effect name like "snapshot". The
    return value (if non-Null) is bound to the effect's optional
    `as: <name>` field for subsequent effects in the same list. *)
type platform_effect = Yojson.Safe.t -> (string * Yojson.Safe.t) list -> State_store.t -> Yojson.Safe.t

let rec run_effects_inner
    (effects : Yojson.Safe.t list)
    (ctx : (string * Yojson.Safe.t) list)
    (store : State_store.t)
    (actions : Yojson.Safe.t) (dialogs : Yojson.Safe.t)
    ?(schema = false)
    ?(platform_effects : (string * platform_effect) list = [])
    (diagnostics : Schema.diagnostic list ref) : unit =
  (* Thread ctx through sibling effects: `let:` at position N extends
     ctx for positions N+1..end. Nested lists (then/else/do) get their
     own threading via recursive calls and don't leak bindings back. *)
  let ctx_ref = ref ctx in
  let try_platform (eff : Yojson.Safe.t) : bool =
    match eff with
    | `Assoc pairs ->
      (* Extract optional as: <name> return-binding (PHASE3 §5.5).
         Skip the "as" key when dispatching to a handler. *)
      let as_name = match List.assoc_opt "as" pairs with
        | Some (`String s) -> Some s | _ -> None
      in
      List.exists (fun (key, value) ->
        if key = "as" then false
        else match List.assoc_opt key platform_effects with
          | Some handler ->
            let result = handler value !ctx_ref store in
            (match as_name, result with
             | Some name, v when v <> `Null ->
               ctx_ref := (name, v) ::
                 List.filter (fun (k, _) -> k <> name) !ctx_ref
             | _ -> ());
            true
          | None -> false
      ) pairs
    | `String key ->
      (match List.assoc_opt key platform_effects with
       | Some handler -> ignore (handler `Null !ctx_ref store); true
       | None -> false)
    | _ -> false
  in
  List.iter (fun eff ->
    match eff with
    | `Assoc _ ->
      let mem key = Workspace_loader.json_member key eff in
      (* let: { name: expr, ... } — PHASE3 §5.1 *)
      (match mem "let" with
       | Some (`Assoc pairs) ->
         ctx_ref := List.fold_left (fun acc (name, expr) ->
           let value = eval_expr expr store acc in
           (name, value_to_json value) :: List.filter (fun (k, _) -> k <> name) acc
         ) !ctx_ref pairs
       | _ ->
         (* foreach: { source, as } do: [...] — PHASE3 §5.3 *)
         match mem "foreach", mem "do" with
         | Some (`Assoc spec), Some (`List body) ->
           let source_expr = (match List.assoc_opt "source" spec with
             | Some v -> v | None -> `String "[]") in
           let var_name = (match List.assoc_opt "as" spec with
             | Some (`String s) -> s | _ -> "item") in
           let items = match eval_expr source_expr store !ctx_ref with
             | Expr_eval.List lst -> lst
             | _ -> []
           in
           List.iteri (fun i item ->
             (* Fresh iteration scope: outer ctx + iteration variable.
                Bindings made inside do: do not leak between iterations. *)
             let iter_ctx =
               (var_name, item) ::
               ("_index", `Int i) ::
               List.filter (fun (k, _) ->
                 k <> var_name && k <> "_index"
               ) !ctx_ref
             in
             run_effects_inner body iter_ctx store actions dialogs
               ~schema ~platform_effects diagnostics
           ) items
         | _ ->
           if not (try_platform eff) then
             run_one eff !ctx_ref store actions dialogs
               ~platform_effects ~schema diagnostics)
    | `String _ ->
      (* Bare-string effects — platform handlers may catch snapshot etc. *)
      ignore (try_platform eff)
    | _ -> ()
  ) effects

and run_one (eff : Yojson.Safe.t) (ctx : (string * Yojson.Safe.t) list)
    (store : State_store.t)
    (actions : Yojson.Safe.t) (dialogs : Yojson.Safe.t)
    ?(schema = false)
    ?(platform_effects : (string * platform_effect) list = [])
    (diagnostics : Schema.diagnostic list ref) : unit =
  let mem key = Workspace_loader.json_member key eff in

  (* set: { key: expr, ... } *)
  (match mem "set" with
   | Some (`Assoc pairs) ->
     if schema then begin
       (* Schema-driven: evaluate then coerce+validate *)
       let evaluated = List.map (fun (key, expr) ->
         let value = eval_expr expr store ctx in
         (key, value_to_json value)
       ) pairs in
       Schema.apply_set_schemadriven evaluated store diagnostics
     end else
       List.iter (fun (key, expr) ->
         let value = eval_expr expr store ctx in
         State_store.set store key (value_to_json value)
       ) pairs
   | _ ->

  (* toggle: state_key *)
  match mem "toggle" with
  | Some (`String key) ->
    let current = match State_store.get store key with `Bool b -> b | _ -> false in
    State_store.set store key (`Bool (not current))
  | _ ->

  (* pop: panel.field_name  or  global_field_name *)
  match mem "pop" with
  | Some (`String target) ->
    let dot = String.index_opt target '.' in
    (match dot with
     | Some i when String.sub target 0 i = "panel" ->
       let field = String.sub target (i + 1) (String.length target - i - 1) in
       (match State_store.get_active_panel_id store with
        | Some pid ->
          let lst = State_store.get_panel store pid field in
          (match lst with
           | `List (_ :: _ as items) ->
             let without_last = List.filteri (fun i _ -> i < List.length items - 1) items in
             State_store.set_panel store pid field (`List without_last)
           | _ -> ())
        | None -> ())
     | _ ->
       let lst = State_store.get store target in
       (match lst with
        | `List (_ :: _ as items) ->
          let without_last = List.filteri (fun i _ -> i < List.length items - 1) items in
          State_store.set store target (`List without_last)
        | _ -> ()))
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
           ~platform_effects ~schema diagnostics
       | _ -> ())
    else
      (match List.assoc_opt "else" cond with
       | Some (`List else_effects) ->
         run_effects_inner else_effects ctx store actions dialogs
           ~platform_effects ~schema diagnostics
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
            ~platform_effects ~schema diagnostics
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
           | _ -> ());
          (* Capture preview snapshot if the dialog declares
             preview_targets. Restored on close_dialog unless first
             cleared by an OK action via clear_dialog_snapshot. *)
          (match List.assoc_opt "preview_targets" dlg_def with
           | Some (`Assoc targets_obj) ->
             let targets = List.filter_map (fun (k, v) ->
               match v with `String s -> Some (k, s) | _ -> None
             ) targets_obj in
             State_store.capture_dialog_snapshot store targets
           | _ -> ())
        | _ -> ())
     | _ -> ())
  | _ ->

  (* close_dialog: null or dialog_id *)
  match mem "close_dialog" with
  | Some _ ->
    (* Preview restore: if a snapshot survived (i.e., no OK action
       cleared it), revert each target to its captured original
       value. Phase 0 handles only top-level state keys. *)
    (match State_store.get_dialog_snapshot store with
     | Some snapshot ->
       List.iter (fun (key, value) ->
         if not (String.contains key '.') then
           State_store.set store key value
       ) snapshot;
       State_store.clear_dialog_snapshot store
     | None -> ());
    State_store.close_dialog store
  | None ->

  (* clear_dialog_snapshot: drop the preview snapshot so close_dialog
     does not restore. OK actions emit this before close_dialog to commit. *)
  match mem "clear_dialog_snapshot" with
  | Some _ -> State_store.clear_dialog_snapshot store
  | None ->

  (* start_timer: { id, delay_ms, effects } *)
  match mem "start_timer" with
  | Some (`Assoc st) ->
    let timer_id = (match List.assoc_opt "id" st with Some (`String s) -> s | _ -> "") in
    let delay_ms = (match List.assoc_opt "delay_ms" st with Some (`Int n) -> n | _ -> 250) in
    let nested = (match List.assoc_opt "effects" st with Some (`List e) -> e | _ -> []) in
    let timer_diags = ref [] in
    Timer_manager.start_timer timer_id delay_ms (fun () ->
      run_effects_inner nested ctx store actions dialogs
        ~platform_effects ~schema timer_diags
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
    ?(schema = false)
    ?(platform_effects : (string * platform_effect) list = [])
    ?(diagnostics : Schema.diagnostic list ref = ref [])
    (effects : Yojson.Safe.t list)
    (ctx : (string * Yojson.Safe.t) list)
    (store : State_store.t) : unit =
  run_effects_inner effects ctx store actions dialogs
    ~schema ~platform_effects diagnostics

(* ------------------------------------------------------------------ *)
(* Stroke panel state binding                                          *)
(* ------------------------------------------------------------------ *)

(** Rendering-affecting stroke state keys. *)
let stroke_render_keys = [
  "stroke_cap"; "stroke_join"; "stroke_weight"; "stroke_miter_limit";
  "stroke_dashed"; "stroke_dash_1"; "stroke_gap_1";
  "stroke_dash_2"; "stroke_gap_2"; "stroke_dash_3"; "stroke_gap_3";
  "stroke_align_stroke"; "stroke_start_arrowhead"; "stroke_end_arrowhead";
  "stroke_start_arrowhead_scale"; "stroke_end_arrowhead_scale";
  "stroke_arrow_align"; "stroke_profile"; "stroke_profile_flipped";
]

let json_to_float_opt = function
  | `Float f -> Some f
  | `Int n -> Some (float_of_int n)
  | _ -> None

let json_to_float_default default = function
  | `Float f -> f
  | `Int n -> float_of_int n
  | _ -> default

let json_to_string_default default = function
  | `String s -> s
  | _ -> default

let json_to_bool_default default = function
  | `Bool b -> b
  | _ -> default

(** Build a Stroke from the state store's stroke_* keys and apply to selection. *)
let apply_stroke_panel_to_selection (store : State_store.t)
    (ctrl : Controller.controller) =
  let s = State_store.get_all store in
  let get key = match List.assoc_opt key s with Some v -> v | None -> `Null in
  let cap = match json_to_string_default "butt" (get "stroke_cap") with
    | "round" -> Element.Round_cap
    | "square" -> Element.Square
    | _ -> Element.Butt in
  let join = match json_to_string_default "miter" (get "stroke_join") with
    | "round" -> Element.Round_join
    | "bevel" -> Element.Bevel
    | _ -> Element.Miter in
  let miter_limit = json_to_float_default 10.0 (get "stroke_miter_limit") in
  let align = match json_to_string_default "center" (get "stroke_align_stroke") with
    | "inside" -> Element.Inside
    | "outside" -> Element.Outside
    | _ -> Element.Center in
  let dashed = json_to_bool_default false (get "stroke_dashed") in
  let dash_pattern =
    if dashed then begin
      let d1 = json_to_float_default 12.0 (get "stroke_dash_1") in
      let g1 = json_to_float_default 12.0 (get "stroke_gap_1") in
      let base = [d1; g1] in
      let extra1 = match json_to_float_opt (get "stroke_dash_2"),
                          json_to_float_opt (get "stroke_gap_2") with
        | Some d2, Some g2 -> [d2; g2]
        | _ -> [] in
      let extra2 = match json_to_float_opt (get "stroke_dash_3"),
                          json_to_float_opt (get "stroke_gap_3") with
        | Some d3, Some g3 -> [d3; g3]
        | _ -> [] in
      base @ extra1 @ extra2
    end else [] in
  let start_arrow = Element.arrowhead_of_string
    (json_to_string_default "none" (get "stroke_start_arrowhead")) in
  let end_arrow = Element.arrowhead_of_string
    (json_to_string_default "none" (get "stroke_end_arrowhead")) in
  let start_arrow_scale = json_to_float_default 100.0
    (get "stroke_start_arrowhead_scale") in
  let end_arrow_scale = json_to_float_default 100.0
    (get "stroke_end_arrowhead_scale") in
  let arrow_align = match json_to_string_default "tip_at_end" (get "stroke_arrow_align") with
    | "center_at_end" -> Element.Center_at_end
    | _ -> Element.Tip_at_end in
  (* Get base stroke from selection or default *)
  let doc = ctrl#document in
  let base_stroke =
    match Document.PathMap.min_binding_opt doc.Document.selection with
    | Some (path, _) ->
      let elem = Document.get_element doc path in
      (match elem with
       | Element.Line { stroke; _ } | Element.Rect { stroke; _ }
       | Element.Circle { stroke; _ } | Element.Ellipse { stroke; _ }
       | Element.Polyline { stroke; _ } | Element.Polygon { stroke; _ }
       | Element.Path { stroke; _ } | Element.Text { stroke; _ }
       | Element.Text_path { stroke; _ } -> stroke
       | _ -> ctrl#model#default_stroke)
    | None -> ctrl#model#default_stroke
  in
  let base = match base_stroke with
    | Some s -> s
    | None -> match ctrl#model#default_stroke with
      | Some s -> s
      | None -> Element.make_stroke Element.black
  in
  let width = match ctrl#model#default_stroke with
    | Some ds -> ds.stroke_width
    | None -> base.stroke_width in
  let new_stroke = Element.make_stroke ~width ~linecap:cap ~linejoin:join
    ~miter_limit ~align ~dash_pattern ~start_arrow ~end_arrow
    ~start_arrow_scale ~end_arrow_scale ~arrow_align
    ~opacity:base.stroke_opacity base.stroke_color in
  ctrl#model#set_default_stroke (Some new_stroke);
  if not (Document.PathMap.is_empty doc.Document.selection) then begin
    ctrl#model#snapshot;
    ctrl#set_selection_stroke (Some new_stroke);
    let profile = json_to_string_default "uniform" (get "stroke_profile") in
    let flipped = json_to_bool_default false (get "stroke_profile_flipped") in
    let width_pts = Element.profile_to_width_points profile width flipped in
    ctrl#set_selection_width_profile width_pts
  end

(** Sync stroke panel state from the first selected element's stroke. *)
let sync_stroke_panel_from_selection (store : State_store.t)
    (ctrl : Controller.controller) =
  let doc = ctrl#document in
  match Document.PathMap.min_binding_opt doc.Document.selection with
  | None -> ()
  | Some (path, _) ->
    let elem = Document.get_element doc path in
    let stroke_opt = match elem with
      | Element.Line { stroke; _ } | Element.Rect { stroke; _ }
      | Element.Circle { stroke; _ } | Element.Ellipse { stroke; _ }
      | Element.Polyline { stroke; _ } | Element.Polygon { stroke; _ }
      | Element.Path { stroke; _ } | Element.Text { stroke; _ }
      | Element.Text_path { stroke; _ } -> stroke
      | _ -> None
    in
    match stroke_opt with
    | None -> ()
    | Some s ->
      let cap_str = match s.stroke_linecap with
        | Butt -> "butt" | Round_cap -> "round" | Square -> "square" in
      let join_str = match s.stroke_linejoin with
        | Miter -> "miter" | Round_join -> "round" | Bevel -> "bevel" in
      State_store.set store "stroke_cap" (`String cap_str);
      State_store.set store "stroke_join" (`String join_str);
      State_store.set store "stroke_weight" (`Float s.stroke_width);
      State_store.set store "stroke_miter_limit" (`Float s.stroke_miter_limit);
      let align_str = match s.stroke_align with
        | Center -> "center" | Inside -> "inside" | Outside -> "outside" in
      State_store.set store "stroke_align_stroke" (`String align_str);
      State_store.set store "stroke_dashed" (`Bool (s.stroke_dash_pattern <> []));
      let dp = s.stroke_dash_pattern in
      (match dp with
       | d1 :: g1 :: rest ->
         State_store.set store "stroke_dash_1" (`Float d1);
         State_store.set store "stroke_gap_1" (`Float g1);
         (match rest with
          | d2 :: g2 :: rest2 ->
            State_store.set store "stroke_dash_2" (`Float d2);
            State_store.set store "stroke_gap_2" (`Float g2);
            (match rest2 with
             | d3 :: g3 :: _ ->
               State_store.set store "stroke_dash_3" (`Float d3);
               State_store.set store "stroke_gap_3" (`Float g3)
             | _ -> ())
          | _ -> ())
       | _ -> ());
      State_store.set store "stroke_start_arrowhead"
        (`String (Element.string_of_arrowhead s.stroke_start_arrow));
      State_store.set store "stroke_end_arrowhead"
        (`String (Element.string_of_arrowhead s.stroke_end_arrow));
      State_store.set store "stroke_start_arrowhead_scale"
        (`Float s.stroke_start_arrow_scale);
      State_store.set store "stroke_end_arrowhead_scale"
        (`Float s.stroke_end_arrow_scale);
      let arrow_align_str = match s.stroke_arrow_align with
        | Tip_at_end -> "tip_at_end" | Center_at_end -> "center_at_end" in
      State_store.set store "stroke_arrow_align" (`String arrow_align_str)

(** Check if a state key is a rendering-affecting stroke key. *)
let is_stroke_render_key key =
  List.mem key stroke_render_keys

(* ── Gradient panel writeback — Phase 5 ──────────────────────── *)

(** Build a gradient from the panel state in [store] and write it to
    every selected element's fill_gradient or stroke_gradient (per
    [state.fill_on_top]). Clears [gradient_preview_state]. Mirrors
    [jas_dioxus::AppState::apply_gradient_panel_to_selection]. *)
let apply_gradient_panel_to_selection (store : State_store.t)
    (ctrl : Controller.controller) =
  let open Element in
  let get_str key default = match State_store.get store key with
    | `String s -> s | _ -> default in
  let get_float key default = match State_store.get store key with
    | `Float f -> f | `Int n -> float_of_int n | _ -> default in
  let get_bool key default = match State_store.get store key with
    | `Bool b -> b | _ -> default in
  let g = {
    gtype = gradient_type_of_string (get_str "gradient_type" "linear");
    gangle = get_float "gradient_angle" 0.0;
    gaspect_ratio = get_float "gradient_aspect_ratio" 100.0;
    gmethod = gradient_method_of_string (get_str "gradient_method" "classic");
    gdither = get_bool "gradient_dither" false;
    gstroke_sub_mode = stroke_sub_mode_of_string (get_str "gradient_stroke_sub_mode" "within");
    (* Stops are panel-local; Phase 5 follow-up adds explicit
       store-key binding for the stops list. *)
    gstops = [];
    gnodes = [];
  } in
  let fill_on_top = get_bool "fill_on_top" true in
  if fill_on_top then ctrl#set_selection_fill_gradient (Some g)
  else ctrl#set_selection_stroke_gradient (Some g);
  State_store.set store "gradient_preview_state" (`Bool false)

(** Demote the selection's active-attribute gradient back to a solid.
    The underlying solid Fill / Stroke is left untouched. *)
let demote_gradient_panel_selection (store : State_store.t)
    (ctrl : Controller.controller) =
  let fill_on_top = match State_store.get store "fill_on_top" with
    | `Bool b -> b | _ -> true in
  if fill_on_top then ctrl#set_selection_fill_gradient None
  else ctrl#set_selection_stroke_gradient None

(* ── Gradient panel — Phase 4 (selection -> panel reads) ──────── *)

(** Read fill gradient from an Element variant, if present. Phase 1b
    placed gradient fields directly on each element variant. *)
let fill_gradient_opt = function
  | Element.Rect { fill_gradient; _ }
  | Element.Circle { fill_gradient; _ }
  | Element.Ellipse { fill_gradient; _ }
  | Element.Polyline { fill_gradient; _ }
  | Element.Polygon { fill_gradient; _ }
  | Element.Path { fill_gradient; _ } -> fill_gradient
  | _ -> None

let stroke_gradient_opt = function
  | Element.Line { stroke_gradient; _ }
  | Element.Rect { stroke_gradient; _ }
  | Element.Circle { stroke_gradient; _ }
  | Element.Ellipse { stroke_gradient; _ }
  | Element.Polyline { stroke_gradient; _ }
  | Element.Polygon { stroke_gradient; _ }
  | Element.Path { stroke_gradient; _ } -> stroke_gradient
  | _ -> None

let fill_color_opt = function
  | Element.Rect { fill = Some f; _ }
  | Element.Circle { fill = Some f; _ }
  | Element.Ellipse { fill = Some f; _ }
  | Element.Polyline { fill = Some f; _ }
  | Element.Polygon { fill = Some f; _ }
  | Element.Path { fill = Some f; _ } -> Some f.Element.fill_color
  | _ -> None

let stroke_color_opt = function
  | Element.Line { stroke = Some s; _ }
  | Element.Rect { stroke = Some s; _ }
  | Element.Circle { stroke = Some s; _ }
  | Element.Ellipse { stroke = Some s; _ }
  | Element.Polyline { stroke = Some s; _ }
  | Element.Polygon { stroke = Some s; _ }
  | Element.Path { stroke = Some s; _ } -> Some s.Element.stroke_color
  | _ -> None

(** Sync gradient panel state from the selection's active attribute
    (fill or stroke per [state.fill_on_top]).

    Behavior per GRADIENT.md §Multi-selection and §Fill-type coupling:
      - Empty selection: leave panel state alone (session defaults).
      - Uniform with gradient: populate panel fields from the shared
        gradient on the active attribute.
      - Mixed: leave panel fields alone; the renderer handles
        blank-vs-uniform display per the multi-selection table.
      - Uniform without gradient: seed a preview gradient (first stop
        from current solid color, second stop white) and set
        [gradient_preview_state] = true. First edit (Phase 5) will
        materialise this onto the elements.

    Mirrors [jas_dioxus::AppState::sync_gradient_panel_from_selection]
    and [JasSwift.syncGradientPanelFromSelection]. Phase 4 lands the
    read direction; Phase 5 wires the writeback. *)
let sync_gradient_panel_from_selection (store : State_store.t)
    (ctrl : Controller.controller) =
  let doc = ctrl#document in
  if Document.PathMap.is_empty doc.Document.selection then ()
  else begin
    let fill_on_top = match State_store.get store "fill_on_top" with
      | `Bool b -> b | _ -> true in
    let elements = Document.PathMap.bindings doc.Document.selection
                   |> List.map (fun (path, _) -> Document.get_element doc path) in
    let pick g_of e = if fill_on_top then fill_gradient_opt e else g_of e in
    let pick_g e = if fill_on_top then fill_gradient_opt e else stroke_gradient_opt e in
    let _ = pick in
    let pick_solid e = if fill_on_top then fill_color_opt e else stroke_color_opt e in
    let gradients = List.map pick_g elements in
    let mixed = match gradients with
      | [] -> false
      | first :: rest -> List.exists (fun g -> g <> first) rest in
    if mixed then begin
      State_store.set store "gradient_preview_state" (`Bool false)
    end else begin
      match List.hd gradients with
      | Some g ->
        let type_str = Element.gradient_type_to_string g.Element.gtype in
        let method_str = Element.gradient_method_to_string g.Element.gmethod in
        let sub_mode_str = Element.stroke_sub_mode_to_string g.Element.gstroke_sub_mode in
        State_store.set store "gradient_type" (`String type_str);
        State_store.set store "gradient_angle" (`Float g.Element.gangle);
        State_store.set store "gradient_aspect_ratio" (`Float g.Element.gaspect_ratio);
        State_store.set store "gradient_method" (`String method_str);
        State_store.set store "gradient_dither" (`Bool g.Element.gdither);
        State_store.set store "gradient_stroke_sub_mode" (`String sub_mode_str);
        State_store.set store "gradient_stops_count" (`Int (List.length g.Element.gstops));
        State_store.set store "gradient_preview_state" (`Bool false)
      | None ->
        let seed_hex =
          match List.find_map pick_solid elements with
          | Some c ->
            let (r, g, b, _) = Element.color_to_rgba c in
            Printf.sprintf "#%02x%02x%02x"
              (int_of_float (r *. 255.0))
              (int_of_float (g *. 255.0))
              (int_of_float (b *. 255.0))
          | None -> "#000000"
        in
        State_store.set store "gradient_type" (`String "linear");
        State_store.set store "gradient_angle" (`Float 0.0);
        State_store.set store "gradient_aspect_ratio" (`Float 100.0);
        State_store.set store "gradient_method" (`String "classic");
        State_store.set store "gradient_dither" (`Bool false);
        State_store.set store "gradient_stroke_sub_mode" (`String "within");
        State_store.set store "gradient_seed_first_color" (`String seed_hex);
        State_store.set store "gradient_preview_state" (`Bool true)
    end
  end

(* ── Paragraph panel — text-kind gating (Phase 3a) ──────────── *)

(** Compute [text_selected] / [area_text_selected] from the current
    selection and write them to the [paragraph_panel_content] panel
    scope so PARAGRAPH.md §Text-kind gating bind.disabled expressions
    resolve to the live values rather than the YAML defaults of true.

    Mirrors the paragraph-panel block in the Rust dock_panel.rs
    [build_live_panel_overrides] and the Swift
    [paragraphPanelLiveOverrides]. Like
    [sync_stroke_panel_from_selection], this is currently unwired in
    OCaml (no selection-change observer pumps it) — Phase 4 hooks it
    in alongside the panel→selection write pipeline. *)
let sync_paragraph_panel_from_selection (store : State_store.t)
    (ctrl : Controller.controller) : unit =
  let doc = ctrl#document in
  let any_text = ref false in
  let all_area = ref true in
  let wrappers : Element.tspan list ref = ref [] in
  Document.PathMap.iter (fun path _ ->
    let elem = Document.get_element doc path in
    match elem with
    | Element.Text { text_width; text_height; tspans; _ } ->
      any_text := true;
      if not (text_width > 0.0 && text_height > 0.0) then all_area := false;
      Array.iter (fun (t : Element.tspan) ->
        if t.jas_role = Some "paragraph" then
          wrappers := t :: !wrappers
      ) tspans
    | Element.Text_path _ ->
      any_text := true;
      all_area := false
    | _ -> ()
  ) doc.Document.selection;
  let text_selected = !any_text in
  let area_text_selected = !any_text && !all_area in
  State_store.set_panel store "paragraph_panel_content"
    "text_selected" (`Bool text_selected);
  State_store.set_panel store "paragraph_panel_content"
    "area_text_selected" (`Bool area_text_selected);
  (* Phase 3c mixed-state aggregation. For each panel-surface
     paragraph attribute we collect every wrapper's effective value
     (Some(v) or the type's default). If all wrappers agree the
     agreed value flows to the matching panel key; if they disagree
     the override is omitted so the panel keeps its prior /
     YAML-default value. *)
  let ws = !wrappers in
  if ws = [] then () else begin
    (* Universally quantified so each call instantiates fresh — OCaml
       type inference would otherwise lock the helper to whatever type
       the first call uses. *)
    let agree : 'a. ('a -> 'a -> bool) -> 'a list -> 'a option =
      fun eq vs ->
        match vs with
        | [] -> None
        | first :: _ ->
          if List.for_all (eq first) vs then Some first else None
    in
    let f_eq a b = a = b in
    (match agree f_eq (List.map (fun (t : Element.tspan) ->
              match t.jas_left_indent with Some v -> v | None -> 0.0) ws) with
     | Some v -> State_store.set_panel store "paragraph_panel_content"
                   "left_indent" (`Float v)
     | None -> ());
    (match agree f_eq (List.map (fun (t : Element.tspan) ->
              match t.jas_right_indent with Some v -> v | None -> 0.0) ws) with
     | Some v -> State_store.set_panel store "paragraph_panel_content"
                   "right_indent" (`Float v)
     | None -> ());
    (* Phase 1b1: first-line indent (signed), space-before / -after. *)
    (match agree f_eq (List.map (fun (t : Element.tspan) ->
              match t.text_indent with Some v -> v | None -> 0.0) ws) with
     | Some v -> State_store.set_panel store "paragraph_panel_content"
                   "first_line_indent" (`Float v)
     | None -> ());
    (match agree f_eq (List.map (fun (t : Element.tspan) ->
              match t.jas_space_before with Some v -> v | None -> 0.0) ws) with
     | Some v -> State_store.set_panel store "paragraph_panel_content"
                   "space_before" (`Float v)
     | None -> ());
    (match agree f_eq (List.map (fun (t : Element.tspan) ->
              match t.jas_space_after with Some v -> v | None -> 0.0) ws) with
     | Some v -> State_store.set_panel store "paragraph_panel_content"
                   "space_after" (`Float v)
     | None -> ());
    (match agree f_eq (List.map (fun (t : Element.tspan) ->
              match t.jas_hyphenate with Some v -> v | None -> false) ws) with
     | Some v -> State_store.set_panel store "paragraph_panel_content"
                   "hyphenate" (`Bool v)
     | None -> ());
    (match agree f_eq (List.map (fun (t : Element.tspan) ->
              match t.jas_hanging_punctuation with Some v -> v | None -> false) ws) with
     | Some v -> State_store.set_panel store "paragraph_panel_content"
                   "hanging_punctuation" (`Bool v)
     | None -> ());
    (* Single backing attr split into two panel dropdowns. Aggregate
       first, then route by prefix. *)
    (match agree f_eq (List.map (fun (t : Element.tspan) ->
            match t.jas_list_style with Some v -> v | None -> "") ws) with
    | None -> ()
    | Some ls ->
      if String.length ls >= 7 && String.sub ls 0 7 = "bullet-" then begin
        State_store.set_panel store "paragraph_panel_content"
          "bullets" (`String ls);
        State_store.set_panel store "paragraph_panel_content"
          "numbered_list" (`String "")
      end else if String.length ls >= 4 && String.sub ls 0 4 = "num-" then begin
        State_store.set_panel store "paragraph_panel_content"
          "numbered_list" (`String ls);
        State_store.set_panel store "paragraph_panel_content"
          "bullets" (`String "")
      end else begin
        (* Empty agreement (no marker) clears both dropdowns. *)
        State_store.set_panel store "paragraph_panel_content"
          "bullets" (`String "");
        State_store.set_panel store "paragraph_panel_content"
          "numbered_list" (`String "")
      end);
    (* Phase 4: alignment radio aggregation. text_align +
       text_align_last together drive which of the seven radio bools
       is set per the §Alignment sub-mapping; agreement on both
       fields is required. *)
    let tas = List.map (fun (t : Element.tspan) ->
                match t.text_align with Some v -> v | None -> "left") ws in
    let tals = List.map (fun (t : Element.tspan) ->
                 match t.text_align_last with Some v -> v | None -> "") ws in
    (match agree f_eq tas, agree f_eq tals with
     | Some ta, Some tal ->
       List.iter (fun k -> State_store.set_panel store
                  "paragraph_panel_content" k (`Bool false))
         ["align_left"; "align_center"; "align_right";
          "justify_left"; "justify_center"; "justify_right"; "justify_all"];
       let key = match ta, tal with
         | "center", _ -> "align_center"
         | "right", _ -> "align_right"
         | "justify", "left" -> "justify_left"
         | "justify", "center" -> "justify_center"
         | "justify", "right" -> "justify_right"
         | "justify", "justify" -> "justify_all"
         | _ -> "align_left"
       in
       State_store.set_panel store "paragraph_panel_content" key (`Bool true)
     | _ -> ())
  end

(* ── Character panel apply-to-selection pipeline (Layer B) ─── *)

(** Format a number for CSS length / value output: integers have no
    decimal, fractions drop trailing zeros. Matches Rust's
    [fmt_num] / Python's [_fmt_num]. *)
let _fmt_num (n : float) : string =
  if Float.equal n (Float.of_int (Int.of_float n)) then
    string_of_int (Int.of_float n)
  else
    let s = Printf.sprintf "%.4f" n in
    (* Trim trailing zeros, then any trailing decimal point. *)
    let rec trim_zeros s =
      let len = String.length s in
      if len > 0 && s.[len - 1] = '0' then trim_zeros (String.sub s 0 (len - 1))
      else s in
    let s = trim_zeros s in
    let len = String.length s in
    if len > 0 && s.[len - 1] = '.' then String.sub s 0 (len - 1) else s

(** Convenience accessor: panel field as float with default. *)
let _panel_f (panel : (string * Yojson.Safe.t) list) (key : string) (default : float) : float =
  match List.assoc_opt key panel with
  | Some (`Int n) -> Float.of_int n
  | Some (`Float n) -> n
  | _ -> default

(** Convenience accessor: panel field as bool (default false). *)
let _panel_b (panel : (string * Yojson.Safe.t) list) (key : string) : bool =
  match List.assoc_opt key panel with
  | Some (`Bool b) -> b
  | _ -> false

(** Convenience accessor: panel field as string (default ""). *)
let _panel_s (panel : (string * Yojson.Safe.t) list) (key : string) : string =
  match List.assoc_opt key panel with
  | Some (`String s) -> s
  | _ -> ""

(** Translate the Character-panel state dict into the element-attribute
    dict that [apply_character_panel_to_selection] will write onto each
    selected Text / Text_path. Pure function — extracted for testability.

    Mapping rules mirror CHARACTER.md's SVG-attribute table and the
    Rust / Python implementations:
    - underline + strikethrough combine into text_decoration (alphabetical).
    - all_caps -> text_transform: uppercase; small_caps (when All Caps is
      off) -> font_variant: small-caps.
    - super / sub -> baseline_shift: super / sub; numeric pt loses.
    - style_name parses into font_weight + font_style.
    - leading -> line_height ("Npt", empty at the 120% Auto default).
    - tracking / kerning (1/1000 em) -> letter_spacing / kerning ("Nem").
    - character_rotation -> rotate (degrees, empty at 0).
    - horizontal_scale / vertical_scale -> percent, empty at 100%.
    - language -> xml_lang; anti_aliasing -> aa_mode (Sharp default empties). *)
type character_attrs = {
  font_family : string option;
  font_size : float option;
  font_weight : string option;
  font_style : string option;
  text_decoration : string;
  text_transform : string;
  font_variant : string;
  baseline_shift : string;
  line_height : string;
  letter_spacing : string;
  xml_lang : string option;
  aa_mode : string;
  rotate : string;
  horizontal_scale : string;
  vertical_scale : string;
  kerning : string;
}

let attrs_from_character_panel (panel : (string * Yojson.Safe.t) list) : character_attrs =
  let font_family = match List.assoc_opt "font_family" panel with
    | Some (`String s) -> Some s | _ -> None in
  let font_size = match List.assoc_opt "font_size" panel with
    | Some (`Int n) -> Some (Float.of_int n)
    | Some (`Float n) -> Some n
    | _ -> None in
  (* style_name -> font_weight + font_style (unknown names leave them None). *)
  let style = String.trim (_panel_s panel "style_name") in
  let (font_weight, font_style) = match style with
    | "Regular" -> (Some "normal", Some "normal")
    | "Italic" -> (Some "normal", Some "italic")
    | "Bold" -> (Some "bold", Some "normal")
    | "Bold Italic" | "Italic Bold" -> (Some "bold", Some "italic")
    | _ -> (None, None) in
  (* underline + strikethrough -> text_decoration (alphabetical tokens). *)
  let underline = _panel_b panel "underline" in
  let strikethrough = _panel_b panel "strikethrough" in
  let text_decoration = String.concat " " (List.filter_map (fun x -> x) [
    if strikethrough then Some "line-through" else None;
    if underline then Some "underline" else None;
  ]) in
  (* all_caps / small_caps mutual exclusion. *)
  let all_caps = _panel_b panel "all_caps" in
  let small_caps = _panel_b panel "small_caps" in
  let text_transform = if all_caps then "uppercase" else "" in
  let font_variant = if small_caps && not all_caps then "small-caps" else "" in
  (* super / sub mutual exclusion + numeric fallback. *)
  let superscript = _panel_b panel "superscript" in
  let subscript = _panel_b panel "subscript" in
  let bs_num = _panel_f panel "baseline_shift" 0.0 in
  let baseline_shift =
    if superscript then "super"
    else if subscript then "sub"
    else if Float.equal bs_num 0.0 then ""
    else _fmt_num bs_num ^ "pt" in
  (* leading -> line_height (empty at 120% Auto default). *)
  let fs_num = _panel_f panel "font_size" 12.0 in
  let leading = _panel_f panel "leading" (fs_num *. 1.2) in
  let line_height =
    if Float.abs (leading -. fs_num *. 1.2) < 1e-6 then ""
    else _fmt_num leading ^ "pt" in
  (* tracking (1/1000 em) -> letter_spacing. *)
  let tracking = _panel_f panel "tracking" 0.0 in
  let letter_spacing =
    if Float.equal tracking 0.0 then ""
    else _fmt_num (tracking /. 1000.0) ^ "em" in
  (* kerning combo_box: named modes (Auto / Optical / Metrics) pass
     through verbatim; numeric strings are 1/1000 em and convert to
     "{N}em". Empty / "0" / "Auto" all omit (the element default).
     Legacy JSON number values also land here via the Float branch. *)
  let kerning =
    match List.assoc_opt "kerning" panel with
    | Some (`String s) ->
      let trimmed = String.trim s in
      (match trimmed with
       | "" | "0" | "Auto" -> ""
       | "Optical" | "Metrics" -> trimmed
       | _ ->
         (try
            let n = float_of_string trimmed in
            if Float.equal n 0.0 then ""
            else _fmt_num (n /. 1000.0) ^ "em"
          with Failure _ -> ""))
    | Some (`Int n) ->
      if n = 0 then ""
      else _fmt_num (Float.of_int n /. 1000.0) ^ "em"
    | Some (`Float n) ->
      if Float.equal n 0.0 then ""
      else _fmt_num (n /. 1000.0) ^ "em"
    | _ -> "" in
  (* character_rotation (degrees). *)
  let rot = _panel_f panel "character_rotation" 0.0 in
  let rotate = if Float.equal rot 0.0 then "" else _fmt_num rot in
  (* vertical / horizontal scale (percent, identity = empty). *)
  let v_scale = _panel_f panel "vertical_scale" 100.0 in
  let h_scale = _panel_f panel "horizontal_scale" 100.0 in
  let vertical_scale = if Float.equal v_scale 100.0 then "" else _fmt_num v_scale in
  let horizontal_scale = if Float.equal h_scale 100.0 then "" else _fmt_num h_scale in
  (* language / anti_aliasing. Sharp default empties. *)
  let xml_lang = match List.assoc_opt "language" panel with
    | Some (`String s) -> Some s | _ -> None in
  let aa_raw = _panel_s panel "anti_aliasing" in
  let aa_mode = if aa_raw = "Sharp" || aa_raw = "" then "" else aa_raw in
  { font_family; font_size; font_weight; font_style;
    text_decoration; text_transform; font_variant; baseline_shift;
    line_height; letter_spacing; xml_lang; aa_mode;
    rotate; horizontal_scale; vertical_scale; kerning }

(** Apply a computed attribute dict to a single Text / Text_path
    element, returning a new element. Fields outside the
    character_attrs surface are preserved. *)
let apply_character_attrs_to_elem (elem : Element.element) (a : character_attrs)
  : Element.element =
  let (<|>) v def = match v with Some x -> x | None -> def in
  match elem with
  | Element.Text t ->
    Element.Text {
      t with
      font_family = a.font_family <|> t.font_family;
      font_size = a.font_size <|> t.font_size;
      font_weight = a.font_weight <|> t.font_weight;
      font_style = a.font_style <|> t.font_style;
      text_decoration = a.text_decoration;
      text_transform = a.text_transform;
      font_variant = a.font_variant;
      baseline_shift = a.baseline_shift;
      line_height = a.line_height;
      letter_spacing = a.letter_spacing;
      xml_lang = a.xml_lang <|> t.xml_lang;
      aa_mode = a.aa_mode;
      rotate = a.rotate;
      horizontal_scale = a.horizontal_scale;
      vertical_scale = a.vertical_scale;
      kerning = a.kerning;
    }
  | Element.Text_path tp ->
    Element.Text_path {
      tp with
      font_family = a.font_family <|> tp.font_family;
      font_size = a.font_size <|> tp.font_size;
      font_weight = a.font_weight <|> tp.font_weight;
      font_style = a.font_style <|> tp.font_style;
      text_decoration = a.text_decoration;
      text_transform = a.text_transform;
      font_variant = a.font_variant;
      baseline_shift = a.baseline_shift;
      line_height = a.line_height;
      letter_spacing = a.letter_spacing;
      xml_lang = a.xml_lang <|> tp.xml_lang;
      aa_mode = a.aa_mode;
      rotate = a.rotate;
      horizontal_scale = a.horizontal_scale;
      vertical_scale = a.vertical_scale;
      kerning = a.kerning;
    }
  | other -> other

(** Build a [tspan] override template from the Character panel state
    that forces every panel-scoped field onto the targeted tspans
    regardless of the element-level defaults. Used by the per-range
    write path. Unlike the pending template, this builder does NOT
    diff against element values — clicking Regular on a bold range
    emits [Some "normal"] so the range's bold override is cleared. *)
let build_panel_full_overrides
    (panel : (string * Yojson.Safe.t) list)
  : Element.tspan =
  let t = ref (Tspan.default_tspan ()) in
  let set_opt (f : Element.tspan -> Element.tspan) = t := f !t in
  let font_family = match List.assoc_opt "font_family" panel with
    | Some (`String s) -> s | _ -> "sans-serif" in
  set_opt (fun x -> { x with font_family = Some font_family });
  let font_size = match List.assoc_opt "font_size" panel with
    | Some (`Int n) -> Float.of_int n
    | Some (`Float n) -> n
    | _ -> 12.0 in
  set_opt (fun x -> { x with font_size = Some font_size });
  let style = match List.assoc_opt "style_name" panel with
    | Some (`String s) -> String.trim s | _ -> "" in
  let (fw_parsed, fst_parsed) = match style with
    | "Regular" -> (Some "normal", Some "normal")
    | "Italic" -> (Some "normal", Some "italic")
    | "Bold" -> (Some "bold", Some "normal")
    | "Bold Italic" | "Italic Bold" -> (Some "bold", Some "italic")
    | _ -> (None, None) in
  (match fw_parsed with
   | Some fw -> set_opt (fun x -> { x with font_weight = Some fw })
   | None -> ());
  (match fst_parsed with
   | Some fs -> set_opt (fun x -> { x with font_style = Some fs })
   | None -> ());
  let underline = match List.assoc_opt "underline" panel with
    | Some (`Bool b) -> b | _ -> false in
  let strikethrough = match List.assoc_opt "strikethrough" panel with
    | Some (`Bool b) -> b | _ -> false in
  let td = List.filter_map (fun x -> x) [
    if strikethrough then Some "line-through" else None;
    if underline then Some "underline" else None;
  ] in
  set_opt (fun x -> { x with text_decoration = Some td });
  let all_caps = match List.assoc_opt "all_caps" panel with
    | Some (`Bool b) -> b | _ -> false in
  let tt = if all_caps then "uppercase" else "" in
  set_opt (fun x -> { x with text_transform = Some tt });
  let small_caps = match List.assoc_opt "small_caps" panel with
    | Some (`Bool b) -> b | _ -> false in
  let fv = if small_caps && not all_caps then "small-caps" else "" in
  set_opt (fun x -> { x with font_variant = Some fv });
  let lang = match List.assoc_opt "language" panel with
    | Some (`String s) -> s | _ -> "" in
  set_opt (fun x -> { x with xml_lang = Some lang });
  let rot = match List.assoc_opt "character_rotation" panel with
    | Some (`Int n) -> Float.of_int n
    | Some (`Float n) -> n
    | _ -> 0.0 in
  set_opt (fun x -> { x with rotate = Some rot });
  (* Leading → line_height (pt). *)
  let leading = match List.assoc_opt "leading" panel with
    | Some (`Int n) -> Float.of_int n
    | Some (`Float n) -> n
    | _ -> font_size *. 1.2 in
  set_opt (fun x -> { x with line_height = Some leading });
  (* Tracking → letter_spacing (em). Panel unit is 1/1000 em. *)
  let tracking = match List.assoc_opt "tracking" panel with
    | Some (`Int n) -> Float.of_int n
    | Some (`Float n) -> n
    | _ -> 0.0 in
  set_opt (fun x -> { x with letter_spacing = Some (tracking /. 1000.0) });
  (* Baseline shift numeric (pt), skipped when super / sub is on. *)
  let superscript = match List.assoc_opt "superscript" panel with
    | Some (`Bool b) -> b | _ -> false in
  let subscript = match List.assoc_opt "subscript" panel with
    | Some (`Bool b) -> b | _ -> false in
  let bs_num = match List.assoc_opt "baseline_shift" panel with
    | Some (`Int n) -> Float.of_int n
    | Some (`Float n) -> n
    | _ -> 0.0 in
  if not (superscript || subscript) then
    set_opt (fun x -> { x with baseline_shift = Some bs_num });
  (* Anti-aliasing → jas_aa_mode. "Sharp" / empty → empty override. *)
  let aa_raw = match List.assoc_opt "anti_aliasing" panel with
    | Some (`String s) -> s | _ -> "Sharp" in
  let aa_mode = if aa_raw = "Sharp" || aa_raw = "" then "" else aa_raw in
  set_opt (fun x -> { x with jas_aa_mode = Some aa_mode });
  !t

(** Apply [overrides] to the tspans covering the character range
    [[char_start, char_end)]. Runs TSPAN.md's per-range algorithm:
    [split_range] isolates the targeted tspans,
    [merge_tspan_overrides] copies the override fields onto each
    one, [merge] collapses adjacent-equal tspans. When [?elem] is
    supplied, runs identity-omission (TSPAN.md step 3) between the
    override-merge and the final merge so redundant overrides get
    cleared. *)
let apply_overrides_to_tspan_range
    ?(elem : Element.element option)
    (tspans : Element.tspan array)
    (char_start : int) (char_end : int)
    (overrides : Element.tspan)
  : Element.tspan array =
  if char_start >= char_end then tspans
  else
    let (split, first, last) = Tspan.split_range tspans char_start char_end in
    match first, last with
    | Some f, Some l ->
      for i = f to l do
        let merged = Tspan.merge_tspan_overrides split.(i) overrides in
        let finalized = match elem with
          | Some e -> Tspan.identity_omit_tspan merged e
          | None -> merged in
        split.(i) <- finalized
      done;
      Tspan.merge split
    | _ -> split

(** Build a [tspan] override template from the Character panel state
    that contains only the fields where the panel differs from the
    currently-edited element. [None] when everything matches. Scope
    (Phase 3 MVP, mirrors Rust 390513e / Swift bea4d61): font-family,
    font-size, font-weight, font-style, text-decoration,
    text-transform, font-variant, xml-lang, rotate. Complex attrs
    (baseline-shift super/sub, kerning modes, scales, line-height)
    aren't pending-override candidates yet — they still write to the
    element normally. *)
let build_panel_pending_template
    (panel : (string * Yojson.Safe.t) list)
    (elem : Element.element)
  : Element.tspan option =
  let (elem_ff, elem_fs, elem_fw, elem_fst, elem_td, elem_tt, elem_fv,
       elem_xl, elem_rot, elem_lh_str, elem_ls_str, elem_bs_str,
       elem_aa_str) = match elem with
    | Element.Text r ->
      (r.font_family, r.font_size, r.font_weight, r.font_style,
       r.text_decoration, r.text_transform, r.font_variant,
       r.xml_lang, r.rotate,
       r.line_height, r.letter_spacing, r.baseline_shift, r.aa_mode)
    | Element.Text_path r ->
      (r.font_family, r.font_size, r.font_weight, r.font_style,
       r.text_decoration, r.text_transform, r.font_variant,
       r.xml_lang, r.rotate,
       r.line_height, r.letter_spacing, r.baseline_shift, r.aa_mode)
    | _ -> raise Exit in
  let tpl = ref (Tspan.default_tspan ()) in
  let any = ref false in
  (* font-family *)
  (match List.assoc_opt "font_family" panel with
   | Some (`String s) when s <> elem_ff ->
     tpl := { !tpl with font_family = Some s }; any := true
   | _ -> ());
  (* font-size *)
  let panel_fs = match List.assoc_opt "font_size" panel with
    | Some (`Int n) -> Some (Float.of_int n)
    | Some (`Float n) -> Some n
    | _ -> None in
  (match panel_fs with
   | Some fs when abs_float (fs -. elem_fs) > 1e-6 ->
     tpl := { !tpl with font_size = Some fs }; any := true
   | _ -> ());
  (* style_name → font_weight + font_style *)
  let style = match List.assoc_opt "style_name" panel with
    | Some (`String s) -> String.trim s | _ -> "" in
  let (fw_parsed, fst_parsed) = match style with
    | "Regular" -> (Some "normal", Some "normal")
    | "Italic" -> (Some "normal", Some "italic")
    | "Bold" -> (Some "bold", Some "normal")
    | "Bold Italic" | "Italic Bold" -> (Some "bold", Some "italic")
    | _ -> (None, None) in
  (match fw_parsed with
   | Some fw when fw <> elem_fw ->
     tpl := { !tpl with font_weight = Some fw }; any := true
   | _ -> ());
  (match fst_parsed with
   | Some fs when fs <> elem_fst ->
     tpl := { !tpl with font_style = Some fs }; any := true
   | _ -> ());
  (* text-decoration: parse both sides into sorted sets so "none"
     and "" (no decoration) collapse. *)
  let underline = match List.assoc_opt "underline" panel with
    | Some (`Bool b) -> b | _ -> false in
  let strikethrough = match List.assoc_opt "strikethrough" panel with
    | Some (`Bool b) -> b | _ -> false in
  let panel_td = List.sort compare (List.filter_map (fun x -> x) [
    if strikethrough then Some "line-through" else None;
    if underline then Some "underline" else None;
  ]) in
  let elem_td_parsed = List.sort compare
    (List.filter (fun t -> t <> "none")
       (String.split_on_char ' ' elem_td
        |> List.filter (fun s -> s <> ""))) in
  if panel_td <> elem_td_parsed then begin
    tpl := { !tpl with text_decoration = Some panel_td };
    any := true
  end;
  (* text-transform (All Caps) *)
  let all_caps = match List.assoc_opt "all_caps" panel with
    | Some (`Bool b) -> b | _ -> false in
  let tt = if all_caps then "uppercase" else "" in
  if tt <> elem_tt then begin
    tpl := { !tpl with text_transform = Some tt }; any := true
  end;
  (* font-variant (Small Caps when All Caps is off) *)
  let small_caps = match List.assoc_opt "small_caps" panel with
    | Some (`Bool b) -> b | _ -> false in
  let fv = if small_caps && not all_caps then "small-caps" else "" in
  if fv <> elem_fv then begin
    tpl := { !tpl with font_variant = Some fv }; any := true
  end;
  (* language *)
  (match List.assoc_opt "language" panel with
   | Some (`String s) when s <> elem_xl ->
     tpl := { !tpl with xml_lang = Some s }; any := true
   | _ -> ());
  (* character rotation: float on the panel, string on the element. *)
  let rot = match List.assoc_opt "character_rotation" panel with
    | Some (`Int n) -> Float.of_int n
    | Some (`Float n) -> n
    | _ -> 0.0 in
  let rot_str = if rot = 0.0 then ""
    else Printf.sprintf "%g" rot in
  if rot_str <> elem_rot then begin
    tpl := { !tpl with rotate = if rot = 0.0 then None else Some rot };
    if rot <> 0.0 then any := true
  end;
  (* Leading → line_height. Element stores as CSS length string,
     empty round-trips to auto (120% of font_size). *)
  let has_suffix ~suffix s =
    let ls = String.length s in
    let lsuf = String.length suffix in
    ls >= lsuf && String.sub s (ls - lsuf) lsuf = suffix
  in
  let parse_pt s =
    let s = String.trim s in
    if s = "" then None
    else
      let rest = if has_suffix ~suffix:"pt" s
        then String.sub s 0 (String.length s - 2) else s in
      try Some (float_of_string rest) with _ -> None
  in
  let parse_em s =
    let s = String.trim s in
    if s = "" then None
    else
      let rest = if has_suffix ~suffix:"em" s
        then String.sub s 0 (String.length s - 2) else s in
      try Some (float_of_string rest) with _ -> None
  in
  let leading = match List.assoc_opt "leading" panel with
    | Some (`Int n) -> Some (Float.of_int n)
    | Some (`Float n) -> Some n
    | _ -> None in
  let elem_lh_val = match parse_pt elem_lh_str with
    | Some v -> v | None -> elem_fs *. 1.2 in
  (match leading with
   | Some v when abs_float (v -. elem_lh_val) > 1e-6 ->
     tpl := { !tpl with line_height = Some v }; any := true
   | _ -> ());
  (* Tracking → letter_spacing (em). Panel unit: 1/1000 em. *)
  let tracking = match List.assoc_opt "tracking" panel with
    | Some (`Int n) -> Float.of_int n
    | Some (`Float n) -> n
    | _ -> 0.0 in
  let elem_tracking = (match parse_em elem_ls_str with
    | Some v -> v *. 1000.0 | None -> 0.0) in
  if abs_float (tracking -. elem_tracking) > 1e-6 then begin
    tpl := { !tpl with letter_spacing = Some (tracking /. 1000.0) };
    any := true
  end;
  (* Baseline shift numeric (pt), skipped when super / sub is on. *)
  let superscript = match List.assoc_opt "superscript" panel with
    | Some (`Bool b) -> b | _ -> false in
  let subscript = match List.assoc_opt "subscript" panel with
    | Some (`Bool b) -> b | _ -> false in
  if not (superscript || subscript) then begin
    let bs = match List.assoc_opt "baseline_shift" panel with
      | Some (`Int n) -> Float.of_int n
      | Some (`Float n) -> n
      | _ -> 0.0 in
    let elem_bs_val = match parse_pt elem_bs_str with
      | Some v -> v | None -> 0.0 in
    if abs_float (bs -. elem_bs_val) > 1e-6 then begin
      tpl := { !tpl with baseline_shift = Some bs }; any := true
    end
  end;
  (* Anti-aliasing → jas_aa_mode. *)
  let aa_raw = match List.assoc_opt "anti_aliasing" panel with
    | Some (`String s) -> s | _ -> "Sharp" in
  let aa_mode = if aa_raw = "Sharp" || aa_raw = "" then "" else aa_raw in
  if aa_mode <> elem_aa_str then begin
    tpl := { !tpl with jas_aa_mode = Some aa_mode }; any := true
  end;
  if !any then Some !tpl else None

let apply_character_panel_to_selection (store : State_store.t)
    (ctrl : Controller.controller) : unit =
  let panel_list () =
    let read k = (k, State_store.get_panel store "character_panel" k) in
    List.map read [
      "font_family"; "style_name"; "font_size";
      "leading"; "kerning"; "tracking";
      "vertical_scale"; "horizontal_scale";
      "baseline_shift"; "character_rotation";
      "all_caps"; "small_caps"; "superscript"; "subscript";
      "underline"; "strikethrough";
      "language"; "anti_aliasing";
    ]
  in
  (* Phase 3: route to next-typed-character state when there is an
     active edit session with a bare caret (no range selection).
     Replace semantics: clear pending, prime from new template.
     Non-bare-caret sessions fall through to the legacy element-
     level write below. *)
  let routed_to_pending = match ctrl#model#current_edit_session with
    | Some session when not session#has_selection ->
      (try
        let elem = Document.get_element ctrl#document session#path in
        let template = build_panel_pending_template (panel_list ()) elem in
        session#clear_pending_override ();
        (match template with
         | Some tpl -> session#set_pending_override tpl
         | None -> ());
        true
      with _ -> true (* swallow — Exit on non-Text elem path still counts
                       as "handled by pending route" *))
    | _ -> false in
  if routed_to_pending then () else
  (* Per-range write: when the active session has a range selection,
     apply the panel state to that range via split_range +
     merge_tspan_overrides + merge. *)
  let routed_to_range = match ctrl#model#current_edit_session with
    | Some session when session#has_selection ->
      (try
        let elem = Document.get_element ctrl#document session#path in
        let (lo, hi) = session#selection_range in
        let overrides = build_panel_full_overrides (panel_list ()) in
        let new_elem = match elem with
          | Element.Text r ->
            let new_tspans = apply_overrides_to_tspan_range
              ~elem r.tspans lo hi overrides in
            Some (Element.Text { r with tspans = new_tspans })
          | Element.Text_path r ->
            let new_tspans = apply_overrides_to_tspan_range
              ~elem r.tspans lo hi overrides in
            Some (Element.Text_path { r with tspans = new_tspans })
          | _ -> None
        in
        (match new_elem with
         | Some e ->
           ctrl#model#snapshot;
           ctrl#set_document (Document.replace_element ctrl#document session#path e)
         | None -> ());
        true
      with _ -> false)
    | _ -> false in
  if routed_to_range then () else
  let doc = ctrl#document in
  if Document.PathMap.is_empty doc.Document.selection then ()
  else begin
    let panel = match List.assoc_opt "character_panel" (State_store.get_all store) with
      | _ -> () |> fun () ->
        (* Use raw panels access via get_active_panel_state when the
           character panel is active; fall back to empty for the
           subscription-driven call where the caller triggers this
           after a set_panel on "character_panel" regardless of
           which panel is currently "active". *)
        match State_store.get_panel store "character_panel" "font_family" with
        | `Null ->
          (* Panel not initialised — read nothing, apply nothing. *)
          []
        | _ ->
          (* Walk all keys via get_panel-style reads. We reconstruct
             the panel dict by pulling the known character-panel
             keys; this matches Rust's CharacterPanelState shape. *)
          let read k = (k, State_store.get_panel store "character_panel" k) in
          List.map read [
            "font_family"; "style_name"; "font_size";
            "leading"; "kerning"; "tracking";
            "vertical_scale"; "horizontal_scale";
            "baseline_shift"; "character_rotation";
            "all_caps"; "small_caps"; "superscript"; "subscript";
            "underline"; "strikethrough";
            "language"; "anti_aliasing";
          ]
    in
    let attrs = attrs_from_character_panel panel in
    let new_doc = Document.PathMap.fold (fun path _ acc ->
      let elem = Document.get_element acc path in
      match elem with
      | Element.Text _ | Element.Text_path _ ->
        Document.replace_element acc path (apply_character_attrs_to_elem elem attrs)
      | _ -> acc
    ) doc.Document.selection doc in
    (* Only snapshot + commit when any text element was actually found
       (otherwise no-op preserves the undo history). *)
    if not (new_doc == doc) then begin
      ctrl#model#snapshot;
      ctrl#model#set_document new_doc
    end
  end

(** Subscribe [apply_character_panel_to_selection] to panel-state writes
    on the "character_panel" scope of [store]. Once registered, any
    widget write on the Character panel flows through to the selected
    Text / Text_path element automatically. *)
let subscribe_character_panel (store : State_store.t)
    (ctrl_getter : unit -> Controller.controller) : unit =
  State_store.subscribe_panel store "character_panel" (fun _key _value ->
    apply_character_panel_to_selection store (ctrl_getter ()))

(** Subscribe [apply_stroke_panel_to_selection] to global writes on
    stroke keys. Filters via [is_stroke_render_key] so non-stroke
    writes don't fire the pipeline. *)
let subscribe_stroke_panel (store : State_store.t)
    (ctrl_getter : unit -> Controller.controller) : unit =
  State_store.subscribe_global store (fun key _value ->
    if is_stroke_render_key key then
      apply_stroke_panel_to_selection store (ctrl_getter ()))

(** Phase 5 follow-up: subscribe to gradient panel state changes on
    the global store. Every write to a gradient_* key triggers
    apply_gradient_panel_to_selection so the selection sees the
    edit immediately. Mirrors [subscribe_stroke_panel]. *)
let gradient_render_keys = [
  "gradient_type"; "gradient_angle"; "gradient_aspect_ratio";
  "gradient_method"; "gradient_dither"; "gradient_stroke_sub_mode";
]

let is_gradient_render_key key =
  List.mem key gradient_render_keys

let subscribe_gradient_panel (store : State_store.t)
    (ctrl_getter : unit -> Controller.controller) : unit =
  State_store.subscribe_global store (fun key _value ->
    if is_gradient_render_key key then
      apply_gradient_panel_to_selection store (ctrl_getter ()))

(* ── Phase 4: paragraph panel→selection writes ──────────── *)

let _opt_f v = if Float.equal v 0.0 then None else Some v
let _opt_b v = if v then Some true else None
let _bool_of_json = function `Bool b -> b | _ -> false
let _str_of_json = function `String s -> s | _ -> ""
let _float_of_json = function `Float f -> f | `Int n -> Float.of_int n | _ -> 0.0

(** Map the seven alignment radio bools to a [(text_align,
    text_align_last)] pair per PARAGRAPH.md §Alignment sub-mapping.
    Default ALIGN_LEFT_BUTTON omits both per identity-value rule. *)
let _paragraph_align_attrs (panel : (string * Yojson.Safe.t) list)
  : string option * string option =
  let read k = match List.assoc_opt k panel with
    | Some v -> _bool_of_json v | None -> false in
  if read "align_center" then (Some "center", None)
  else if read "align_right" then (Some "right", None)
  else if read "justify_left" then (Some "justify", Some "left")
  else if read "justify_center" then (Some "justify", Some "center")
  else if read "justify_right" then (Some "justify", Some "right")
  else if read "justify_all" then (Some "justify", Some "justify")
  else (None, None)

(** Push the YAML-stored paragraph panel state onto every paragraph
    wrapper tspan inside the selection. Per the identity-value rule,
    attrs equal to their default are *omitted* (set to [None]) rather
    than written. The seven alignment radio bools collapse to one
    [(text_align, text_align_last)] pair per the §Alignment
    sub-mapping; [bullets] and [numbered_list] both write the single
    [jas_list_style] attribute. Phase 4. *)
let apply_paragraph_panel_to_selection (store : State_store.t)
    (ctrl : Controller.controller) : unit =
  let pid = "paragraph_panel_content" in
  let read_panel k = State_store.get_panel store pid k in
  let panel = List.map (fun k -> (k, read_panel k)) [
    "align_left"; "align_center"; "align_right";
    "justify_left"; "justify_center"; "justify_right"; "justify_all";
    "bullets"; "numbered_list";
    "left_indent"; "right_indent"; "first_line_indent";
    "space_before"; "space_after";
    "hyphenate"; "hanging_punctuation";
  ] in
  let read_b k = match List.assoc_opt k panel with
    | Some v -> _bool_of_json v | None -> false in
  let read_s k = match List.assoc_opt k panel with
    | Some v -> _str_of_json v | None -> "" in
  let read_f k = match List.assoc_opt k panel with
    | Some v -> _float_of_json v | None -> 0.0 in
  let (text_align, text_align_last) = _paragraph_align_attrs panel in
  let bullets = read_s "bullets" in
  let numbered = read_s "numbered_list" in
  let list_style =
    if String.length bullets > 0 then Some bullets
    else if String.length numbered > 0 then Some numbered
    else None in
  let li = _opt_f (read_f "left_indent") in
  let ri = _opt_f (read_f "right_indent") in
  let fli = let v = read_f "first_line_indent" in
    if Float.equal v 0.0 then None else Some v in
  let sb = _opt_f (read_f "space_before") in
  let sa = _opt_f (read_f "space_after") in
  let hyph = _opt_b (read_b "hyphenate") in
  let hang = _opt_b (read_b "hanging_punctuation") in
  let doc = ctrl#document in
  if Document.PathMap.is_empty doc.Document.selection then () else begin
    let any_change = ref false in
    let new_doc = Document.PathMap.fold (fun path _ acc ->
      let elem = Document.get_element acc path in
      match elem with
      | Element.Text r ->
        let tspans = Array.copy r.tspans in
        let wrapper_indices = ref [] in
        Array.iteri (fun i (t : Element.tspan) ->
          if t.jas_role = Some "paragraph" then
            wrapper_indices := i :: !wrapper_indices
        ) tspans;
        let indices =
          if !wrapper_indices = [] && Array.length tspans > 0 then begin
            (* Promote first tspan to paragraph wrapper. *)
            tspans.(0) <- { tspans.(0) with jas_role = Some "paragraph" };
            [0]
          end else List.rev !wrapper_indices in
        if indices = [] then acc
        else begin
          List.iter (fun i ->
            tspans.(i) <- { tspans.(i) with
              text_align;
              text_align_last;
              text_indent = fli;
              jas_left_indent = li;
              jas_right_indent = ri;
              jas_space_before = sb;
              jas_space_after = sa;
              jas_hyphenate = hyph;
              jas_hanging_punctuation = hang;
              jas_list_style = list_style;
            }
          ) indices;
          any_change := true;
          Document.replace_element acc path (Element.Text { r with tspans })
        end
      | Element.Text_path r ->
        let tspans = Array.copy r.tspans in
        let wrapper_indices = ref [] in
        Array.iteri (fun i (t : Element.tspan) ->
          if t.jas_role = Some "paragraph" then
            wrapper_indices := i :: !wrapper_indices
        ) tspans;
        let indices =
          if !wrapper_indices = [] && Array.length tspans > 0 then begin
            tspans.(0) <- { tspans.(0) with jas_role = Some "paragraph" };
            [0]
          end else List.rev !wrapper_indices in
        if indices = [] then acc
        else begin
          List.iter (fun i ->
            tspans.(i) <- { tspans.(i) with
              text_align;
              text_align_last;
              text_indent = fli;
              jas_left_indent = li;
              jas_right_indent = ri;
              jas_space_before = sb;
              jas_space_after = sa;
              jas_hyphenate = hyph;
              jas_hanging_punctuation = hang;
              jas_list_style = list_style;
            }
          ) indices;
          any_change := true;
          Document.replace_element acc path (Element.Text_path { r with tspans })
        end
      | _ -> acc
    ) doc.Document.selection doc in
    if !any_change then begin
      ctrl#model#snapshot;
      ctrl#model#set_document new_doc
    end
  end

(** Reset every Paragraph panel control to its default per
    PARAGRAPH.md §Reset Panel and remove the corresponding
    [jas:*] / [text-*] attributes from every paragraph wrapper tspan
    in the selection (defaults appear as absence, identity rule). *)
let reset_paragraph_panel (store : State_store.t)
    (ctrl : Controller.controller) : unit =
  let pid = "paragraph_panel_content" in
  let set k v = State_store.set_panel store pid k v in
  set "align_left" (`Bool true);
  set "align_center" (`Bool false);
  set "align_right" (`Bool false);
  set "justify_left" (`Bool false);
  set "justify_center" (`Bool false);
  set "justify_right" (`Bool false);
  set "justify_all" (`Bool false);
  set "bullets" (`String "");
  set "numbered_list" (`String "");
  set "left_indent" (`Float 0.0);
  set "right_indent" (`Float 0.0);
  set "first_line_indent" (`Float 0.0);
  set "space_before" (`Float 0.0);
  set "space_after" (`Float 0.0);
  set "hyphenate" (`Bool false);
  set "hanging_punctuation" (`Bool false);
  apply_paragraph_panel_to_selection store ctrl

(** Apply mutual exclusion side effects for a paragraph panel write.
    Called by [set_paragraph_panel_field] before the user's value
    lands so the seven alignment radio bools collapse to one and
    [bullets] / [numbered_list] never both hold a non-empty value. *)
let apply_paragraph_panel_mutual_exclusion (store : State_store.t)
    (key : string) (value : Yojson.Safe.t) : unit =
  let pid = "paragraph_panel_content" in
  let align_keys = ["align_left"; "align_center"; "align_right";
                    "justify_left"; "justify_center";
                    "justify_right"; "justify_all"] in
  if List.mem key align_keys then begin
    match value with
    | `Bool true ->
      List.iter (fun k ->
        if k <> key then State_store.set_panel store pid k (`Bool false)
      ) align_keys
    | _ -> ()
  end else if key = "bullets" then begin
    match value with
    | `String s when String.length s > 0 ->
      State_store.set_panel store pid "numbered_list" (`String "")
    | _ -> ()
  end else if key = "numbered_list" then begin
    match value with
    | `String s when String.length s > 0 ->
      State_store.set_panel store pid "bullets" (`String "")
    | _ -> ()
  end

(** Sync from selection → mutual exclusion → set field → apply.
    Called by [_write_back_bind] for every paragraph_panel_content
    widget write so untouched fields keep the selection's current
    values, the radio / list-style invariants hold, and the wrappers
    receive the full updated state in one snapshot. *)
let set_paragraph_panel_field (store : State_store.t)
    (ctrl : Controller.controller) (key : string)
    (value : Yojson.Safe.t) : unit =
  sync_paragraph_panel_from_selection store ctrl;
  apply_paragraph_panel_mutual_exclusion store key value;
  State_store.set_panel store "paragraph_panel_content" key value;
  apply_paragraph_panel_to_selection store ctrl

(* ── Phase 8: Justification dialog OK commit ──────────── *)

(** 11 Justification-dialog field values. [None] means the field was
    blank (mixed selection) and should not write. *)
type justification_dialog_values = {
  word_spacing_min : float option;
  word_spacing_desired : float option;
  word_spacing_max : float option;
  letter_spacing_min : float option;
  letter_spacing_desired : float option;
  letter_spacing_max : float option;
  glyph_scaling_min : float option;
  glyph_scaling_desired : float option;
  glyph_scaling_max : float option;
  auto_leading : float option;
  single_word_justify : string option;
}

(** Commit the 11 Justification-dialog fields onto every paragraph
    wrapper tspan in the selection. Per the identity-value rule
    each value at its spec default (word-spacing 80/100/133,
    letter-spacing 0/0/0, glyph-scaling 100/100/100, auto-leading
    120, single-word-justify 'justify') writes [None] so the
    wrapper attribute stays absent. Phase 8. *)
let apply_justification_dialog_to_selection
    (ctrl : Controller.controller) (v : justification_dialog_values) : unit =
  let opt_n value default =
    match value with
    | None -> None
    | Some f -> if Float.abs (f -. default) < 1e-6 then None else Some f in
  let ws_min = opt_n v.word_spacing_min 80.0 in
  let ws_des = opt_n v.word_spacing_desired 100.0 in
  let ws_max = opt_n v.word_spacing_max 133.0 in
  let ls_min = opt_n v.letter_spacing_min 0.0 in
  let ls_des = opt_n v.letter_spacing_desired 0.0 in
  let ls_max = opt_n v.letter_spacing_max 0.0 in
  let gs_min = opt_n v.glyph_scaling_min 100.0 in
  let gs_des = opt_n v.glyph_scaling_desired 100.0 in
  let gs_max = opt_n v.glyph_scaling_max 100.0 in
  let auto_leading = opt_n v.auto_leading 120.0 in
  let single_word_justify =
    match v.single_word_justify with
    | Some s when s <> "justify" -> Some s
    | _ -> None in
  let doc = ctrl#document in
  if Document.PathMap.is_empty doc.Document.selection then () else begin
    let any_change = ref false in
    let new_doc = Document.PathMap.fold (fun path _ acc ->
      let elem = Document.get_element acc path in
      let update_wrappers tspans =
        let arr = Array.copy tspans in
        let wrapper_indices = ref [] in
        Array.iteri (fun i (t : Element.tspan) ->
          if t.jas_role = Some "paragraph" then
            wrapper_indices := i :: !wrapper_indices
        ) arr;
        let indices =
          if !wrapper_indices = [] && Array.length arr > 0 then begin
            arr.(0) <- { arr.(0) with jas_role = Some "paragraph" };
            [0]
          end else List.rev !wrapper_indices in
        List.iter (fun i ->
          arr.(i) <- { arr.(i) with
            jas_word_spacing_min = ws_min;
            jas_word_spacing_desired = ws_des;
            jas_word_spacing_max = ws_max;
            jas_letter_spacing_min = ls_min;
            jas_letter_spacing_desired = ls_des;
            jas_letter_spacing_max = ls_max;
            jas_glyph_scaling_min = gs_min;
            jas_glyph_scaling_desired = gs_des;
            jas_glyph_scaling_max = gs_max;
            jas_auto_leading = auto_leading;
            jas_single_word_justify = single_word_justify;
          }
        ) indices;
        (arr, indices <> [])
      in
      match elem with
      | Element.Text r ->
        let (tspans, changed) = update_wrappers r.tspans in
        if changed then begin
          any_change := true;
          Document.replace_element acc path (Element.Text { r with tspans })
        end else acc
      | Element.Text_path r ->
        let (tspans, changed) = update_wrappers r.tspans in
        if changed then begin
          any_change := true;
          Document.replace_element acc path (Element.Text_path { r with tspans })
        end else acc
      | _ -> acc
    ) doc.Document.selection doc in
    if !any_change then begin
      ctrl#model#snapshot;
      ctrl#model#set_document new_doc
    end
  end

(** 8 Hyphenation-dialog field values (master + 7 sub-controls).
    [None] means the field was blank (mixed selection) and should
    not write. Phase 9. *)
type hyphenation_dialog_values = {
  hyphenate : bool option;
  min_word : float option;
  min_before : float option;
  min_after : float option;
  limit : float option;
  zone : float option;
  bias : float option;
  capitalized : bool option;
}

(** Commit the master toggle + 7 Hyphenation-dialog fields onto every
    paragraph wrapper tspan in the selection. Identity-value rule:
    each value at its spec default (master off, 3/1/1, 0, 0, 0, off)
    writes [None] so the wrapper attribute is omitted. Also mirrors
    the master toggle to panel.hyphenate so the main panel checkbox
    reflects the dialog commit. Phase 9. *)
let apply_hyphenation_dialog_to_selection
    (store : State_store.t) (ctrl : Controller.controller)
    (v : hyphenation_dialog_values) : unit =
  let opt_n value default =
    match value with
    | None -> None
    | Some f -> if Float.abs (f -. default) < 1e-6 then None else Some f in
  let opt_b value =
    match value with
    | None -> None
    | Some b -> if b then Some true else None in
  let hyph = opt_b v.hyphenate in
  let min_word = opt_n v.min_word 3.0 in
  let min_before = opt_n v.min_before 1.0 in
  let min_after = opt_n v.min_after 1.0 in
  let limit = opt_n v.limit 0.0 in
  let zone = opt_n v.zone 0.0 in
  let bias = opt_n v.bias 0.0 in
  let cap = opt_b v.capitalized in
  let doc = ctrl#document in
  if not (Document.PathMap.is_empty doc.Document.selection) then begin
    let any_change = ref false in
    let new_doc = Document.PathMap.fold (fun path _ acc ->
      let elem = Document.get_element acc path in
      let update_wrappers tspans =
        let arr = Array.copy tspans in
        let wrapper_indices = ref [] in
        Array.iteri (fun i (t : Element.tspan) ->
          if t.jas_role = Some "paragraph" then
            wrapper_indices := i :: !wrapper_indices
        ) arr;
        let indices =
          if !wrapper_indices = [] && Array.length arr > 0 then begin
            arr.(0) <- { arr.(0) with jas_role = Some "paragraph" };
            [0]
          end else List.rev !wrapper_indices in
        List.iter (fun i ->
          arr.(i) <- { arr.(i) with
            jas_hyphenate = hyph;
            jas_hyphenate_min_word = min_word;
            jas_hyphenate_min_before = min_before;
            jas_hyphenate_min_after = min_after;
            jas_hyphenate_limit = limit;
            jas_hyphenate_zone = zone;
            jas_hyphenate_bias = bias;
            jas_hyphenate_capitalized = cap;
          }
        ) indices;
        (arr, indices <> [])
      in
      match elem with
      | Element.Text r ->
        let (tspans, changed) = update_wrappers r.tspans in
        if changed then begin
          any_change := true;
          Document.replace_element acc path (Element.Text { r with tspans })
        end else acc
      | Element.Text_path r ->
        let (tspans, changed) = update_wrappers r.tspans in
        if changed then begin
          any_change := true;
          Document.replace_element acc path (Element.Text_path { r with tspans })
        end else acc
      | _ -> acc
    ) doc.Document.selection doc in
    if !any_change then begin
      ctrl#model#snapshot;
      ctrl#model#set_document new_doc
    end
  end;
  (* Master mirror to panel state for HYPHENATE_CHECKBOX. *)
  match v.hyphenate with
  | Some h ->
    State_store.set_panel store "paragraph_panel_content" "hyphenate" (`Bool h)
  | None -> ()

(* ══════════════════════════════════════════════════════════════════ *)
(* Align panel                                                        *)
(* ══════════════════════════════════════════════════════════════════ *)

(** Reset the four Align panel state fields to their defaults per
    ALIGN.md Panel menu Reset Panel. Writes both the global
    [state.align_*] surface and the panel-local mirrors. *)
let reset_align_panel (store : State_store.t) =
  let pid = "align_panel_content" in
  State_store.set store "align_to" (`String "selection");
  State_store.set store "align_key_object_path" `Null;
  State_store.set store "align_distribute_spacing" (`Float 0.0);
  State_store.set store "align_use_preview_bounds" (`Bool false);
  State_store.set_panel store pid "align_to" (`String "selection");
  State_store.set_panel store pid "key_object_path" `Null;
  State_store.set_panel store pid "distribute_spacing_value" (`Float 0.0);
  State_store.set_panel store pid "use_preview_bounds" (`Bool false)

(** Decode a [__path__] json marker into an OCaml path list. *)
let decode_align_path_marker json =
  match json with
  | `Assoc pairs ->
    (match List.assoc_opt "__path__" pairs with
     | Some (`List arr) ->
       Some (List.filter_map (function
         | `Int i -> Some i
         | _ -> None) arr)
     | _ -> None)
  | _ -> None

(** Distribute Spacing explicit gap — [Some gap] when the panel
    is in Key Object mode with a designated key, else [None]. *)
let align_panel_explicit_gap (store : State_store.t) : float option =
  let align_to = match State_store.get store "align_to" with
    | `String s -> s | _ -> "selection" in
  let has_key = match State_store.get store "align_key_object_path" with
    | `Null -> false | _ -> true in
  if align_to = "key_object" && has_key then
    match State_store.get store "align_distribute_spacing" with
    | `Float f -> Some f
    | `Int i -> Some (float_of_int i)
    | _ -> Some 0.0
  else None

(** Execute one of the 14 Align panel operations by name. Reads
    align state, gathers the current selection, builds an
    [align_reference], calls the algorithm, and applies the
    resulting translations by rebuilding the document through
    [Document.replace_element] + [Element.with_transform_translated].
    Artboard falls back to selection bounds until the document
    model grows artboards (see transcripts/ALIGN.md). *)
let apply_align_operation (store : State_store.t) (ctrl : Controller.controller)
    (op : string) : unit =
  let model = ctrl#model in
  let doc = model#document in
  let elements = Document.PathMap.bindings doc.Document.selection
    |> List.map (fun (path, _es) -> (path, Document.get_element doc path)) in
  if List.length elements < 2 then ()
  else begin
    let use_preview = match State_store.get store "align_use_preview_bounds" with
      | `Bool b -> b | _ -> false in
    let bounds_fn =
      if use_preview then Align.preview_bounds
      else Align.geometric_bounds in
    let align_to = match State_store.get store "align_to" with
      | `String s -> s | _ -> "selection" in
    let just_elems = List.map snd elements in
    let reference = match align_to with
      | "artboard" ->
        (* ARTBOARDS.md §Selection semantics — current =
           topmost panel-selected, else first artboard. The at-
           least-one invariant guarantees artboards[0] exists; if
           empty (pathological), fall back to the selection union
           so the op still moves elements. *)
        let sel_ids = match State_store.get_panel store "artboards"
                              "artboards_panel_selection" with
          | `List xs ->
            List.filter_map (function `String s -> Some s | _ -> None) xs
          | _ -> []
        in
        let current = List.find_opt
          (fun (a : Artboard.artboard) -> List.mem a.id sel_ids)
          doc.Document.artboards
        in
        let current = match current with
          | Some a -> Some a
          | None -> (match doc.Document.artboards with
              | [] -> None
              | a :: _ -> Some a)
        in
        (match current with
         | Some ab -> Align.Artboard (ab.x, ab.y, ab.width, ab.height)
         | None -> Align.Artboard (Align.union_bounds just_elems bounds_fn))
      | "key_object" ->
        (match decode_align_path_marker
                 (State_store.get store "align_key_object_path") with
         | None ->
           Align.Selection (Align.union_bounds just_elems bounds_fn)
         | Some kp ->
           let e = Document.get_element doc kp in
           Align.Key_object { bbox = bounds_fn e; path = kp })
      | _ ->
        Align.Selection (Align.union_bounds just_elems bounds_fn)
    in
    let explicit = align_panel_explicit_gap store in
    let translations = match op with
      | "align_left" -> Align.align_left elements reference bounds_fn
      | "align_horizontal_center" -> Align.align_horizontal_center elements reference bounds_fn
      | "align_right" -> Align.align_right elements reference bounds_fn
      | "align_top" -> Align.align_top elements reference bounds_fn
      | "align_vertical_center" -> Align.align_vertical_center elements reference bounds_fn
      | "align_bottom" -> Align.align_bottom elements reference bounds_fn
      | "distribute_left" -> Align.distribute_left elements reference bounds_fn
      | "distribute_horizontal_center" -> Align.distribute_horizontal_center elements reference bounds_fn
      | "distribute_right" -> Align.distribute_right elements reference bounds_fn
      | "distribute_top" -> Align.distribute_top elements reference bounds_fn
      | "distribute_vertical_center" -> Align.distribute_vertical_center elements reference bounds_fn
      | "distribute_bottom" -> Align.distribute_bottom elements reference bounds_fn
      | "distribute_vertical_spacing" ->
        Align.distribute_vertical_spacing elements reference explicit bounds_fn
      | "distribute_horizontal_spacing" ->
        Align.distribute_horizontal_spacing elements reference explicit bounds_fn
      | _ -> []
    in
    if translations <> [] then begin
      let new_doc = List.fold_left (fun doc (t : Align.align_translation) ->
        let elem = Document.get_element doc t.path in
        let moved = Element.with_transform_translated
          ~dx:t.dx ~dy:t.dy elem in
        Document.replace_element doc t.path moved
      ) doc translations in
      model#set_document new_doc
    end
  end

(** Try key-object designation at canvas coordinates. Returns
    [true] when the click was consumed (the canvas tool should
    not see it) and [false] when Align To is not in key-object
    mode. *)
let try_designate_align_key_object (store : State_store.t)
    (ctrl : Controller.controller) (x : float) (y : float) : bool =
  let align_to = match State_store.get store "align_to" with
    | `String s -> s | _ -> "selection" in
  if align_to <> "key_object" then false
  else begin
    let doc = ctrl#model#document in
    let hit = Document.PathMap.fold (fun path _es acc ->
      match acc with
      | Some _ -> acc
      | None ->
        let e = Document.get_element doc path in
        let (bx, by, bw, bh) = Element.bounds e in
        if x >= bx && x <= bx +. bw && y >= by && y <= by +. bh
        then Some path else None
    ) doc.Document.selection None in
    let pid = "align_panel_content" in
    let current_key = decode_align_path_marker
      (State_store.get store "align_key_object_path") in
    (match hit with
     | Some p when current_key = Some p ->
       (* Toggle: clicking the current key clears it. *)
       State_store.set store "align_key_object_path" `Null;
       State_store.set_panel store pid "key_object_path" `Null
     | Some p ->
       let marker = `Assoc ["__path__", `List (List.map (fun i -> `Int i) p)] in
       State_store.set store "align_key_object_path" marker;
       State_store.set_panel store pid "key_object_path" marker
     | None ->
       State_store.set store "align_key_object_path" `Null;
       State_store.set_panel store pid "key_object_path" `Null);
    true
  end

(** Clear the key-object path if the previously-designated key
    is no longer part of the current selection. Idempotent. *)
let sync_align_key_object_from_selection
    (store : State_store.t) (ctrl : Controller.controller) : unit =
  match decode_align_path_marker
    (State_store.get store "align_key_object_path") with
  | None -> ()
  | Some key_path ->
    let doc = ctrl#model#document in
    let still_selected = Document.PathMap.mem key_path doc.Document.selection in
    if not still_selected then begin
      State_store.set store "align_key_object_path" `Null;
      State_store.set_panel store "align_panel_content"
        "key_object_path" `Null
    end
