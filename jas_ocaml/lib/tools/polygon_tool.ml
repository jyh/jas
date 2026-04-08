(** Polygon tool: drag to draw a regular polygon with N sides. *)

class polygon_tool = object
  inherit Drawing_tool.drawing_tool_base

  method private create_element sx sy ex ey =
    let pts = Canvas_tool.regular_polygon_points sx sy ex ey Canvas_tool.polygon_sides in
    Some (Element.Polygon {
      points = pts;
      fill = None; stroke = Canvas_tool.default_stroke;
      opacity = 1.0; transform = None; locked = false; visibility = Preview;
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
