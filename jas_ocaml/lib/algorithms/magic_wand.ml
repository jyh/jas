(* Magic Wand match predicate. See magic_wand.mli + MAGIC_WAND_TOOL.md
   §Predicate. *)

type config = {
  fill_color : bool;
  fill_tolerance : float;
  stroke_color : bool;
  stroke_tolerance : float;
  stroke_weight : bool;
  stroke_weight_tolerance : float;
  opacity : bool;
  opacity_tolerance : float;
  blending_mode : bool;
}

let default_config = {
  fill_color = true;
  fill_tolerance = 32.0;
  stroke_color = true;
  stroke_tolerance = 32.0;
  stroke_weight = true;
  stroke_weight_tolerance = 5.0;
  opacity = true;
  opacity_tolerance = 5.0;
  blending_mode = false;
}

(* Element accessors. Variants without fill / stroke / opacity report
   sensible defaults (no fill, no stroke, opacity 1.0) so the
   predicate can run on any element variant. *)
let fill_of (e : Element.element) : Element.fill option =
  match e with
  | Element.Rect { fill; _ }
  | Element.Circle { fill; _ }
  | Element.Ellipse { fill; _ }
  | Element.Polyline { fill; _ }
  | Element.Polygon { fill; _ }
  | Element.Path { fill; _ }
  | Element.Text { fill; _ }
  | Element.Text_path { fill; _ } -> fill
  | _ -> None

let stroke_of (e : Element.element) : Element.stroke option =
  match e with
  | Element.Line { stroke; _ }
  | Element.Rect { stroke; _ }
  | Element.Circle { stroke; _ }
  | Element.Ellipse { stroke; _ }
  | Element.Polyline { stroke; _ }
  | Element.Polygon { stroke; _ }
  | Element.Path { stroke; _ }
  | Element.Text { stroke; _ }
  | Element.Text_path { stroke; _ } -> stroke
  | _ -> None

let opacity_of (e : Element.element) : float =
  match e with
  | Element.Line { opacity; _ }
  | Element.Rect { opacity; _ }
  | Element.Circle { opacity; _ }
  | Element.Ellipse { opacity; _ }
  | Element.Polyline { opacity; _ }
  | Element.Polygon { opacity; _ }
  | Element.Path { opacity; _ }
  | Element.Text { opacity; _ }
  | Element.Text_path { opacity; _ }
  | Element.Group { opacity; _ }
  | Element.Layer { opacity; _ } -> opacity
  | _ -> 1.0

(* Euclidean RGB distance on the 0..255 scale. Inputs are
   [Element.color_to_rgba] outputs (R, G, B, A) in [0.0, 1.0]; we
   scale R, G, B to [0, 255] and ignore alpha — Fill / Stroke carry
   their own [opacity] field. *)
let rgb_distance (a : Element.color) (b : Element.color) : float =
  let (ar, ag, ab, _) = Element.color_to_rgba a in
  let (br, bg, bb, _) = Element.color_to_rgba b in
  let dr = (ar -. br) *. 255.0 in
  let dg = (ag -. bg) *. 255.0 in
  let db = (ab -. bb) *. 255.0 in
  sqrt (dr *. dr +. dg *. dg +. db *. db)

let fill_color_matches
    (seed : Element.fill option) (cand : Element.fill option)
    (tolerance : float) : bool =
  match seed, cand with
  | None, None -> true
  | Some s, Some c -> rgb_distance s.fill_color c.fill_color <= tolerance
  | _ -> false

let stroke_color_matches
    (seed : Element.stroke option) (cand : Element.stroke option)
    (tolerance : float) : bool =
  match seed, cand with
  | None, None -> true
  | Some s, Some c ->
    rgb_distance s.stroke_color c.stroke_color <= tolerance
  | _ -> false

let stroke_weight_matches
    (seed : Element.stroke option) (cand : Element.stroke option)
    (tolerance : float) : bool =
  match seed, cand with
  | None, None -> true
  | Some s, Some c -> Float.abs (s.stroke_width -. c.stroke_width) <= tolerance
  | _ -> false

let opacity_matches (seed : float) (cand : float) (tolerance : float) : bool =
  Float.abs (seed -. cand) *. 100.0 <= tolerance

let blending_mode_matches
    (seed : Element.blend_mode) (cand : Element.blend_mode) : bool =
  seed = cand

let magic_wand_match
    (seed : Element.element) (candidate : Element.element)
    (cfg : config) : bool =
  let any_enabled =
    cfg.fill_color || cfg.stroke_color || cfg.stroke_weight
    || cfg.opacity || cfg.blending_mode
  in
  if not any_enabled then false
  else if cfg.fill_color
       && not (fill_color_matches (fill_of seed) (fill_of candidate)
                 cfg.fill_tolerance)
  then false
  else if cfg.stroke_color
       && not (stroke_color_matches (stroke_of seed) (stroke_of candidate)
                 cfg.stroke_tolerance)
  then false
  else if cfg.stroke_weight
       && not (stroke_weight_matches (stroke_of seed) (stroke_of candidate)
                 cfg.stroke_weight_tolerance)
  then false
  else if cfg.opacity
       && not (opacity_matches (opacity_of seed) (opacity_of candidate)
                 cfg.opacity_tolerance)
  then false
  else if cfg.blending_mode
       && not (blending_mode_matches
                 (Element.get_blend_mode seed)
                 (Element.get_blend_mode candidate))
  then false
  else true
