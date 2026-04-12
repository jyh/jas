(** Partial Selection tool: select control points and drag Bezier handles. *)

class partial_selection_tool = object (self)
  inherit Selection_tool.selection_tool_base as super

  val mutable handle_drag : (int list * int * string) option = None
  val mutable handle_drag_start : (float * float) option = None
  val mutable handle_drag_end : (float * float) option = None

  method private check_handle_hit (ctx : Canvas_tool.tool_context) x y =
    match ctx.hit_test_handle x y with
    | Some (path, anchor_idx, ht) ->
      handle_drag <- Some (path, anchor_idx, ht);
      handle_drag_start <- Some (x, y);
      handle_drag_end <- Some (x, y);
      true
    | None -> false

  method private select_rect (ctx : Canvas_tool.tool_context) x y w h ~extend =
    ctx.controller#direct_select_rect ~extend x y w h

  method! on_move (ctx : Canvas_tool.tool_context) x y ~shift ~dragging =
    if handle_drag <> None then begin
      handle_drag_end <- Some (x, y);
      ctx.request_update ()
    end else
      super#on_move ctx x y ~shift ~dragging

  method! on_release (ctx : Canvas_tool.tool_context) x y ~shift ~alt =
    match handle_drag, handle_drag_start with
    | Some (path, anchor_idx, ht), Some (sx, sy) ->
      let dx = x -. sx and dy = y -. sy in
      handle_drag <- None;
      handle_drag_start <- None;
      handle_drag_end <- None;
      if dx <> 0.0 || dy <> 0.0 then begin
        ctx.model#snapshot;
        ctx.controller#move_path_handle path anchor_idx ht dx dy
      end;
      ctx.request_update ()
    | _ ->
      ignore (self : #Selection_tool.selection_tool_base);
      super#on_release ctx x y ~shift ~alt

  method! draw_overlay (ctx : Canvas_tool.tool_context) cr =
    (match handle_drag, handle_drag_start, handle_drag_end with
     | Some (path, anchor_idx, ht), Some (sx, sy), Some (ex, ey) ->
       let dx = ex -. sx and dy = ey -. sy in
       let elem = Document.get_element ctx.model#document path in
       (match elem with
        | Element.Path ({ d; _ } as r) ->
          let new_d = Element.move_path_handle d anchor_idx ht dx dy in
          let moved = Element.Path { r with d = new_d } in
          let es_opt = Document.PathMap.find_opt path ctx.model#document.Document.selection in
          (match es_opt with
           | Some es ->
             Cairo.set_source_rgb cr 0.0 0.47 1.0;
             Cairo.set_line_width cr 1.0;
             Cairo.set_dash cr [| 4.0; 4.0 |];
             let n = Element.control_point_count moved in
             let cps = Document.selection_kind_to_sorted es.es_kind ~total:n in
             let is_partial = match es.es_kind with
               | Document.SelKindPartial _ -> true
               | Document.SelKindAll -> false in
             ctx.draw_element_overlay cr moved ~is_partial cps;
             Cairo.set_dash cr [||]
           | None -> ())
        | _ -> ())
     | _ -> ());
    super#draw_overlay ctx cr
end
