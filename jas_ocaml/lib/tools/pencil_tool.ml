(** Pencil tool for freehand drawing with automatic Bezier curve fitting. *)

let fit_error = 4.0

class pencil_tool = object (_self)
  val mutable points : (float * float) list = []
  val mutable drawing = false

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    ctx.model#snapshot;
    drawing <- true;
    points <- [(x, y)];
    ctx.request_update ()

  method on_move (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore (shift, dragging);
    if drawing then begin
      points <- (x, y) :: points;
      ctx.request_update ()
    end

  method on_release (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    if drawing then begin
      drawing <- false;
      points <- (x, y) :: points;
      let pts = List.rev points in
      if List.length pts >= 2 then begin
        let segments = Fit_curve.fit_curve pts fit_error in
        match segments with
        | [] ->
          points <- [];
          ctx.request_update ()
        | seg0 :: _ ->
          let cmds = ref [Element.MoveTo (seg0.Fit_curve.p1x, seg0.Fit_curve.p1y)] in
          List.iter (fun (seg : Fit_curve.segment) ->
            cmds := Element.CurveTo (seg.c1x, seg.c1y, seg.c2x, seg.c2y, seg.p2x, seg.p2y) :: !cmds
          ) segments;
          let d = List.rev !cmds in
          let path = Element.make_path d
            ~stroke:(Some (Element.make_stroke ~width:1.0 (Element.make_color 0.0 0.0 0.0))) in
          ctx.controller#add_element path;
          points <- [];
          ctx.request_update ()
      end else begin
        points <- [];
        ctx.request_update ()
      end
    end

  method on_double_click (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = ()
  method on_key (_ctx : Canvas_tool.tool_context) (_keycode : int) = false
  method on_key_release (_ctx : Canvas_tool.tool_context) (_keycode : int) = false
  method activate (_ctx : Canvas_tool.tool_context) = ()
  method deactivate (_ctx : Canvas_tool.tool_context) = ()

  method draw_overlay (_ctx : Canvas_tool.tool_context) cr =
    if drawing && List.length points >= 2 then begin
      let pts = List.rev points in
      Cairo.set_source_rgb cr 0.0 0.0 0.0;
      Cairo.set_line_width cr 1.0;
      (match pts with
       | (x0, y0) :: rest ->
         Cairo.move_to cr x0 y0;
         List.iter (fun (x, y) -> Cairo.line_to cr x y) rest;
         Cairo.stroke cr
       | [] -> ())
    end
end
