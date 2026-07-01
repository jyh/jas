(* Art brush warp. See art_along_path.mli. Faithful port of
   jas_dioxus/src/algorithms/art_along_path.rs. *)

type t = {
  artwork_width : float;
  artwork_height : float;
  artwork : (float * float) list list;
  scale : float;
  flip_across : bool;
  flip_along : bool;
  stroke_weight : float;
}

(* Flatten the first subpath of [commands] into a point array. Cubics /
   quads are subdivided uniformly (16 / 12), mirroring the Rust sampler. *)
let flatten (commands : Element.path_command list) : (float * float) array =
  let out = ref [] in (* reversed *)
  let cx = ref 0.0 and cy = ref 0.0 and sx = ref 0.0 and sy = ref 0.0 in
  let started = ref false in
  let push x y =
    match !out with
    | (lx, ly) :: _ when lx = x && ly = y -> ()
    | _ -> out := (x, y) :: !out
  in
  (try
     List.iter
       (fun cmd ->
         match cmd with
         | Element.MoveTo (x, y) ->
           if !started then raise Exit;
           cx := x; cy := y; sx := x; sy := y; push x y
         | Element.LineTo (x, y) -> push x y; cx := x; cy := y; started := true
         | Element.CurveTo (x1, y1, x2, y2, x, y) ->
           for k = 1 to 16 do
             let t = float_of_int k /. 16.0 in
             let u = 1.0 -. t in
             let bx = (u *. u *. u *. !cx) +. (3.0 *. u *. u *. t *. x1)
                      +. (3.0 *. u *. t *. t *. x2) +. (t *. t *. t *. x) in
             let by = (u *. u *. u *. !cy) +. (3.0 *. u *. u *. t *. y1)
                      +. (3.0 *. u *. t *. t *. y2) +. (t *. t *. t *. y) in
             push bx by
           done;
           cx := x; cy := y; started := true
         | Element.QuadTo (x1, y1, x, y) ->
           for k = 1 to 12 do
             let t = float_of_int k /. 12.0 in
             let u = 1.0 -. t in
             let bx = (u *. u *. !cx) +. (2.0 *. u *. t *. x1) +. (t *. t *. x) in
             let by = (u *. u *. !cy) +. (2.0 *. u *. t *. y1) +. (t *. t *. y) in
             push bx by
           done;
           cx := x; cy := y; started := true
         | Element.ClosePath ->
           if !cx <> !sx || !cy <> !sy then push !sx !sy;
           raise Exit
         | _ -> raise Exit)
       commands
   with Exit -> ());
  Array.of_list (List.rev !out)

(* Point (x, y) and tangent (radians) at arc-length [s] along the polyline. *)
let point_at_arclength pts cum total s =
  let s = if s < 0.0 then 0.0 else if s > total then total else s in
  let n = Array.length pts in
  let lo = ref 1 and hi = ref (n - 1) in
  while !lo < !hi do
    let mid = (!lo + !hi) / 2 in
    if cum.(mid) < s then lo := mid + 1 else hi := mid
  done;
  let i = !lo in
  let seg = cum.(i) -. cum.(i - 1) in
  let f = if seg > 0.0 then (s -. cum.(i - 1)) /. seg else 0.0 in
  let x0, y0 = pts.(i - 1) in
  let x1, y1 = pts.(i) in
  let x = x0 +. ((x1 -. x0) *. f) in
  let y = y0 +. ((y1 -. y0) *. f) in
  let tan = atan2 (y1 -. y0) (x1 -. x0) in
  (x, y, tan)

let warp (commands : Element.path_command list) (brush : t) :
    (float * float) list list =
  if brush.artwork_width <= 0.0 || brush.artwork_height <= 0.0 then []
  else
    let pts = flatten commands in
    let n = Array.length pts in
    if n < 2 then []
    else begin
      let cum = Array.make n 0.0 in
      for i = 1 to n - 1 do
        let px, py = pts.(i) in
        let qx, qy = pts.(i - 1) in
        let dx = px -. qx and dy = py -. qy in
        cum.(i) <- cum.(i - 1) +. sqrt ((dx *. dx) +. (dy *. dy))
      done;
      let total = cum.(n - 1) in
      if total <= 0.0 then []
      else
        let h_out = (brush.scale /. 100.0) *. brush.stroke_weight in
        List.map
          (fun poly ->
            List.map
              (fun (ax, ay) ->
                let t = ax /. brush.artwork_width in
                let t = if t < 0.0 then 0.0 else if t > 1.0 then 1.0 else t in
                let t = if brush.flip_along then 1.0 -. t else t in
                let px, py, tan = point_at_arclength pts cum total (t *. total) in
                let off =
                  (ay -. (brush.artwork_height /. 2.0))
                  /. brush.artwork_height *. h_out
                in
                let off = if brush.flip_across then -.off else off in
                let nx = -.sin tan and ny = cos tan in
                (px +. (nx *. off), py +. (ny *. off)))
              poly)
          brush.artwork
    end
