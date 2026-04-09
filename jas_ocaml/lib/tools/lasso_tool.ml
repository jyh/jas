(** Lasso tool — freehand polygon selection. *)

let min_point_dist = 2.0

type lasso_state =
  | Idle
  | Drawing of { points : (float * float) list; shift : bool }

class lasso_tool = object (self)
  inherit Canvas_tool.default_methods

  val mutable state = Idle

  method on_press _ctx _x _y ~shift ~alt:_ =
    ignore (self : #Canvas_tool.canvas_tool);
    state <- Drawing { points = [(_x, _y)]; shift }

  method on_move _ctx x y ~shift ~dragging:_ =
    match state with
    | Drawing { points; _ } ->
      (match points with
       | (lx, ly) :: _ ->
         let dist = sqrt ((x -. lx) ** 2.0 +. (y -. ly) ** 2.0) in
         if dist >= min_point_dist then
           state <- Drawing { points = (x, y) :: points; shift }
         else
           state <- Drawing { points; shift }
       | [] -> state <- Drawing { points = [(x, y)]; shift })
    | Idle -> ()

  method on_release ctx _x _y ~shift ~alt:_ =
    (match state with
     | Drawing { points; shift = s } ->
       let extend = s || shift in
       let pts = List.rev points in
       if List.length pts >= 3 then begin
         ctx.Canvas_tool.model#snapshot;
         ctx.Canvas_tool.controller#select_polygon ~extend (Array.of_list pts)
       end else if not extend then
         ctx.Canvas_tool.controller#set_selection Document.PathMap.empty
     | Idle -> ());
    state <- Idle

  method on_double_click _ctx _x _y = ()

  method on_key _ctx _key = false

  method on_key_release _ctx _key = false

  method draw_overlay _ctx cr =
    match state with
    | Drawing { points; _ } when List.length points >= 2 ->
      let pts = List.rev points in
      Cairo.set_source_rgba cr 0.0 0.47 0.84 0.8;
      Cairo.set_line_width cr 1.0;
      (match pts with
       | (x0, y0) :: rest ->
         Cairo.move_to cr x0 y0;
         List.iter (fun (x, y) -> Cairo.line_to cr x y) rest;
         Cairo.Path.close cr;
         Cairo.stroke_preserve cr;
         Cairo.set_source_rgba cr 0.0 0.47 0.84 0.1;
         Cairo.fill cr
       | [] -> ())
    | _ -> ()

  method activate _ctx = state <- Idle
  method deactivate _ctx = state <- Idle
end
