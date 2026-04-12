(** Selection tool: marquee select, drag-to-move, Alt+drag copies.

    [selection_tool_base] is the shared base for the three selection
    variants. [Partial_selection_tool] and [Interior_selection_tool] live
    in their own files and inherit from it. *)

(** Drag-to-marquee or drag-to-move state machine. Subclasses choose
    how the marquee rectangle resolves into a selection (whole element
    vs. group expansion vs. direct hit) and may override hit detection
    on selection handles. *)
class virtual selection_tool_base : object
  inherit Canvas_tool.default_methods

  method virtual private select_rect :
    Canvas_tool.tool_context -> float -> float -> float -> float -> extend:bool -> unit
  (** Resolve a marquee rectangle [(x, y, w, h)] into a selection.
      [extend:true] adds to the existing selection. *)

  method virtual private check_handle_hit :
    Canvas_tool.tool_context -> float -> float -> bool
  (** Return true if the press hit a selection handle, suppressing the
      normal marquee/move flow. *)

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

(** The default Selection tool. Whole-element marquee selection;
    no handle hit-testing. *)
class selection_tool : object
  inherit selection_tool_base
  method private select_rect :
    Canvas_tool.tool_context -> float -> float -> float -> float -> extend:bool -> unit
  method private check_handle_hit :
    Canvas_tool.tool_context -> float -> float -> bool
end
