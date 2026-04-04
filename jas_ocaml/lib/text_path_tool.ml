(** Text-on-path tool: drag to create a curve with text along it. *)

class text_path_tool = object (_self)
  val mutable drag_start : (float * float) option = None
  val mutable drag_end : (float * float) option = None
  val mutable control_pt : (float * float) option = None

  method on_press (_ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    drag_start <- Some (x, y);
    drag_end <- Some (x, y);
    control_pt <- None

  method on_move (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore (shift, dragging);
    match drag_start with
    | Some (sx, sy) ->
      drag_end <- Some (x, y);
      let mx = (sx +. x) /. 2.0 and my = (sy +. y) /. 2.0 in
      let dx = x -. sx and dy = y -. sy in
      let dist = sqrt (dx *. dx +. dy *. dy) in
      if dist > 4.0 then begin
        let nx = -. dy /. dist and ny = dx /. dist in
        control_pt <- Some (mx +. nx *. dist *. 0.3, my +. ny *. dist *. 0.3)
      end;
      ctx.request_update ()
    | None -> ()

  method on_release (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    match drag_start with
    | None -> ()
    | Some (sx, sy) ->
      drag_start <- None;
      drag_end <- None;
      let w = abs_float (x -. sx) and h = abs_float (y -. sy) in
      if w > 4.0 || h > 4.0 then begin
        let d = match control_pt with
          | Some (cx, cy) ->
            [Element.MoveTo (sx, sy); Element.CurveTo (cx, cy, cx, cy, x, y)]
          | None ->
            [Element.MoveTo (sx, sy); Element.LineTo (x, y)]
        in
        let elem = Element.make_text_path
          ~fill:(Some Element.{ fill_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 } })
          d "Lorem Ipsum" in
        ctx.controller#add_element elem
      end;
      control_pt <- None

  method on_double_click (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = ()
  method on_key (_ctx : Canvas_tool.tool_context) (_key : int) = false
  method activate (_ctx : Canvas_tool.tool_context) = ()
  method deactivate (_ctx : Canvas_tool.tool_context) = ()

  method draw_overlay (_ctx : Canvas_tool.tool_context) cr =
    match drag_start, drag_end with
    | Some (sx, sy), Some (ex, ey) ->
      Cairo.set_source_rgba cr 0.4 0.4 0.4 1.0;
      Cairo.set_line_width cr 1.0;
      Cairo.set_dash cr [| 4.0; 4.0 |];
      Cairo.move_to cr sx sy;
      (match control_pt with
       | Some (cx, cy) ->
         Cairo.curve_to cr cx cy cx cy ex ey
       | None ->
         Cairo.line_to cr ex ey);
      Cairo.stroke cr;
      Cairo.set_dash cr [||]
    | _ -> ()
end
