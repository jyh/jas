(** Document controller (MVC pattern).

    Provides mutation operations on the Model's document. *)

class controller : ?model:Model.model -> unit -> object
  method model : Model.model
  method document : Document.document
  method set_document : Document.document -> unit
  method set_filename : string -> unit
  method add_layer : Element.element -> unit
  method remove_layer : int -> unit
  method add_element : Element.element -> unit
  method select_all : unit
  method select_rect : ?extend:bool -> float -> float -> float -> float -> unit
  method select_polygon : ?extend:bool -> (float * float) array -> unit
  method interior_select_rect : ?extend:bool -> float -> float -> float -> float -> unit
  method partial_select_rect : ?extend:bool -> float -> float -> float -> float -> unit
  method set_selection : Document.selection -> unit
  method select_element : Document.element_path -> unit
  method select_control_point : Document.element_path -> int -> unit
  method move_path_handle : int list -> int -> string -> float -> float -> unit
  method lock_selection : unit
  method unlock_all : unit
  method hide_selection : unit
  method show_all : unit
  method move_selection : float -> float -> unit
  method copy_selection : float -> float -> unit
  method set_selection_fill : Element.fill option -> unit
  method set_selection_stroke : Element.stroke option -> unit
  method set_selection_width_profile : Element.stroke_width_point list -> unit
end

type fill_summary = FillNoSelection | FillUniform of Element.fill option | FillMixed
type stroke_summary = StrokeNoSelection | StrokeUniform of Element.stroke option | StrokeMixed

val selection_fill_summary : Document.document -> fill_summary
val selection_stroke_summary : Document.document -> stroke_summary

val create : ?model:Model.model -> unit -> controller
