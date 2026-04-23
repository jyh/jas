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

  (* Build a Path element from commands, applying model defaults. *)
  let make_path_from_commands cmds spec_args store ctx : Element.element =
    let has_fill = List.mem_assoc "fill" spec_args in
    let has_stroke = List.mem_assoc "stroke" spec_args in
    let default_fill = ctrl#model#default_fill in
    let default_stroke = ctrl#model#default_stroke in
    let fill = resolve_fill_field (List.assoc_opt "fill" spec_args) has_fill
                 store ctx default_fill in
    let stroke = resolve_stroke_field (List.assoc_opt "stroke" spec_args)
                   has_stroke store ctx default_stroke in
    Element.make_path ~fill ~stroke cmds
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
              let d = List.rev !cmds in
              let elem = make_path_from_commands d args store ctx in
              ctrl#add_element elem
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
  ]
