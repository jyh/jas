(** YAML tool-runtime effects — the [platform_effects] set that the
    [Yaml_tool] (see Phase 5) registers before dispatching a tool
    handler. Mirrors the doc.* dispatcher in [Interpreter.effects.rs]
    / [JasSwift/Sources/Tools/YamlToolEffects.swift].

    Phase 2 of the OCaml migration covers the selection-family
    effects that only depend on existing [Controller] methods.
    Later phases add doc.add_element, buffer.* / anchor.* effects,
    and the doc.path.* suite as their supporting infrastructure
    lands. *)

(** Convert a JSON value expression (literal or string expression)
    to a number. Returns [0.0] for missing / unparseable. *)
let eval_number (arg : Yojson.Safe.t option)
    (store : State_store.t) (ctx : (string * Yojson.Safe.t) list)
    : float =
  match arg with
  | None | Some `Null -> 0.0
  | Some (`Int i) -> float_of_int i
  | Some (`Float f) -> f
  | Some (`String s) ->
    let eval_ctx = State_store.eval_context ~extra:ctx store in
    (match Expr_eval.evaluate s eval_ctx with
     | Expr_eval.Number n -> n
     | _ -> 0.0)
  | _ -> 0.0

(** Convert a JSON value to a boolean. Strings are evaluated as
    expressions; other non-bool values are false. *)
let eval_bool (arg : Yojson.Safe.t option)
    (store : State_store.t) (ctx : (string * Yojson.Safe.t) list)
    : bool =
  match arg with
  | None | Some `Null -> false
  | Some (`Bool b) -> b
  | Some (`String s) ->
    let eval_ctx = State_store.eval_context ~extra:ctx store in
    (match Expr_eval.evaluate s eval_ctx with
     | Expr_eval.Bool b -> b
     | _ -> false)
  | _ -> false

(** Pull a single [element_path] out of a [doc.*] effect spec.
    Accepts:
      - a raw JSON array of ints ([[0, 0]])
      - a string expression evaluating to [Value.Path]
      - a string expression evaluating to a list of int values
      - a [{path: <expr>}] dict (recurses)
      - a [__path__] marker dict
    Returns [None] when the spec doesn't resolve to a valid path. *)
let rec extract_path (spec : Yojson.Safe.t)
    (store : State_store.t) (ctx : (string * Yojson.Safe.t) list)
    : int list option =
  match spec with
  | `List items ->
    let out = List.filter_map (function
      | `Int i -> Some i
      | `Float f -> Some (int_of_float f)
      | _ -> None) items
    in
    if List.length out = List.length items then Some out else None
  | `Assoc pairs ->
    (match List.assoc_opt "__path__" pairs with
     | Some (`List arr) ->
       let out = List.filter_map (function
         | `Int i -> Some i
         | _ -> None) arr in
       if List.length out = List.length arr then Some out else None
     | _ ->
       (match List.assoc_opt "path" pairs with
        | Some inner -> extract_path inner store ctx
        | None -> None))
  | `String s ->
    let eval_ctx = State_store.eval_context ~extra:ctx store in
    (match Expr_eval.evaluate s eval_ctx with
     | Expr_eval.Path indices -> Some indices
     | Expr_eval.List items ->
       let out = List.filter_map (function
         | `Int i -> Some i
         | `Float f -> Some (int_of_float f)
         | _ -> None) items in
       if List.length out = List.length items then Some out else None
     | _ -> None)
  | _ -> None

(** Pull a list of paths out of a [{paths: [...]}] spec. *)
let extract_path_list (spec : Yojson.Safe.t)
    (store : State_store.t) (ctx : (string * Yojson.Safe.t) list)
    : int list list =
  match spec with
  | `Assoc pairs ->
    (match List.assoc_opt "paths" pairs with
     | Some (`List items) ->
       List.filter_map (fun item -> extract_path item store ctx) items
     | _ -> [])
  | _ -> []

(** True when [path] references an existing element in [doc]. *)
let is_valid_path (doc : Document.document) (path : int list) : bool =
  try
    let _ = Document.get_element doc path in
    true
  with _ -> false

(** Normalize a [{x1, y1, x2, y2, additive}] spec to
    [(x, y, w, h, additive)]. *)
let normalize_rect_args (args : (string * Yojson.Safe.t) list)
    (store : State_store.t) (ctx : (string * Yojson.Safe.t) list)
    : float * float * float * float * bool =
  let lookup k = List.assoc_opt k args in
  let x1 = eval_number (lookup "x1") store ctx in
  let y1 = eval_number (lookup "y1") store ctx in
  let x2 = eval_number (lookup "x2") store ctx in
  let y2 = eval_number (lookup "y2") store ctx in
  let additive = eval_bool (lookup "additive") store ctx in
  (Float.min x1 x2, Float.min y1 y2,
   Float.abs (x2 -. x1), Float.abs (y2 -. y1), additive)

(** Build the [platform_effects] list that [Yaml_tool] hands to
    [run_effects] on each dispatch. Called with the active
    [Controller] so mutations land on its [Model]. *)
let build (ctrl : Controller.controller) : (string * Effects.platform_effect) list =
  let doc_snapshot _ _ _ =
    ctrl#model#snapshot;
    `Null
  in
  let doc_clear_selection _ _ _ =
    ctrl#set_selection Document.PathMap.empty;
    `Null
  in
  let doc_set_selection spec ctx store =
    let paths = extract_path_list spec store ctx in
    let doc = ctrl#document in
    let valid = List.filter_map (fun p ->
      if is_valid_path doc p
      then Some (p, Document.element_selection_all p)
      else None
    ) paths in
    let sel = List.fold_left (fun acc (path, es) ->
      Document.PathMap.add path es acc
    ) Document.PathMap.empty valid in
    ctrl#set_selection sel;
    `Null
  in
  let doc_add_to_selection spec ctx store =
    (match extract_path spec store ctx with
     | None -> ()
     | Some path ->
       let doc = ctrl#document in
       if not (Document.PathMap.mem path doc.selection) then
         let sel = Document.PathMap.add path
           (Document.element_selection_all path) doc.selection in
         ctrl#set_selection sel);
    `Null
  in
  let doc_toggle_selection spec ctx store =
    (match extract_path spec store ctx with
     | None -> ()
     | Some path ->
       let doc = ctrl#document in
       let sel =
         if Document.PathMap.mem path doc.selection
         then Document.PathMap.remove path doc.selection
         else Document.PathMap.add path
                (Document.element_selection_all path) doc.selection
       in
       ctrl#set_selection sel);
    `Null
  in
  let doc_translate_selection spec ctx store =
    (match spec with
     | `Assoc args ->
       let lookup k = List.assoc_opt k args in
       let dx = eval_number (lookup "dx") store ctx in
       let dy = eval_number (lookup "dy") store ctx in
       if dx <> 0.0 || dy <> 0.0 then ctrl#move_selection dx dy
     | _ -> ());
    `Null
  in
  let doc_copy_selection spec ctx store =
    (match spec with
     | `Assoc args ->
       let lookup k = List.assoc_opt k args in
       let dx = eval_number (lookup "dx") store ctx in
       let dy = eval_number (lookup "dy") store ctx in
       ctrl#copy_selection dx dy
     | _ -> ());
    `Null
  in
  let doc_select_in_rect spec ctx store =
    (match spec with
     | `Assoc args ->
       let (rx, ry, rw, rh, additive) = normalize_rect_args args store ctx in
       ctrl#select_rect ~extend:additive rx ry rw rh
     | _ -> ());
    `Null
  in
  let doc_partial_select_in_rect spec ctx store =
    (match spec with
     | `Assoc args ->
       let (rx, ry, rw, rh, additive) = normalize_rect_args args store ctx in
       ctrl#partial_select_rect ~extend:additive rx ry rw rh
     | _ -> ());
    `Null
  in
  [ ("doc.snapshot", doc_snapshot);
    ("doc.clear_selection", doc_clear_selection);
    ("doc.set_selection", doc_set_selection);
    ("doc.add_to_selection", doc_add_to_selection);
    ("doc.toggle_selection", doc_toggle_selection);
    ("doc.translate_selection", doc_translate_selection);
    ("doc.copy_selection", doc_copy_selection);
    ("doc.select_in_rect", doc_select_in_rect);
    ("doc.partial_select_in_rect", doc_partial_select_in_rect);
  ]
