(** Interior Selection tool: marquee select that picks groups as units. *)

class interior_selection_tool = object
  inherit Selection_tool.selection_tool_base

  method private check_handle_hit (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = false
  method private select_rect (ctx : Canvas_tool.tool_context) x y w h ~extend =
    ctx.controller#group_select_rect ~extend x y w h
end
