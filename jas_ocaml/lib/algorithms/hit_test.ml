(** Geometry helpers for precise hit-testing.

    Pure-geometry functions used by the controller for marquee selection,
    element intersection tests, and control-point queries.  These do not
    depend on the document model -- only on element geometry. *)

(* ------------------------------------------------------------------ *)
(* Primitive geometry                                                  *)
(* ------------------------------------------------------------------ *)

let point_in_rect px py rx ry rw rh =
  rx <= px && px <= rx +. rw && ry <= py && py <= ry +. rh

let cross ox oy ax ay bx by =
  (ax -. ox) *. (by -. oy) -. (ay -. oy) *. (bx -. ox)

let on_segment px1 py1 px2 py2 qx qy =
  min px1 px2 <= qx && qx <= max px1 px2 &&
  min py1 py2 <= qy && qy <= max py1 py2

let segments_intersect ax1 ay1 ax2 ay2 bx1 by1 bx2 by2 =
  let d1 = cross bx1 by1 bx2 by2 ax1 ay1 in
  let d2 = cross bx1 by1 bx2 by2 ax2 ay2 in
  let d3 = cross ax1 ay1 ax2 ay2 bx1 by1 in
  let d4 = cross ax1 ay1 ax2 ay2 bx2 by2 in
  if ((d1 > 0.0 && d2 < 0.0) || (d1 < 0.0 && d2 > 0.0)) &&
     ((d3 > 0.0 && d4 < 0.0) || (d3 < 0.0 && d4 > 0.0)) then true
  else let eps = 1e-10 in
  if abs_float d1 < eps && on_segment bx1 by1 bx2 by2 ax1 ay1 then true
  else if abs_float d2 < eps && on_segment bx1 by1 bx2 by2 ax2 ay2 then true
  else if abs_float d3 < eps && on_segment ax1 ay1 ax2 ay2 bx1 by1 then true
  else if abs_float d4 < eps && on_segment ax1 ay1 ax2 ay2 bx2 by2 then true
  else false

let segment_intersects_rect x1 y1 x2 y2 rx ry rw rh =
  if point_in_rect x1 y1 rx ry rw rh then true
  else if point_in_rect x2 y2 rx ry rw rh then true
  else
    let edges = [
      (rx, ry, rx +. rw, ry);
      (rx +. rw, ry, rx +. rw, ry +. rh);
      (rx +. rw, ry +. rh, rx, ry +. rh);
      (rx, ry +. rh, rx, ry);
    ] in
    List.exists (fun (ex1, ey1, ex2, ey2) ->
      segments_intersect x1 y1 x2 y2 ex1 ey1 ex2 ey2
    ) edges

let rects_intersect ax ay aw ah bx by bw bh =
  ax < bx +. bw && ax +. aw > bx && ay < by +. bh && ay +. ah > by

let circle_intersects_rect cx cy r rx ry rw rh filled =
  let closest_x = max rx (min cx (rx +. rw)) in
  let closest_y = max ry (min cy (ry +. rh)) in
  let dist_sq = (cx -. closest_x) ** 2.0 +. (cy -. closest_y) ** 2.0 in
  if not filled then
    let corners = [(rx, ry); (rx +. rw, ry); (rx +. rw, ry +. rh); (rx, ry +. rh)] in
    let max_dist_sq = List.fold_left (fun acc (cx2, cy2) ->
      max acc ((cx -. cx2) ** 2.0 +. (cy -. cy2) ** 2.0)
    ) 0.0 corners in
    dist_sq <= r *. r && r *. r <= max_dist_sq
  else
    dist_sq <= r *. r

let ellipse_intersects_rect cx cy erx ery rx ry rw rh filled =
  if erx = 0.0 || ery = 0.0 then false
  else circle_intersects_rect (cx /. erx) (cy /. ery) 1.0
    (rx /. erx) (ry /. ery) (rw /. erx) (rh /. ery) filled

(* ------------------------------------------------------------------ *)
(* Element-level queries                                               *)
(* ------------------------------------------------------------------ *)

let segments_of_element (elem : Element.element) =
  let open Element in
  match elem with
  | Line { x1; y1; x2; y2; _ } -> [(x1, y1, x2, y2)]
  | Rect { x; y; width; height; _ } ->
    [(x, y, x +. width, y); (x +. width, y, x +. width, y +. height);
     (x +. width, y +. height, x, y +. height); (x, y +. height, x, y)]
  | Polyline { points; _ } ->
    let rec pairs = function
      | [] | [_] -> []
      | (x1, y1) :: ((x2, y2) :: _ as rest) -> (x1, y1, x2, y2) :: pairs rest
    in
    pairs points
  | Polygon { points; _ } ->
    (match points with
     | [] -> []
     | _ ->
       let rec pairs = function
         | [] | [_] -> []
         | (x1, y1) :: ((x2, y2) :: _ as rest) -> (x1, y1, x2, y2) :: pairs rest
       in
       let segs = pairs points in
       let (lx, ly) = List.nth points (List.length points - 1) in
       let (fx, fy) = List.hd points in
       segs @ [(lx, ly, fx, fy)])
  | Path { d; _ } ->
    let pts = Element.flatten_path_commands d in
    let rec pairs = function
      | [] | [_] -> []
      | (x1, y1) :: ((x2, y2) :: _ as rest) -> (x1, y1, x2, y2) :: pairs rest
    in
    pairs pts
  | _ -> []

let all_cps elem = List.init (Element.control_point_count elem) Fun.id

(* ------------------------------------------------------------------ *)
(* Polygon geometry                                                    *)
(* ------------------------------------------------------------------ *)

let point_in_polygon px py poly =
  let n = Array.length poly in
  if n < 3 then false
  else
    let inside = ref false in
    let j = ref (n - 1) in
    for i = 0 to n - 1 do
      let (xi, yi) = poly.(i) in
      let (xj, yj) = poly.(!j) in
      if ((yi > py) <> (yj > py)) && (px < (xj -. xi) *. (py -. yi) /. (yj -. yi) +. xi) then
        inside := not !inside;
      j := i
    done;
    !inside

let segment_intersects_polygon x1 y1 x2 y2 poly =
  if point_in_polygon x1 y1 poly || point_in_polygon x2 y2 poly then true
  else
    let n = Array.length poly in
    let found = ref false in
    for i = 0 to n - 1 do
      let j = (i + 1) mod n in
      if segments_intersect x1 y1 x2 y2
           (fst poly.(i)) (snd poly.(i)) (fst poly.(j)) (snd poly.(j)) then
        found := true
    done;
    !found

(* ------------------------------------------------------------------ *)
(* Transform-aware element hit-testing                                 *)
(* ------------------------------------------------------------------ *)

let rec element_intersects_rect (elem : Element.element) rx ry rw rh =
  match Element.transform_of elem with
  | Some t ->
    (match Element.inverse t with
     | None -> false
     | Some inv ->
       let corners = [|
         Element.apply_point inv rx ry;
         Element.apply_point inv (rx +. rw) ry;
         Element.apply_point inv (rx +. rw) (ry +. rh);
         Element.apply_point inv rx (ry +. rh);
       |] in
       element_intersects_polygon_local elem corners)
  | None -> element_intersects_rect_local elem rx ry rw rh

and element_intersects_rect_local (elem : Element.element) rx ry rw rh =
  let open Element in
  match elem with
  | Line { x1; y1; x2; y2; _ } ->
    segment_intersects_rect x1 y1 x2 y2 rx ry rw rh
  | Rect { x; y; width; height; fill; _ } ->
    if fill <> None then
      rects_intersect x y width height rx ry rw rh
    else
      List.exists (fun (sx1, sy1, sx2, sy2) ->
        segment_intersects_rect sx1 sy1 sx2 sy2 rx ry rw rh
      ) (segments_of_element elem)
  | Circle { cx; cy; r; fill; _ } ->
    circle_intersects_rect cx cy r rx ry rw rh (fill <> None)
  | Ellipse { cx; cy; rx = erx; ry = ery; fill; _ } ->
    ellipse_intersects_rect cx cy erx ery rx ry rw rh (fill <> None)
  | Polyline { fill; _ } ->
    if fill <> None then
      let (bx, by, bw, bh) = Element.bounds elem in
      rects_intersect bx by bw bh rx ry rw rh
    else
      List.exists (fun (sx1, sy1, sx2, sy2) ->
        segment_intersects_rect sx1 sy1 sx2 sy2 rx ry rw rh
      ) (segments_of_element elem)
  | Polygon { points; fill; _ } ->
    if fill <> None then
      List.exists (fun (px, py) -> point_in_rect px py rx ry rw rh) points ||
      List.exists (fun (sx1, sy1, sx2, sy2) ->
        segment_intersects_rect sx1 sy1 sx2 sy2 rx ry rw rh
      ) (segments_of_element elem)
    else
      List.exists (fun (sx1, sy1, sx2, sy2) ->
        segment_intersects_rect sx1 sy1 sx2 sy2 rx ry rw rh
      ) (segments_of_element elem)
  | Path { fill; _ } ->
    let segs = segments_of_element elem in
    if fill <> None then
      let endpoints = List.concat_map (fun (sx1, sy1, sx2, sy2) ->
        [(sx1, sy1); (sx2, sy2)]
      ) segs in
      List.exists (fun (px, py) -> point_in_rect px py rx ry rw rh) endpoints ||
      List.exists (fun (sx1, sy1, sx2, sy2) ->
        segment_intersects_rect sx1 sy1 sx2 sy2 rx ry rw rh
      ) segs
    else
      List.exists (fun (sx1, sy1, sx2, sy2) ->
        segment_intersects_rect sx1 sy1 sx2 sy2 rx ry rw rh
      ) segs
  | Text _ ->
    let (bx, by, bw, bh) = Element.bounds elem in
    rects_intersect bx by bw bh rx ry rw rh
  | _ ->
    let (bx, by, bw, bh) = Element.bounds elem in
    rects_intersect bx by bw bh rx ry rw rh

and element_intersects_polygon (elem : Element.element) poly =
  match Element.transform_of elem with
  | Some t ->
    (match Element.inverse t with
     | None -> false
     | Some inv ->
       let local_poly = Array.map (fun (x, y) -> Element.apply_point inv x y) poly in
       element_intersects_polygon_local elem local_poly)
  | None -> element_intersects_polygon_local elem poly

and element_intersects_polygon_local (elem : Element.element) poly =
  let open Element in
  match elem with
  | Line { x1; y1; x2; y2; _ } ->
    segment_intersects_polygon x1 y1 x2 y2 poly
  | Rect { x; y; width; height; fill; _ } ->
    if fill <> None then begin
      let corners = [| (x, y); (x +. width, y);
                       (x +. width, y +. height); (x, y +. height) |] in
      if Array.exists (fun (cx, cy) -> point_in_polygon cx cy poly) corners then true
      else if Array.exists (fun (px, py) -> point_in_rect px py x y width height) poly then true
      else List.exists (fun (sx1, sy1, sx2, sy2) ->
        segment_intersects_polygon sx1 sy1 sx2 sy2 poly
      ) (segments_of_element elem)
    end else
      List.exists (fun (sx1, sy1, sx2, sy2) ->
        segment_intersects_polygon sx1 sy1 sx2 sy2 poly
      ) (segments_of_element elem)
  | Text _ | Group _ | Layer _ ->
    let (bx, by, bw, bh) = Element.bounds elem in
    let corners = [| (bx, by); (bx +. bw, by);
                     (bx +. bw, by +. bh); (bx, by +. bh) |] in
    if Array.exists (fun (cx, cy) -> point_in_polygon cx cy poly) corners then true
    else if Array.exists (fun (px, py) -> point_in_rect px py bx by bw bh) poly then true
    else
      let rect_segs = [
        (bx, by, bx +. bw, by); (bx +. bw, by, bx +. bw, by +. bh);
        (bx +. bw, by +. bh, bx, by +. bh); (bx, by +. bh, bx, by)
      ] in
      List.exists (fun (sx1, sy1, sx2, sy2) ->
        segment_intersects_polygon sx1 sy1 sx2 sy2 poly
      ) rect_segs
  | _ ->
    let (bx, by, bw, bh) = Element.bounds elem in
    let corners = [| (bx, by); (bx +. bw, by);
                     (bx +. bw, by +. bh); (bx, by +. bh) |] in
    if Array.exists (fun (cx, cy) -> point_in_polygon cx cy poly) corners then true
    else if Array.exists (fun (px, py) -> point_in_rect px py bx by bw bh) poly then true
    else
      let rect_segs = [
        (bx, by, bx +. bw, by); (bx +. bw, by, bx +. bw, by +. bh);
        (bx +. bw, by +. bh, bx, by +. bh); (bx, by +. bh, bx, by)
      ] in
      List.exists (fun (sx1, sy1, sx2, sy2) ->
        segment_intersects_polygon sx1 sy1 sx2 sy2 poly
      ) rect_segs
