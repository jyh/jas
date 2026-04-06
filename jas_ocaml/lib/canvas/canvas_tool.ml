(** Tool protocol: shared types, geometry helpers, and tool factory.

    Tool implementations live in separate modules:
    - Selection_tool: selection, group selection, direct selection
    - Drawing_tool: line, rect, polygon
    - Pen_tool: pen (Bezier path creation)
    - Text_tool: text placement and editing *)

(* ------------------------------------------------------------------ *)
(* Tool context                                                        *)
(* ------------------------------------------------------------------ *)

type tool_context = {
  model : Model.model;
  controller : Controller.controller;
  hit_test_selection : float -> float -> bool;
  hit_test_handle : float -> float -> (int list * int * string) option;
  hit_test_text : float -> float -> (int list * Element.element) option;
  hit_test_path_curve : float -> float -> (int list * Element.element) option;
  request_update : unit -> unit;
  start_text_edit : int list -> Element.element -> unit;
  commit_text_edit : unit -> unit;
  draw_element_overlay : Cairo.context -> Element.element -> int list -> unit;
}

(* ------------------------------------------------------------------ *)
(* Tool class type                                                     *)
(* ------------------------------------------------------------------ *)

class type canvas_tool = object
  method on_press : tool_context -> float -> float -> shift:bool -> alt:bool -> unit
  method on_move : tool_context -> float -> float -> shift:bool -> dragging:bool -> unit
  method on_release : tool_context -> float -> float -> shift:bool -> alt:bool -> unit
  method on_double_click : tool_context -> float -> float -> unit
  method on_key : tool_context -> int -> bool
  method on_key_release : tool_context -> int -> bool
  method draw_overlay : tool_context -> Cairo.context -> unit
  method activate : tool_context -> unit
  method deactivate : tool_context -> unit
end

(* ------------------------------------------------------------------ *)
(* Geometry helpers                                                    *)
(* ------------------------------------------------------------------ *)

let constrain_angle sx sy ex ey =
  let dx = ex -. sx and dy = ey -. sy in
  let dist = sqrt (dx *. dx +. dy *. dy) in
  if dist = 0.0 then (ex, ey)
  else
    let angle = atan2 dy dx in
    let snapped = Float.round (angle /. (Float.pi /. 4.0)) *. (Float.pi /. 4.0) in
    (sx +. dist *. cos snapped, sy +. dist *. sin snapped)

(* Shared tool constants *)
let hit_radius = 8.0          (* pixels to detect a click on a control point *)
let handle_draw_size = 10.0   (* diameter of control-point handles in pixels *)
let drag_threshold = 4.0      (* pixels of movement before a click becomes a drag *)
let paste_offset = 24.0       (* translation in pt applied when pasting *)
let long_press_ms = 500       (* milliseconds before a press becomes a long-press *)
let polygon_sides = 5         (* default number of sides for the polygon tool *)

let regular_polygon_points x1 y1 x2 y2 n =
  let ex = x2 -. x1 and ey = y2 -. y1 in
  let s = sqrt (ex *. ex +. ey *. ey) in
  if s = 0.0 then List.init n (fun _ -> (x1, y1))
  else
    let mx = (x1 +. x2) /. 2.0 and my = (y1 +. y2) /. 2.0 in
    let px = -. ey /. s and py = ex /. s in
    let d = s /. (2.0 *. tan (Float.pi /. float_of_int n)) in
    let cx = mx +. d *. px and cy = my +. d *. py in
    let r = s /. (2.0 *. sin (Float.pi /. float_of_int n)) in
    let theta0 = atan2 (y1 -. cy) (x1 -. cx) in
    List.init n (fun k ->
      let angle = theta0 +. 2.0 *. Float.pi *. float_of_int k /. float_of_int n in
      (cx +. r *. cos angle, cy +. r *. sin angle))

(* ------------------------------------------------------------------ *)
(* Shared defaults                                                     *)
(* ------------------------------------------------------------------ *)

let default_stroke = Some Element.{
  stroke_color = { r = 0.0; g = 0.0; b = 0.0; a = 1.0 };
  stroke_width = 1.0;
  stroke_linecap = Butt;
  stroke_linejoin = Miter;
}

