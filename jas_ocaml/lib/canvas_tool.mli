(** Tool protocol and implementations for the canvas tool system. *)

(** Facade passed to tools giving access to model, controller, and canvas services. *)
type tool_context = {
  model : Model.model;
  controller : Controller.controller;
  hit_test_selection : float -> float -> bool;
  hit_test_handle : float -> float -> (int list * int * string) option;
  hit_test_text : float -> float -> (int list * Element.element) option;
  request_update : unit -> unit;
  start_text_edit : int list -> Element.element -> unit;
  commit_text_edit : unit -> unit;
  draw_element_overlay : Cairo.context -> Element.element -> int list -> unit;
}

(** Interface for canvas interaction tools. *)
class type canvas_tool = object
  method on_press : tool_context -> float -> float -> shift:bool -> alt:bool -> unit
  method on_move : tool_context -> float -> float -> shift:bool -> dragging:bool -> unit
  method on_release : tool_context -> float -> float -> shift:bool -> alt:bool -> unit
  method on_double_click : tool_context -> float -> float -> unit
  method on_key : tool_context -> int -> bool
  method draw_overlay : tool_context -> Cairo.context -> unit
  method activate : tool_context -> unit
  method deactivate : tool_context -> unit
end

(** Constrain an angle to 45-degree increments. *)
val constrain_angle : float -> float -> float -> float -> float * float

(** Number of sides for the polygon tool. *)
val polygon_sides : int

(** Compute regular polygon vertices. *)
val regular_polygon_points : float -> float -> float -> float -> int -> (float * float) list

(** Default stroke used by drawing and pen tools. *)
val default_stroke : Element.stroke option

