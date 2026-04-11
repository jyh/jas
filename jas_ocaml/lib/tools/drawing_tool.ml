(** Drawing tool base class shared by line / rect / rounded_rect / polygon / star.

    The individual drawing tools live in their own per-tool files
    ([line_tool.ml], [rect_tool.ml], etc.) and inherit from [drawing_tool_base]
    here. This file holds only the base class. *)

class virtual drawing_tool_base = object (_self)
  inherit Canvas_tool.default_methods
  val mutable drag_start : (float * float) option = None
  val mutable drag_end : (float * float) option = None

  method virtual private create_element : Canvas_tool.tool_context -> float -> float -> float -> float -> Element.element option
  method virtual private draw_preview : Cairo.context -> float -> float -> float -> float -> unit

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    ctx.model#snapshot;
    drag_start <- Some (x, y);
    drag_end <- Some (x, y)

  method on_move (ctx : Canvas_tool.tool_context) x y ~shift ~(dragging : bool) =
    ignore dragging;
    match drag_start with
    | Some (sx, sy) ->
      let (cx, cy) = if shift then Canvas_tool.constrain_angle sx sy x y else (x, y) in
      drag_end <- Some (cx, cy);
      ctx.request_update ()
    | None -> ()

  method on_release (ctx : Canvas_tool.tool_context) x y ~shift ~(alt : bool) =
    ignore alt;
    match drag_start with
    | None -> ()
    | Some (sx, sy) ->
      let (ex, ey) = if shift then Canvas_tool.constrain_angle sx sy x y else (x, y) in
      drag_start <- None;
      drag_end <- None;
      (match _self#create_element ctx sx sy ex ey with
       | Some elem -> ctx.controller#add_element elem
       | None -> ())

  method on_double_click (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = ()
  method on_key (_ctx : Canvas_tool.tool_context) (_key : int) = false
  method on_key_release (_ctx : Canvas_tool.tool_context) (_key : int) = false
  method activate (_ctx : Canvas_tool.tool_context) = ()
  method deactivate (_ctx : Canvas_tool.tool_context) = ()

  method draw_overlay (_ctx : Canvas_tool.tool_context) cr =
    match drag_start, drag_end with
    | Some (sx, sy), Some (ex, ey) ->
      Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
      Cairo.set_line_width cr 1.0;
      Cairo.set_dash cr [| 4.0; 4.0 |];
      _self#draw_preview cr sx sy ex ey;
      Cairo.stroke cr;
      Cairo.set_dash cr [||]
    | _ -> ()
end
