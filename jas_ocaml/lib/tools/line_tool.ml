(** Line tool: drag to draw a straight line segment. *)

class line_tool = object
  inherit Drawing_tool.drawing_tool_base

  method private create_element (ctx : Canvas_tool.tool_context) sx sy ex ey =
    Some (Element.Line {
      x1 = sx; y1 = sy; x2 = ex; y2 = ey;
      stroke = ctx.model#default_stroke;
      width_points = [];
      opacity = 1.0; transform = None; locked = false; visibility = Preview;
    })

  method private draw_preview cr sx sy ex ey =
    Cairo.move_to cr sx sy;
    Cairo.line_to cr ex ey
end
