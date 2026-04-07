(** Delete Anchor Point tool.

    Clicking on an anchor point removes it from the path, merging the
    adjacent segments into a single curve that preserves the outer
    control handles. *)

let hit_radius = Canvas_tool.hit_radius

(** Get the anchor (endpoint) position for a path command. *)
let cmd_anchor = function
  | Element.MoveTo (x, y) | Element.LineTo (x, y) -> Some (x, y)
  | Element.CurveTo (_, _, _, _, x, y) -> Some (x, y)
  | _ -> None

(** Find the command index of an anchor point near (px, py) in a path. *)
let find_anchor_at d px py threshold =
  let result = ref None in
  List.iteri (fun i cmd ->
    if !result = None then
      match cmd_anchor cmd with
      | Some (ax, ay) ->
        let dist = sqrt ((px -. ax) *. (px -. ax) +. (py -. ay) *. (py -. ay)) in
        if dist <= threshold then result := Some i
      | None -> ()
  ) d;
  !result

(** Hit test for existing anchor points on paths in the document. *)
let hit_test_anchor doc px py =
  let threshold = hit_radius in
  let result = ref None in
  Array.iteri (fun li layer ->
    let children = match layer with
      | Element.Layer { children; _ } -> children
      | _ -> [||]
    in
    Array.iteri (fun ci child ->
      if !result = None then begin
        (match child with
         | Element.Path { d; _ } ->
           (match find_anchor_at d px py threshold with
            | Some idx -> result := Some ([li; ci], child, idx)
            | None -> ())
         | Element.Group { children = gc; locked; _ } when not locked ->
           Array.iteri (fun gi gchild ->
             if !result = None then
               match gchild with
               | Element.Path { d; _ } ->
                 (match find_anchor_at d px py threshold with
                  | Some idx -> result := Some ([li; ci; gi], gchild, idx)
                  | None -> ())
               | _ -> ()
           ) gc
         | _ -> ())
      end
    ) children
  ) doc.Document.layers;
  !result

(** Delete the anchor at anchor_idx, merging adjacent segments.
    Returns None if the path would have fewer than 2 anchors. *)
let delete_anchor_from_path d anchor_idx =
  let anchor_count = List.length (List.filter (fun cmd ->
    match cmd with
    | Element.MoveTo _ | Element.LineTo _ | Element.CurveTo _ -> true
    | _ -> false
  ) d) in
  if anchor_count <= 2 then None
  else
    let arr = Array.of_list d in
    let n = Array.length arr in
    if anchor_idx = 0 then begin
      (* Delete first point: promote next to MoveTo *)
      if n > 1 then
        let (nx, ny) = match arr.(1) with
          | Element.LineTo (x, y) -> (x, y)
          | Element.CurveTo (_, _, _, _, x, y) -> (x, y)
          | _ -> (0.0, 0.0)
        in
        let result = [Element.MoveTo (nx, ny)] in
        let rest = ref [] in
        for i = n - 1 downto 2 do
          rest := arr.(i) :: !rest
        done;
        Some (result @ !rest)
      else None
    end else begin
      let effective_last = match arr.(n - 1) with
        | Element.ClosePath -> n - 2
        | _ -> n - 1
      in
      if anchor_idx = effective_last then begin
        (* Delete last anchor: remove last segment *)
        let result = ref [] in
        for i = anchor_idx - 1 downto 0 do
          result := arr.(i) :: !result
        done;
        if effective_last < n - 1 then
          result := !result @ [Element.ClosePath];
        Some !result
      end else begin
        (* Interior anchor: merge adjacent segments *)
        let cmd_at = arr.(anchor_idx) in
        let cmd_after = arr.(anchor_idx + 1) in
        let merged = match cmd_at, cmd_after with
          | Element.CurveTo (x1, y1, _, _, _, _),
            Element.CurveTo (_, _, x2, y2, x, y) ->
            Element.CurveTo (x1, y1, x2, y2, x, y)
          | Element.CurveTo (x1, y1, _, _, _, _),
            Element.LineTo (x, y) ->
            Element.CurveTo (x1, y1, x, y, x, y)
          | Element.LineTo _,
            Element.CurveTo (_, _, x2, y2, x, y) ->
            let (px, py) = if anchor_idx > 0 then
              match cmd_anchor arr.(anchor_idx - 1) with
              | Some (px, py) -> (px, py)
              | None -> (0.0, 0.0)
            else (0.0, 0.0)
            in
            Element.CurveTo (px, py, x2, y2, x, y)
          | Element.LineTo _, Element.LineTo (x, y) ->
            Element.LineTo (x, y)
          | _ -> cmd_after
        in
        let result = ref [] in
        for i = n - 1 downto 0 do
          if i = anchor_idx then
            result := merged :: !result
          else if i = anchor_idx + 1 then
            ()
          else
            result := arr.(i) :: !result
        done;
        Some !result
      end
    end

class delete_anchor_point_tool = object (_self)
  inherit Canvas_tool.default_methods
  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore shift; ignore alt;
    let doc = ctx.model#document in
    match hit_test_anchor doc x y with
    | Some (path, elem, anchor_idx) ->
      ctx.model#snapshot;
      let d = match elem with Element.Path { d; _ } -> d | _ -> [] in
      (match delete_anchor_from_path d anchor_idx with
       | Some new_cmds ->
         let new_elem = match elem with
           | Element.Path { fill; stroke; opacity; transform; locked; _ } ->
             Element.Path { d = new_cmds; fill; stroke; opacity; transform; locked }
           | _ -> elem
         in
         let new_doc = Document.replace_element doc path new_elem in
         (* Select all remaining control points *)
         let cp_count = Element.control_point_count new_elem in
         let all_cps = List.init cp_count Fun.id in
         let new_sel = Document.PathMap.add path
           (Document.make_element_selection ~control_points:all_cps path)
           new_doc.Document.selection in
         ctx.model#set_document { new_doc with Document.selection = new_sel };
         ctx.request_update ()
       | None ->
         (* Path too small - remove entirely *)
         let new_doc = Document.delete_element doc path in
         ctx.model#set_document new_doc;
         ctx.request_update ())
    | None -> ()

  method on_move (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) ~(shift : bool) ~(dragging : bool) =
    ignore shift; ignore dragging

  method on_release (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) ~(shift : bool) ~(alt : bool) =
    ignore shift; ignore alt

  method on_double_click (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = ()

  method on_key (_ctx : Canvas_tool.tool_context) (_key : int) = false

  method on_key_release (_ctx : Canvas_tool.tool_context) (_key : int) = false

  method draw_overlay (_ctx : Canvas_tool.tool_context) (_cr : Cairo.context) = ()

  method activate (_ctx : Canvas_tool.tool_context) = ()

  method deactivate (_ctx : Canvas_tool.tool_context) = ()
end
