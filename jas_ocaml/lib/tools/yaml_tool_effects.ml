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
  (* ── brush.* library mutation helpers ─────────────────── *)

  let eval_string_value arg store ctx : string =
    match arg with
    | None | Some `Null -> ""
    | Some (`String s) ->
      let eval_ctx = State_store.eval_context ~extra:ctx store in
      (match Expr_eval.evaluate s eval_ctx with
       | Expr_eval.Str rs -> rs
       | _ -> "")
    | _ -> ""
  in

  let eval_string_list arg store ctx : string list =
    match arg with
    | Some (`List items) ->
      List.filter_map (fun v -> match v with
        | `String s -> Some s
        | _ -> None) items
    | Some (`String s) ->
      let eval_ctx = State_store.eval_context ~extra:ctx store in
      (match Expr_eval.evaluate s eval_ctx with
       | Expr_eval.List items ->
         List.filter_map (fun v -> match v with
           | `String s -> Some s
           | _ -> None) items
       | _ -> [])
    | _ -> []
  in

  let resolve_value_or_expr arg store ctx : Yojson.Safe.t =
    match arg with
    | None | Some `Null -> `Null
    | Some (`String s) ->
      let eval_ctx = State_store.eval_context ~extra:ctx store in
      Expr_eval.value_to_json (Expr_eval.evaluate s eval_ctx)
    | Some v -> v
  in

  (* Sync the canvas brush registry with the current
     data.brush_libraries so the next paint sees the update. The
     registry lives in its own module to avoid a dependency cycle
     between yaml_tool_effects and canvas_subwindow. *)
  let sync_canvas_brushes (store : State_store.t) =
    Brush_registry.set
      (State_store.get_data_path store "brush_libraries")
  in

  let library_brushes_path lib_id =
    "brush_libraries." ^ lib_id ^ ".brushes"
  in

  let brush_filter_library_by_slug store lib_id slugs =
    let path = library_brushes_path lib_id in
    match State_store.get_data_path store path with
    | `List brushes ->
      let next = List.filter (fun b ->
        match b with
        | `Assoc fields ->
          (match List.assoc_opt "slug" fields with
           | Some (`String s) -> not (List.mem s slugs)
           | _ -> true)
        | _ -> true
      ) brushes in
      State_store.set_data_path store path (`List next)
    | _ -> ()
  in

  let brush_duplicate_in_library store lib_id slugs : string list =
    let path = library_brushes_path lib_id in
    match State_store.get_data_path store path with
    | `List brushes ->
      let existing = ref (List.fold_left (fun acc b ->
        match b with
        | `Assoc fields ->
          (match List.assoc_opt "slug" fields with
           | Some (`String s) -> s :: acc
           | _ -> acc)
        | _ -> acc) [] brushes)
      in
      let new_slugs = ref [] in
      let rec unique_slug base n =
        let candidate = if n = 1
          then base ^ "_copy"
          else Printf.sprintf "%s_copy_%d" base n in
        if List.mem candidate !existing
        then unique_slug base (n + 1)
        else candidate
      in
      let next = List.concat_map (fun b ->
        match b with
        | `Assoc fields ->
          let slug = match List.assoc_opt "slug" fields with
            | Some (`String s) -> s | _ -> "" in
          if List.mem slug slugs then begin
            let new_slug = unique_slug slug 1 in
            existing := new_slug :: !existing;
            new_slugs := new_slug :: !new_slugs;
            let name = match List.assoc_opt "name" fields with
              | Some (`String n) -> n
              | _ -> "Brush" in
            let copy_fields = List.map (fun (k, v) ->
              match k with
              | "name" -> (k, `String (name ^ " copy"))
              | "slug" -> (k, `String new_slug)
              | _ -> (k, v)) fields in
            [b; `Assoc copy_fields]
          end
          else [b]
        | _ -> [b]
      ) brushes in
      State_store.set_data_path store path (`List next);
      List.rev !new_slugs
    | _ -> []
  in

  let brush_append_to_library store lib_id brush =
    let path = library_brushes_path lib_id in
    let brushes = match State_store.get_data_path store path with
      | `List bs -> bs
      | _ -> [] in
    State_store.set_data_path store path (`List (brushes @ [brush]))
  in

  let brush_update_in_library store lib_id slug patch =
    let path = library_brushes_path lib_id in
    let patch_fields = match patch with `Assoc fs -> fs | _ -> [] in
    if patch_fields = [] then ()
    else match State_store.get_data_path store path with
      | `List brushes ->
        let next = List.map (fun b ->
          match b with
          | `Assoc fields ->
            let matches = match List.assoc_opt "slug" fields with
              | Some (`String s) -> s = slug
              | _ -> false in
            if matches then
              let merged = List.map (fun (k, v) ->
                match List.assoc_opt k patch_fields with
                | Some new_v -> (k, new_v)
                | None -> (k, v)) fields in
              let added = List.filter
                (fun (k, _) -> not (List.mem_assoc k fields)) patch_fields in
              `Assoc (merged @ added)
            else b
          | _ -> b
        ) brushes in
        State_store.set_data_path store path (`List next)
      | _ -> ()
  in

  (* Generic data.* primitives — write/append/remove/insert in the
     data namespace at a dotted path. Mirrors the JS Phase 1.13
     effects. *)
  let data_set spec ctx store =
    (match spec with
     | `Assoc args ->
       let path = eval_string_value (List.assoc_opt "path" args) store ctx in
       if path <> "" then begin
         let value = resolve_value_or_expr (List.assoc_opt "value" args) store ctx in
         State_store.set_data_path store path value
       end
     | _ -> ());
    `Null
  in

  let data_list_append spec ctx store =
    (match spec with
     | `Assoc args ->
       let path = eval_string_value (List.assoc_opt "path" args) store ctx in
       if path <> "" then begin
         let value = resolve_value_or_expr (List.assoc_opt "value" args) store ctx in
         let cur = match State_store.get_data_path store path with
           | `List items -> items
           | _ -> []
         in
         State_store.set_data_path store path (`List (cur @ [value]))
       end
     | _ -> ());
    `Null
  in

  let data_list_remove spec ctx store =
    (match spec with
     | `Assoc args ->
       let path = eval_string_value (List.assoc_opt "path" args) store ctx in
       let index = int_of_float (eval_number (List.assoc_opt "index" args) store ctx) in
       if path <> "" then
         (match State_store.get_data_path store path with
          | `List items when index >= 0 && index < List.length items ->
            let next = List.filteri (fun i _ -> i <> index) items in
            State_store.set_data_path store path (`List next)
          | _ -> ())
     | _ -> ());
    `Null
  in

  let data_list_insert spec ctx store =
    (match spec with
     | `Assoc args ->
       let path = eval_string_value (List.assoc_opt "path" args) store ctx in
       let index = int_of_float (eval_number (List.assoc_opt "index" args) store ctx) in
       if path <> "" then begin
         let value = resolve_value_or_expr (List.assoc_opt "value" args) store ctx in
         let cur = match State_store.get_data_path store path with
           | `List items -> items
           | _ -> []
         in
         let len = List.length cur in
         let i = max 0 (min index len) in
         let before = List.filteri (fun j _ -> j < i) cur in
         let after = List.filteri (fun j _ -> j >= i) cur in
         State_store.set_data_path store path (`List (before @ [value] @ after))
       end
     | _ -> ());
    `Null
  in

  (* brush.options_confirm — per-mode dispatch reading dialog
     state. Phase 1 Calligraphic only. The YAML
     brush_options_confirm action calls this. *)
  let brush_options_confirm _spec _ctx store =
    let dialog = State_store.get_dialog_state store in
    let params = match State_store.get_dialog_params store with
      | Some p -> p
      | None -> [] in
    let get_str fields k =
      match List.assoc_opt k fields with
      | Some (`String s) -> s
      | _ -> ""
    in
    let get_num fields k default =
      match List.assoc_opt k fields with
      | Some (`Int n) -> float_of_int n
      | Some (`Float f) -> f
      | _ -> default
    in
    let mode = match get_str params "mode" with "" -> "create" | s -> s in
    let library = get_str params "library" in
    let brush_slug = get_str params "brush_slug" in
    let name = match get_str dialog "brush_name" with "" -> "Brush" | s -> s in
    let brush_type = match get_str dialog "brush_type" with "" -> "calligraphic" | s -> s in
    let angle = get_num dialog "angle" 0.0 in
    let roundness = get_num dialog "roundness" 100.0 in
    let size = get_num dialog "size" 5.0 in
    let angle_var = match List.assoc_opt "angle_variation" dialog with
      | Some v -> v | None -> `Assoc [("mode", `String "fixed")] in
    let roundness_var = match List.assoc_opt "roundness_variation" dialog with
      | Some v -> v | None -> `Assoc [("mode", `String "fixed")] in
    let size_var = match List.assoc_opt "size_variation" dialog with
      | Some v -> v | None -> `Assoc [("mode", `String "fixed")] in

    let lib_key =
      if library <> "" then library
      else match State_store.get_data_path store "brush_libraries" with
        | `Assoc ((k, _) :: _) -> k
        | _ -> "" in
    if lib_key = "" then `Null
    else begin
      (match mode with
       | "create" ->
         (* Slug from name: lowercase, non-alphanum -> _ *)
         let raw = String.map (fun c ->
           if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then c
           else if c >= 'A' && c <= 'Z' then Char.chr (Char.code c + 32)
           else '_') name in
         let path = library_brushes_path lib_key in
         let existing = match State_store.get_data_path store path with
           | `List items -> List.filter_map (fun b ->
               match b with `Assoc f ->
                 (match List.assoc_opt "slug" f with
                  | Some (`String s) -> Some s | _ -> None)
               | _ -> None) items
           | _ -> [] in
         let slug = ref raw in
         let n = ref 2 in
         while List.mem !slug existing do
           slug := Printf.sprintf "%s_%d" raw !n;
           incr n
         done;
         let base = [
           ("name", `String name);
           ("slug", `String !slug);
           ("type", `String brush_type);
         ] in
         let cal_fields =
           if brush_type = "calligraphic"
           then [
             ("angle", `Float angle);
             ("roundness", `Float roundness);
             ("size", `Float size);
             ("angle_variation", angle_var);
             ("roundness_variation", roundness_var);
             ("size_variation", size_var);
           ]
           else [] in
         brush_append_to_library store lib_key (`Assoc (base @ cal_fields));
         sync_canvas_brushes store
       | "library_edit" when brush_slug <> "" ->
         let base = [("name", `String name)] in
         let cal_fields =
           if brush_type = "calligraphic"
           then [
             ("angle", `Float angle);
             ("roundness", `Float roundness);
             ("size", `Float size);
             ("angle_variation", angle_var);
             ("roundness_variation", roundness_var);
             ("size_variation", size_var);
           ]
           else [] in
         brush_update_in_library store lib_key brush_slug (`Assoc (base @ cal_fields));
         sync_canvas_brushes store
       | "instance_edit" ->
         let overrides = `Assoc [
           ("angle", `Float angle);
           ("roundness", `Float roundness);
           ("size", `Float size);
         ] in
         let s = Yojson.Safe.to_string overrides in
         ctrl#set_selection_stroke_brush_overrides (Some s)
       | _ -> ());
      `Null
    end
  in

  let brush_delete_selected spec ctx store =
    (match spec with
     | `Assoc args ->
       let lib_id = eval_string_value (List.assoc_opt "library" args) store ctx in
       let slugs = eval_string_list (List.assoc_opt "slugs" args) store ctx in
       if lib_id <> "" && slugs <> [] then begin
         brush_filter_library_by_slug store lib_id slugs;
         State_store.set_panel store "brushes" "selected_brushes" (`List []);
         sync_canvas_brushes store
       end
     | _ -> ());
    `Null
  in

  let brush_duplicate_selected spec ctx store =
    (match spec with
     | `Assoc args ->
       let lib_id = eval_string_value (List.assoc_opt "library" args) store ctx in
       let slugs = eval_string_list (List.assoc_opt "slugs" args) store ctx in
       if lib_id <> "" && slugs <> [] then begin
         let new_slugs = brush_duplicate_in_library store lib_id slugs in
         State_store.set_panel store "brushes" "selected_brushes"
           (`List (List.map (fun s -> `String s) new_slugs));
         sync_canvas_brushes store
       end
     | _ -> ());
    `Null
  in

  let brush_append_effect spec ctx store =
    (match spec with
     | `Assoc args ->
       let lib_id = eval_string_value (List.assoc_opt "library" args) store ctx in
       let brush = resolve_value_or_expr (List.assoc_opt "brush" args) store ctx in
       (match brush with
        | `Assoc _ when lib_id <> "" ->
          brush_append_to_library store lib_id brush;
          sync_canvas_brushes store
        | _ -> ())
     | _ -> ());
    `Null
  in

  let brush_update_effect spec ctx store =
    (match spec with
     | `Assoc args ->
       let lib_id = eval_string_value (List.assoc_opt "library" args) store ctx in
       let slug = eval_string_value (List.assoc_opt "slug" args) store ctx in
       let patch = resolve_value_or_expr (List.assoc_opt "patch" args) store ctx in
       (match patch with
        | `Assoc _ when lib_id <> "" && slug <> "" ->
          brush_update_in_library store lib_id slug patch;
          sync_canvas_brushes store
        | _ -> ())
     | _ -> ());
    `Null
  in

  (* Phase 1 supports brush attributes only; other attrs ignored.
     Used by apply_brush_to_selection / remove_brush_from_selection
     in actions.yaml. Mirrors the JS Phase 1.8 effect. *)
  let doc_set_attr_on_selection spec ctx store =
    (match spec with
     | `Assoc args ->
       let attr = match List.assoc_opt "attr" args with
         | Some (`String s) -> s
         | _ -> "" in
       let value =
         match List.assoc_opt "value" args with
         | None | Some `Null -> None
         | Some (`String s) ->
           let eval_ctx = State_store.eval_context ~extra:ctx store in
           (match Expr_eval.evaluate s eval_ctx with
            | Expr_eval.Str rs when rs <> "" -> Some rs
            | _ -> None)
         | _ -> None
       in
       (match attr with
        | "stroke_brush" -> ctrl#set_selection_stroke_brush value
        | "stroke_brush_overrides" -> ctrl#set_selection_stroke_brush_overrides value
        | _ -> ())
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
  (* ── Buffer effects (Phase 3) ─────────────────────────── *)
  let buffer_push spec ctx store =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String name) ->
          let lookup k = List.assoc_opt k args in
          let x = eval_number (lookup "x") store ctx in
          let y = eval_number (lookup "y") store ctx in
          Point_buffers.push name x y
        | _ -> ())
     | _ -> ());
    `Null
  in
  let buffer_clear spec _ _ =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String name) -> Point_buffers.clear name
        | _ -> ())
     | _ -> ());
    `Null
  in
  let anchor_push spec ctx store =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String name) ->
          let lookup k = List.assoc_opt k args in
          let x = eval_number (lookup "x") store ctx in
          let y = eval_number (lookup "y") store ctx in
          Anchor_buffers.push name x y
        | _ -> ())
     | _ -> ());
    `Null
  in
  let anchor_set_last_out spec ctx store =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String name) ->
          let lookup k = List.assoc_opt k args in
          let hx = eval_number (lookup "hx") store ctx in
          let hy = eval_number (lookup "hy") store ctx in
          Anchor_buffers.set_last_out_handle name hx hy
        | _ -> ())
     | _ -> ());
    `Null
  in
  let anchor_pop spec _ _ =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String name) -> Anchor_buffers.pop name
        | _ -> ())
     | _ -> ());
    `Null
  in
  let anchor_clear spec _ _ =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String name) -> Anchor_buffers.clear name
        | _ -> ())
     | _ -> ());
    `Null
  in
  let doc_select_polygon_from_buffer spec ctx store =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String name) ->
          let additive = eval_bool (List.assoc_opt "additive" args) store ctx in
          let pts = Point_buffers.points name in
          if List.length pts >= 3 then
            let arr = Array.of_list pts in
            ctrl#select_polygon ~extend:additive arr
        | _ -> ())
     | _ -> ());
    `Null
  in

  (* ── Phase 4b helpers ─────────────────────────────────── *)

  (* Evaluate a value-returning field — string expressions get
     evaluated, other JSON values get wrapped directly. *)
  let eval_expr_as_value arg store ctx : Expr_eval.value =
    match arg with
    | None | Some `Null -> Expr_eval.Null
    | Some (`String s) ->
      let eval_ctx = State_store.eval_context ~extra:ctx store in
      Expr_eval.evaluate s eval_ctx
    | Some v -> Expr_eval.value_of_json v
  in

  (* Resolve an optional fill: field. Absent → default; null →
     None; explicit color / hex string → Some fill. *)
  (* Parse a hex string to an Element.color. *)
  let color_from_hex (s : string) : Element.color =
    let (r, g, b) = Color_util.parse_hex s in
    Element.color_rgb
      (float_of_int r /. 255.0)
      (float_of_int g /. 255.0)
      (float_of_int b /. 255.0)
  in

  let resolve_fill_field field has_key store ctx default
    : Element.fill option =
    if not has_key then default
    else begin
      let v = eval_expr_as_value field store ctx in
      match v with
      | Expr_eval.Null -> None
      | Expr_eval.Color c | Expr_eval.Str c ->
        Some { fill_color = color_from_hex c; fill_opacity = 1.0 }
      | _ -> default
    end
  in

  let resolve_stroke_field field has_key store ctx
      (default : Element.stroke option)
    : Element.stroke option =
    if not has_key then default
    else begin
      let v = eval_expr_as_value field store ctx in
      match v with
      | Expr_eval.Null -> None
      | Expr_eval.Color c | Expr_eval.Str c ->
        Some {
          stroke_color = color_from_hex c;
          stroke_width = 1.0;
          stroke_linecap = Butt;
          stroke_linejoin = Miter;
          stroke_miter_limit = 10.0;
          stroke_align = Center;
          stroke_dash_pattern = [];
          stroke_start_arrow = Arrow_none;
          stroke_end_arrow = Arrow_none;
          stroke_start_arrow_scale = 100.0;
          stroke_end_arrow_scale = 100.0;
          stroke_arrow_align = Tip_at_end;
          stroke_opacity = 1.0;
        }
      | _ -> default
    end
  in

  (* Build an Element from a {type, ...} spec. *)
  let build_element_json spec store ctx : Element.element option =
    match spec with
    | `Assoc args ->
      let lookup k = List.assoc_opt k args in
      let has_fill = List.mem_assoc "fill" args in
      let has_stroke = List.mem_assoc "stroke" args in
      let default_fill = ctrl#model#default_fill in
      let default_stroke = ctrl#model#default_stroke in
      let fill = resolve_fill_field (lookup "fill") has_fill store ctx default_fill in
      let stroke = resolve_stroke_field (lookup "stroke") has_stroke store ctx default_stroke in
      (match List.assoc_opt "type" args with
       | Some (`String "rect") ->
         let x = eval_number (lookup "x") store ctx in
         let y = eval_number (lookup "y") store ctx in
         let w = eval_number (lookup "width") store ctx in
         let h = eval_number (lookup "height") store ctx in
         let rx = eval_number (lookup "rx") store ctx in
         let ry = eval_number (lookup "ry") store ctx in
         Some (Element.make_rect ~rx ~ry ~fill ~stroke x y w h)
       | Some (`String "line") ->
         let x1 = eval_number (lookup "x1") store ctx in
         let y1 = eval_number (lookup "y1") store ctx in
         let x2 = eval_number (lookup "x2") store ctx in
         let y2 = eval_number (lookup "y2") store ctx in
         Some (Element.make_line ~stroke x1 y1 x2 y2)
       | Some (`String "polygon") ->
         let x1 = eval_number (lookup "x1") store ctx in
         let y1 = eval_number (lookup "y1") store ctx in
         let x2 = eval_number (lookup "x2") store ctx in
         let y2 = eval_number (lookup "y2") store ctx in
         let sides_raw = int_of_float (eval_number (lookup "sides") store ctx) in
         let sides = if sides_raw <= 0 then 5 else sides_raw in
         let pts = Regular_shapes.regular_polygon_points x1 y1 x2 y2 sides in
         Some (Element.make_polygon ~fill ~stroke pts)
       | Some (`String "star") ->
         let x1 = eval_number (lookup "x1") store ctx in
         let y1 = eval_number (lookup "y1") store ctx in
         let x2 = eval_number (lookup "x2") store ctx in
         let y2 = eval_number (lookup "y2") store ctx in
         let raw = int_of_float (eval_number (lookup "points") store ctx) in
         let n = if raw <= 0 then 5 else raw in
         let pts = Regular_shapes.star_points x1 y1 x2 y2 n in
         Some (Element.make_polygon ~fill ~stroke pts)
       | _ -> None)
    | _ -> None
  in

  let doc_add_element spec ctx store =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "element" args with
        | Some elem_spec ->
          (match build_element_json elem_spec store ctx with
           | Some elem -> ctrl#add_element elem
           | None -> ())
        | None -> ())
     | _ -> ());
    `Null
  in

  (* Build a Path element from commands, applying model defaults.
     Threads optional stroke_brush from spec onto the new Path so the
     Paintbrush tool's on_mouseup can pass `state.stroke_brush`
     through. The renderer then dispatches the brush via the
     calligraphic outliner. *)
  (* Paintbrush stroke-width commit rule per PAINTBRUSH_TOOL.md
     §Fill and stroke: no brush → state.stroke_width; brush with size
     (Calligraphic/Scatter/Bristle) → overrides.size, else brush.size;
     brush with no size (Art/Pattern) → state.stroke_width. *)
  let paintbrush_stroke_width stroke_brush overrides store ctx : float =
    let state_width =
      match eval_expr_as_value (Some (`String "state.stroke_width"))
              store ctx with
      | Expr_eval.Number n -> n
      | _ -> 1.0
    in
    match stroke_brush with
    | None -> state_width
    | Some slug ->
      let override_size =
        match overrides with
        | Some json_str ->
          (try
             match Yojson.Safe.from_string json_str with
             | `Assoc pairs ->
               (match List.assoc_opt "size" pairs with
                | Some (`Float n) -> Some n
                | Some (`Int n) -> Some (float_of_int n)
                | _ -> None)
             | _ -> None
           with _ -> None)
        | None -> None
      in
      (match override_size with
       | Some n -> n
       | None ->
         (* Parse "libId/brushSlug" and look up brush.size. *)
         let parts = String.split_on_char '/' slug in
         (match parts with
          | [lib_id; brush_slug] ->
            let path = "brush_libraries." ^ lib_id ^ ".brushes" in
            let data = State_store.get_data_path store path in
            (match data with
             | `List brushes ->
               let found = List.find_opt (fun b ->
                 match b with
                 | `Assoc fields ->
                   (match List.assoc_opt "slug" fields with
                    | Some (`String s) -> s = brush_slug
                    | _ -> false)
                 | _ -> false
               ) brushes in
               (match found with
                | Some (`Assoc fields) ->
                  (match List.assoc_opt "size" fields with
                   | Some (`Float n) -> n
                   | Some (`Int n) -> float_of_int n
                   | _ -> state_width)
                | _ -> state_width)
             | _ -> state_width)
          | _ -> state_width))
  in

  (* make_path_from_commands: pencil-style callers (no stroke_brush
     key) get default fill/stroke; paintbrush-style callers (presence
     of stroke_brush) switch on PAINTBRUSH_TOOL.md §Fill and stroke:
     - stroke = Stroke(state.stroke_color, paintbrush_stroke_width)
     - fill = state.fill_color when fill_new_strokes else None
     - stroke_brush_overrides passed onto the Path. *)
  let make_path_from_commands cmds spec_args store ctx : Element.element =
    let has_stroke_brush_arg = List.mem_assoc "stroke_brush" spec_args in
    let stroke_brush =
      match eval_expr_as_value (List.assoc_opt "stroke_brush" spec_args) store ctx with
      | Expr_eval.Str rs when rs <> "" -> Some rs
      | _ -> None
    in
    let stroke_brush_overrides =
      match eval_expr_as_value
              (List.assoc_opt "stroke_brush_overrides" spec_args) store ctx with
      | Expr_eval.Str rs when rs <> "" -> Some rs
      | _ -> None
    in
    let fill =
      if List.mem_assoc "fill_new_strokes" spec_args then begin
        if eval_bool (List.assoc_opt "fill_new_strokes" spec_args) store ctx
        then
          (match eval_expr_as_value (Some (`String "state.fill_color"))
                   store ctx with
           | Expr_eval.Color c | Expr_eval.Str c ->
             (try Some (Element.make_fill (color_from_hex c))
              with _ -> None)
           | _ -> None)
        else None
      end
      else
        let has_fill = List.mem_assoc "fill" spec_args in
        let default_fill = ctrl#model#default_fill in
        resolve_fill_field (List.assoc_opt "fill" spec_args) has_fill
          store ctx default_fill
    in
    let stroke =
      if has_stroke_brush_arg then begin
        let color_str =
          match eval_expr_as_value (Some (`String "state.stroke_color"))
                  store ctx with
          | Expr_eval.Color c | Expr_eval.Str c -> c
          | _ -> "#000000"
        in
        let color =
          try color_from_hex color_str
          with _ -> Element.color_rgb 0.0 0.0 0.0
        in
        let width = paintbrush_stroke_width stroke_brush
                      stroke_brush_overrides store ctx in
        Some (Element.make_stroke ~width color)
      end
      else
        let has_stroke = List.mem_assoc "stroke" spec_args in
        let default_stroke = ctrl#model#default_stroke in
        resolve_stroke_field (List.assoc_opt "stroke" spec_args)
          has_stroke store ctx default_stroke
    in
    Element.make_path ~fill ~stroke ~stroke_brush ~stroke_brush_overrides cmds
  in

  let doc_add_path_from_buffer spec ctx store =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String name) ->
          let raw_fit_error = match List.assoc_opt "fit_error" args with
            | Some _ -> eval_number (List.assoc_opt "fit_error" args) store ctx
            | None -> 4.0
          in
          let fit_error = if raw_fit_error = 0.0 then 4.0 else raw_fit_error in
          let points = Point_buffers.points name in
          if List.length points >= 2 then begin
            let segments = Fit_curve.fit_curve points fit_error in
            match segments with
            | [] -> ()
            | seg0 :: _ ->
              let cmds = ref [Element.MoveTo (seg0.p1x, seg0.p1y)] in
              List.iter (fun (seg : Fit_curve.segment) ->
                cmds := Element.CurveTo (seg.c1x, seg.c1y,
                                         seg.c2x, seg.c2y,
                                         seg.p2x, seg.p2y) :: !cmds
              ) segments;
              (* Paintbrush §Gestures close-at-release: append ClosePath
                 when close=true. *)
              if eval_bool (List.assoc_opt "close" args) store ctx then
                cmds := Element.ClosePath :: !cmds;
              let d = List.rev !cmds in
              let elem = make_path_from_commands d args store ctx in
              ctrl#add_element elem
          end
        | _ -> ())
     | _ -> ());
    `Null
  in

  (* ── Paintbrush edit-gesture effects per PAINTBRUSH_TOOL.md
     §Edit gesture ──────────────────────────────────────────── *)
  let encode_path_for_paintbrush (path : int list) : Yojson.Safe.t =
    `Assoc [("__path__", `List (List.map (fun i -> `Int i) path))]
  in
  let decode_path_for_paintbrush (v : Yojson.Safe.t) : int list option =
    match v with
    | `Assoc pairs ->
      (match List.assoc_opt "__path__" pairs with
       | Some (`List arr) ->
         let out = List.filter_map (function
           | `Int i -> Some i | _ -> None) arr in
         if List.length out = List.length arr then Some out else None
       | _ -> None)
    | _ -> None
  in

  let doc_paintbrush_edit_start spec ctx store =
    (match spec with
     | `Assoc args ->
       let x = eval_number (List.assoc_opt "x" args) store ctx in
       let y = eval_number (List.assoc_opt "y" args) store ctx in
       let within = eval_number (List.assoc_opt "within" args) store ctx in
       let within_sq = within *. within in
       let best = ref None in
       let doc = ctrl#document in
       Document.PathMap.iter (fun path _ ->
         let elem = Document.get_element doc path in
         match elem with
         | Element.Path { d; _ } when not (Element.is_locked elem)
                                    && List.length d >= 2 ->
           let (flat, _cmd_map) = Path_ops.flatten_with_cmd_map d in
           if flat <> [] then
             List.iteri (fun i (fx, fy) ->
               let dx = fx -. x and dy = fy -. y in
               let dsq = dx *. dx +. dy *. dy in
               if dsq <= within_sq then begin
                 match !best with
                 | Some (_, _, bdsq) when bdsq <= dsq -> ()
                 | _ -> best := Some (path, i, dsq)
               end
             ) flat
         | _ -> ()
       ) doc.Document.selection;
       (match !best with
        | Some (path, entry_idx, _) ->
          State_store.set_tool store "paintbrush" "mode"
            (`String "edit");
          State_store.set_tool store "paintbrush" "edit_target_path"
            (encode_path_for_paintbrush path);
          State_store.set_tool store "paintbrush" "edit_entry_idx"
            (`Int entry_idx)
        | None -> ())
     | _ -> ());
    `Null
  in

  let doc_paintbrush_edit_commit spec ctx store =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String buffer) ->
          let raw_e = eval_number (List.assoc_opt "fit_error" args) store ctx in
          let fit_error = if raw_e = 0.0 then 4.0 else raw_e in
          let within = eval_number (List.assoc_opt "within" args) store ctx in
          let within_sq = within *. within in
          let target_path_v = State_store.get_tool store "paintbrush"
                                "edit_target_path" in
          (match decode_path_for_paintbrush target_path_v with
           | None -> ()
           | Some target_path ->
             let entry_idx =
               match State_store.get_tool store "paintbrush"
                       "edit_entry_idx" with
               | `Int n -> n
               | `Float n -> int_of_float n
               | _ -> -1
             in
             if entry_idx < 0 then ()
             else begin
               let drag_points = Point_buffers.points buffer in
               if List.length drag_points < 2 then ()
               else begin
                 let doc = ctrl#document in
                 let target_elem = Document.get_element doc target_path in
                 match target_elem with
                 | Element.Path { d; _ } when not (Element.is_locked target_elem)
                                            && List.length d >= 2 ->
                   let (flat, cmd_map) = Path_ops.flatten_with_cmd_map d in
                   if flat = [] || entry_idx >= List.length flat then ()
                   else begin
                     let last = List.nth drag_points
                                  (List.length drag_points - 1) in
                     let (last_x, last_y) = last in
                     let best = ref None in
                     List.iteri (fun i (fx, fy) ->
                       let dx = fx -. last_x and dy = fy -. last_y in
                       let dsq = dx *. dx +. dy *. dy in
                       match !best with
                       | Some (_, bdsq) when bdsq <= dsq -> ()
                       | _ -> best := Some (i, dsq)
                     ) flat;
                     match !best with
                     | None -> ()
                     | Some (_, bdsq) when bdsq > within_sq -> ()
                     | Some (exit_idx, _) when exit_idx = entry_idx -> ()
                     | Some (exit_idx, _) ->
                       let lo_flat = min entry_idx exit_idx in
                       let hi_flat = max entry_idx exit_idx in
                       let c0 = List.nth cmd_map lo_flat in
                       let c1 = List.nth cmd_map hi_flat in
                       if c0 >= c1 || c1 >= List.length d then ()
                       else begin
                         let ordered_drag =
                           if exit_idx < entry_idx then List.rev drag_points
                           else drag_points in
                         let start_pt = Path_ops.cmd_start_point d c0 in
                         let points_to_fit = start_pt :: ordered_drag in
                         if List.length points_to_fit < 2 then ()
                         else begin
                           let segments = Fit_curve.fit_curve
                                            points_to_fit fit_error in
                           if segments = [] then ()
                           else begin
                             let prefix = List.filteri (fun i _ -> i < c0) d in
                             let suffix = List.filteri (fun i _ -> i > c1) d in
                             let new_curves = List.map (fun (seg : Fit_curve.segment) ->
                               Element.CurveTo (seg.c1x, seg.c1y,
                                                seg.c2x, seg.c2y,
                                                seg.p2x, seg.p2y)
                             ) segments in
                             let new_cmds = prefix @ new_curves @ suffix in
                             let new_elem = match target_elem with
                               | Element.Path pe -> Element.Path { pe with d = new_cmds }
                               | _ -> target_elem in
                             let new_doc = Document.replace_element doc
                                             target_path new_elem in
                             ctrl#set_document new_doc
                           end
                         end
                       end
                   end
                 | _ -> ()
               end
             end)
        | _ -> ())
     | _ -> ());
    `Null
  in

  (* ── Blob Brush commit helpers + effects ─────────────── *)

  (* Runtime tip resolution per BLOB_BRUSH_TOOL.md — when
     state.stroke_brush refers to a Calligraphic library brush, its
     size/angle/roundness drive the tip (with stroke_brush_overrides
     layered). Otherwise the dialog defaults state.blob_brush_* are
     used. Variation modes other than `fixed` are evaluated as the
     base value in Phase 1. *)
  let blob_brush_effective_tip store ctx : float * float * float =
    let num_or expr default =
      match eval_expr_as_value (Some (`String expr)) store ctx with
      | Expr_eval.Number n -> n
      | _ -> default
    in
    let default_size = num_or "state.blob_brush_size" 10.0 in
    let default_angle = num_or "state.blob_brush_angle" 0.0 in
    let default_roundness = num_or "state.blob_brush_roundness" 100.0 in
    let slug_val = eval_expr_as_value
                     (Some (`String "state.stroke_brush")) store ctx in
    let slug = match slug_val with
      | Expr_eval.Str s when s <> "" -> Some s
      | _ -> None
    in
    match slug with
    | None -> (default_size, default_angle, default_roundness)
    | Some slug ->
      (match String.index_opt slug '/' with
       | None -> (default_size, default_angle, default_roundness)
       | Some i ->
         let lib_id = String.sub slug 0 i in
         let brush_slug = String.sub slug (i + 1)
                            (String.length slug - i - 1) in
         let path = "brush_libraries." ^ lib_id ^ ".brushes" in
         match State_store.get_data_path store path with
         | `List brushes ->
           let found = List.find_opt (fun b ->
             match b with
             | `Assoc fields ->
               (match List.assoc_opt "slug" fields with
                | Some (`String s) -> s = brush_slug
                | _ -> false)
             | _ -> false) brushes in
           (match found with
            | Some (`Assoc fields) ->
              let is_cal = match List.assoc_opt "type" fields with
                | Some (`String "calligraphic") -> true
                | _ -> false in
              if not is_cal then
                (default_size, default_angle, default_roundness)
              else begin
                let size = match List.assoc_opt "size" fields with
                  | Some (`Float n) -> n
                  | Some (`Int n) -> float_of_int n
                  | _ -> default_size in
                let angle = match List.assoc_opt "angle" fields with
                  | Some (`Float n) -> n
                  | Some (`Int n) -> float_of_int n
                  | _ -> default_angle in
                let roundness = match List.assoc_opt "roundness" fields with
                  | Some (`Float n) -> n
                  | Some (`Int n) -> float_of_int n
                  | _ -> default_roundness in
                (* Apply state.stroke_brush_overrides if present. *)
                let ovr = eval_expr_as_value
                            (Some (`String "state.stroke_brush_overrides"))
                            store ctx in
                match ovr with
                | Expr_eval.Str s when s <> "" ->
                  (try
                     match Yojson.Safe.from_string s with
                     | `Assoc o ->
                       let pick key default =
                         match List.assoc_opt key o with
                         | Some (`Float n) -> n
                         | Some (`Int n) -> float_of_int n
                         | _ -> default in
                       (pick "size" size, pick "angle" angle,
                        pick "roundness" roundness)
                     | _ -> (size, angle, roundness)
                   with _ -> (size, angle, roundness))
                | _ -> (size, angle, roundness)
              end
            | _ -> (default_size, default_angle, default_roundness))
         | _ -> (default_size, default_angle, default_roundness))
  in

  (* 16-segment rotated-ellipse ring at (cx, cy). *)
  let blob_brush_oval_ring cx cy size angle_deg roundness_pct : Boolean.ring =
    let segments = 16 in
    let rx = size *. 0.5 in
    let ry = size *. (roundness_pct /. 100.0) *. 0.5 in
    let rad = angle_deg *. Float.pi /. 180.0 in
    let cs = cos rad and sn = sin rad in
    Array.init segments (fun i ->
      let t = 2.0 *. Float.pi *. float_of_int i /. float_of_int segments in
      let lx = rx *. cos t in
      let ly = ry *. sin t in
      let x = cx +. lx *. cs -. ly *. sn in
      let y = cy +. lx *. sn +. ly *. cs in
      (x, y))
  in

  (* Arc-length resample a point sequence at uniform intervals. Always
     keeps the first and last points. Interpolation is essential:
     naive sample-at-existing-points leaves seams when OS mousemove
     events are coarser than the tip radius. *)
  let blob_brush_arc_length_subsample (points : (float * float) list)
      (spacing : float) : (float * float) list =
    let n = List.length points in
    if n < 2 || spacing <= 0.0 then points
    else begin
      let arr = Array.of_list points in
      let out = ref [arr.(0)] in
      let remaining = ref spacing in
      for i = 0 to n - 2 do
        let (ax, ay) = arr.(i) in
        let (bx, by) = arr.(i + 1) in
        let dx = bx -. ax in
        let dy = by -. ay in
        let seg_len = sqrt (dx *. dx +. dy *. dy) in
        if seg_len > 0.0 then begin
          let t_at = ref 0.0 in
          while !t_at +. !remaining <= seg_len do
            t_at := !t_at +. !remaining;
            let t = !t_at /. seg_len in
            out := (ax +. dx *. t, ay +. dy *. t) :: !out;
            remaining := spacing
          done;
          remaining := !remaining -. (seg_len -. !t_at)
        end
      done;
      let tail = arr.(n - 1) in
      (match !out with
       | last :: _ when last = tail -> ()
       | _ -> out := tail :: !out);
      List.rev !out
    end
  in

  (* Build the swept region from buffer points and tip params.
     Subsamples the buffer at 1/2 * min tip dimension, places an oval
     at each sample, and unions them via boolean_union. *)
  let blob_brush_sweep_region (points : (float * float) list)
      (size, angle, roundness) : Boolean.polygon_set =
    let min_dim = min size (size *. roundness /. 100.0) in
    let spacing = max (min_dim *. 0.5) 0.5 in
    let samples = blob_brush_arc_length_subsample points spacing in
    List.fold_left (fun region (cx, cy) ->
      let oval = [blob_brush_oval_ring cx cy size angle roundness] in
      if region = [] then oval
      else Boolean.boolean_union region oval
    ) [] samples
  in

  (* Fill equality per BLOB_BRUSH_TOOL.md §Merge condition. *)
  let blob_brush_fill_matches (a : Element.fill option) (b : Element.fill option) : bool =
    match a, b with
    | Some fa, Some fb ->
      let hex_of (c : Element.color) =
        let (r, g, b, _) = Element.color_to_rgba c in
        let clamp x = max 0 (min 255 (int_of_float (Float.round (x *. 255.0)))) in
        Printf.sprintf "%02x%02x%02x" (clamp r) (clamp g) (clamp b)
      in
      (String.lowercase_ascii (hex_of fa.Element.fill_color))
        = (String.lowercase_ascii (hex_of fb.Element.fill_color))
      && Float.abs (fa.Element.fill_opacity -. fb.Element.fill_opacity) < 1e-9
    | _ -> false
  in

  (* Insert element at (layer_idx, child_idx), shifting later children. *)
  let blob_brush_insert_at (doc : Document.document)
      (layer_idx : int) (child_idx : int)
      (elem : Element.element) : Document.document =
    if layer_idx < 0 || layer_idx >= Array.length doc.Document.layers then doc
    else begin
      let layer = doc.Document.layers.(layer_idx) in
      let children = Document.children_of layer in
      let n = Array.length children in
      let clamped = max 0 (min child_idx n) in
      let new_children = Array.init (n + 1) (fun i ->
        if i < clamped then children.(i)
        else if i = clamped then elem
        else children.(i - 1)) in
      let new_layer = Document.with_children layer new_children in
      { doc with layers = Array.mapi (fun i l ->
          if i = layer_idx then new_layer else l) doc.Document.layers }
    end
  in

  let doc_blob_brush_commit_painting spec ctx store =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String buffer) when buffer <> "" ->
          let _epsilon = eval_number
                           (List.assoc_opt "fidelity_epsilon" args) store ctx in
          let merge_only_with_selection = eval_bool
                                            (List.assoc_opt "merge_only_with_selection" args) store ctx in
          let _keep_selected = eval_bool
                                 (List.assoc_opt "keep_selected" args) store ctx in
          let points = Point_buffers.points buffer in
          if List.length points < 2 then ()
          else begin
            let tip = blob_brush_effective_tip store ctx in
            let swept = blob_brush_sweep_region points tip in
            if swept = [] then ()
            else begin
              (* Resolve fill from state.fill_color. *)
              let new_fill =
                match eval_expr_as_value
                        (Some (`String "state.fill_color")) store ctx with
                | Expr_eval.Color c | Expr_eval.Str c ->
                  (try Some (Element.make_fill (color_from_hex c))
                   with _ -> None)
                | _ -> None
              in
              let doc = ctrl#document in
              let matches = ref [] in
              let unified = ref swept in
              Array.iteri (fun li layer ->
                let children = Document.children_of layer in
                Array.iteri (fun ci child ->
                  match child with
                  | Element.Path pe
                    when pe.tool_origin = Some "blob_brush"
                      && blob_brush_fill_matches pe.fill new_fill ->
                    let path = [li; ci] in
                    if merge_only_with_selection
                       && not (Document.PathMap.mem path doc.Document.selection) then ()
                    else begin
                      let existing = Path_ops.path_to_polygon_set pe.d in
                      let inter = Boolean.boolean_intersect !unified existing in
                      if inter <> [] then begin
                        unified := Boolean.boolean_union !unified existing;
                        matches := path :: !matches
                      end
                    end
                  | _ -> ()
                ) children
              ) doc.Document.layers;
              let matches_asc = List.sort compare (List.rev !matches) in
              let (insert_layer, insert_idx) =
                match matches_asc with
                | [] -> (0, None)
                | lowest :: _ ->
                  (match lowest with
                   | [li; ci] -> (li, Some ci)
                   | _ -> (0, None))
              in
              let new_d = Path_ops.polygon_set_to_path !unified in
              if new_d = [] then ()
              else begin
                let new_elem = Element.make_path
                                 ~fill:new_fill
                                 ~stroke:None
                                 ~tool_origin:(Some "blob_brush")
                                 new_d in
                (* Remove matches in reverse (so earlier indices stay
                   valid), then insert. *)
                let new_doc =
                  List.fold_left (fun d path ->
                    Document.delete_element d path)
                    doc (List.rev matches_asc) in
                let new_doc = match insert_idx with
                  | Some idx ->
                    blob_brush_insert_at new_doc insert_layer idx new_elem
                  | None ->
                    let n = Array.length
                              (Document.children_of new_doc.Document.layers.(insert_layer)) in
                    blob_brush_insert_at new_doc insert_layer n new_elem
                in
                ctrl#set_document new_doc
              end
            end
          end
        | _ -> ())
     | _ -> ());
    `Null
  in

  let doc_blob_brush_commit_erasing spec ctx store =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String buffer) when buffer <> "" ->
          let _epsilon = eval_number
                           (List.assoc_opt "fidelity_epsilon" args) store ctx in
          let points = Point_buffers.points buffer in
          if List.length points < 2 then ()
          else begin
            let tip = blob_brush_effective_tip store ctx in
            let swept = blob_brush_sweep_region points tip in
            if swept = [] then ()
            else begin
              let doc = ctrl#document in
              let new_doc = ref doc in
              let layer_count = Array.length doc.Document.layers in
              (* Iterate in reverse so deletions don't invalidate earlier
                 indices. *)
              for li = layer_count - 1 downto 0 do
                let children = Document.children_of doc.Document.layers.(li) in
                for ci = Array.length children - 1 downto 0 do
                  match children.(ci) with
                  | Element.Path pe
                    when pe.tool_origin = Some "blob_brush" ->
                    let existing = Path_ops.path_to_polygon_set pe.d in
                    let inter = Boolean.boolean_intersect existing swept in
                    if inter <> [] then begin
                      let remainder = Boolean.boolean_subtract existing swept in
                      let path = [li; ci] in
                      let new_d = Path_ops.polygon_set_to_path remainder in
                      if new_d = [] then
                        new_doc := Document.delete_element !new_doc path
                      else
                        let new_pe = Element.Path { pe with d = new_d } in
                        new_doc := Document.replace_element !new_doc path new_pe
                    end
                  | _ -> ()
                done
              done;
              ctrl#set_document !new_doc
            end
          end
        | _ -> ())
     | _ -> ());
    `Null
  in

  (* ── Path-editing helpers ─────────────────────────────── *)

  (* Rebuild a Path element with replaced command list, carrying
     over fill/stroke/etc. *)
  let path_with_commands (elem : Element.element) (cmds : Element.path_command list)
    : Element.element =
    match elem with
    | Element.Path pe ->
      Element.Path { pe with d = cmds }
    | _ -> elem
  in

  (* Walk children one level of groups looking for a path with an
     anchor inside [radius] of (x, y). Returns [(element_path, anchor_idx)]. *)
  let anchor_index_near (d : Element.path_command list) x y radius : int option =
    let result = ref None in
    let idx = ref 0 in
    (try
      List.iter (fun cmd ->
        let pt = match cmd with
          | Element.MoveTo (px, py) | Element.LineTo (px, py) -> Some (px, py)
          | Element.CurveTo (_, _, _, _, px, py) -> Some (px, py)
          | _ -> None
        in
        (match pt with
         | Some (px, py) ->
           let dx = x -. px and dy = y -. py in
           if Float.sqrt (dx *. dx +. dy *. dy) <= radius then begin
             result := Some !idx;
             raise Exit
           end
         | None -> ());
        incr idx
      ) d
    with Exit -> ());
    !result
  in

  let find_path_anchor_near doc x y radius : (int list * int) option =
    let result = ref None in
    let layer_count = Array.length doc.Document.layers in
    (try
      for li = 0 to layer_count - 1 do
        let layer = doc.Document.layers.(li) in
        let children = match layer with
          | Element.Layer { children; _ } -> children | _ -> [||]
        in
        let cn = Array.length children in
        for ci = 0 to cn - 1 do
          let child = children.(ci) in
          (match child with
           | Element.Path { d; _ } when not (Element.is_locked child) ->
             (match anchor_index_near d x y radius with
              | Some i -> result := Some ([li; ci], i); raise Exit
              | None -> ())
           | Element.Group { children = gc; _ } when not (Element.is_locked child) ->
             let gn = Array.length gc in
             for gi = 0 to gn - 1 do
               match gc.(gi) with
               | Element.Path { d; _ } when not (Element.is_locked gc.(gi)) ->
                 (match anchor_index_near d x y radius with
                  | Some i -> result := Some ([li; ci; gi], i); raise Exit
                  | None -> ())
               | _ -> ()
             done
           | _ -> ())
        done
      done
    with Exit -> ());
    !result
  in

  let doc_path_delete_anchor_near spec ctx store =
    (match spec with
     | `Assoc args ->
       let lookup k = List.assoc_opt k args in
       let x = eval_number (lookup "x") store ctx in
       let y = eval_number (lookup "y") store ctx in
       let raw_r = eval_number (lookup "hit_radius") store ctx in
       let radius = if raw_r = 0.0 then 8.0 else raw_r in
       (match find_path_anchor_near ctrl#document x y radius with
        | None -> ()
        | Some (path, anchor_idx) ->
          let elem = Document.get_element ctrl#document path in
          (match elem with
           | Element.Path { d; _ } ->
             ctrl#model#snapshot;
             (match Path_ops.delete_anchor_from_path d anchor_idx with
              | Some new_cmds ->
                let new_elem = path_with_commands elem new_cmds in
                let doc = Document.replace_element ctrl#document path new_elem in
                (* Keep path in selection (matches native Delete-anchor). *)
                let sel = Document.PathMap.remove path doc.selection in
                let sel = Document.PathMap.add path
                  (Document.element_selection_all path) sel in
                ctrl#set_document { doc with selection = sel }
              | None ->
                (* Path too small — remove the element entirely. *)
                let doc = Document.delete_element ctrl#document path in
                ctrl#set_document doc)
           | _ -> ()))
     | _ -> ());
    `Null
  in

  (* Re-project (x, y) onto segment [seg_idx] to recover distance. *)
  let projection_distance (d : Element.path_command list) seg_idx x y
    : float =
    let cx = ref 0.0 and cy = ref 0.0 in
    let result = ref Float.infinity in
    let idx = ref 0 in
    (try
      List.iter (fun cmd ->
        let i = !idx in
        (match cmd with
         | Element.MoveTo (mx, my) -> cx := mx; cy := my
         | Element.LineTo (lx, ly) ->
           if i = seg_idx then begin
             let (dist, _) = Path_ops.closest_on_line !cx !cy lx ly x y in
             result := dist;
             raise Exit
           end;
           cx := lx; cy := ly
         | Element.CurveTo (x1, y1, x2, y2, ex, ey) ->
           if i = seg_idx then begin
             let (dist, _) = Path_ops.closest_on_cubic !cx !cy x1 y1 x2 y2
                               ex ey x y in
             result := dist;
             raise Exit
           end;
           cx := ex; cy := ey
         | _ -> ());
        incr idx
      ) d
    with Exit -> ());
    !result
  in

  let doc_path_insert_anchor_on_segment_near spec ctx store =
    (match spec with
     | `Assoc args ->
       let lookup k = List.assoc_opt k args in
       let x = eval_number (lookup "x") store ctx in
       let y = eval_number (lookup "y") store ctx in
       let raw_r = eval_number (lookup "hit_radius") store ctx in
       let radius = if raw_r = 0.0 then 8.0 else raw_r in
       let best = ref None in
       let try_path d path =
         match Path_ops.closest_segment_and_t d x y with
         | None -> ()
         | Some (seg_idx, t) ->
           let dist = projection_distance d seg_idx x y in
           (match !best with
            | Some (_, _, _, best_dist) when best_dist <= dist -> ()
            | _ -> best := Some (path, seg_idx, t, dist))
       in
       let doc = ctrl#document in
       let layer_count = Array.length doc.layers in
       for li = 0 to layer_count - 1 do
         let layer = doc.layers.(li) in
         let children = match layer with
           | Element.Layer { children; _ } -> children | _ -> [||]
         in
         let cn = Array.length children in
         for ci = 0 to cn - 1 do
           let child = children.(ci) in
           (match child with
            | Element.Path { d; _ } when not (Element.is_locked child) ->
              try_path d [li; ci]
            | Element.Group { children = gc; _ } when not (Element.is_locked child) ->
              Array.iteri (fun gi g ->
                match g with
                | Element.Path { d; _ } when not (Element.is_locked g) ->
                  try_path d [li; ci; gi]
                | _ -> ()
              ) gc
            | _ -> ())
         done
       done;
       (match !best with
        | None -> ()
        | Some (_, _, _, dist) when dist > radius -> ()
        | Some (path, seg_idx, t, _) ->
          let elem = Document.get_element doc path in
          (match elem with
           | Element.Path { d; _ } ->
             ctrl#model#snapshot;
             let ins = Path_ops.insert_point_in_path d seg_idx t in
             let new_elem = path_with_commands elem ins.commands in
             ctrl#set_document (Document.replace_element doc path new_elem)
           | _ -> ()))
     | _ -> ());
    `Null
  in

  (* ── Eraser + smoothing ──────────────────────────────── *)

  let doc_path_erase_at_rect spec ctx store =
    (match spec with
     | `Assoc args ->
       let lookup k = List.assoc_opt k args in
       let last_x = eval_number (lookup "last_x") store ctx in
       let last_y = eval_number (lookup "last_y") store ctx in
       let x = eval_number (lookup "x") store ctx in
       let y = eval_number (lookup "y") store ctx in
       let raw = eval_number (lookup "eraser_size") store ctx in
       let eraser_size = if raw = 0.0 then 2.0 else raw in
       let min_x = Float.min last_x x -. eraser_size in
       let min_y = Float.min last_y y -. eraser_size in
       let max_x = Float.max last_x x +. eraser_size in
       let max_y = Float.max last_y y +. eraser_size in
       let doc = ctrl#document in
       let layers = Array.copy doc.Document.layers in
       let changed = ref false in
       Array.iteri (fun li layer ->
         match layer with
         | Element.Layer layer_rec ->
           let new_children = ref [] in
           let layer_changed = ref false in
           Array.iter (fun child ->
             match child with
             | Element.Path { d; _ } when not (Element.is_locked child) ->
               let flat = Element.flatten_path_commands d in
               if List.length flat < 2 then
                 new_children := child :: !new_children
               else begin
                 match Path_ops.find_eraser_hit flat min_x min_y max_x max_y with
                 | None -> new_children := child :: !new_children
                 | Some hit ->
                   let (_bx, _by, bw, bh) = Element.bounds child in
                   if bw <= eraser_size *. 2.0 && bh <= eraser_size *. 2.0 then
                     layer_changed := true  (* drop entirely *)
                   else begin
                     let is_closed = List.exists (fun c ->
                       c = Element.ClosePath) d in
                     let results = Path_ops.split_path_at_eraser d hit is_closed in
                     List.iter (fun cmds ->
                       if List.length cmds >= 2 then begin
                         let open_cmds = List.filter (fun c ->
                           c <> Element.ClosePath) cmds in
                         let new_elem = path_with_commands child open_cmds in
                         new_children := new_elem :: !new_children
                       end
                     ) results;
                     layer_changed := true
                   end
               end
             | _ -> new_children := child :: !new_children
           ) layer_rec.children;
           if !layer_changed then begin
             changed := true;
             layers.(li) <- Element.Layer {
               layer_rec with children = Array.of_list (List.rev !new_children)
             }
           end
         | _ -> ()
       ) doc.layers;
       if !changed then
         ctrl#set_document {
           doc with layers; selection = Document.PathMap.empty
         }
     | _ -> ());
    `Null
  in

  let doc_path_smooth_at_cursor spec ctx store =
    (match spec with
     | `Assoc args ->
       let lookup k = List.assoc_opt k args in
       let x = eval_number (lookup "x") store ctx in
       let y = eval_number (lookup "y") store ctx in
       let raw_r = eval_number (lookup "radius") store ctx in
       let radius = if raw_r = 0.0 then 100.0 else raw_r in
       let raw_e = eval_number (lookup "fit_error") store ctx in
       let fit_error = if raw_e = 0.0 then 8.0 else raw_e in
       let radius_sq = radius *. radius in
       let doc = ref ctrl#document in
       let changed = ref false in
       Document.PathMap.iter (fun path _ ->
         let elem = Document.get_element !doc path in
         match elem with
         | Element.Path { d; _ } when not (Element.is_locked elem)
                                    && List.length d >= 2 ->
           let (flat, cmd_map) = Path_ops.flatten_with_cmd_map d in
           if List.length flat >= 2 then begin
             let first_hit = ref None in
             let last_hit = ref None in
             List.iteri (fun i (px, py) ->
               let dx = px -. x and dy = py -. y in
               if dx *. dx +. dy *. dy <= radius_sq then begin
                 if !first_hit = None then first_hit := Some i;
                 last_hit := Some i
               end
             ) flat;
             match !first_hit, !last_hit with
             | Some fh, Some lh ->
               let first_cmd = List.nth cmd_map fh in
               let last_cmd = List.nth cmd_map lh in
               if first_cmd < last_cmd then begin
                 let range_flat =
                   List.mapi (fun i p -> (i, p)) flat
                   |> List.filter (fun (i, _) ->
                     let ci = List.nth cmd_map i in
                     ci >= first_cmd && ci <= last_cmd)
                   |> List.map snd
                 in
                 let start_pt = Path_ops.cmd_start_point d first_cmd in
                 let points_to_fit = start_pt :: range_flat in
                 if List.length points_to_fit >= 2 then begin
                   let segments = Fit_curve.fit_curve points_to_fit fit_error in
                   if segments <> [] then begin
                     let prefix = List.filteri (fun i _ -> i < first_cmd) d in
                     let suffix = List.filteri (fun i _ -> i > last_cmd) d in
                     let new_curves = List.map (fun (seg : Fit_curve.segment) ->
                       Element.CurveTo (seg.c1x, seg.c1y,
                                        seg.c2x, seg.c2y,
                                        seg.p2x, seg.p2y)
                     ) segments in
                     let new_cmds = prefix @ new_curves @ suffix in
                     if List.length new_cmds < List.length d then begin
                       let new_elem = path_with_commands elem new_cmds in
                       doc := Document.replace_element !doc path new_elem;
                       changed := true
                     end
                   end
                 end
               end
             | _ -> ()
           end
         | _ -> ()
       ) !doc.Document.selection;
       if !changed then ctrl#set_document !doc
     | _ -> ());
    `Null
  in

  (* ── Magic Wand effect ─────────────────────────────────────
     See MAGIC_WAND_TOOL.md §Predicate + §Eligibility filter. *)

  let read_magic_wand_config store ctx : Magic_wand.config =
    let bool_at key fallback =
      match eval_expr_as_value (Some (`String ("state." ^ key))) store ctx with
      | Expr_eval.Bool b -> b
      | _ -> fallback
    in
    let num_at key fallback =
      match eval_expr_as_value (Some (`String ("state." ^ key))) store ctx with
      | Expr_eval.Number n -> n
      | _ -> fallback
    in
    let d = Magic_wand.default_config in
    {
      Magic_wand.fill_color = bool_at "magic_wand_fill_color" d.fill_color;
      fill_tolerance = num_at "magic_wand_fill_tolerance" d.fill_tolerance;
      stroke_color = bool_at "magic_wand_stroke_color" d.stroke_color;
      stroke_tolerance = num_at "magic_wand_stroke_tolerance" d.stroke_tolerance;
      stroke_weight = bool_at "magic_wand_stroke_weight" d.stroke_weight;
      stroke_weight_tolerance =
        num_at "magic_wand_stroke_weight_tolerance" d.stroke_weight_tolerance;
      opacity = bool_at "magic_wand_opacity" d.opacity;
      opacity_tolerance =
        num_at "magic_wand_opacity_tolerance" d.opacity_tolerance;
      blending_mode = bool_at "magic_wand_blending_mode" d.blending_mode;
    }
  in

  (* Walk the document and invoke [visit path elem] for every leaf
     element that passes the §Eligibility filter — locked / hidden
     elements are skipped, and Group / Layer containers descend into
     their children rather than acting as candidates themselves. *)
  let rec walk_eligible_in (elem : Element.element)
      (cur_path : int list)
      (visit : int list -> Element.element -> unit) : unit =
    if Element.is_locked elem then ()
    else if Element.get_visibility elem = Element.Invisible then ()
    else
      match elem with
      | Element.Group { children; _ } ->
        Array.iteri (fun i child ->
          walk_eligible_in child (cur_path @ [i]) visit
        ) children
      | Element.Layer { children; _ } ->
        Array.iteri (fun i child ->
          walk_eligible_in child (cur_path @ [i]) visit
        ) children
      | _ -> visit cur_path elem
  in

  let walk_eligible (doc : Document.document)
      (visit : int list -> Element.element -> unit) : unit =
    Array.iteri (fun li layer ->
      walk_eligible_in layer [li] visit
    ) doc.layers
  in

  let doc_magic_wand_apply spec ctx store =
    (match spec with
     | `Assoc args ->
       let lookup k = List.assoc_opt k args in
       (match extract_path (Option.value (lookup "seed") ~default:`Null)
                store ctx with
        | None -> ()
        | Some seed_path ->
          let mode_raw =
            match eval_expr_as_value (lookup "mode") store ctx with
            | Expr_eval.Str s -> s
            | _ -> ""
          in
          let mode = if mode_raw = "" then "replace" else mode_raw in
          let doc = ctrl#document in
          if not (is_valid_path doc seed_path) then ()
          else begin
            let seed_elem = Document.get_element doc seed_path in
            let cfg = read_magic_wand_config store ctx in
            let matches = ref [] in
            walk_eligible doc (fun path candidate ->
              if path = seed_path then
                matches := path :: !matches
              else if Magic_wand.magic_wand_match seed_elem candidate cfg then
                matches := path :: !matches
            );
            let matched = List.rev !matches in
            let new_set =
              List.fold_left (fun acc path ->
                Document.PathMap.add path
                  (Document.element_selection_all path) acc
              ) Document.PathMap.empty matched
            in
            (match mode with
             | "add" ->
               let merged = Document.PathMap.union
                 (fun _ a _ -> Some a) doc.selection new_set in
               ctrl#set_selection merged
             | "subtract" ->
               let kept = Document.PathMap.filter (fun path _ ->
                 not (Document.PathMap.mem path new_set)
               ) doc.selection in
               ctrl#set_selection kept
             | _ ->
               (* replace (default) *)
               ctrl#set_selection new_set)
          end)
     | _ -> ());
    `Null
  in

  (* ── Transform tools (Scale / Rotate / Shear) ─────────── *)

  (* Resolve the active reference point. Reads
     state.transform_reference_point as a Value.List of two numbers
     when set, else falls back to the union bounding-box center of
     the current selection. *)
  let resolve_reference_point store ctx : float * float =
    let eval_ctx = State_store.eval_context ~extra:ctx store in
    (match Expr_eval.evaluate "state.transform_reference_point" eval_ctx with
     | Expr_eval.List items when List.length items >= 2 ->
       let to_f = function
         | `Int i -> Some (float_of_int i)
         | `Float f -> Some f | _ -> None
       in
       (match to_f (List.nth items 0), to_f (List.nth items 1) with
        | Some rx, Some ry -> Some (rx, ry)
        | _ -> None)
     | _ -> None)
    |> function
    | Some pt -> pt
    | None ->
      let doc = ctrl#document in
      let elements = Document.PathMap.bindings doc.selection
                     |> List.filter_map (fun (path, _) ->
                       if is_valid_path doc path
                       then Some (Document.get_element doc path)
                       else None)
      in
      if elements = [] then (0.0, 0.0)
      else
        let (x, y, w, h) =
          Align.union_bounds elements Align.geometric_bounds in
        (x +. w /. 2.0, y +. h /. 2.0)
  in

  let drag_to_scale_factors ~px ~py ~cx ~cy ~rx ~ry ~shift =
    let denom_x = px -. rx and denom_y = py -. ry in
    let sx = if abs_float denom_x < 1e-9 then 1.0 else (cx -. rx) /. denom_x in
    let sy = if abs_float denom_y < 1e-9 then 1.0 else (cy -. ry) /. denom_y in
    if shift then
      let prod = sx *. sy in
      let sign = if prod >= 0.0 then 1.0 else -. 1.0 in
      let s = sign *. sqrt (abs_float prod) in
      (s, s)
    else (sx, sy)
  in

  let drag_to_rotate_angle ~px ~py ~cx ~cy ~rx ~ry ~shift =
    let theta_press = atan2 (py -. ry) (px -. rx) in
    let theta_cursor = atan2 (cy -. ry) (cx -. rx) in
    let theta_deg = (theta_cursor -. theta_press) *. 180.0 /. Float.pi in
    if shift then
      Float.round (theta_deg /. 45.0) *. 45.0
    else theta_deg
  in

  let drag_to_shear_params ~px ~py ~cx ~cy ~rx ~ry ~shift =
    let dx = cx -. px and dy = cy -. py in
    if shift then begin
      if abs_float dx >= abs_float dy then
        let denom = max (abs_float (py -. ry)) 1e-9 in
        let k = dx /. denom in
        (atan k *. 180.0 /. Float.pi, "horizontal", 0.0)
      else
        let denom = max (abs_float (px -. rx)) 1e-9 in
        let k = dy /. denom in
        (atan k *. 180.0 /. Float.pi, "vertical", 0.0)
    end else begin
      let ax = px -. rx and ay = py -. ry in
      let axis_len = max (sqrt (ax *. ax +. ay *. ay)) 1e-9 in
      let perp_x = -. ay /. axis_len and perp_y = ax /. axis_len in
      let perp_dist = (cx -. px) *. perp_x +. (cy -. py) *. perp_y in
      let k = perp_dist /. axis_len in
      let axis_angle_deg = atan2 ay ax *. 180.0 /. Float.pi in
      (atan k *. 180.0 /. Float.pi, "custom", axis_angle_deg)
    end
  in

  (* Apply [matrix] to every element selected, pre-multiplied onto
     the existing transform. Optionally multiplies stroke widths
     (when [scale_strokes] is set with the geometric-mean factor)
     and rounded_rect corner radii (when [scale_corners] is set
     with axis-independent abs-factors). *)
  let apply_matrix_to_selection
      ?(scale_strokes : float option = None)
      ?(scale_corners : (float * float) option = None)
      (matrix : Element.transform) =
    let scale_stroke_width (factor : float) elem =
      match elem with
      | Element.Line r ->
        (match r.stroke with
         | Some s -> Element.with_stroke elem
                       (Some { s with stroke_width = s.stroke_width *. factor })
         | None -> elem)
      | Element.Rect r ->
        (match r.stroke with
         | Some s -> Element.with_stroke elem
                       (Some { s with stroke_width = s.stroke_width *. factor })
         | None -> elem)
      | Element.Circle r ->
        (match r.stroke with
         | Some s -> Element.with_stroke elem
                       (Some { s with stroke_width = s.stroke_width *. factor })
         | None -> elem)
      | Element.Ellipse r ->
        (match r.stroke with
         | Some s -> Element.with_stroke elem
                       (Some { s with stroke_width = s.stroke_width *. factor })
         | None -> elem)
      | Element.Polyline r ->
        (match r.stroke with
         | Some s -> Element.with_stroke elem
                       (Some { s with stroke_width = s.stroke_width *. factor })
         | None -> elem)
      | Element.Polygon r ->
        (match r.stroke with
         | Some s -> Element.with_stroke elem
                       (Some { s with stroke_width = s.stroke_width *. factor })
         | None -> elem)
      | Element.Path r ->
        (match r.stroke with
         | Some s -> Element.with_stroke elem
                       (Some { s with stroke_width = s.stroke_width *. factor })
         | None -> elem)
      | _ -> elem
    in
    let scale_rr_corners (sx_abs, sy_abs) elem =
      match elem with
      | Element.Rect r ->
        Element.Rect { r with rx = r.rx *. sx_abs; ry = r.ry *. sy_abs }
      | _ -> elem
    in
    let doc = ctrl#document in
    let new_doc = ref doc in
    Document.PathMap.iter (fun path _ ->
      if is_valid_path !new_doc path then begin
        let elem = Document.get_element !new_doc path in
        let elem = Element.with_transform_premultiplied matrix elem in
        let elem = match scale_strokes with
          | Some factor -> scale_stroke_width factor elem
          | None -> elem
        in
        let elem = match scale_corners with
          | Some sxy -> scale_rr_corners sxy elem
          | None -> elem
        in
        new_doc := Document.replace_element !new_doc path elem
      end
    ) doc.selection;
    ctrl#set_document !new_doc
  in

  let scale_apply_args store ctx args copy : unit =
    let lookup k = List.assoc_opt k args in
    let (sx, sy) =
      if List.mem_assoc "sx" args then
        (eval_number (lookup "sx") store ctx,
         eval_number (lookup "sy") store ctx)
      else
        let (rx, ry) = resolve_reference_point store ctx in
        let px = eval_number (lookup "press_x") store ctx in
        let py = eval_number (lookup "press_y") store ctx in
        let cx = eval_number (lookup "cursor_x") store ctx in
        let cy = eval_number (lookup "cursor_y") store ctx in
        let shift = eval_bool (lookup "shift") store ctx in
        drag_to_scale_factors ~px ~py ~cx ~cy ~rx ~ry ~shift
    in
    if abs_float (sx -. 1.0) < 1e-9 && abs_float (sy -. 1.0) < 1e-9 then ()
    else begin
      if copy then ctrl#copy_selection 0.0 0.0;
      let (rx, ry) = resolve_reference_point store ctx in
      let matrix = Transform_apply.scale_matrix ~sx ~sy ~rx ~ry in
      let strokes_on =
        match Expr_eval.evaluate "state.scale_strokes"
                (State_store.eval_context ~extra:ctx store) with
        | Expr_eval.Bool b -> b
        | _ -> true
      in
      let corners_on =
        match Expr_eval.evaluate "state.scale_corners"
                (State_store.eval_context ~extra:ctx store) with
        | Expr_eval.Bool b -> b
        | _ -> false
      in
      let stroke_factor =
        if strokes_on then
          Some (Transform_apply.stroke_width_factor ~sx ~sy)
        else None
      in
      let corner_factors =
        if corners_on then Some (abs_float sx, abs_float sy) else None
      in
      apply_matrix_to_selection
        ~scale_strokes:stroke_factor
        ~scale_corners:corner_factors
        matrix
    end
  in

  let rotate_apply_args store ctx args copy : unit =
    let lookup k = List.assoc_opt k args in
    let theta_deg =
      if List.mem_assoc "angle" args then
        eval_number (lookup "angle") store ctx
      else
        let (rx, ry) = resolve_reference_point store ctx in
        let px = eval_number (lookup "press_x") store ctx in
        let py = eval_number (lookup "press_y") store ctx in
        let cx = eval_number (lookup "cursor_x") store ctx in
        let cy = eval_number (lookup "cursor_y") store ctx in
        let shift = eval_bool (lookup "shift") store ctx in
        drag_to_rotate_angle ~px ~py ~cx ~cy ~rx ~ry ~shift
    in
    if abs_float theta_deg < 1e-9 then ()
    else begin
      if copy then ctrl#copy_selection 0.0 0.0;
      let (rx, ry) = resolve_reference_point store ctx in
      apply_matrix_to_selection
        (Transform_apply.rotate_matrix ~theta_deg ~rx ~ry)
    end
  in

  let shear_apply_args store ctx args copy : unit =
    let lookup k = List.assoc_opt k args in
    let (angle_deg, axis, axis_angle_deg) =
      if List.mem_assoc "angle" args && List.mem_assoc "axis" args then
        let a = eval_number (lookup "angle") store ctx in
        let ax = eval_string_value (lookup "axis") store ctx in
        let aa = eval_number (lookup "axis_angle") store ctx in
        (a, ax, aa)
      else
        let (rx, ry) = resolve_reference_point store ctx in
        let px = eval_number (lookup "press_x") store ctx in
        let py = eval_number (lookup "press_y") store ctx in
        let cx = eval_number (lookup "cursor_x") store ctx in
        let cy = eval_number (lookup "cursor_y") store ctx in
        let shift = eval_bool (lookup "shift") store ctx in
        drag_to_shear_params ~px ~py ~cx ~cy ~rx ~ry ~shift
    in
    if abs_float angle_deg < 1e-9 then ()
    else begin
      if copy then ctrl#copy_selection 0.0 0.0;
      let (rx, ry) = resolve_reference_point store ctx in
      apply_matrix_to_selection
        (Transform_apply.shear_matrix
           ~angle_deg ~axis ~axis_angle_deg ~rx ~ry)
    end
  in

  let doc_scale_apply spec ctx store =
    (match spec with
     | `Assoc args ->
       let copy = eval_bool (List.assoc_opt "copy" args) store ctx in
       scale_apply_args store ctx args copy
     | _ -> ());
    `Null
  in
  let doc_rotate_apply spec ctx store =
    (match spec with
     | `Assoc args ->
       let copy = eval_bool (List.assoc_opt "copy" args) store ctx in
       rotate_apply_args store ctx args copy
     | _ -> ());
    `Null
  in
  let doc_shear_apply spec ctx store =
    (match spec with
     | `Assoc args ->
       let copy = eval_bool (List.assoc_opt "copy" args) store ctx in
       shear_apply_args store ctx args copy
     | _ -> ());
    `Null
  in

  let doc_preview_capture _ _ _ =
    ctrl#model#capture_preview_snapshot;
    `Null
  in
  let doc_preview_restore _ _ _ =
    ctrl#model#restore_preview_snapshot;
    `Null
  in
  let doc_preview_clear _ _ _ =
    ctrl#model#clear_preview_snapshot;
    `Null
  in

  (* ── Probe / commit anchor + partial selection ─────────── *)

  let encode_path (path : int list) : Yojson.Safe.t =
    `Assoc [("__path__", `List (List.map (fun i -> `Int i) path))]
  in

  let decode_path (v : Yojson.Safe.t) : int list option =
    match v with
    | `Assoc pairs ->
      (match List.assoc_opt "__path__" pairs with
       | Some (`List arr) ->
         let out = List.filter_map (function
           | `Int i -> Some i | _ -> None) arr in
         if List.length out = List.length arr then Some out else None
       | _ -> None)
    | _ -> None
  in

  let find_path_handle_near doc x y radius
    : (int list * int * string) option =
    let result = ref None in
    let check (d : Element.path_command list) path =
      (* Iterate anchors (0..n-1) and query handle positions. *)
      let rec walk ai =
        match Path_ops.cmd_start_point d 0 with
        | _ ->
          let (h_in, h_out) = Element.path_handle_positions d ai in
          (match h_in with
           | Some (hx, hy) ->
             let dx = x -. hx and dy = y -. hy in
             if Float.sqrt (dx *. dx +. dy *. dy) < radius then begin
               result := Some (path, ai, "in");
               raise Exit
             end
           | None -> ());
          (match h_out with
           | Some (hx, hy) ->
             let dx = x -. hx and dy = y -. hy in
             if Float.sqrt (dx *. dx +. dy *. dy) < radius then begin
               result := Some (path, ai, "out");
               raise Exit
             end
           | None -> ());
          let elem = Element.make_path d in
          let total = Element.control_point_count elem in
          if ai + 1 < total then walk (ai + 1)
      in
      try walk 0 with Exit -> ()
    in
    let layer_count = Array.length doc.Document.layers in
    (try
      for li = 0 to layer_count - 1 do
        let children = match doc.layers.(li) with
          | Element.Layer { children; _ } -> children | _ -> [||]
        in
        let cn = Array.length children in
        for ci = 0 to cn - 1 do
          match children.(ci) with
          | Element.Path { d; _ } when not (Element.is_locked children.(ci)) ->
            check d [li; ci];
            (match !result with Some _ -> raise Exit | None -> ())
          | Element.Group { children = gc; _ }
            when not (Element.is_locked children.(ci)) ->
            Array.iteri (fun gi g ->
              match g with
              | Element.Path { d; _ } when not (Element.is_locked g) ->
                check d [li; ci; gi];
                (match !result with Some _ -> raise Exit | None -> ())
              | _ -> ()
            ) gc
          | _ -> ()
        done
      done
    with Exit -> ());
    !result
  in

  let find_path_anchor_by_cp doc x y radius : (int list * int) option =
    let result = ref None in
    let check elem path =
      let cps = Element.control_points elem in
      List.iteri (fun i (px, py) ->
        match !result with
        | Some _ -> ()
        | None ->
          let dx = x -. px and dy = y -. py in
          if Float.sqrt (dx *. dx +. dy *. dy) < radius then
            result := Some (path, i)
      ) cps
    in
    let layer_count = Array.length doc.Document.layers in
    (try
      for li = 0 to layer_count - 1 do
        let children = match doc.layers.(li) with
          | Element.Layer { children; _ } -> children | _ -> [||]
        in
        let cn = Array.length children in
        for ci = 0 to cn - 1 do
          let child = children.(ci) in
          (match child with
           | Element.Path _ when not (Element.is_locked child) ->
             check child [li; ci];
             (match !result with Some _ -> raise Exit | None -> ())
           | Element.Group { children = gc; _ }
             when not (Element.is_locked child) ->
             Array.iteri (fun gi g ->
               match g with
               | Element.Path _ when not (Element.is_locked g) ->
                 check g [li; ci; gi];
                 (match !result with Some _ -> raise Exit | None -> ())
               | _ -> ()
             ) gc
           | _ -> ())
        done
      done
    with Exit -> ());
    !result
  in

  let doc_path_probe_anchor_hit spec ctx store =
    (match spec with
     | `Assoc args ->
       let lookup k = List.assoc_opt k args in
       let x = eval_number (lookup "x") store ctx in
       let y = eval_number (lookup "y") store ctx in
       let raw_r = eval_number (lookup "hit_radius") store ctx in
       let radius = if raw_r = 0.0 then 8.0 else raw_r in
       let doc = ctrl#document in
       (match find_path_handle_near doc x y radius with
        | Some (path, ai, handle_type) ->
          State_store.set_tool store "anchor_point" "mode"
            (`String "pressed_handle");
          State_store.set_tool store "anchor_point" "handle_type"
            (`String handle_type);
          State_store.set_tool store "anchor_point" "hit_anchor_idx"
            (`Int ai);
          State_store.set_tool store "anchor_point" "hit_path"
            (encode_path path)
        | None ->
          (match find_path_anchor_by_cp doc x y radius with
           | Some (path, ai) ->
             let elem = Document.get_element doc path in
             let mode = match elem with
               | Element.Path { d; _ } when Element.is_smooth_point d ai ->
                 "pressed_smooth"
               | _ -> "pressed_corner"
             in
             State_store.set_tool store "anchor_point" "mode"
               (`String mode);
             State_store.set_tool store "anchor_point" "hit_anchor_idx"
               (`Int ai);
             State_store.set_tool store "anchor_point" "hit_path"
               (encode_path path)
           | None ->
             State_store.set_tool store "anchor_point" "mode"
               (`String "idle")))
     | _ -> ());
    `Null
  in

  let doc_path_commit_anchor_edit spec ctx store =
    (match spec with
     | `Assoc args ->
       let lookup k = List.assoc_opt k args in
       let tx = eval_number (lookup "target_x") store ctx in
       let ty = eval_number (lookup "target_y") store ctx in
       let ox = eval_number (lookup "origin_x") store ctx in
       let oy = eval_number (lookup "origin_y") store ctx in
       let mode = match State_store.get_tool store "anchor_point" "mode" with
         | `String s -> s | _ -> "idle"
       in
       if mode <> "idle" then begin
         match decode_path (State_store.get_tool store "anchor_point" "hit_path") with
         | None -> ()
         | Some path ->
           let ai = match State_store.get_tool store "anchor_point" "hit_anchor_idx" with
             | `Int i -> i | _ -> 0
           in
           let elem = Document.get_element ctrl#document path in
           (match elem with
            | Element.Path { d; _ } ->
              let apply new_cmds =
                let new_elem = path_with_commands elem new_cmds in
                ctrl#set_document
                  (Document.replace_element ctrl#document path new_elem)
              in
              (match mode with
               | "pressed_smooth" ->
                 ctrl#model#snapshot;
                 apply (Element.convert_smooth_to_corner d ai)
               | "pressed_corner" ->
                 let moved = Float.hypot (tx -. ox) (ty -. oy) in
                 if moved > 1.0 then begin
                   ctrl#model#snapshot;
                   apply (Element.convert_corner_to_smooth d ai tx ty)
                 end
               | "pressed_handle" ->
                 let handle_type = match
                   State_store.get_tool store "anchor_point" "handle_type"
                 with `String s -> s | _ -> "" in
                 let dx = tx -. ox and dy = ty -. oy in
                 if Float.abs dx > 0.5 || Float.abs dy > 0.5 then begin
                   ctrl#model#snapshot;
                   apply (Element.move_path_handle_independent
                            d ai handle_type dx dy)
                 end
               | _ -> ())
            | _ -> ())
       end
     | _ -> ());
    `Null
  in

  let doc_move_path_handle spec ctx store =
    (match spec with
     | `Assoc args ->
       let lookup k = List.assoc_opt k args in
       let dx = eval_number (lookup "dx") store ctx in
       let dy = eval_number (lookup "dy") store ctx in
       (match decode_path
                (State_store.get_tool store "partial_selection" "handle_path")
        with
        | None -> ()
        | Some path ->
          let ai = match State_store.get_tool store "partial_selection"
                           "handle_anchor_idx" with
            | `Int i -> i | _ -> 0 in
          let ht = match State_store.get_tool store "partial_selection"
                           "handle_type" with
            | `String s -> s | _ -> "" in
          ctrl#move_path_handle path ai ht dx dy)
     | _ -> ());
    `Null
  in

  (* Partial-selection probe — handle on selected path, else CP
     hit anywhere, else marquee. *)
  let doc_path_probe_partial_hit spec ctx store =
    (match spec with
     | `Assoc args ->
       let lookup k = List.assoc_opt k args in
       let x = eval_number (lookup "x") store ctx in
       let y = eval_number (lookup "y") store ctx in
       let raw_r = eval_number (lookup "hit_radius") store ctx in
       let radius = if raw_r = 0.0 then 8.0 else raw_r in
       let shift = eval_bool (lookup "shift") store ctx in

       (* 1. Handle hit on a selected Path. *)
       let doc = ctrl#document in
       let handle_hit = ref None in
       (try
         Document.PathMap.iter (fun path _ ->
           let elem = Document.get_element doc path in
           match elem with
           | Element.Path { d; _ } ->
             let total = Element.control_point_count elem in
             for ai = 0 to total - 1 do
               let (h_in, h_out) = Element.path_handle_positions d ai in
               (match h_in with
                | Some (hx, hy) ->
                  if Float.hypot (x -. hx) (y -. hy) < radius then begin
                    handle_hit := Some (path, ai, "in");
                    raise Exit
                  end
                | None -> ());
               (match h_out with
                | Some (hx, hy) ->
                  if Float.hypot (x -. hx) (y -. hy) < radius then begin
                    handle_hit := Some (path, ai, "out");
                    raise Exit
                  end
                | None -> ())
             done
           | _ -> ()
         ) doc.selection
       with Exit -> ());

       (match !handle_hit with
        | Some (path, ai, ht) ->
          State_store.set_tool store "partial_selection" "mode"
            (`String "handle");
          State_store.set_tool store "partial_selection" "handle_anchor_idx"
            (`Int ai);
          State_store.set_tool store "partial_selection" "handle_type"
            (`String ht);
          State_store.set_tool store "partial_selection" "handle_path"
            (encode_path path)
        | None ->
          (* 2. CP hit on any unlocked element (recurse into groups). *)
          let cp_hit = ref None in
          let rec recurse elem path =
            if Element.is_locked elem then ()
            else
              match elem with
              | Element.Group { children; _ }
              | Element.Layer { children; _ } ->
                let n = Array.length children in
                for i = n - 1 downto 0 do
                  if !cp_hit = None then
                    recurse children.(i) (path @ [i])
                done
              | _ ->
                let cps = Element.control_points elem in
                List.iteri (fun i (px, py) ->
                  match !cp_hit with
                  | Some _ -> ()
                  | None ->
                    if Float.hypot (x -. px) (y -. py) < radius then
                      cp_hit := Some (path, i)
                ) cps
          in
          let layer_count = Array.length doc.layers in
          for li = layer_count - 1 downto 0 do
            if !cp_hit = None then
              recurse doc.layers.(li) [li]
          done;
          (match !cp_hit with
           | Some (path, cp_idx) ->
             let already_selected =
               match Document.PathMap.find_opt path doc.selection with
               | Some es -> Document.selection_kind_contains es.es_kind cp_idx
               | None -> false
             in
             if not already_selected || shift then begin
               ctrl#model#snapshot;
               if shift then begin
                 let sel = doc.selection in
                 match Document.PathMap.find_opt path sel with
                 | Some es ->
                   let elem = Document.get_element doc path in
                   let total = Element.control_point_count elem in
                   let cps =
                     Document.selection_kind_to_sorted es.es_kind ~total in
                   let new_cps =
                     if List.mem cp_idx cps
                     then List.filter (fun i -> i <> cp_idx) cps
                     else cp_idx :: cps
                   in
                   let new_es =
                     Document.element_selection_partial path new_cps in
                   let new_sel = Document.PathMap.add path new_es sel in
                   ctrl#set_selection new_sel
                 | None ->
                   let new_es =
                     Document.element_selection_partial path [cp_idx] in
                   let new_sel = Document.PathMap.add path new_es doc.selection in
                   ctrl#set_selection new_sel
               end
               else
                 ctrl#select_control_point path cp_idx
             end;
             State_store.set_tool store "partial_selection" "mode"
               (`String "moving_pending")
           | None ->
             (* 3. No hit — marquee. *)
             State_store.set_tool store "partial_selection" "mode"
               (`String "marquee")))
     | _ -> ());
    `Null
  in

  let doc_path_commit_partial_marquee spec ctx store =
    (match spec with
     | `Assoc args ->
       let (rx, ry, rw, rh, additive) = normalize_rect_args args store ctx in
       if rw > 1.0 || rh > 1.0 then begin
         ctrl#model#snapshot;
         ctrl#partial_select_rect ~extend:additive rx ry rw rh
       end
       else if not additive then
         ctrl#set_selection Document.PathMap.empty
     | _ -> ());
    `Null
  in

  let doc_add_path_from_anchor_buffer spec ctx store =
    (match spec with
     | `Assoc args ->
       (match List.assoc_opt "buffer" args with
        | Some (`String name) ->
          let closed = eval_bool (List.assoc_opt "closed" args) store ctx in
          let anchors = Anchor_buffers.anchors name in
          if List.length anchors >= 2 then begin
            let first = List.hd anchors in
            let cmds = ref [Element.MoveTo (first.x, first.y)] in
            let prev = ref first in
            List.iteri (fun i (a : Anchor_buffers.anchor) ->
              if i > 0 then begin
                cmds := Element.CurveTo (!prev.hx_out, !prev.hy_out,
                                         a.hx_in, a.hy_in,
                                         a.x, a.y) :: !cmds;
                prev := a
              end
            ) anchors;
            if closed then begin
              let last = List.nth anchors (List.length anchors - 1) in
              cmds := Element.CurveTo (last.hx_out, last.hy_out,
                                       first.hx_in, first.hy_in,
                                       first.x, first.y) :: !cmds;
              cmds := Element.ClosePath :: !cmds
            end;
            let d = List.rev !cmds in
            let elem = make_path_from_commands d args store ctx in
            ctrl#add_element elem
          end
        | _ -> ())
     | _ -> ());
    `Null
  in

  [ ("doc.snapshot", doc_snapshot);
    ("doc.clear_selection", doc_clear_selection);
    ("doc.set_selection", doc_set_selection);
    ("doc.add_to_selection", doc_add_to_selection);
    ("doc.toggle_selection", doc_toggle_selection);
    ("doc.translate_selection", doc_translate_selection);
    ("doc.set_attr_on_selection", doc_set_attr_on_selection);
    ("data.set", data_set);
    ("data.list_append", data_list_append);
    ("data.list_remove", data_list_remove);
    ("data.list_insert", data_list_insert);
    ("brush.delete_selected", brush_delete_selected);
    ("brush.duplicate_selected", brush_duplicate_selected);
    ("brush.append", brush_append_effect);
    ("brush.update", brush_update_effect);
    ("brush.options_confirm", brush_options_confirm);
    ("doc.copy_selection", doc_copy_selection);
    ("doc.select_in_rect", doc_select_in_rect);
    ("doc.partial_select_in_rect", doc_partial_select_in_rect);
    (* Phase 3 buffer effects *)
    ("buffer.push", buffer_push);
    ("buffer.clear", buffer_clear);
    ("anchor.push", anchor_push);
    ("anchor.set_last_out", anchor_set_last_out);
    ("anchor.pop", anchor_pop);
    ("anchor.clear", anchor_clear);
    ("doc.select_polygon_from_buffer", doc_select_polygon_from_buffer);
    (* Phase 4b: element + path-editing effects *)
    ("doc.add_element", doc_add_element);
    ("doc.add_path_from_buffer", doc_add_path_from_buffer);
    ("doc.add_path_from_anchor_buffer", doc_add_path_from_anchor_buffer);
    ("doc.path.delete_anchor_near", doc_path_delete_anchor_near);
    ("doc.path.insert_anchor_on_segment_near",
     doc_path_insert_anchor_on_segment_near);
    ("doc.path.erase_at_rect", doc_path_erase_at_rect);
    ("doc.path.smooth_at_cursor", doc_path_smooth_at_cursor);
    ("doc.magic_wand.apply", doc_magic_wand_apply);
    (* Transform tools — Scale / Rotate / Shear apply + preview snapshot.
       See SCALE_TOOL.md / ROTATE_TOOL.md / SHEAR_TOOL.md \167 Apply behavior. *)
    ("doc.scale.apply", doc_scale_apply);
    ("doc.rotate.apply", doc_rotate_apply);
    ("doc.shear.apply", doc_shear_apply);
    ("doc.preview.capture", doc_preview_capture);
    ("doc.preview.restore", doc_preview_restore);
    ("doc.preview.clear", doc_preview_clear);
    ("doc.paintbrush.edit_start", doc_paintbrush_edit_start);
    ("doc.paintbrush.edit_commit", doc_paintbrush_edit_commit);
    ("doc.blob_brush.commit_painting", doc_blob_brush_commit_painting);
    ("doc.blob_brush.commit_erasing", doc_blob_brush_commit_erasing);
    ("doc.path.probe_anchor_hit", doc_path_probe_anchor_hit);
    ("doc.path.commit_anchor_edit", doc_path_commit_anchor_edit);
    ("doc.move_path_handle", doc_move_path_handle);
    ("doc.path.probe_partial_hit", doc_path_probe_partial_hit);
    ("doc.path.commit_partial_marquee", doc_path_commit_partial_marquee);
  ]
