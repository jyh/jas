(** Immutable document elements conforming to SVG element types.

    All elements are immutable value types. Element types and attributes
    follow the SVG 1.1 specification. *)

(** Line segments per Bezier curve when flattening paths. *)
let flatten_steps = 20

(** RGBA color with components in [0, 1]. *)
type color = {
  r : float;
  g : float;
  b : float;
  a : float;
}

(** SVG stroke-linecap. *)
type linecap =
  | Butt
  | Round_cap
  | Square

(** SVG stroke-linejoin. *)
type linejoin =
  | Miter
  | Round_join
  | Bevel

(** SVG fill presentation attribute. *)
type fill = {
  fill_color : color;
}

(** SVG stroke presentation attributes. *)
type stroke = {
  stroke_color : color;
  stroke_width : float;
  stroke_linecap : linecap;
  stroke_linejoin : linejoin;
}

(** SVG transform as a 2D affine matrix [a b c d e f]. *)
type transform = {
  a : float;
  b : float;
  c : float;
  d : float;
  e : float;
  f : float;
}

(** SVG path commands (the 'd' attribute). *)
type path_command =
  | MoveTo of float * float                                       (** M x y *)
  | LineTo of float * float                                       (** L x y *)
  | CurveTo of float * float * float * float * float * float      (** C x1 y1 x2 y2 x y *)
  | SmoothCurveTo of float * float * float * float                (** S x2 y2 x y *)
  | QuadTo of float * float * float * float                       (** Q x1 y1 x y *)
  | SmoothQuadTo of float * float                                 (** T x y *)
  | ArcTo of float * float * float * bool * bool * float * float  (** A rx ry rot large sweep x y *)
  | ClosePath                                                     (** Z *)

(** SVG element types. All elements are immutable. *)
type element =
  | Line of {
      x1 : float; y1 : float;
      x2 : float; y2 : float;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
    }
  | Rect of {
      x : float; y : float;
      width : float; height : float;
      rx : float; ry : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
    }
  | Circle of {
      cx : float; cy : float; r : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
    }
  | Ellipse of {
      cx : float; cy : float;
      rx : float; ry : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
    }
  | Polyline of {
      points : (float * float) list;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
    }
  | Polygon of {
      points : (float * float) list;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
    }
  | Path of {
      d : path_command list;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
    }
  | Text of {
      x : float; y : float;
      content : string;
      font_family : string;
      font_size : float;
      font_weight : string;
      font_style : string;
      text_decoration : string;
      text_width : float;
      text_height : float;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
    }
  | Text_path of {
      d : path_command list;
      content : string;
      start_offset : float;
      font_family : string;
      font_size : float;
      font_weight : string;
      font_style : string;
      text_decoration : string;
      fill : fill option;
      stroke : stroke option;
      opacity : float;
      transform : transform option;
      locked : bool;
    }
  | Group of {
      children : element array;
      opacity : float;
      transform : transform option;
      locked : bool;
    }
  | Layer of {
      name : string;
      children : element array;
      opacity : float;
      transform : transform option;
      locked : bool;
    }

(** Expand a bounding box by half the stroke width on all sides. *)
let inflate_bounds (bx, by, bw, bh) stroke =
  match stroke with
  | None -> (bx, by, bw, bh)
  | Some { stroke_width; _ } ->
    let half = stroke_width /. 2.0 in
    (bx -. half, by -. half, bw +. stroke_width, bh +. stroke_width)

let path_cmd_bounds cmds =
  let collect_endpoints =
    List.fold_left (fun (xs, ys) cmd ->
      match cmd with
      | MoveTo (x, y) | LineTo (x, y) | SmoothQuadTo (x, y) ->
        (x :: xs, y :: ys)
      | CurveTo (x1, y1, x2, y2, x, y) ->
        (x1 :: x2 :: x :: xs, y1 :: y2 :: y :: ys)
      | SmoothCurveTo (x2, y2, x, y) ->
        (x2 :: x :: xs, y2 :: y :: ys)
      | QuadTo (x1, y1, x, y) ->
        (x1 :: x :: xs, y1 :: y :: ys)
      | ArcTo (_, _, _, _, _, x, y) ->
        (x :: xs, y :: ys)
      | ClosePath -> (xs, ys)
    ) ([], [])
  in
  let (xs, ys) = collect_endpoints cmds in
  match xs, ys with
  | [], [] -> (0.0, 0.0, 0.0, 0.0)
  | _ ->
    let min_f = List.fold_left min infinity in
    let max_f = List.fold_left max neg_infinity in
    let min_x = min_f xs and min_y = min_f ys in
    (min_x, min_y, max_f xs -. min_x, max_f ys -. min_y)

(** Return the bounding box as (x, y, width, height). *)
let rec bounds = function
  | Line { x1; y1; x2; y2; stroke; _ } ->
    let min_x = min x1 x2 in
    let min_y = min y1 y2 in
    inflate_bounds (min_x, min_y, abs_float (x2 -. x1), abs_float (y2 -. y1)) stroke
  | Rect { x; y; width; height; stroke; _ } ->
    inflate_bounds (x, y, width, height) stroke
  | Circle { cx; cy; r; stroke; _ } ->
    inflate_bounds (cx -. r, cy -. r, r *. 2.0, r *. 2.0) stroke
  | Ellipse { cx; cy; rx; ry; stroke; _ } ->
    inflate_bounds (cx -. rx, cy -. ry, rx *. 2.0, ry *. 2.0) stroke
  | Polyline { points; stroke; _ } ->
    begin match points with
    | [] -> (0.0, 0.0, 0.0, 0.0)
    | _ ->
      let xs = List.map fst points in
      let ys = List.map snd points in
      let min_f = List.fold_left min infinity in
      let max_f = List.fold_left max neg_infinity in
      let min_x = min_f xs and min_y = min_f ys in
      inflate_bounds (min_x, min_y, max_f xs -. min_x, max_f ys -. min_y) stroke
    end
  | Polygon { points; stroke; _ } ->
    begin match points with
    | [] -> (0.0, 0.0, 0.0, 0.0)
    | _ ->
      let xs = List.map fst points in
      let ys = List.map snd points in
      let min_f = List.fold_left min infinity in
      let max_f = List.fold_left max neg_infinity in
      let min_x = min_f xs and min_y = min_f ys in
      inflate_bounds (min_x, min_y, max_f xs -. min_x, max_f ys -. min_y) stroke
    end
  | Path { d; stroke; _ } ->
    inflate_bounds (path_cmd_bounds d) stroke
  | Text_path { d; stroke; _ } ->
    inflate_bounds (path_cmd_bounds d) stroke
  | Text { x; y; content; font_size; text_width; text_height; _ } ->
    if text_width > 0.0 && text_height > 0.0 then
      (x, y, text_width, text_height)
    else
      let approx_width = float_of_int (String.length content) *. font_size *. 0.6 in
      (x, y -. font_size, approx_width, font_size)
  | Group { children; _ } | Layer { children; _ } ->
    if Array.length children = 0 then (0.0, 0.0, 0.0, 0.0)
    else
      let all_bounds = Array.map bounds children in
      let min_x = Array.fold_left (fun acc (x, _, _, _) -> min acc x) infinity all_bounds in
      let min_y = Array.fold_left (fun acc (_, y, _, _) -> min acc y) infinity all_bounds in
      let max_x = Array.fold_left (fun acc (x, _, w, _) -> max acc (x +. w)) neg_infinity all_bounds in
      let max_y = Array.fold_left (fun acc (_, y, _, h) -> max acc (y +. h)) neg_infinity all_bounds in
      (min_x, min_y, max_x -. min_x, max_y -. min_y)

(** Helper constructors. *)

let make_color ?(a = 1.0) r g b = { r; g; b; a }

let make_fill color = { fill_color = color }

let make_stroke ?(width = 1.0) ?(linecap = Butt) ?(linejoin = Miter) color =
  { stroke_color = color; stroke_width = width; stroke_linecap = linecap; stroke_linejoin = linejoin }

let identity_transform = { a = 1.0; b = 0.0; c = 0.0; d = 1.0; e = 0.0; f = 0.0 }

let make_translate tx ty = { identity_transform with e = tx; f = ty }

let make_scale sx sy = { identity_transform with a = sx; d = sy }

let make_rotate angle_deg =
  let rad = angle_deg *. Float.pi /. 180.0 in
  { identity_transform with a = cos rad; b = sin rad; c = -. sin rad; d = cos rad }

let make_line ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) x1 y1 x2 y2 =
  Line { x1; y1; x2; y2; stroke; opacity; transform; locked }

let make_rect ?(rx = 0.0) ?(ry = 0.0) ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) x y width height =
  Rect { x; y; width; height; rx; ry; fill; stroke; opacity; transform; locked }

let make_circle ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) cx cy r =
  Circle { cx; cy; r; fill; stroke; opacity; transform; locked }

let make_ellipse ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) cx cy rx ry =
  Ellipse { cx; cy; rx; ry; fill; stroke; opacity; transform; locked }

let make_polyline ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) points =
  Polyline { points; fill; stroke; opacity; transform; locked }

let make_polygon ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) points =
  Polygon { points; fill; stroke; opacity; transform; locked }

let make_path ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) d =
  Path { d; fill; stroke; opacity; transform; locked }

let make_text ?(font_family = "sans-serif") ?(font_size = 16.0) ?(font_weight = "normal") ?(font_style = "normal") ?(text_decoration = "none") ?(text_width = 0.0) ?(text_height = 0.0) ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) x y content =
  Text { x; y; content; font_family; font_size; font_weight; font_style; text_decoration; text_width; text_height; fill; stroke; opacity; transform; locked }

let make_text_path ?(start_offset = 0.0) ?(font_family = "sans-serif") ?(font_size = 16.0) ?(font_weight = "normal") ?(font_style = "normal") ?(text_decoration = "none") ?(fill = None) ?(stroke = None) ?(opacity = 1.0) ?(transform = None) ?(locked = false) d content =
  Text_path { d; content; start_offset; font_family; font_size; font_weight; font_style; text_decoration; fill; stroke; opacity; transform; locked }

let make_group ?(opacity = 1.0) ?(transform = None) ?(locked = false) children =
  Group { children; opacity; transform; locked }

let make_layer ?(name = "Layer") ?(opacity = 1.0) ?(transform = None) ?(locked = false) children =
  Layer { name; children; opacity; transform; locked }

let is_locked = function
  | Line { locked; _ } | Rect { locked; _ } | Circle { locked; _ }
  | Ellipse { locked; _ } | Polyline { locked; _ } | Polygon { locked; _ }
  | Path { locked; _ } | Text { locked; _ } | Text_path { locked; _ }
  | Group { locked; _ } | Layer { locked; _ } -> locked

let set_locked v = function
  | Line r -> Line { r with locked = v }
  | Rect r -> Rect { r with locked = v }
  | Circle r -> Circle { r with locked = v }
  | Ellipse r -> Ellipse { r with locked = v }
  | Polyline r -> Polyline { r with locked = v }
  | Polygon r -> Polygon { r with locked = v }
  | Path r -> Path { r with locked = v }
  | Text r -> Text { r with locked = v }
  | Text_path r -> Text_path { r with locked = v }
  | Group r -> Group { r with locked = v }
  | Layer r -> Layer { r with locked = v }

let path_anchor_points d =
  List.fold_left (fun acc cmd ->
    match cmd with
    | MoveTo (x, y) | LineTo (x, y) | SmoothQuadTo (x, y) -> (x, y) :: acc
    | CurveTo (_, _, _, _, x, y) | SmoothCurveTo (_, _, x, y) -> (x, y) :: acc
    | QuadTo (_, _, x, y) -> (x, y) :: acc
    | ArcTo (_, _, _, _, _, x, y) -> (x, y) :: acc
    | ClosePath -> acc
  ) [] d |> List.rev

let path_handle_positions d anchor_idx =
  (* Map anchor indices to command indices (skip ClosePath) *)
  let cmd_arr = Array.of_list d in
  let n = Array.length cmd_arr in
  let cmd_indices = Array.make n 0 in
  let count = ref 0 in
  for ci = 0 to n - 1 do
    match cmd_arr.(ci) with
    | ClosePath -> ()
    | _ -> cmd_indices.(!count) <- ci; incr count
  done;
  if anchor_idx < 0 || anchor_idx >= !count then (None, None)
  else begin
    let ci = cmd_indices.(anchor_idx) in
    let cmd = cmd_arr.(ci) in
    let anchor = match cmd with
      | MoveTo (x, y) | LineTo (x, y) -> Some (x, y)
      | CurveTo (_, _, _, _, x, y) -> Some (x, y)
      | _ -> None
    in
    match anchor with
    | None -> (None, None)
    | Some (ax, ay) ->
      let h_in = match cmd with
        | CurveTo (_, _, x2, y2, _, _) ->
          if abs_float (x2 -. ax) > 0.01 || abs_float (y2 -. ay) > 0.01
          then Some (x2, y2) else None
        | _ -> None
      in
      let h_out =
        if ci + 1 < n then
          match cmd_arr.(ci + 1) with
          | CurveTo (x1, y1, _, _, _, _) ->
            if abs_float (x1 -. ax) > 0.01 || abs_float (y1 -. ay) > 0.01
            then Some (x1, y1) else None
          | _ -> None
        else None
      in
      (h_in, h_out)
  end

let reflect_handle_keep_distance ax ay nhx nhy opp_hx opp_hy =
  let dnx = nhx -. ax in
  let dny = nhy -. ay in
  let dist_new = sqrt (dnx *. dnx +. dny *. dny) in
  let dist_opp = sqrt ((opp_hx -. ax) *. (opp_hx -. ax) +. (opp_hy -. ay) *. (opp_hy -. ay)) in
  if dist_new < 1e-6 then (opp_hx, opp_hy)
  else
    let scale = -. dist_opp /. dist_new in
    (ax +. dnx *. scale, ay +. dny *. scale)

let move_path_handle d anchor_idx handle_type dx dy =
  let cmd_arr = Array.of_list d in
  let n = Array.length cmd_arr in
  let cmd_indices = Array.make n 0 in
  let count = ref 0 in
  for ci = 0 to n - 1 do
    match cmd_arr.(ci) with
    | ClosePath -> ()
    | _ -> cmd_indices.(!count) <- ci; incr count
  done;
  if anchor_idx < 0 || anchor_idx >= !count then d
  else begin
    let ci = cmd_indices.(anchor_idx) in
    let cmd = cmd_arr.(ci) in
    (* Get anchor position *)
    let anchor = match cmd with
      | MoveTo (x, y) | LineTo (x, y) -> Some (x, y)
      | CurveTo (_, _, _, _, x, y) -> Some (x, y)
      | _ -> None
    in
    (match anchor with
     | None -> ()
     | Some (ax, ay) ->
       if handle_type = "in" then begin
         match cmd with
         | CurveTo (x1, y1, x2, y2, x, y) ->
           let nhx = x2 +. dx in
           let nhy = y2 +. dy in
           cmd_arr.(ci) <- CurveTo (x1, y1, nhx, nhy, x, y);
           (* Rotate opposite (out) handle to stay collinear, keep its distance *)
           if ci + 1 < n then
             (match cmd_arr.(ci + 1) with
              | CurveTo (ox1, oy1, nx2, ny2, nx, ny) ->
                let (rx, ry) = reflect_handle_keep_distance ax ay nhx nhy ox1 oy1 in
                cmd_arr.(ci + 1) <- CurveTo (rx, ry, nx2, ny2, nx, ny)
              | _ -> ())
         | _ -> ()
       end else if handle_type = "out" then begin
         if ci + 1 < n then
           match cmd_arr.(ci + 1) with
           | CurveTo (x1, y1, x2, y2, x, y) ->
             let nhx = x1 +. dx in
             let nhy = y1 +. dy in
             cmd_arr.(ci + 1) <- CurveTo (nhx, nhy, x2, y2, x, y);
             (* Rotate opposite (in) handle to stay collinear, keep its distance *)
             (match cmd with
              | CurveTo (cx1, cy1, cx2, cy2, cx, cy) ->
                let (rx, ry) = reflect_handle_keep_distance ax ay nhx nhy cx2 cy2 in
                cmd_arr.(ci) <- CurveTo (cx1, cy1, rx, ry, cx, cy)
              | _ -> ())
           | _ -> ()
       end);
    Array.to_list cmd_arr
  end

let control_point_count = function
  | Line _ -> 2
  | Rect _ | Circle _ | Ellipse _ -> 4
  | Polygon { points; _ } -> List.length points
  | Path { d; _ } | Text_path { d; _ } -> List.length (path_anchor_points d)
  | _ -> 4

let control_points = function
  | Line { x1; y1; x2; y2; _ } -> [(x1, y1); (x2, y2)]
  | Rect { x; y; width; height; _ } ->
    [(x, y); (x +. width, y); (x +. width, y +. height); (x, y +. height)]
  | Circle { cx; cy; r; _ } ->
    [(cx, cy -. r); (cx +. r, cy); (cx, cy +. r); (cx -. r, cy)]
  | Ellipse { cx; cy; rx; ry; _ } ->
    [(cx, cy -. ry); (cx +. rx, cy); (cx, cy +. ry); (cx -. rx, cy)]
  | Polygon { points; _ } -> points
  | Path { d; _ } | Text_path { d; _ } -> path_anchor_points d
  | elem ->
    let (bx, by, bw, bh) = bounds elem in
    [(bx, by); (bx +. bw, by); (bx +. bw, by +. bh); (bx, by +. bh)]

let move_control_points elem indices dx dy =
  let mem i = List.mem i indices in
  match elem with
  | Line r ->
    Line { r with
      x1 = r.x1 +. (if mem 0 then dx else 0.0);
      y1 = r.y1 +. (if mem 0 then dy else 0.0);
      x2 = r.x2 +. (if mem 1 then dx else 0.0);
      y2 = r.y2 +. (if mem 1 then dy else 0.0);
    }
  | Rect r ->
    if List.length indices >= 4 then
      Rect { r with x = r.x +. dx; y = r.y +. dy }
    else
      let pts = [| (r.x, r.y); (r.x +. r.width, r.y);
                   (r.x +. r.width, r.y +. r.height); (r.x, r.y +. r.height) |] in
      for i = 0 to 3 do
        if mem i then
          let (px, py) = pts.(i) in
          pts.(i) <- (px +. dx, py +. dy)
      done;
      Polygon { points = Array.to_list pts;
                fill = r.fill; stroke = r.stroke;
                opacity = r.opacity; transform = r.transform;
                locked = r.locked }
  | Circle r ->
    if List.length indices >= 4 then
      Circle { r with cx = r.cx +. dx; cy = r.cy +. dy }
    else
      let cps = [| (r.cx, r.cy -. r.r); (r.cx +. r.r, r.cy);
                    (r.cx, r.cy +. r.r); (r.cx -. r.r, r.cy) |] in
      for i = 0 to 3 do
        if mem i then
          let (px, py) = cps.(i) in
          cps.(i) <- (px +. dx, py +. dy)
      done;
      let ncx = (fst cps.(1) +. fst cps.(3)) /. 2.0 in
      let ncy = (snd cps.(0) +. snd cps.(2)) /. 2.0 in
      let nr = max (abs_float (fst cps.(1) -. ncx)) (abs_float (snd cps.(0) -. ncy)) in
      Circle { r with cx = ncx; cy = ncy; r = nr }
  | Ellipse r ->
    if List.length indices >= 4 then
      Ellipse { r with cx = r.cx +. dx; cy = r.cy +. dy }
    else
      let cps = [| (r.cx, r.cy -. r.ry); (r.cx +. r.rx, r.cy);
                    (r.cx, r.cy +. r.ry); (r.cx -. r.rx, r.cy) |] in
      for i = 0 to 3 do
        if mem i then
          let (px, py) = cps.(i) in
          cps.(i) <- (px +. dx, py +. dy)
      done;
      let ncx = (fst cps.(1) +. fst cps.(3)) /. 2.0 in
      let ncy = (snd cps.(0) +. snd cps.(2)) /. 2.0 in
      Ellipse { r with cx = ncx; cy = ncy;
                rx = abs_float (fst cps.(1) -. ncx);
                ry = abs_float (snd cps.(0) -. ncy) }
  | Polygon r ->
    let new_points = List.mapi (fun i (px, py) ->
      if mem i then (px +. dx, py +. dy) else (px, py)
    ) r.points in
    Polygon { r with points = new_points }
  | Path r ->
    let cmds = Array.of_list r.d in
    let n = Array.length cmds in
    let anchor_idx = ref 0 in
    for ci = 0 to n - 1 do
      match cmds.(ci) with
      | ClosePath -> ()
      | _ ->
        if mem !anchor_idx then begin
          (match cmds.(ci) with
           | MoveTo (x, y) ->
             cmds.(ci) <- MoveTo (x +. dx, y +. dy);
             if ci + 1 < n then
               (match cmds.(ci + 1) with
                | CurveTo (x1, y1, x2, y2, x, y) ->
                  cmds.(ci + 1) <- CurveTo (x1 +. dx, y1 +. dy, x2, y2, x, y)
                | _ -> ())
           | CurveTo (x1, y1, x2, y2, x, y) ->
             cmds.(ci) <- CurveTo (x1, y1, x2 +. dx, y2 +. dy, x +. dx, y +. dy);
             if ci + 1 < n then
               (match cmds.(ci + 1) with
                | CurveTo (nx1, ny1, nx2, ny2, nx, ny) ->
                  cmds.(ci + 1) <- CurveTo (nx1 +. dx, ny1 +. dy, nx2, ny2, nx, ny)
                | _ -> ())
           | LineTo (x, y) ->
             cmds.(ci) <- LineTo (x +. dx, y +. dy)
           | _ -> ())
        end;
        incr anchor_idx
    done;
    Path { r with d = Array.to_list cmds }
  | Text_path r ->
    let cmds = Array.of_list r.d in
    let n = Array.length cmds in
    let anchor_idx = ref 0 in
    for ci = 0 to n - 1 do
      match cmds.(ci) with
      | ClosePath -> ()
      | _ ->
        if mem !anchor_idx then begin
          (match cmds.(ci) with
           | MoveTo (x, y) ->
             cmds.(ci) <- MoveTo (x +. dx, y +. dy);
             if ci + 1 < n then
               (match cmds.(ci + 1) with
                | CurveTo (x1, y1, x2, y2, x, y) ->
                  cmds.(ci + 1) <- CurveTo (x1 +. dx, y1 +. dy, x2, y2, x, y)
                | _ -> ())
           | CurveTo (x1, y1, x2, y2, x, y) ->
             cmds.(ci) <- CurveTo (x1, y1, x2 +. dx, y2 +. dy, x +. dx, y +. dy);
             if ci + 1 < n then
               (match cmds.(ci + 1) with
                | CurveTo (nx1, ny1, nx2, ny2, nx, ny) ->
                  cmds.(ci + 1) <- CurveTo (nx1 +. dx, ny1 +. dy, nx2, ny2, nx, ny)
                | _ -> ())
           | LineTo (x, y) ->
             cmds.(ci) <- LineTo (x +. dx, y +. dy)
           | _ -> ())
        end;
        incr anchor_idx
    done;
    Text_path { r with d = Array.to_list cmds }
  | _ -> elem


(* ----------------------------------------------------------------- *)
(* Path geometry utilities                                           *)
(* ----------------------------------------------------------------- *)

let flatten_path_commands d =
  let pts = ref [] in
  let cx = ref 0.0 in
  let cy = ref 0.0 in
  let steps = flatten_steps in
  let first = ref (0.0, 0.0) in
  List.iter (fun cmd ->
    match cmd with
    | MoveTo (x, y) ->
      pts := (x, y) :: !pts;
      cx := x; cy := y; first := (x, y)
    | LineTo (x, y) ->
      pts := (x, y) :: !pts;
      cx := x; cy := y
    | CurveTo (x1, y1, x2, y2, x, y) ->
      for i = 1 to steps do
        let t = float_of_int i /. float_of_int steps in
        let mt = 1.0 -. t in
        let mt2 = mt *. mt in
        let mt3 = mt2 *. mt in
        let t2 = t *. t in
        let t3 = t2 *. t in
        let px = mt3 *. !cx +. 3.0 *. mt2 *. t *. x1 +. 3.0 *. mt *. t2 *. x2 +. t3 *. x in
        let py = mt3 *. !cy +. 3.0 *. mt2 *. t *. y1 +. 3.0 *. mt *. t2 *. y2 +. t3 *. y in
        pts := (px, py) :: !pts
      done;
      cx := x; cy := y
    | QuadTo (x1, y1, x, y) ->
      for i = 1 to steps do
        let t = float_of_int i /. float_of_int steps in
        let mt = 1.0 -. t in
        let px = mt *. mt *. !cx +. 2.0 *. mt *. t *. x1 +. t *. t *. x in
        let py = mt *. mt *. !cy +. 2.0 *. mt *. t *. y1 +. t *. t *. y in
        pts := (px, py) :: !pts
      done;
      cx := x; cy := y
    | ClosePath ->
      let (fx, fy) = !first in
      pts := (fx, fy) :: !pts
    | _ ->
      (* SmoothCurveTo, SmoothQuadTo, ArcTo: approximate as line *)
      let (x, y) = match cmd with
        | SmoothCurveTo (_, _, x, y) | SmoothQuadTo (x, y) | ArcTo (_, _, _, _, _, x, y) -> (x, y)
        | _ -> (!cx, !cy)
      in
      pts := (x, y) :: !pts;
      cx := x; cy := y
  ) d;
  List.rev !pts

let arc_lengths pts =
  let rec go acc prev = function
    | [] -> List.rev acc
    | (x, y) :: rest ->
      let (px, py) = prev in
      let dx = x -. px in
      let dy = y -. py in
      let len = (List.hd acc) +. sqrt (dx *. dx +. dy *. dy) in
      go (len :: acc) (x, y) rest
  in
  match pts with
  | [] -> [0.0]
  | first :: rest -> go [0.0] first rest

let path_point_at_offset d t =
  let pts = flatten_path_commands d in
  match pts with
  | [] -> (0.0, 0.0)
  | [p] -> p
  | _ ->
    let lengths = arc_lengths pts in
    let total = List.nth lengths (List.length lengths - 1) in
    if total = 0.0 then List.hd pts
    else
      let target = (max 0.0 (min 1.0 t)) *. total in
      let pts_arr = Array.of_list pts in
      let len_arr = Array.of_list lengths in
      let n = Array.length len_arr in
      let result = ref pts_arr.(n - 1) in
      (try
        for i = 1 to n - 1 do
          if len_arr.(i) >= target then begin
            let seg_len = len_arr.(i) -. len_arr.(i - 1) in
            if seg_len = 0.0 then result := pts_arr.(i)
            else begin
              let frac = (target -. len_arr.(i - 1)) /. seg_len in
              let (ax, ay) = pts_arr.(i - 1) in
              let (bx, by) = pts_arr.(i) in
              result := (ax +. frac *. (bx -. ax), ay +. frac *. (by -. ay))
            end;
            raise Exit
          end
        done
      with Exit -> ());
      !result

let path_closest_offset d px py =
  let pts = flatten_path_commands d in
  match pts with
  | [] | [_] -> 0.0
  | _ ->
    let lengths = arc_lengths pts in
    let total = List.nth lengths (List.length lengths - 1) in
    if total = 0.0 then 0.0
    else
      let pts_arr = Array.of_list pts in
      let len_arr = Array.of_list lengths in
      let n = Array.length pts_arr in
      let best_dist = ref infinity in
      let best_offset = ref 0.0 in
      for i = 1 to n - 1 do
        let (ax, ay) = pts_arr.(i - 1) in
        let (bx, by) = pts_arr.(i) in
        let dx = bx -. ax in
        let dy = by -. ay in
        let seg_len_sq = dx *. dx +. dy *. dy in
        if seg_len_sq > 0.0 then begin
          let t = max 0.0 (min 1.0 (((px -. ax) *. dx +. (py -. ay) *. dy) /. seg_len_sq)) in
          let qx = ax +. t *. dx in
          let qy = ay +. t *. dy in
          let dist = sqrt ((px -. qx) *. (px -. qx) +. (py -. qy) *. (py -. qy)) in
          if dist < !best_dist then begin
            best_dist := dist;
            best_offset := (len_arr.(i - 1) +. t *. (len_arr.(i) -. len_arr.(i - 1))) /. total
          end
        end
      done;
      !best_offset

let path_distance_to_point d px py =
  let pts = flatten_path_commands d in
  match pts with
  | [] -> infinity
  | [p] -> let (x, y) = p in sqrt ((px -. x) *. (px -. x) +. (py -. y) *. (py -. y))
  | _ ->
    let pts_arr = Array.of_list pts in
    let n = Array.length pts_arr in
    let best_dist = ref infinity in
    for i = 1 to n - 1 do
      let (ax, ay) = pts_arr.(i - 1) in
      let (bx, by) = pts_arr.(i) in
      let dx = bx -. ax in
      let dy = by -. ay in
      let seg_len_sq = dx *. dx +. dy *. dy in
      if seg_len_sq > 0.0 then begin
        let t = max 0.0 (min 1.0 (((px -. ax) *. dx +. (py -. ay) *. dy) /. seg_len_sq)) in
        let qx = ax +. t *. dx in
        let qy = ay +. t *. dy in
        let dist = sqrt ((px -. qx) *. (px -. qx) +. (py -. qy) *. (py -. qy)) in
        if dist < !best_dist then best_dist := dist
      end
    done;
    !best_dist
