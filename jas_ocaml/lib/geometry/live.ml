(** LiveElement framework helpers — port of jas_dioxus live.rs.
    See [transcripts/BOOLEAN.md] § Live element framework. *)

open Element

let default_precision = 0.0283

(** Compute the number of segments required to approximate a circle
    of the given radius so the max perpendicular distance between
    the polyline and the arc is at most [precision]. *)
let segments_for_arc radius precision =
  if radius <= 0.0 || precision <= 0.0 then 32
  else
    let n = Float.pi *. sqrt (radius /. (2.0 *. precision)) in
    max 8 (int_of_float (Float.ceil n))

let circle_to_ring cx cy r precision =
  let n = segments_for_arc r precision in
  Array.init n (fun i ->
    let theta = 2.0 *. Float.pi *. float_of_int i /. float_of_int n in
    (cx +. r *. cos theta, cy +. r *. sin theta))

let ellipse_to_ring cx cy rx ry precision =
  let n = segments_for_arc (max rx ry) precision in
  Array.init n (fun i ->
    let theta = 2.0 *. Float.pi *. float_of_int i /. float_of_int n in
    (cx +. rx *. cos theta, cy +. ry *. sin theta))

(** Flatten path commands into one ring per subpath. MoveTo starts a
    new ring; ClosePath finalizes the current ring. Open subpaths are
    finalized at the next MoveTo or end of commands. Rings with fewer
    than 3 points are dropped. FLATTEN_STEPS = 20; matches the
    pre-existing path-flattening in this library. *)
let flatten_path_to_rings d =
  let steps = 20 in
  let rings = ref [] in
  let cur = ref [] in
  let cx = ref 0.0 in
  let cy = ref 0.0 in
  let flush () =
    match !cur with
    | pts when List.length pts >= 3 ->
      rings := (Array.of_list (List.rev pts)) :: !rings;
      cur := []
    | _ -> cur := []
  in
  List.iter (function
    | MoveTo (x, y) ->
      flush ();
      cur := (x, y) :: !cur;
      cx := x; cy := y
    | LineTo (x, y) ->
      cur := (x, y) :: !cur;
      cx := x; cy := y
    | CurveTo (x1, y1, x2, y2, x, y) ->
      let sx, sy = !cx, !cy in
      for i = 1 to steps do
        let t = float_of_int i /. float_of_int steps in
        let mt = 1.0 -. t in
        let px = mt ** 3.0 *. sx
                 +. 3.0 *. mt ** 2.0 *. t *. x1
                 +. 3.0 *. mt *. t ** 2.0 *. x2
                 +. t ** 3.0 *. x in
        let py = mt ** 3.0 *. sy
                 +. 3.0 *. mt ** 2.0 *. t *. y1
                 +. 3.0 *. mt *. t ** 2.0 *. y2
                 +. t ** 3.0 *. y in
        cur := (px, py) :: !cur
      done;
      cx := x; cy := y
    | QuadTo (x1, y1, x, y) ->
      let sx, sy = !cx, !cy in
      for i = 1 to steps do
        let t = float_of_int i /. float_of_int steps in
        let mt = 1.0 -. t in
        let px = mt ** 2.0 *. sx +. 2.0 *. mt *. t *. x1 +. t ** 2.0 *. x in
        let py = mt ** 2.0 *. sy +. 2.0 *. mt *. t *. y1 +. t ** 2.0 *. y in
        cur := (px, py) :: !cur
      done;
      cx := x; cy := y
    | ClosePath -> flush ()
    | SmoothCurveTo (_, _, x, y)
    | SmoothQuadTo (x, y)
    | ArcTo (_, _, _, _, _, x, y) ->
      (* Approximate as line-to-endpoint, matching the existing
         flatten_path_commands behavior. *)
      cur := (x, y) :: !cur;
      cx := x; cy := y
  ) d;
  flush ();
  List.rev !rings

let rec element_to_polygon_set elem precision =
  match elem with
  | Rect { x; y; width; height; _ } ->
    [| (x, y); (x +. width, y); (x +. width, y +. height); (x, y +. height) |]
    :: []
  | Polygon { points; _ } ->
    if points = [] then []
    else [Array.of_list points]
  | Polyline { points; _ } ->
    (* Implicitly closed for even-odd fill. *)
    if points = [] then []
    else [Array.of_list points]
  | Circle { cx; cy; r; _ } -> [circle_to_ring cx cy r precision]
  | Ellipse { cx; cy; rx; ry; _ } -> [ellipse_to_ring cx cy rx ry precision]
  | Group { children; _ } | Layer { children; _ } ->
    Array.fold_left (fun acc child ->
      acc @ element_to_polygon_set child precision
    ) [] children
  | Live (Compound_shape cs) -> evaluate cs precision
  | Path { d; _ } | Text_path { d; _ } -> flatten_path_to_rings d
  (* Line has zero area; Text glyph flattening deferred. *)
  | Line _ | Text _ -> []

and apply_operation op operand_sets =
  match op, operand_sets with
  | _, [] -> []
  | Op_union, first :: rest ->
    List.fold_left Boolean.boolean_union first rest
  | Op_intersection, first :: rest ->
    List.fold_left Boolean.boolean_intersect first rest
  | Op_subtract_front, [x] -> x
  | Op_subtract_front, operands ->
    let rec split_last acc = function
      | [] -> failwith "impossible"
      | [x] -> List.rev acc, x
      | x :: xs -> split_last (x :: acc) xs
    in
    let survivors, cutter = split_last [] operands in
    List.fold_left (fun acc s ->
      Boolean.boolean_union acc (Boolean.boolean_subtract s cutter)
    ) [] survivors
  | Op_exclude, first :: rest ->
    List.fold_left Boolean.boolean_exclude first rest

and evaluate cs precision =
  let operand_sets =
    Array.to_list cs.operands
    |> List.map (fun op -> element_to_polygon_set op precision)
  in
  apply_operation cs.operation operand_sets

(** Replace a compound shape with one Polygon per ring of the
    evaluated geometry. Each output polygon carries the compound
    shape's own fill / stroke / common props; the operand tree is
    discarded. Rings with fewer than 3 points are dropped. See
    BOOLEAN.md § Expand and Release semantics. *)
let expand (cs : compound_shape) precision : element list =
  let ps = evaluate cs precision in
  List.filter_map (fun ring ->
    if Array.length ring < 3 then None
    else
      let points = Array.to_list ring in
      Some (Polygon {
        points;
        fill = cs.fill;
        stroke = cs.stroke;
        opacity = cs.opacity;
        transform = cs.transform;
        locked = cs.locked;
        visibility = cs.visibility;
        blend_mode = cs.blend_mode;
      })
  ) ps

(** Inverse of Make. Returns the operands unchanged. Each operand
    keeps its own paint; the compound shape's paint is discarded. *)
let release (cs : compound_shape) : element array = cs.operands

let bounds_of_polygon_set ps =
  let min_x = ref infinity in
  let min_y = ref infinity in
  let max_x = ref neg_infinity in
  let max_y = ref neg_infinity in
  List.iter (fun ring ->
    Array.iter (fun (x, y) ->
      if x < !min_x then min_x := x;
      if y < !min_y then min_y := y;
      if x > !max_x then max_x := x;
      if y > !max_y then max_y := y
    ) ring
  ) ps;
  if not (Float.is_finite !min_x) then (0.0, 0.0, 0.0, 0.0)
  else (!min_x, !min_y, !max_x -. !min_x, !max_y -. !min_y)

(** Set the hook at module init time so Element.bounds can compute
    Live bounds without a cycle. *)
let () =
  Element.live_bounds_hook := (fun lv ->
    match lv with
    | Compound_shape cs ->
      bounds_of_polygon_set (evaluate cs default_precision))
