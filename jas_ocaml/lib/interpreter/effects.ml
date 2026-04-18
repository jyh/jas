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
  (* kerning (1/1000 em, numeric only for now). *)
  let kerning_num = _panel_f panel "kerning" 0.0 in
  let kerning =
    if Float.equal kerning_num 0.0 then ""
    else _fmt_num (kerning_num /. 1000.0) ^ "em" in
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

(** Push the Character-panel state to every selected Text / Text_path.
    No-op when the selection is empty or contains no text elements.
    Mirrors Rust [apply_character_panel_to_selection] / Python's
    [apply_character_panel_to_selection]. *)
let apply_character_panel_to_selection (store : State_store.t)
    (ctrl : Controller.controller) : unit =
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
