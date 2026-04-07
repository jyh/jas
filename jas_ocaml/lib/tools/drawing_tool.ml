(** Drawing tools: line, rect, polygon. *)

(* ------------------------------------------------------------------ *)
(* Drawing tool base                                                   *)
(* ------------------------------------------------------------------ *)

class virtual drawing_tool_base = object (_self)
  val mutable drag_start : (float * float) option = None
  val mutable drag_end : (float * float) option = None

  method virtual private create_element : float -> float -> float -> float -> Element.element option
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
      (match _self#create_element sx sy ex ey with
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

(* ------------------------------------------------------------------ *)
(* Line tool                                                           *)
(* ------------------------------------------------------------------ *)

class line_tool = object
  inherit drawing_tool_base

  method private create_element sx sy ex ey =
    Some (Element.Line {
      x1 = sx; y1 = sy; x2 = ex; y2 = ey;
      stroke = Canvas_tool.default_stroke;
      opacity = 1.0; transform = None; locked = false;
    })

  method private draw_preview cr sx sy ex ey =
    Cairo.move_to cr sx sy;
    Cairo.line_to cr ex ey
end

(* ------------------------------------------------------------------ *)
(* Rect tool                                                           *)
(* ------------------------------------------------------------------ *)

class rect_tool = object
  inherit drawing_tool_base

  method private create_element sx sy ex ey =
    Some (Element.Rect {
      x = min sx ex; y = min sy ey;
      width = abs_float (ex -. sx); height = abs_float (ey -. sy);
      rx = 0.0; ry = 0.0;
      fill = None; stroke = Canvas_tool.default_stroke;
      opacity = 1.0; transform = None; locked = false;
    })

  method private draw_preview cr sx sy ex ey =
    let rx = min sx ex and ry = min sy ey in
    let rw = abs_float (ex -. sx) and rh = abs_float (ey -. sy) in
    Cairo.rectangle cr rx ry ~w:rw ~h:rh
end

(* ------------------------------------------------------------------ *)
(* Rounded Rect tool                                                   *)
(* ------------------------------------------------------------------ *)

(** Default corner radius (in points) for new rounded rectangles. *)
let rounded_rect_radius = 10.0

class rounded_rect_tool = object
  inherit drawing_tool_base

  method private create_element sx sy ex ey =
    let w = abs_float (ex -. sx) in
    let h = abs_float (ey -. sy) in
    if w <= 0.0 || h <= 0.0 then None
    else
      Some (Element.Rect {
        x = min sx ex; y = min sy ey;
        width = w; height = h;
        rx = rounded_rect_radius; ry = rounded_rect_radius;
        fill = None; stroke = Canvas_tool.default_stroke;
        opacity = 1.0; transform = None; locked = false;
      })

  method private draw_preview cr sx sy ex ey =
    let x = min sx ex and y = min sy ey in
    let w = abs_float (ex -. sx) and h = abs_float (ey -. sy) in
    let r = min rounded_rect_radius (min (w /. 2.0) (h /. 2.0)) in
    if r <= 0.0 then
      Cairo.rectangle cr x y ~w ~h
    else begin
      Cairo.move_to cr (x +. r) y;
      Cairo.line_to cr (x +. w -. r) y;
      Cairo.curve_to cr (x +. w) y (x +. w) y (x +. w) (y +. r);
      Cairo.line_to cr (x +. w) (y +. h -. r);
      Cairo.curve_to cr (x +. w) (y +. h) (x +. w) (y +. h) (x +. w -. r) (y +. h);
      Cairo.line_to cr (x +. r) (y +. h);
      Cairo.curve_to cr x (y +. h) x (y +. h) x (y +. h -. r);
      Cairo.line_to cr x (y +. r);
      Cairo.curve_to cr x y x y (x +. r) y;
      Cairo.Path.close cr
    end
end

(* ------------------------------------------------------------------ *)
(* Polygon tool                                                        *)
(* ------------------------------------------------------------------ *)

class polygon_tool = object
  inherit drawing_tool_base

  method private create_element sx sy ex ey =
    let pts = Canvas_tool.regular_polygon_points sx sy ex ey Canvas_tool.polygon_sides in
    Some (Element.Polygon {
      points = pts;
      fill = None; stroke = Canvas_tool.default_stroke;
      opacity = 1.0; transform = None; locked = false;
    })

  method private draw_preview cr sx sy ex ey =
    let pts = Canvas_tool.regular_polygon_points sx sy ex ey Canvas_tool.polygon_sides in
    match pts with
    | (fx, fy) :: rest ->
      Cairo.move_to cr fx fy;
      List.iter (fun (px, py) -> Cairo.line_to cr px py) rest;
      Cairo.Path.close cr
    | [] -> ()
end
