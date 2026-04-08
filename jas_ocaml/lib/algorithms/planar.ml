(** Planar graph extraction: turn a collection of polylines (open or
    closed) into a planar subdivision and enumerate the bounded
    faces. Port of jas_dioxus/src/algorithms/planar.rs.

    Pipeline:
    {ol
    {- Collect all line segments from all input polylines.}
    {- Find every segment-segment intersection (naive O(n²)).}
    {- Snap nearby intersection points and shared endpoints into
       single vertices.}
    {- Prune vertices of degree 1 iteratively.}
    {- Build a DCEL (doubly connected edge list).}
    {- Traverse half-edge cycles to enumerate faces.}
    {- Drop the unbounded outer face.}
    {- Compute face containment to mark hole relationships.}}

    Deferred (mirrors Boolean_normalize): Bezier curves (caller
    flattens), T-junctions, collinear overlap, incremental rebuild,
    spatial acceleration. *)

(* ------------------------------------------------------------------ *)
(* Public types                                                        *)
(* ------------------------------------------------------------------ *)

type point = float * float

type polyline = point array

type vertex_id = int
type half_edge_id = int
type face_id = int

type vertex = {
  pos : point;
  outgoing : half_edge_id;
}

type half_edge = {
  origin : vertex_id;
  twin : half_edge_id;
  next : half_edge_id;
  prev : half_edge_id;
}

type face = {
  boundary : half_edge_id;
  holes : half_edge_id list;
  parent : face_id option;
  depth : int;
}

type t = {
  vertices : vertex array;
  half_edges : half_edge array;
  faces : face array;
}

let empty : t = {
  vertices = [||];
  half_edges = [||];
  faces = [||];
}

(* ------------------------------------------------------------------ *)
(* Numerical helpers                                                   *)
(* ------------------------------------------------------------------ *)

(** Vertex coincidence and zero-length tolerance. *)
let vert_eps = 1e-9

(** Parameter-band epsilon for [intersect_proper]. Mirrors
    Boolean_normalize. *)
let param_eps = 1e-9

(** Determinant tolerance for parallel-segment rejection. *)
let denom_eps = 1e-12

let dist (ax, ay) (bx, by) =
  let dx = ax -. bx in
  let dy = ay -. by in
  sqrt (dx *. dx +. dy *. dy)

(** Linear-search vertex dedup against a [Buffer]-style ref. *)
let add_or_find_vertex (verts : point list ref) (count : int ref) (pt : point) : int =
  let arr = !verts in
  let rec loop i = function
    | [] -> -1
    | v :: rest -> if dist v pt < vert_eps then i else loop (i + 1) rest
  in
  let found = loop 0 (List.rev arr) in
  if found >= 0 then found
  else begin
    verts := pt :: !verts;
    let id = !count in
    incr count;
    id
  end

(** Parametric line-line intersection requiring a strictly interior
    crossing on both segments. Mirrors
    Boolean_normalize.segment_proper_intersection. *)
let intersect_proper (a1x, a1y) (a2x, a2y) (b1x, b1y) (b2x, b2y) =
  let dx_a = a2x -. a1x in
  let dy_a = a2y -. a1y in
  let dx_b = b2x -. b1x in
  let dy_b = b2y -. b1y in
  let denom = dx_a *. dy_b -. dy_a *. dx_b in
  if abs_float denom < denom_eps then None
  else
    let dx_ab = a1x -. b1x in
    let dy_ab = a1y -. b1y in
    let s = (dx_b *. dy_ab -. dy_b *. dx_ab) /. denom in
    let t = (dx_a *. dy_ab -. dy_a *. dx_ab) /. denom in
    if s <= param_eps || s >= 1.0 -. param_eps
       || t <= param_eps || t >= 1.0 -. param_eps
    then None
    else Some ((a1x +. s *. dx_a, a1y +. s *. dy_a), s, t)

(** Winding number with half-open upward/downward classification. *)
let winding_number (poly : point array) (px, py) =
  let n = Array.length poly in
  if n < 3 then 0
  else
    let w = ref 0 in
    for i = 0 to n - 1 do
      let (x1, y1) = poly.(i) in
      let (x2, y2) = poly.((i + 1) mod n) in
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

(** Pick a point strictly inside the polygon traced by [poly],
    regardless of CW/CCW orientation. Mirrors
    Boolean_normalize.sample_inside_simple_ring. *)
let sample_inside (poly : point array) =
  let n = Array.length poly in
  assert (n >= 3);
  let (x0, y0) = poly.(0) in
  let (x1, y1) = poly.(1) in
  let mx = (x0 +. x1) /. 2.0 in
  let my = (y0 +. y1) /. 2.0 in
  let dx = x1 -. x0 in
  let dy = y1 -. y0 in
  let len = sqrt (dx *. dx +. dy *. dy) in
  if len = 0.0 then
    let (x2, y2) = poly.(2) in
    ((x0 +. x1 +. x2) /. 3.0, (y0 +. y1 +. y2) /. 3.0)
  else
    let nx = -. dy /. len in
    let ny = dx /. len in
    let offset = len *. 1e-4 in
    let left = (mx +. nx *. offset, my +. ny *. offset) in
    let right = (mx -. nx *. offset, my -. ny *. offset) in
    if winding_number poly left <> 0 then left else right

(* ------------------------------------------------------------------ *)
(* Build                                                               *)
(* ------------------------------------------------------------------ *)

let build (polylines : polyline list) : t =
  (* ----- 1. Collect non-degenerate segments ----- *)
  let segments = ref [] in
  let n_segs = ref 0 in
  List.iter (fun poly ->
    let n = Array.length poly in
    if n >= 2 then
      for i = 0 to n - 2 do
        let a = poly.(i) in
        let b = poly.(i + 1) in
        if dist a b > vert_eps then begin
          segments := (a, b) :: !segments;
          incr n_segs
        end
      done
  ) polylines;
  let segments = Array.of_list (List.rev !segments) in
  if Array.length segments = 0 then empty
  else begin

  (* ----- 2-3. Per-segment vertex lists with snap-merging ----- *)
  let vert_pts = ref [] in
  let n_verts = ref 0 in
  let seg_params = Array.make (Array.length segments) [] in
  Array.iteri (fun si (a, b) ->
    let va = add_or_find_vertex vert_pts n_verts a in
    let vb = add_or_find_vertex vert_pts n_verts b in
    seg_params.(si) <- [(0.0, va); (1.0, vb)]
  ) segments;

  (* ----- 4. Naive O(n²) proper-interior intersection ----- *)
  let n_seg = Array.length segments in
  for i = 0 to n_seg - 1 do
    for j = i + 1 to n_seg - 1 do
      let (a1, a2) = segments.(i) in
      let (b1, b2) = segments.(j) in
      match intersect_proper a1 a2 b1 b2 with
      | None -> ()
      | Some (p, s, t) ->
        let v = add_or_find_vertex vert_pts n_verts p in
        seg_params.(i) <- (s, v) :: seg_params.(i);
        seg_params.(j) <- (t, v) :: seg_params.(j)
    done
  done;

  (* Snapshot the (now-final) vertex point list as an array. *)
  let vert_arr = Array.of_list (List.rev !vert_pts) in

  (* ----- 5. Sort each segment's params, drop snapped duplicates,
     emit atomic edges. ----- *)
  let module IntPair = struct
    type t = int * int
    let compare (a1, a2) (b1, b2) =
      let c = compare a1 b1 in
      if c <> 0 then c else compare a2 b2
  end in
  let module EdgeSet = Set.Make(IntPair) in
  let edge_set = ref EdgeSet.empty in
  for si = 0 to n_seg - 1 do
    let sorted =
      List.sort (fun (a, _) (b, _) -> compare a b) seg_params.(si)
    in
    let chain =
      let rec loop prev = function
        | [] -> []
        | (_, v) :: rest ->
          if Some v = prev then loop prev rest
          else v :: loop (Some v) rest
      in
      loop None sorted
    in
    let rec emit = function
      | [] | [_] -> ()
      | u :: (v :: _ as rest) ->
        if u <> v then begin
          let e = if u < v then (u, v) else (v, u) in
          edge_set := EdgeSet.add e !edge_set
        end;
        emit rest
    in
    emit chain
  done;
  let edges_ref = ref (EdgeSet.elements !edge_set) in

  (* ----- 6. Iteratively prune degree-1 vertices ----- *)
  let n_v_total = !n_verts in
  let prune () =
    let rec loop () =
      match !edges_ref with
      | [] -> ()
      | _ ->
        let deg = Array.make n_v_total 0 in
        List.iter (fun (u, v) ->
          deg.(u) <- deg.(u) + 1;
          deg.(v) <- deg.(v) + 1
        ) !edges_ref;
        let before = List.length !edges_ref in
        edges_ref :=
          List.filter (fun (u, v) -> deg.(u) >= 2 && deg.(v) >= 2) !edges_ref;
        if List.length !edges_ref < before then loop ()
    in
    loop ()
  in
  prune ();
  if !edges_ref = [] then empty
  else begin
    let edges_list = !edges_ref in

    (* Compact the vertex array to drop pruned-away vertices. *)
    let used = Array.make n_v_total false in
    List.iter (fun (u, v) -> used.(u) <- true; used.(v) <- true) edges_list;
    let new_id = Array.make n_v_total (-1) in
    let compacted = ref [] in
    let n_c = ref 0 in
    for i = 0 to n_v_total - 1 do
      if used.(i) then begin
        new_id.(i) <- !n_c;
        compacted := vert_arr.(i) :: !compacted;
        incr n_c
      end
    done;
    let vert_pts = Array.of_list (List.rev !compacted) in
    let n_v = !n_c in
    let edges =
      Array.of_list
        (List.map (fun (u, v) -> (new_id.(u), new_id.(v))) edges_list)
    in

    (* ----- 7. Build half-edges and DCEL links ----- *)
    let n_he = Array.length edges * 2 in
    let he_origin = Array.make n_he 0 in
    let he_twin = Array.make n_he 0 in
    Array.iteri (fun k (u, v) ->
      let i = k * 2 in
      he_origin.(i) <- u;
      he_origin.(i + 1) <- v;
      he_twin.(i) <- i + 1;
      he_twin.(i + 1) <- i
    ) edges;

    (* Per-vertex outgoing half-edges, sorted CCW by angle. *)
    let outgoing_buf = Array.make n_v [] in
    for i = 0 to n_he - 1 do
      let v = he_origin.(i) in
      outgoing_buf.(v) <- i :: outgoing_buf.(v)
    done;
    let outgoing_at = Array.make n_v [||] in
    for v = 0 to n_v - 1 do
      let arr = Array.of_list outgoing_buf.(v) in
      let (ox, oy) = vert_pts.(v) in
      Array.sort (fun a b ->
        let (tax, tay) = vert_pts.(he_origin.(he_twin.(a))) in
        let (tbx, tby) = vert_pts.(he_origin.(he_twin.(b))) in
        let aa = atan2 (tay -. oy) (tax -. ox) in
        let ab = atan2 (tby -. oy) (tbx -. ox) in
        compare aa ab
      ) arr;
      outgoing_at.(v) <- arr
    done;

    (* For each half-edge e ending at v:
         next(e) = the outgoing half-edge from v immediately CW from
                   e.twin in the angular order at v. *)
    let he_next = Array.make n_he 0 in
    let he_prev = Array.make n_he 0 in
    for e = 0 to n_he - 1 do
      let etwin = he_twin.(e) in
      let v = he_origin.(etwin) in
      let lst = outgoing_at.(v) in
      let len = Array.length lst in
      let idx = ref (-1) in
      for k = 0 to len - 1 do
        if lst.(k) = etwin then idx := k
      done;
      let cw_idx = (!idx + len - 1) mod len in
      let next_e = lst.(cw_idx) in
      he_next.(e) <- next_e;
      he_prev.(next_e) <- e
    done;

    (* ----- 8. Enumerate half-edge cycles ----- *)
    let he_cycle = Array.make n_he (-1) in
    let cycles_ref = ref [] in
    let n_cycles = ref 0 in
    for start = 0 to n_he - 1 do
      if he_cycle.(start) = -1 then begin
        let cyc_buf = ref [] in
        let e = ref start in
        let stop = ref false in
        while not !stop do
          he_cycle.(!e) <- !n_cycles;
          cyc_buf := !e :: !cyc_buf;
          e := he_next.(!e);
          if !e = start then stop := true
        done;
        cycles_ref := (Array.of_list (List.rev !cyc_buf)) :: !cycles_ref;
        incr n_cycles
      end
    done;
    let cycles = Array.of_list (List.rev !cycles_ref) in

    (* ----- 9. Signed area; classify positive vs negative ----- *)
    let n_cyc = Array.length cycles in
    let areas = Array.make n_cyc 0.0 in
    let cycle_polys = Array.make n_cyc [||] in
    for i = 0 to n_cyc - 1 do
      let cyc = cycles.(i) in
      let n = Array.length cyc in
      let poly = Array.make n (0.0, 0.0) in
      for k = 0 to n - 1 do
        poly.(k) <- vert_pts.(he_origin.(cyc.(k)))
      done;
      cycle_polys.(i) <- poly;
      let sum = ref 0.0 in
      for k = 0 to n - 1 do
        let (ax, ay) = poly.(k) in
        let (bx, by) = poly.((k + 1) mod n) in
        sum := !sum +. ax *. by -. bx *. ay
      done;
      areas.(i) <- !sum /. 2.0
    done;

    let pos_cycles =
      let buf = ref [] in
      for i = n_cyc - 1 downto 0 do
        if areas.(i) > 0.0 then buf := i :: !buf
      done;
      Array.of_list !buf
    in
    let neg_cycles =
      let buf = ref [] in
      for i = n_cyc - 1 downto 0 do
        if areas.(i) < 0.0 then buf := i :: !buf
      done;
      !buf
    in
    let n_faces = Array.length pos_cycles in

    (* ----- 11. Parent of each face: smallest enclosing positive cycle. *)
    let parents = Array.make n_faces None in
    for fi = 0 to n_faces - 1 do
      let cyc_f = pos_cycles.(fi) in
      let area_f = areas.(cyc_f) in
      let sample = sample_inside cycle_polys.(cyc_f) in
      let best = ref None in
      let best_area = ref infinity in
      for gi = 0 to n_faces - 1 do
        if gi <> fi then begin
          let cyc_g = pos_cycles.(gi) in
          let area_g = areas.(cyc_g) in
          if area_g > area_f
             && winding_number cycle_polys.(cyc_g) sample <> 0
             && area_g < !best_area
          then begin
            best_area := area_g;
            best := Some gi
          end
        end
      done;
      parents.(fi) <- !best
    done;

    (* ----- 12. Depth via topological propagation ----- *)
    let depth = Array.make n_faces 0 in
    let changed = ref true in
    while !changed do
      changed := false;
      for f = 0 to n_faces - 1 do
        if depth.(f) = 0 then begin
          match parents.(f) with
          | None -> depth.(f) <- 1; changed := true
          | Some p ->
            if depth.(p) <> 0 then begin
              depth.(f) <- depth.(p) + 1;
              changed := true
            end
        end
      done
    done;

    (* ----- 13. Hole assignment ----- *)
    let face_holes = Array.make n_faces [] in
    List.iter (fun neg_i ->
      let area_neg = abs_float areas.(neg_i) in
      let sample = sample_inside cycle_polys.(neg_i) in
      let best = ref None in
      let best_area = ref infinity in
      for fi = 0 to n_faces - 1 do
        let cyc_g = pos_cycles.(fi) in
        let area_f = areas.(cyc_g) in
        if area_f > area_neg
           && winding_number cycle_polys.(cyc_g) sample <> 0
           && area_f < !best_area
        then begin
          best_area := area_f;
          best := Some fi
        end
      done;
      match !best with
      | Some fi -> face_holes.(fi) <- neg_i :: face_holes.(fi)
      | None -> ()
    ) neg_cycles;

    (* ----- Materialize public structures ----- *)
    let vertices =
      Array.init n_v (fun i ->
        let outgoing =
          let lst = outgoing_at.(i) in
          if Array.length lst > 0 then lst.(0) else 0
        in
        { pos = vert_pts.(i); outgoing })
    in
    let half_edges =
      Array.init n_he (fun e ->
        { origin = he_origin.(e);
          twin = he_twin.(e);
          next = he_next.(e);
          prev = he_prev.(e) })
    in
    let faces =
      Array.init n_faces (fun fi ->
        let outer_cycle = pos_cycles.(fi) in
        let boundary = cycles.(outer_cycle).(0) in
        let holes =
          List.map (fun c -> cycles.(c).(0)) (List.rev face_holes.(fi))
        in
        { boundary;
          holes;
          parent = (match parents.(fi) with
                    | None -> None
                    | Some p -> Some p);
          depth = depth.(fi) })
    in
    { vertices; half_edges; faces }
  end
  end

(* ------------------------------------------------------------------ *)
(* Public queries                                                      *)
(* ------------------------------------------------------------------ *)

let face_count (g : t) = Array.length g.faces

let top_level_faces (g : t) =
  let buf = ref [] in
  for i = Array.length g.faces - 1 downto 0 do
    if g.faces.(i).depth = 1 then buf := i :: !buf
  done;
  !buf

let cycle_signed_area (g : t) (start : half_edge_id) =
  let sum = ref 0.0 in
  let e = ref start in
  let stop = ref false in
  while not !stop do
    let (ax, ay) = g.vertices.(g.half_edges.(!e).origin).pos in
    let next_e = g.half_edges.(!e).next in
    let (bx, by) = g.vertices.(g.half_edges.(next_e).origin).pos in
    sum := !sum +. ax *. by -. bx *. ay;
    e := next_e;
    if !e = start then stop := true
  done;
  !sum /. 2.0

let cycle_polygon (g : t) (start : half_edge_id) : point array =
  let buf = ref [] in
  let e = ref start in
  let stop = ref false in
  while not !stop do
    buf := g.vertices.(g.half_edges.(!e).origin).pos :: !buf;
    e := g.half_edges.(!e).next;
    if !e = start then stop := true
  done;
  Array.of_list (List.rev !buf)

let face_outer_area (g : t) (face : face_id) =
  abs_float (cycle_signed_area g g.faces.(face).boundary)

let face_net_area (g : t) (face : face_id) =
  let outer = face_outer_area g face in
  let holes_sum =
    List.fold_left
      (fun acc h -> acc +. abs_float (cycle_signed_area g h))
      0.0 g.faces.(face).holes
  in
  outer -. holes_sum

let hit_test (g : t) (point : point) : face_id option =
  let best = ref None in
  let best_depth = ref 0 in
  for fi = 0 to Array.length g.faces - 1 do
    let poly = cycle_polygon g g.faces.(fi).boundary in
    if winding_number poly point <> 0 && g.faces.(fi).depth > !best_depth
    then begin
      best_depth := g.faces.(fi).depth;
      best := Some fi
    end
  done;
  !best
