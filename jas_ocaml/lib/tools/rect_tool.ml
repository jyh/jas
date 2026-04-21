(** Rectangle tool: drag to draw an axis-aligned rectangle. *)

class rect_tool = object
  inherit Drawing_tool.drawing_tool_base

  method private create_element (ctx : Canvas_tool.tool_context) sx sy ex ey =
    Some (Element.Rect {
      x = min sx ex; y = min sy ey;
      width = abs_float (ex -. sx); height = abs_float (ey -. sy);
      rx = 0.0; ry = 0.0;
      fill = ctx.model#default_fill; stroke = ctx.model#default_stroke;
      opacity = 1.0; transform = None; locked = false; visibility = Preview; blend_mode = Normal;
      mask = None;
    })

  method private draw_preview cr sx sy ex ey =
    let rx = min sx ex and ry = min sy ey in
    let rw = abs_float (ex -. sx) and rh = abs_float (ey -. sy) in
    Cairo.rectangle cr rx ry ~w:rw ~h:rh
end
