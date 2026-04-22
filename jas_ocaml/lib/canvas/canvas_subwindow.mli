(** A canvas view embedded as a tab in a notebook. *)

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
  bbox:bounding_box -> object
  method widget : GObj.widget
  method canvas : GMisc.drawing_area
  method model : Model.model
  method title : string
  method bbox : bounding_box
  method pen_finish : unit
  method pen_finish_close : unit
  method pen_cancel : unit
  method forward_key : int -> bool
  method forward_key_release : int -> bool
  method forward_key_event : GdkEvent.Key.t -> bool
  method tool_is_editing : bool
end

val create :
  ?model:Model.model ->
  controller:Controller.controller ->
  toolbar:Toolbar.toolbar ->
  ?on_focus:(unit -> unit) ->
  ?on_save:(unit -> unit) ->
  ?bbox:bounding_box ->
  GPack.notebook -> canvas_subwindow

(** How the mask subtree's rendered alpha is applied to the
    element. Selected by [mask_plan] from the mask's [clip] and
    [invert] fields; consumed by the renderer's
    [draw_element_with_mask] dispatch. OPACITY.md \167Rendering. *)
type mask_plan =
  | Clip_in
  | Clip_out
  | Reveal_outside_bbox

(** Pick a [mask_plan] for the mask, or [None] when the mask is
    inactive ([disabled: true]). *)
val mask_plan : Element.mask -> mask_plan option
