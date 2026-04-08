(** Ring normalizer: turn an arbitrary (possibly self-intersecting)
    polygon set into an equivalent set of simple rings under the
    non-zero winding fill rule. Port of jas_dioxus/src/algorithms/normalize.rs. *)

open Boolean

(* ------------------------------------------------------------------ *)
(* Vertex cleanup                                                      *)
(* ------------------------------------------------------------------ *)

let dedup_consecutive ring =
  let buf = ref [] in
  Array.iter (fun p ->
    match !buf with
    | last :: _ when last = p -> ()
    | _ -> buf := p :: !buf
  ) ring;
  let arr = Array.of_list (List.rev !buf) in
  let n = Array.length arr in
  if n >= 2 && arr.(0) = arr.(n - 1) then Array.sub arr 0 (n - 1)
  else arr

(* ------------------------------------------------------------------ *)
(* Self-intersection detection / splitting                             *)
(* ------------------------------------------------------------------ *)

let segment_proper_intersection (a1x, a1y) (a2x, a2y) (b1x, b1y) (b2x, b2y) =
  let dx_a = a2x -. a1x in
  let dy_a = a2y -. a1y in
  let dx_b = b2x -. b1x in
  let dy_b = b2y -. b1y in
  let denom = dx_a *. dy_b -. dy_a *. dx_b in
  if abs_float denom < 1e-12 then None
  else
    let dx_ab = a1x -. b1x in
    let dy_ab = a1y -. b1y in
    let s = (dx_b *. dy_ab -. dy_b *. dx_ab) /. denom in
    let t = (dx_a *. dy_ab -. dy_a *. dx_ab) /. denom in
    let eps = 1e-9 in
    if s <= eps || s >= 1.0 -. eps || t <= eps || t >= 1.0 -. eps then None
    else Some (a1x +. s *. dx_a, a1y +. s *. dy_a)

let find_first_self_intersection (ring : ring) =
  let n = Array.length ring in
  if n < 4 then None
  else
    let result = ref None in
    let i = ref 0 in
    while !result = None && !i < n do
      let a1 = ring.(!i) in
      let a2 = ring.((!i + 1) mod n) in
      if !i + 2 < n then begin
        let j = ref (!i + 2) in
        while !result = None && !j < n do
          if not (!i = 0 && !j = n - 1) then begin
            let b1 = ring.(!j) in
            let b2 = ring.((!j + 1) mod n) in
            (match segment_proper_intersection a1 a2 b1 b2 with
             | Some p -> result := Some (!i, !j, p)
             | None -> ())
          end;
          incr j
        done
      end;
      incr i
    done;
    !result

let split_ring_at (ring : ring) i j p : ring * ring =
  let n = Array.length ring in
  let a_buf = ref [] in
  for k = 0 to i do a_buf := ring.(k) :: !a_buf done;
  a_buf := p :: !a_buf;
  for k = j + 1 to n - 1 do a_buf := ring.(k) :: !a_buf done;
  let a = Array.of_list (List.rev !a_buf) in
  let b_buf = ref [] in
  b_buf := p :: !b_buf;
  for k = i + 1 to j do b_buf := ring.(k) :: !b_buf done;
  let b = Array.of_list (List.rev !b_buf) in
  (a, b)

let split_recursively (ring : ring) : ring list =
  let stack = ref [ring] in
  let simple = ref [] in
  let continue = ref true in
  while !continue do
    match !stack with
    | [] -> continue := false
    | r :: rest ->
      stack := rest;
      if Array.length r >= 3 then begin
        match find_first_self_intersection r with
        | Some (i, j, p) ->
          let (a, b) = split_ring_at r i j p in
          stack := a :: b :: !stack
        | None ->
          simple := r :: !simple
      end
  done;
  !simple

(* ------------------------------------------------------------------ *)
(* Winding and sampling                                                *)
(* ------------------------------------------------------------------ *)

let winding_number (ring : ring) (px, py) =
  let n = Array.length ring in
  if n < 3 then 0
  else
    let w = ref 0 in
    for i = 0 to n - 1 do
      let (x1, y1) = ring.(i) in
      let (x2, y2) = ring.((i + 1) mod n) in
      let upward = y1 <= py && y2 > py in
      let downward = y2 <= py && y1 > py in
      if upward || downward then begin
        let t = (py -. y1) /. (y2 -. y1) in
        let x_cross = x1 +. t *. (x2 -. x1) in
        if x_cross > px then begin
          if upward then incr w else decr w
        end
      end
    done;
    !w

let sample_inside_simple_ring (ring : ring) =
  let n = Array.length ring in
  assert (n >= 3);
  let (x0, y0) = ring.(0) in
  let (x1, y1) = ring.(1) in
  let mx = (x0 +. x1) /. 2.0 in
  let my = (y0 +. y1) /. 2.0 in
  let dx = x1 -. x0 in
  let dy = y1 -. y0 in
  let len = sqrt (dx *. dx +. dy *. dy) in
  if len = 0.0 then begin
    let (x2, y2) = ring.(2) in
    ((x0 +. x1 +. x2) /. 3.0, (y0 +. y1 +. y2) /. 3.0)
  end
  else
    let nx = -. dy /. len in
    let ny = dx /. len in
    let offset = len *. 1e-4 in
    let left = (mx +. nx *. offset, my +. ny *. offset) in
    let right = (mx -. nx *. offset, my -. ny *. offset) in
    if winding_number ring left <> 0 then left else right

(* ------------------------------------------------------------------ *)
(* Public API                                                          *)
(* ------------------------------------------------------------------ *)

let normalize_ring (ring : ring) : ring list =
  let cleaned = dedup_consecutive ring in
  if Array.length cleaned < 3 then []
  else
    let simple = split_recursively cleaned in
    List.filter_map (fun sub ->
      if Array.length sub < 3 then None
      else
        let sample = sample_inside_simple_ring sub in
        if winding_number cleaned sample <> 0 then Some sub else None
    ) simple

let normalize (input : polygon_set) : polygon_set =
  List.concat_map normalize_ring input

(* Wire the normalizer into Boolean's hook so run_boolean uses it. *)
let () = Boolean.normalize_hook := normalize
