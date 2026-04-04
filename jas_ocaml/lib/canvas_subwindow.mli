(** A floating canvas subwindow embedded inside the main workspace. *)

(** Axis-aligned bounding box for the canvas coordinate space. *)
type bounding_box = {
  bbox_x : float;
  bbox_y : float;
  bbox_width : float;
  bbox_height : float;
}

val make_bounding_box :
  ?x:float -> ?y:float -> ?width:float -> ?height:float -> unit -> bounding_box

class canvas_subwindow :
  model:Model.model ->
  controller:Controller.controller ->
  toolbar:Toolbar.toolbar ->
  x:int -> y:int -> width:int -> height:int ->
  bbox:bounding_box ->
  GPack.fixed -> object
  method widget : GObj.widget
  method canvas : GMisc.drawing_area
  method model : Model.model
  method title : string
  method x : int
  method y : int
  method bbox : bounding_box
  method pen_finish : unit
  method pen_finish_close : unit
  method pen_cancel : unit
end

val create :
  ?model:Model.model ->
  controller:Controller.controller ->
  toolbar:Toolbar.toolbar ->
  x:int -> y:int -> width:int -> height:int ->
  ?bbox:bounding_box ->
  GPack.fixed -> canvas_subwindow
