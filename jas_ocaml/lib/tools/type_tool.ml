(** Type tool for placing and editing text elements. *)

class type_tool = object (_self)
  val mutable drag_start : (float * float) option = None
  val mutable drag_end : (float * float) option = None

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    ctx.model#snapshot;
    drag_start <- Some (x, y);
    drag_end <- Some (x, y)

  method on_move (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore (shift, dragging);
    if drag_start <> None then begin
      drag_end <- Some (x, y);
      ctx.request_update ()
    end

  method on_release (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    match drag_start with
    | None -> ()
    | Some (sx, sy) ->
      drag_start <- None;
      drag_end <- None;
      let w = abs_float (x -. sx) and h = abs_float (y -. sy) in
      if w > Canvas_tool.drag_threshold || h > Canvas_tool.drag_threshold then begin
        let tx = min sx x and ty = min sy y in
        let elem = Element.make_text ~text_width:w ~text_height:h
          ~fill:(Some Element.{
            fill_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 }
          }) tx ty "Lorem Ipsum" in
        ctx.controller#add_element elem
      end else begin
        match ctx.hit_test_text sx sy with
        | Some (path, text_elem) ->
          ctx.start_text_edit path text_elem
        | None ->
          let elem = Element.make_text ~fill:(Some Element.{
            fill_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 }
          }) sx sy "Lorem Ipsum" in
          ctx.controller#add_element elem
      end

  method on_double_click (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = ()
  method on_key (_ctx : Canvas_tool.tool_context) (_key : int) = false
  method on_key_release (_ctx : Canvas_tool.tool_context) (_key : int) = false
  method activate (_ctx : Canvas_tool.tool_context) = ()

  method deactivate (ctx : Canvas_tool.tool_context) =
    ctx.commit_text_edit ()

  method draw_overlay (_ctx : Canvas_tool.tool_context) cr =
    match drag_start, drag_end with
    | Some (sx, sy), Some (ex, ey) ->
      Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
      Cairo.set_line_width cr 1.0;
      Cairo.set_dash cr [| 4.0; 4.0 |];
      let rx = min sx ex and ry = min sy ey in
      let rw = abs_float (ex -. sx) and rh = abs_float (ey -. sy) in
      Cairo.rectangle cr rx ry ~w:rw ~h:rh;
      Cairo.stroke cr;
      Cairo.set_dash cr [||]
    | _ -> ()
end
