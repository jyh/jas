(** Rounded Rectangle tool: drag to draw a rectangle with fixed corner radius. *)

(** Default corner radius (in points) for new rounded rectangles. *)
let rounded_rect_radius = 10.0

class rounded_rect_tool = object
  inherit Drawing_tool.drawing_tool_base

  method private create_element (ctx : Canvas_tool.tool_context) sx sy ex ey =
    let w = abs_float (ex -. sx) in
    let h = abs_float (ey -. sy) in
    if w <= 0.0 || h <= 0.0 then None
    else
      Some (Element.Rect {
        x = min sx ex; y = min sy ey;
        width = w; height = h;
        rx = rounded_rect_radius; ry = rounded_rect_radius;
        fill = ctx.model#default_fill; stroke = ctx.model#default_stroke;
        opacity = 1.0; transform = None; locked = false; visibility = Preview; blend_mode = Normal;
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
