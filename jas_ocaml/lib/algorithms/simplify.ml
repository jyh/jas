(** Polyline-to-Bezier simplification with corner detection.

    Mirrors jas_dioxus/src/algorithms/simplify.rs. See simplify.mli for
    the behavioural contract. *)

(* Default corner angle threshold: 30 degrees, in radians. *)
let default_corner_angle = Float.pi /. 6.0

(* Vector helpers. [norm] returns None for a zero-length edge so that a
   degenerate edge never marks a corner; the 1e-12 guard matches the
   Rust reference exactly. *)
let sub (ax, ay) (bx, by) = (ax -. bx, ay -. by)
let dot (ax, ay) (bx, by) = ax *. bx +. ay *. by
let norm (vx, vy) =
  let m = sqrt (vx *. vx +. vy *. vy) in
  if m < 1e-12 then None else Some (vx /. m, vy /. m)

(* Return indices of corner vertices. *)
let detect_corners points angle_threshold closed =
  let pts = Array.of_list points in
  let n = Array.length pts in
  let cos_threshold = cos angle_threshold in
  let start = if closed then 0 else 1 in
  let stop = if closed then n else n - 1 in
  let corners = ref [] in
  for i = start to stop - 1 do
    let prev_idx = (i + n - 1) mod n in
    let next_idx = (i + 1) mod n in
    let v1 = norm (sub pts.(i) pts.(prev_idx)) in
    let v2 = norm (sub pts.(next_idx) pts.(i)) in
    (* Degenerate (zero-length) edges should not mark corners. *)
    (match v1, v2 with
     | Some a, Some b ->
       let d = dot a b in
       (* d == 1 means edges are collinear (no turn); d < cos_threshold
          means the turn exceeds angle_threshold. *)
       if d < cos_threshold then corners := i :: !corners
     | _ -> ())
  done;
  List.rev !corners

(* Split [points] into runs separated by corners. Each run is a list of
   points; closed-ring runs may wrap around the seam. *)
let split_into_runs points corners closed =
  let pts = Array.of_list points in
  let n = Array.length pts in
  match corners with
  | [] ->
    if closed then
      (* No corners on a closed ring — emit one run that includes the
         seam vertex twice (start == end) so fit_curve can recover a
         closed-loop Bezier approximation. *)
      [ points @ [ pts.(0) ] ]
    else
      [ points ]
  | _ ->
    let corners_arr = Array.of_list corners in
    let m = Array.length corners_arr in
    if closed then begin
      (* Walk corner-to-corner around the ring. Each run starts at
         corner k and ends at corner k+1 (mod m), collecting every
         intermediate vertex. *)
      let runs = ref [] in
      for k = 0 to m - 1 do
        let a = corners_arr.(k) in
        let b = corners_arr.((k + 1) mod m) in
        let run = ref [ pts.(a) ] in
        let i = ref a in
        let continue = ref true in
        while !continue do
          i := (!i + 1) mod n;
          run := pts.(!i) :: !run;
          if !i = b then continue := false
        done;
        runs := List.rev !run :: !runs
      done;
      List.rev !runs
    end else begin
      (* Open polyline: runs are [start..corners.(0)],
         [corners.(0)..corners.(1)], ..., [corners.(last)..n-1]. *)
      let runs = ref [] in
      let prev = ref 0 in
      Array.iter (fun c ->
        let run = ref [] in
        for i = !prev to c do
          run := pts.(i) :: !run
        done;
        runs := List.rev !run :: !runs;
        prev := c
      ) corners_arr;
      let tail = ref [] in
      for i = !prev to n - 1 do
        tail := pts.(i) :: !tail
      done;
      runs := List.rev !tail :: !runs;
      List.rev !runs
    end

let simplify_polyline_with_angle points precision closed corner_angle_threshold =
  let n = List.length points in
  if n < 2 then []
  else if n = 2 then begin
    let p0 = List.nth points 0 in
    let p1 = List.nth points 1 in
    let out =
      [ Element.MoveTo (fst p0, snd p0); Element.LineTo (fst p1, snd p1) ]
    in
    if closed then out @ [ Element.ClosePath ] else out
  end else begin
    let corners = detect_corners points corner_angle_threshold closed in
    let runs = split_into_runs points corners closed in
    let first_run = List.hd runs in
    let first_pt = List.hd first_run in
    let out = ref [ Element.MoveTo (fst first_pt, snd first_pt) ] in
    List.iter (fun run ->
      let run_len = List.length run in
      if run_len = 2 then begin
        (* Pure line segment — no fitting. *)
        let last = List.nth run 1 in
        out := Element.LineTo (fst last, snd last) :: !out
      end else begin
        (* Bezier fit on the run. *)
        let segs = Fit_curve.fit_curve run precision in
        match segs with
        | [] ->
          (* Defensive: fit failed (too few points after filtering); fall
             back to a straight line to the last vertex. *)
          let last = List.nth run (run_len - 1) in
          out := Element.LineTo (fst last, snd last) :: !out
        | _ ->
          List.iter (fun (s : Fit_curve.segment) ->
            out :=
              Element.CurveTo (s.c1x, s.c1y, s.c2x, s.c2y, s.p2x, s.p2y)
              :: !out
          ) segs
      end
    ) runs;
    let out = if closed then Element.ClosePath :: !out else !out in
    List.rev out
  end

let simplify_polyline points precision closed =
  simplify_polyline_with_angle points precision closed default_corner_angle
