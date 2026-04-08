(** Add Anchor Point tool.

    Clicking on a path inserts a new smooth anchor point at that location,
    splitting the clicked bezier segment into two while preserving the
    curve shape (de Casteljau subdivision). *)

let hit_radius = Canvas_tool.hit_radius
let handle_draw_size = Canvas_tool.handle_draw_size
let add_point_threshold = hit_radius +. 2.0

(* ------------------------------------------------------------------ *)
(* Geometry helpers                                                    *)
(* ------------------------------------------------------------------ *)

let lerp a b t = a +. t *. (b -. a)

(** Evaluate a cubic bezier at parameter t. *)
let eval_cubic x0 y0 x1 y1 x2 y2 x3 y3 t =
  let mt = 1.0 -. t in
  let x = mt *. mt *. mt *. x0
    +. 3.0 *. mt *. mt *. t *. x1
    +. 3.0 *. mt *. t *. t *. x2
    +. t *. t *. t *. x3 in
  let y = mt *. mt *. mt *. y0
    +. 3.0 *. mt *. mt *. t *. y1
    +. 3.0 *. mt *. t *. t *. y2
    +. t *. t *. t *. y3 in
  (x, y)

(** Split a cubic bezier at parameter t using de Casteljau's algorithm.
    Returns ((cp1x, cp1y, cp2x, cp2y, mx, my),
             (cp3x, cp3y, cp4x, cp4y, x3, y3)). *)
let split_cubic x0 y0 x1 y1 x2 y2 x3 y3 t =
  let a1x = lerp x0 x1 t and a1y = lerp y0 y1 t in
  let a2x = lerp x1 x2 t and a2y = lerp y1 y2 t in
  let a3x = lerp x2 x3 t and a3y = lerp y2 y3 t in
  let b1x = lerp a1x a2x t and b1y = lerp a1y a2y t in
  let b2x = lerp a2x a3x t and b2y = lerp a2y a3y t in
  let mx = lerp b1x b2x t and my = lerp b1y b2y t in
  ((a1x, a1y, b1x, b1y, mx, my),
   (b2x, b2y, a3x, a3y, x3, y3))

(** Find closest point on a line segment, return (distance, t). *)
let closest_on_line x0 y0 x1 y1 px py =
  let dx = x1 -. x0 and dy = y1 -. y0 in
  let len_sq = dx *. dx +. dy *. dy in
  if len_sq = 0.0 then
    let d = sqrt ((px -. x0) *. (px -. x0) +. (py -. y0) *. (py -. y0)) in
    (d, 0.0)
  else
    let t = max 0.0 (min 1.0 (((px -. x0) *. dx +. (py -. y0) *. dy) /. len_sq)) in
    let qx = x0 +. t *. dx and qy = y0 +. t *. dy in
    let d = sqrt ((px -. qx) *. (px -. qx) +. (py -. qy) *. (py -. qy)) in
    (d, t)

(** Find closest point on a cubic bezier by sampling + ternary search. *)
let closest_on_cubic x0 y0 x1 y1 x2 y2 x3 y3 px py =
  let steps = 50 in
  let best_dist = ref infinity and best_t = ref 0.0 in
  for i = 0 to steps do
    let t = float_of_int i /. float_of_int steps in
    let (bx, by) = eval_cubic x0 y0 x1 y1 x2 y2 x3 y3 t in
    let d = sqrt ((px -. bx) *. (px -. bx) +. (py -. by) *. (py -. by)) in
    if d < !best_dist then begin best_dist := d; best_t := t end
  done;
  let lo = ref (max 0.0 (!best_t -. 1.0 /. float_of_int steps)) in
  let hi = ref (min 1.0 (!best_t +. 1.0 /. float_of_int steps)) in
  for _ = 0 to 19 do
    let t1 = !lo +. (!hi -. !lo) /. 3.0 in
    let t2 = !hi -. (!hi -. !lo) /. 3.0 in
    let (bx1, by1) = eval_cubic x0 y0 x1 y1 x2 y2 x3 y3 t1 in
    let (bx2, by2) = eval_cubic x0 y0 x1 y1 x2 y2 x3 y3 t2 in
    let d1 = sqrt ((px -. bx1) *. (px -. bx1) +. (py -. by1) *. (py -. by1)) in
    let d2 = sqrt ((px -. bx2) *. (px -. bx2) +. (py -. by2) *. (py -. by2)) in
    if d1 < d2 then hi := t2
    else lo := t1
  done;
  best_t := (!lo +. !hi) /. 2.0;
  let (bx, by) = eval_cubic x0 y0 x1 y1 x2 y2 x3 y3 !best_t in
  let d = sqrt ((px -. bx) *. (px -. bx) +. (py -. by) *. (py -. by)) in
  (d, !best_t)

(* ------------------------------------------------------------------ *)
(* Path segment analysis                                               *)
(* ------------------------------------------------------------------ *)

(** Find which segment of the path the point (px, py) is closest to,
    and the parameter t on that segment. Returns (segment_index, t). *)
let closest_segment_and_t d px py =
  let cmds = Array.of_list d in
  let n = Array.length cmds in
  let best_dist = ref infinity in
  let best_seg = ref 0 in
  let best_t = ref 0.0 in
  let cx = ref 0.0 and cy = ref 0.0 in
  for i = 0 to n - 1 do
    (match cmds.(i) with
     | Element.MoveTo (x, y) ->
       cx := x; cy := y
     | Element.LineTo (x, y) ->
       let (dist, t) = closest_on_line !cx !cy x y px py in
       if dist < !best_dist then begin
         best_dist := dist; best_seg := i; best_t := t
       end;
       cx := x; cy := y
     | Element.CurveTo (x1, y1, x2, y2, x, y) ->
       let (dist, t) = closest_on_cubic !cx !cy x1 y1 x2 y2 x y px py in
       if dist < !best_dist then begin
         best_dist := dist; best_seg := i; best_t := t
       end;
       cx := x; cy := y
     | Element.ClosePath -> ()
     | _ -> ())
  done;
  if !best_dist < infinity then Some (!best_seg, !best_t) else None

(** Insert a new anchor point into the path command list at the given segment
    and parameter t. Returns (new_commands, first_new_idx, anchor_x, anchor_y). *)
let insert_point_in_path d seg_idx t =
  let cmds = Array.of_list d in
  let n = Array.length cmds in
  let result = ref [] in
  let first_new_idx = ref 0 in
  let anchor_x = ref 0.0 and anchor_y = ref 0.0 in
  let cx = ref 0.0 and cy = ref 0.0 in
  for i = 0 to n - 1 do
    if i = seg_idx then begin
      match cmds.(i) with
      | Element.CurveTo (x1, y1, x2, y2, x, y) ->
        let ((a1x, a1y, b1x, b1y, mx, my), (b2x, b2y, a3x, a3y, ex, ey)) =
          split_cubic !cx !cy x1 y1 x2 y2 x y t in
        first_new_idx := List.length !result;
        anchor_x := mx; anchor_y := my;
        result := Element.CurveTo (b2x, b2y, a3x, a3y, ex, ey)
                  :: Element.CurveTo (a1x, a1y, b1x, b1y, mx, my)
                  :: !result;
        cx := x; cy := y
      | Element.LineTo (x, y) ->
        let mx = lerp !cx x t and my = lerp !cy y t in
        first_new_idx := List.length !result;
        anchor_x := mx; anchor_y := my;
        result := Element.LineTo (x, y) :: Element.LineTo (mx, my) :: !result;
        cx := x; cy := y
      | cmd ->
        (match cmd with
         | Element.MoveTo (x, y) -> cx := x; cy := y
         | Element.LineTo (x, y) | Element.CurveTo (_, _, _, _, x, y) -> cx := x; cy := y
         | _ -> ());
        result := cmd :: !result
    end else begin
      (match cmds.(i) with
       | Element.MoveTo (x, y) -> cx := x; cy := y
       | Element.LineTo (x, y) | Element.CurveTo (_, _, _, _, x, y) -> cx := x; cy := y
       | _ -> ());
      result := cmds.(i) :: !result
    end
  done;
  let cmds_list = List.rev !result in
  (* first_new_idx equals the number of commands before the split point,
     which is exactly the forward index of the new anchor after reversal. *)
  (* first_new_idx equals the number of commands before the split point,
     which is exactly the forward index of the new anchor after reversal. *)
  let idx = !first_new_idx in
  (cmds_list, idx, !anchor_x, !anchor_y)

(** Update the handles of the newly inserted anchor point during drag.
    first_cmd_idx is the index of the first CurveTo of the split pair. *)
let update_handles cmds first_cmd_idx anchor_x anchor_y drag_x drag_y cusp =
  let arr = Array.of_list cmds in
  (* Outgoing handle = drag position *)
  (match arr.(first_cmd_idx + 1) with
   | Element.CurveTo (_, _, x2, y2, x, y) ->
     arr.(first_cmd_idx + 1) <- Element.CurveTo (drag_x, drag_y, x2, y2, x, y)
   | _ -> ());
  (* Incoming handle: mirror (smooth) or leave unchanged (cusp) *)
  if not cusp then
    (match arr.(first_cmd_idx) with
     | Element.CurveTo (x1, y1, _, _, x, y) ->
       arr.(first_cmd_idx) <- Element.CurveTo (x1, y1,
         2.0 *. anchor_x -. drag_x, 2.0 *. anchor_y -. drag_y, x, y)
     | _ -> ());
  Array.to_list arr

(** Reposition the anchor point, moving handles by the same delta. *)
let reposition_anchor cmds first_cmd_idx new_ax new_ay dx dy =
  let arr = Array.of_list cmds in
  (match arr.(first_cmd_idx) with
   | Element.CurveTo (x1, y1, x2, y2, _x, _y) ->
     arr.(first_cmd_idx) <- Element.CurveTo (x1, y1, x2 +. dx, y2 +. dy, new_ax, new_ay)
   | _ -> ());
  if first_cmd_idx + 1 < Array.length arr then
    (match arr.(first_cmd_idx + 1) with
     | Element.CurveTo (x1, y1, x2, y2, x, y) ->
       arr.(first_cmd_idx + 1) <- Element.CurveTo (x1 +. dx, y1 +. dy, x2, y2, x, y)
     | _ -> ());
  Array.to_list arr

(* ------------------------------------------------------------------ *)
(* Hit testing                                                         *)
(* ------------------------------------------------------------------ *)

(** Hit test for paths in the document. Returns (element_path, path_element). *)
let hit_test_path doc x y =
  let result = ref None in
  Array.iteri (fun li layer ->
    let children = match layer with
      | Element.Layer { children; _ } -> children
      | _ -> [||]
    in
    Array.iteri (fun ci child ->
      if !result = None then
        match child with
        | Element.Path { d; _ } ->
          let dist = Element.path_distance_to_point d x y in
          if dist <= add_point_threshold then
            result := Some ([li; ci], child)
        | Element.Group { children = gc; locked; _ } when not locked ->
          Array.iteri (fun gi gchild ->
            if !result = None then
              match gchild with
              | Element.Path { d; _ } ->
                let dist = Element.path_distance_to_point d x y in
                if dist <= add_point_threshold then
                  result := Some ([li; ci; gi], gchild)
              | _ -> ()
          ) gc
        | _ -> ()
    ) children
  ) doc.Document.layers;
  !result

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

(** Hit test for existing anchor points on paths in the document.
    Returns (element_path, path_element, anchor_cmd_index). *)
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

(* ------------------------------------------------------------------ *)
(* Toggle smooth/corner                                                *)
(* ------------------------------------------------------------------ *)

let find_prev_anchor cmds idx =
  let arr = Array.of_list cmds in
  let result = ref None in
  for i = idx - 1 downto 0 do
    if !result = None then
      match cmd_anchor arr.(i) with
      | Some _ as r -> result := r
      | None -> ()
  done;
  !result

let find_next_anchor cmds idx =
  let arr = Array.of_list cmds in
  let n = Array.length arr in
  let result = ref None in
  for i = idx + 1 to n - 1 do
    if !result = None then
      match cmd_anchor arr.(i) with
      | Some _ as r -> result := r
      | None -> ()
  done;
  !result

let toggle_smooth_corner cmds anchor_idx =
  let arr = Array.of_list cmds in
  let n = Array.length arr in
  let (ax, ay) = match cmd_anchor arr.(anchor_idx) with
    | Some p -> p | None -> (0.0, 0.0) in
  let in_at_anchor = match arr.(anchor_idx) with
    | Element.CurveTo (_, _, x2, y2, _, _) ->
      abs_float (x2 -. ax) < 0.5 && abs_float (y2 -. ay) < 0.5
    | _ -> true in
  let out_at_anchor =
    if anchor_idx + 1 < n then
      match arr.(anchor_idx + 1) with
      | Element.CurveTo (x1, y1, _, _, _, _) ->
        abs_float (x1 -. ax) < 0.5 && abs_float (y1 -. ay) < 0.5
      | _ -> true
    else true in
  let is_corner = in_at_anchor && out_at_anchor in
  if is_corner then begin
    (* Convert corner to smooth *)
    let prev = find_prev_anchor (Array.to_list arr) anchor_idx in
    let next = find_next_anchor (Array.to_list arr) anchor_idx in
    match prev, next with
    | Some (px, py), Some (nx, ny) ->
      let dx = nx -. px and dy = ny -. py in
      let len = sqrt (dx *. dx +. dy *. dy) in
      if len > 0.0 then begin
        let prev_dist = sqrt ((ax -. px) *. (ax -. px) +. (ay -. py) *. (ay -. py)) in
        let next_dist = sqrt ((nx -. ax) *. (nx -. ax) +. (ny -. ay) *. (ny -. ay)) in
        let ux = dx /. len and uy = dy /. len in
        let in_len = prev_dist /. 3.0 and out_len = next_dist /. 3.0 in
        (match arr.(anchor_idx) with
         | Element.CurveTo (x1, y1, _, _, x, y) ->
           arr.(anchor_idx) <- Element.CurveTo (x1, y1,
             ax -. ux *. in_len, ay -. uy *. in_len, x, y)
         | _ -> ());
        if anchor_idx + 1 < n then
          (match arr.(anchor_idx + 1) with
           | Element.CurveTo (_, _, x2, y2, x, y) ->
             arr.(anchor_idx + 1) <- Element.CurveTo (
               ax +. ux *. out_len, ay +. uy *. out_len, x2, y2, x, y)
           | _ -> ())
      end
    | _ -> ()
  end else begin
    (* Convert smooth to corner: collapse handles *)
    (match arr.(anchor_idx) with
     | Element.CurveTo (x1, y1, _, _, x, y) ->
       arr.(anchor_idx) <- Element.CurveTo (x1, y1, ax, ay, x, y)
     | _ -> ());
    if anchor_idx + 1 < n then
      (match arr.(anchor_idx + 1) with
       | Element.CurveTo (_, _, x2, y2, x, y) ->
         arr.(anchor_idx + 1) <- Element.CurveTo (ax, ay, x2, y2, x, y)
       | _ -> ())
  end;
  Array.to_list arr

(* ------------------------------------------------------------------ *)
(* Drag state                                                          *)
(* ------------------------------------------------------------------ *)

type drag_state = {
  elem_path : int list;
  first_cmd_idx : int;
  mutable anchor_x : float;
  mutable anchor_y : float;
  mutable last_x : float;
  mutable last_y : float;
}

(* ------------------------------------------------------------------ *)
(* Tool class                                                          *)
(* ------------------------------------------------------------------ *)

class add_anchor_point_tool = object (_self)
  inherit Canvas_tool.default_methods
  val mutable drag : drag_state option = None
  val mutable space_held : bool = false

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore shift;
    drag <- None;
    let doc = ctx.model#document in
    (* Alt+click on existing anchor: toggle smooth/corner *)
    if alt then begin
      match hit_test_anchor doc x y with
      | Some (path, elem, anchor_idx) ->
        ctx.model#snapshot;
        let d = match elem with Element.Path { d; _ } -> d | _ -> [] in
        let new_cmds = toggle_smooth_corner d anchor_idx in
        let new_elem = match elem with
          | Element.Path { fill; stroke; opacity; transform; locked; visibility; _ } ->
            Element.Path { d = new_cmds; fill; stroke; opacity; transform; locked; visibility }
          | _ -> elem
        in
        let new_doc = Document.replace_element doc path new_elem in
        ctx.model#set_document new_doc;
        ctx.request_update ()
      | None -> ()
    end else begin
      match hit_test_path doc x y with
      | Some (path, elem) ->
        let d = match elem with Element.Path { d; _ } -> d | _ -> [] in
        (match closest_segment_and_t d x y with
         | Some (seg_idx, t) ->
           ctx.model#snapshot;
           let (new_cmds, first_new_idx, ax, ay) = insert_point_in_path d seg_idx t in
           let new_elem = match elem with
             | Element.Path { fill; stroke; opacity; transform; locked; visibility; _ } ->
               Element.Path { d = new_cmds; fill; stroke; opacity; transform; locked; visibility }
             | _ -> elem
           in
           let new_doc = Document.replace_element doc path new_elem in
           (* Update selection: shift CP indices after the insertion
              point. If the previous selection was `SelKindAll`, the
              new anchor is automatically included. *)
           let new_anchor_idx = first_new_idx in
           let new_doc = match Document.get_element_selection doc.Document.selection path with
             | Some es ->
               let new_kind = match es.Document.es_kind with
                 | Document.SelKindAll -> Document.SelKindAll
                 | Document.SelKindPartial s ->
                   let shifted = List.map (fun cp ->
                     if cp >= new_anchor_idx then cp + 1 else cp
                   ) (Document.SortedCps.to_list s) in
                   let shifted = new_anchor_idx :: shifted in
                   Document.SelKindPartial (Document.SortedCps.from_list shifted)
               in
               let new_sel = Document.PathMap.add path
                 { Document.es_path = path; es_kind = new_kind }
                 new_doc.Document.selection in
               { new_doc with Document.selection = new_sel }
             | None -> new_doc
           in
           ctx.model#set_document new_doc;
           (* Allow handle dragging if split produced CurveTo pairs *)
           let cmds_arr = Array.of_list new_cmds in
           let n = Array.length cmds_arr in
           if first_new_idx + 1 < n then begin
             let is_curve_pair = match cmds_arr.(first_new_idx), cmds_arr.(first_new_idx + 1) with
               | Element.CurveTo _, Element.CurveTo _ -> true
               | _ -> false
             in
             if is_curve_pair then
               drag <- Some {
                 elem_path = path;
                 first_cmd_idx = first_new_idx;
                 anchor_x = ax;
                 anchor_y = ay;
                 last_x = x;
                 last_y = y;
               }
           end;
           ctx.request_update ()
         | None -> ())
      | None -> ()
    end

  method on_move (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore shift;
    if not dragging then ()
    else match drag with
    | None -> ()
    | Some ds ->
      let doc = ctx.model#document in
      let elem = Document.get_element doc ds.elem_path in
      let d = match elem with Element.Path { d; _ } -> d | _ -> [] in
      if d <> [] then begin
        let new_cmds =
          if space_held then begin
            (* Space held: reposition the anchor point *)
            let dx = x -. ds.last_x and dy = y -. ds.last_y in
            ds.last_x <- x; ds.last_y <- y;
            ds.anchor_x <- ds.anchor_x +. dx;
            ds.anchor_y <- ds.anchor_y +. dy;
            reposition_anchor d ds.first_cmd_idx ds.anchor_x ds.anchor_y dx dy
          end else begin
            ds.last_x <- x; ds.last_y <- y;
            update_handles d ds.first_cmd_idx ds.anchor_x ds.anchor_y x y false
          end
        in
        let new_elem = match elem with
          | Element.Path { fill; stroke; opacity; transform; locked; visibility; _ } ->
            Element.Path { d = new_cmds; fill; stroke; opacity; transform; locked; visibility }
          | _ -> elem
        in
        let new_doc = Document.replace_element doc ds.elem_path new_elem in
        ctx.model#set_document new_doc;
        ctx.request_update ()
      end

  method on_release (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    drag <- None;
    space_held <- false

  method on_double_click (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = ()

  method on_key (_ctx : Canvas_tool.tool_context) (key : int) =
    if key = GdkKeysyms._space && drag <> None then begin
      space_held <- true; true
    end else false

  method on_key_release (_ctx : Canvas_tool.tool_context) (key : int) =
    if key = GdkKeysyms._space then begin
      space_held <- false; true
    end else false

  method activate (_ctx : Canvas_tool.tool_context) = ()

  method deactivate (_ctx : Canvas_tool.tool_context) =
    drag <- None

  method draw_overlay (_ctx : Canvas_tool.tool_context) cr =
    match drag with
    | None -> ()
    | Some ds ->
      let doc = _ctx.model#document in
      let elem = Document.get_element doc ds.elem_path in
      let d = match elem with Element.Path { d; _ } -> d | _ -> [] in
      let cmds = Array.of_list d in
      let n = Array.length cmds in
      let idx = ds.first_cmd_idx in
      if idx + 1 >= n then ()
      else begin
        let (in_x, in_y) = match cmds.(idx) with
          | Element.CurveTo (_, _, x2, y2, _, _) -> (x2, y2)
          | _ -> (0.0, 0.0) in
        let (out_x, out_y) = match cmds.(idx + 1) with
          | Element.CurveTo (x1, y1, _, _, _, _) -> (x1, y1)
          | _ -> (0.0, 0.0) in
        let ax = ds.anchor_x and ay = ds.anchor_y in
        (* Determine if cusp *)
        let d_in_x = in_x -. ax and d_in_y = in_y -. ay in
        let d_out_x = out_x -. ax and d_out_y = out_y -. ay in
        let cross = d_in_x *. d_out_y -. d_in_y *. d_out_x in
        let dot = d_in_x *. d_out_x +. d_in_y *. d_out_y in
        let in_len = sqrt (d_in_x *. d_in_x +. d_in_y *. d_in_y) in
        let out_len = sqrt (d_out_x *. d_out_x +. d_out_y *. d_out_y) in
        let max_len = max in_len out_len in
        let is_cusp = max_len > 0.5 && (abs_float cross > max_len *. 0.01 || dot > 0.0) in
        (* Draw handle lines *)
        Cairo.set_source_rgb cr 0.0 0.47 1.0;
        Cairo.set_line_width cr 1.0;
        if is_cusp then begin
          Cairo.move_to cr ax ay;
          Cairo.line_to cr in_x in_y;
          Cairo.stroke cr;
          Cairo.move_to cr ax ay;
          Cairo.line_to cr out_x out_y;
          Cairo.stroke cr
        end else begin
          Cairo.move_to cr in_x in_y;
          Cairo.line_to cr out_x out_y;
          Cairo.stroke cr
        end;
        (* Handle circles *)
        let r = 3.0 in
        List.iter (fun (hx, hy) ->
          Cairo.arc cr hx hy ~r ~a1:0.0 ~a2:(2.0 *. Float.pi);
          Cairo.set_source_rgb cr 1.0 1.0 1.0;
          Cairo.fill_preserve cr;
          Cairo.set_source_rgb cr 0.0 0.47 1.0;
          Cairo.stroke cr
        ) [(in_x, in_y); (out_x, out_y)];
        (* Anchor point square *)
        let half = handle_draw_size /. 2.0 in
        Cairo.set_source_rgb cr 0.0 0.47 1.0;
        Cairo.rectangle cr (ax -. half) (ay -. half) ~w:handle_draw_size ~h:handle_draw_size;
        Cairo.fill cr
      end
end
