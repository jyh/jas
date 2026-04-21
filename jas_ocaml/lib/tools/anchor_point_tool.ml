(** Anchor Point (Convert) tool.

    Three interactions, mirroring jas_dioxus/src/tools/anchor_point_tool.rs:

    - Drag on a corner anchor: pull out symmetric handles → smooth.
    - Click on a smooth anchor: collapse handles to anchor → corner.
    - Drag on a control handle: move it independently → cusp.

    Hit-test priority: handles before anchors. *)

let hit_radius = Canvas_tool.hit_radius

(** Anchor positions of a path, indexed by anchor index (closePath skipped). *)
let anchor_points d =
  List.fold_left (fun acc cmd ->
    match cmd with
    | Element.MoveTo (x, y) | Element.LineTo (x, y) -> (x, y) :: acc
    | Element.CurveTo (_, _, _, _, x, y) -> (x, y) :: acc
    | Element.SmoothCurveTo (_, _, x, y) -> (x, y) :: acc
    | Element.QuadTo (_, _, x, y) -> (x, y) :: acc
    | Element.SmoothQuadTo (x, y) -> (x, y) :: acc
    | Element.ArcTo (_, _, _, _, _, x, y) -> (x, y) :: acc
    | Element.ClosePath -> acc
  ) [] d |> List.rev

(** Find the anchor index of a point near (px, py). *)
let find_anchor_at_idx d px py =
  let pts = anchor_points d in
  let result = ref None in
  List.iteri (fun i (ax, ay) ->
    if !result = None then begin
      let dist = sqrt ((px -. ax) *. (px -. ax) +. (py -. ay) *. (py -. ay)) in
      if dist < hit_radius then result := Some i
    end
  ) pts;
  !result

(** Find a handle ((anchor_idx, handle_type, hx, hy)) near (px, py). *)
let find_handle_at d px py =
  let n_anchors = List.length (anchor_points d) in
  let result = ref None in
  let i = ref 0 in
  while !result = None && !i < n_anchors do
    let (h_in, h_out) = Element.path_handle_positions d !i in
    (match h_in with
     | Some (hx, hy) when sqrt ((px -. hx) *. (px -. hx) +. (py -. hy) *. (py -. hy)) < hit_radius ->
       result := Some (!i, "in", hx, hy)
     | _ -> ());
    if !result = None then
      (match h_out with
       | Some (hx, hy) when sqrt ((px -. hx) *. (px -. hx) +. (py -. hy) *. (py -. hy)) < hit_radius ->
         result := Some (!i, "out", hx, hy)
       | _ -> ());
    incr i
  done;
  !result

(** Walk every Path element in the document one level into unlocked
    groups, returning the first one for which `f` produces Some. *)
let each_path_element doc f =
  let result = ref None in
  Array.iteri (fun li layer ->
    if !result = None then begin
      let children = match layer with
        | Element.Layer { children; _ } -> children
        | _ -> [||]
      in
      Array.iteri (fun ci child ->
        if !result = None then begin
          (match child with
           | Element.Path { d; _ } ->
             (match f d with
              | Some r -> result := Some ([li; ci], child, r)
              | None -> ())
           | Element.Group { children = gc; locked; _ } when not locked ->
             Array.iteri (fun gi gchild ->
               if !result = None then
                 match gchild with
                 | Element.Path { d; _ } ->
                   (match f d with
                    | Some r -> result := Some ([li; ci; gi], gchild, r)
                    | None -> ())
                 | _ -> ()
             ) gc
           | _ -> ())
        end
      ) children
    end
  ) doc.Document.layers;
  !result

(** Replace a path element's command list, preserving all other fields. *)
let replace_path_cmds elem new_cmds =
  match elem with
  | Element.Path { fill; stroke; width_points; opacity; transform; locked; visibility; blend_mode; _ } ->
    Element.Path { d = new_cmds; fill; stroke; width_points; opacity; transform; locked; visibility; blend_mode; mask = None }
  | _ -> elem

(** Apply new commands to the path at `path` and push back into the model. *)
let push_path_update (ctx : Canvas_tool.tool_context) path elem new_cmds =
  let new_elem = replace_path_cmds elem new_cmds in
  let new_doc = Document.replace_element ctx.model#document path new_elem in
  ctx.model#set_document new_doc;
  ctx.request_update ()

(** Set the selection to "all CPs of `path`". *)
let select_all_cps (ctx : Canvas_tool.tool_context) path =
  let doc = ctx.model#document in
  let new_sel = Document.PathMap.add path
    (Document.element_selection_all path)
    doc.Document.selection in
  ctx.model#set_document { doc with Document.selection = new_sel }

(* ------------------------------------------------------------------ *)
(* Tool state                                                          *)
(* ------------------------------------------------------------------ *)

type state =
  | Idle
  | Dragging_corner of {
      path : int list;
      pe : Element.element;
      anchor_idx : int;
      start_x : float;
      start_y : float;
    }
  | Dragging_handle of {
      path : int list;
      pe : Element.element;
      anchor_idx : int;
      handle_type : string;
      start_hx : float;
      start_hy : float;
    }
  | Pressed_smooth of {
      path : int list;
      pe : Element.element;
      anchor_idx : int;
      start_x : float;
      start_y : float;
    }

class anchor_point_tool = object (_self)
  inherit Canvas_tool.default_methods
  val mutable state : state = Idle

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore shift; ignore alt;
    let doc = ctx.model#document in
    (* 1. Handle hit takes priority (cusp behaviour). *)
    let handle_hit = each_path_element doc (fun d -> find_handle_at d x y) in
    match handle_hit with
    | Some (path, elem, (ai, ht, hx, hy)) ->
      state <- Dragging_handle {
        path; pe = elem; anchor_idx = ai;
        handle_type = ht; start_hx = hx; start_hy = hy;
      }
    | None ->
      (* 2. Anchor hit. *)
      let anchor_hit = each_path_element doc (fun d -> find_anchor_at_idx d x y) in
      match anchor_hit with
      | None -> ()
      | Some (path, elem, ai) ->
        let d = match elem with Element.Path { d; _ } -> d | _ -> [] in
        if Element.is_smooth_point d ai then
          state <- Pressed_smooth {
            path; pe = elem; anchor_idx = ai; start_x = x; start_y = y;
          }
        else
          state <- Dragging_corner {
            path; pe = elem; anchor_idx = ai; start_x = x; start_y = y;
          }

  method on_move (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore shift;
    if not dragging then ()
    else match state with
    | Dragging_corner { path; pe; anchor_idx; _ } ->
      let d = match pe with Element.Path { d; _ } -> d | _ -> [] in
      let new_cmds = Element.convert_corner_to_smooth d anchor_idx x y in
      push_path_update ctx path pe new_cmds
    | Dragging_handle { path; pe; anchor_idx; handle_type; start_hx; start_hy } ->
      let d = match pe with Element.Path { d; _ } -> d | _ -> [] in
      let dx = x -. start_hx and dy = y -. start_hy in
      let new_cmds = Element.move_path_handle_independent d anchor_idx handle_type dx dy in
      push_path_update ctx path pe new_cmds
    | Pressed_smooth { path; pe; anchor_idx; start_x; start_y } ->
      let dist = sqrt ((x -. start_x) *. (x -. start_x) +. (y -. start_y) *. (y -. start_y)) in
      if dist > 3.0 then begin
        let d = match pe with Element.Path { d; _ } -> d | _ -> [] in
        let corner_cmds = Element.convert_smooth_to_corner d anchor_idx in
        let new_cmds = Element.convert_corner_to_smooth corner_cmds anchor_idx x y in
        push_path_update ctx path pe new_cmds;
        let corner_pe = replace_path_cmds pe corner_cmds in
        state <- Dragging_corner {
          path; pe = corner_pe; anchor_idx; start_x; start_y;
        }
      end
    | Idle -> ()

  method on_release (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore shift; ignore alt;
    let s = state in
    state <- Idle;
    match s with
    | Pressed_smooth { path; pe; anchor_idx; _ } ->
      ctx.model#snapshot;
      let d = match pe with Element.Path { d; _ } -> d | _ -> [] in
      let new_cmds = Element.convert_smooth_to_corner d anchor_idx in
      push_path_update ctx path pe new_cmds;
      select_all_cps ctx path
    | Dragging_corner { path; pe; anchor_idx; start_x; start_y } ->
      let dist = sqrt ((x -. start_x) *. (x -. start_x) +. (y -. start_y) *. (y -. start_y)) in
      if dist > 1.0 then begin
        ctx.model#snapshot;
        let d = match pe with Element.Path { d; _ } -> d | _ -> [] in
        let new_cmds = Element.convert_corner_to_smooth d anchor_idx x y in
        push_path_update ctx path pe new_cmds;
        select_all_cps ctx path
      end
    | Dragging_handle { path; pe; anchor_idx; handle_type; start_hx; start_hy } ->
      let dx = x -. start_hx and dy = y -. start_hy in
      if abs_float dx > 0.5 || abs_float dy > 0.5 then begin
        ctx.model#snapshot;
        let d = match pe with Element.Path { d; _ } -> d | _ -> [] in
        let new_cmds = Element.move_path_handle_independent d anchor_idx handle_type dx dy in
        push_path_update ctx path pe new_cmds;
        select_all_cps ctx path
      end
    | Idle -> ()

  method on_double_click (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = ()

  method on_key (_ctx : Canvas_tool.tool_context) (_key : int) = false

  method on_key_release (_ctx : Canvas_tool.tool_context) (_key : int) = false

  method draw_overlay (_ctx : Canvas_tool.tool_context) (_cr : Cairo.context) = ()

  method activate (_ctx : Canvas_tool.tool_context) = ()

  method deactivate (_ctx : Canvas_tool.tool_context) =
    state <- Idle
end
