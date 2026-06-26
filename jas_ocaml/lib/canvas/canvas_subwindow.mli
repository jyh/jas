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

(** Fixed pixel size of a selection control-point handle square. *)
val handle_size : float

(** Document-space control-point handle rects [(x, y, w, h)] for the
    selected element at [path]. Each rect is centered at the
    element-transformed control point (the element's own transform,
    then each ancestor transform outward) and is a constant
    [handle_size] square, so an element transform MOVES the handles but
    never SCALES the handle glyphs. Returns [[]] for Group/Layer and
    Text/Text_path (no control-point squares). Callers draw these under
    the view (pan/zoom) transform only, NOT the element transform. *)
val selection_handle_rects :
  Document.document -> Document.element_path ->
  (float * float * float * float) list

(** Per-transform geometric-mean SCALE of a 2x3 affine — [sqrt(|det|)] of
    the linear part with [det = a*.d -. b*.c]. Returns [1.0] for [None] or a
    degenerate (det 0) transform. The building block of both
    [selection_outline_scale] and the element-stroke counter-scale. *)
val transform_scale_factor : Element.transform option -> float

(** Counter-scale an element's own STROKE for rendering. Returns
    [(element, accumulated_scale)] where [accumulated_scale = element_scale]
    times [transform_scale_factor] of the element's own transform, and the
    returned element has its stroke width DIVIDED by that scale (so the
    element transform, applied to the painter, never thickens the stroke —
    the stroke still scales with zoom). Returns the element unchanged when
    the accumulated scale is effectively 1.0. The accumulated scale is
    threaded to children so a stroked shape inside a transformed group is
    counter-scaled by the full ancestor chain. *)
val counter_scaled_element :
  Element.element -> float -> Element.element * float

(** Combined transform SCALE of the element at [path] — the geometric
    mean of the linear part, [sqrt(|det|)] with [det = a*.d -. b*.c],
    multiplied over the element's own transform and every ancestor
    (group/layer) transform. Returns [1.0] when there is no transform.

    The selection OUTLINE trace and the bezier tangent handles are drawn
    UNDER the element transform; dividing their fixed pen widths / circle
    radii by this factor cancels the element transform's scaling so they
    render at a constant size (still zoom-scaled, like the handle
    squares). Exact for uniform scale; geometric mean under
    non-uniform/shear. *)
val selection_outline_scale :
  Document.document -> Document.element_path -> float

val set_brush_libraries : Yojson.Safe.t -> unit
(** Install the brush library registry consulted by the Path renderer
    when a path carries a stroke_brush slug. The brushed render then
    fills the Calligraphic outline polygon with the path's stroke
    colour. App startup should call this once with the loaded
    brush_libraries data; subsequent calls replace the registry.
    See BRUSHES.md Stroke styling interaction. *)

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

(** Return the transform that should be applied when rendering
    the mask's subtree on top of the ancestor coord system.
    Track C phase 3, OPACITY.md \167Document model:

    - [linked: true]  — mask inherits [Element.get_transform elem].
    - [linked: false] — mask uses [mask.unlink_transform]
      (captured at unlink time, frozen).

    Returns [None] when the picked transform is absent. *)
val effective_mask_transform
  : Element.mask -> Element.element -> Element.transform option
