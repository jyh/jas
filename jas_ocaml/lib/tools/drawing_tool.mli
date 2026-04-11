(** Drawing tool base class shared by line / rect / rounded_rect /
    polygon / star.

    The individual drawing tools live in their own per-tool files
    ([line_tool.ml], [rect_tool.ml], etc.) and inherit from
    [drawing_tool_base] here. This file holds only the base class. *)

(** Common drag-to-create state machine: press snapshots and starts a
    drag, move updates the drag end (with shift constraining to 45°
    angles), and release calls [create_element] to build the element.

    Subclasses must implement two private methods:
    - [create_element sx sy ex ey] -> the new element to add (or None
      to cancel the drag)
    - [draw_preview cr sx sy ex ey] -> draw the in-progress preview *)
class virtual drawing_tool_base : object
  inherit Canvas_tool.default_methods
  method virtual private create_element :
    Canvas_tool.tool_context -> float -> float -> float -> float -> Element.element option
  method virtual private draw_preview :
    Cairo.context -> float -> float -> float -> float -> unit

  method on_press :
    Canvas_tool.tool_context -> float -> float -> shift:bool -> alt:bool -> unit
  method on_move :
    Canvas_tool.tool_context -> float -> float -> shift:bool -> dragging:bool -> unit
  method on_release :
    Canvas_tool.tool_context -> float -> float -> shift:bool -> alt:bool -> unit
  method on_double_click : Canvas_tool.tool_context -> float -> float -> unit
  method on_key : Canvas_tool.tool_context -> int -> bool
  method on_key_release : Canvas_tool.tool_context -> int -> bool
  method activate : Canvas_tool.tool_context -> unit
  method deactivate : Canvas_tool.tool_context -> unit
  method draw_overlay : Canvas_tool.tool_context -> Cairo.context -> unit
end
