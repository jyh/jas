(** Boolean operations on planar polygons (union, intersection,
    difference, exclusive-or). Port of jas_dioxus/src/algorithms/boolean.rs.

    Data model: a [polygon_set] is a list of rings; a ring is a closed
    polygon expressed as an array of (x, y) vertices without the
    implicit closing vertex. Multiple rings represent a region under
    the even-odd fill rule.

    Inputs may be self-intersecting; they are normalized as a pre-pass
    under the non-zero winding fill rule. See {!Boolean_normalize}. *)

(* ------------------------------------------------------------------ *)
(* Public types                                                        *)
(* ------------------------------------------------------------------ *)

type point = float * float
type ring = point array
type polygon_set = ring list

(* ------------------------------------------------------------------ *)
(* Internal types                                                      *)
(* ------------------------------------------------------------------ *)

type operation = Union | Intersection | Difference | Xor

type polygon_id = Subject | Clipping

let polygon_id_to_int = function Subject -> 0 | Clipping -> 1

type edge_type =
  | Normal
  | Same_transition
  | Different_transition
  | Non_contributing

(* One endpoint of an edge in the sweep. Two events per edge. *)
type sweep_event = {
  mutable point : point;
  mutable is_left : bool;
  mutable polygon : polygon_id;
  mutable other_event : int;
  mutable in_out : bool;
  mutable other_in_out : bool;
  mutable in_result : bool;
  mutable edge_type : edge_type;
  mutable prev_in_result : int; (* -1 means None *)
}

let make_sweep_event point is_left polygon =
  { point; is_left; polygon; other_event = -1;
    in_out = false; other_in_out = false; in_result = false;
    edge_type = Normal; prev_in_result = -1 }

(* ------------------------------------------------------------------ *)
(* Geometric primitives                                                *)
(* ------------------------------------------------------------------ *)

let point_lex_less (ax, ay) (bx, by) =
  if ax <> bx then ax < bx else ay < by

let signed_area (p0x, p0y) (p1x, p1y) (p2x, p2y) =
  (p0x -. p2x) *. (p1y -. p2y) -. (p1x -. p2x) *. (p0y -. p2y)

let points_eq (ax, ay) (bx, by) =
  abs_float (ax -. bx) < 1e-9 && abs_float (ay -. by) < 1e-9

(** Project [p] onto the segment [a -> b], clamped to the segment
    endpoints. Used by [handle_collinear] to keep split points on the
    edge being split. *)
let project_onto_segment (ax, ay) (bx, by) (px, py) =
  let dx = bx -. ax in
  let dy = by -. ay in
  let len_sq = dx *. dx +. dy *. dy in
  if len_sq = 0.0 then (ax, ay)
  else
    let t = ((px -. ax) *. dx +. (py -. ay) *. dy) /. len_sq in
    let t = max 0.0 (min 1.0 t) in
    (ax +. t *. dx, ay +. t *. dy)

(* ------------------------------------------------------------------ *)
(* Event ordering                                                      *)
(* ------------------------------------------------------------------ *)

let event_less events a b =
  let ea = Dynarray.get events a in
  let eb = Dynarray.get events b in
  let (eax, eay) = ea.point in
  let (ebx, eby) = eb.point in
  if eax <> ebx then eax < ebx
  else if eay <> eby then eay < eby
  else if ea.is_left <> eb.is_left then not ea.is_left
  else
    let other_a = (Dynarray.get events ea.other_event).point in
    let other_b = (Dynarray.get events eb.other_event).point in
    let area = signed_area ea.point other_a other_b in
    if area <> 0.0 then area > 0.0
    else polygon_id_to_int ea.polygon < polygon_id_to_int eb.polygon

let status_less events a b =
  if a = b then false
  else
    let ea = Dynarray.get events a in
    let eb = Dynarray.get events b in
    let other_a = (Dynarray.get events ea.other_event).point in
    let other_b = (Dynarray.get events eb.other_event).point in
    if signed_area ea.point other_a eb.point <> 0.0
       || signed_area ea.point other_a other_b <> 0.0 then begin
      (* Not collinear *)
      if ea.point = eb.point then
        signed_area ea.point other_a other_b > 0.0
      else if event_less events a b then
        signed_area ea.point other_a eb.point > 0.0
      else
        signed_area eb.point other_b ea.point < 0.0
    end
    else begin
      (* Collinear: tie-break by polygon then by point order *)
      if ea.polygon <> eb.polygon then
        polygon_id_to_int ea.polygon < polygon_id_to_int eb.polygon
      else if ea.point <> eb.point then
        point_lex_less ea.point eb.point
      else
        point_lex_less other_a other_b
    end

(* ------------------------------------------------------------------ *)
(* Result classification                                               *)
(* ------------------------------------------------------------------ *)

let edge_in_result event op =
  match event.edge_type with
  | Normal ->
    (match op with
     | Union -> event.other_in_out
     | Intersection -> not event.other_in_out
     | Difference ->
       (match event.polygon with
        | Subject -> event.other_in_out
        | Clipping -> not event.other_in_out)
     | Xor -> true)
  | Same_transition -> op = Union || op = Intersection
  | Different_transition -> op = Difference
  | Non_contributing -> false

(* ------------------------------------------------------------------ *)
(* Snap-rounding                                                       *)
(* ------------------------------------------------------------------ *)

let snap_ratio = 1e-9

(** Compute the snap-rounding grid spacing as a power of 2 fraction
    of the combined bounding-box diagonal. Returns None for empty or
    degenerate input. *)
let snap_grid (a : polygon_set) (b : polygon_set) =
  let min_x = ref infinity in
  let min_y = ref infinity in
  let max_x = ref neg_infinity in
  let max_y = ref neg_infinity in
  let any = ref false in
  let scan ring =
    Array.iter (fun (x, y) ->
      if x < !min_x then min_x := x;
      if y < !min_y then min_y := y;
      if x > !max_x then max_x := x;
      if y > !max_y then max_y := y;
      any := true
    ) ring
  in
  List.iter scan a;
  List.iter scan b;
  if not !any then None
  else
    let dx = !max_x -. !min_x in
    let dy = !max_y -. !min_y in
    let diagonal = sqrt (dx *. dx +. dy *. dy) in
    if diagonal <= 0.0 then None
    else
      let target = diagonal *. snap_ratio in
      if target <= 0.0 || not (Float.is_finite target) then None
      else
        let exponent = int_of_float (Float.ceil (Float.log2 target)) in
        Some (Float.ldexp 1.0 exponent)

(** Snap each vertex to the nearest point on a power-of-2 grid lattice,
    drop consecutive duplicates, and drop rings of fewer than 3 distinct
    vertices. *)
let snap_round (ps : polygon_set) ~grid : polygon_set =
  let snap x = Float.round (x /. grid) *. grid in
  List.filter_map (fun ring ->
    let buf = ref [] in
    Array.iter (fun (x, y) ->
      let p = (snap x, snap y) in
      match !buf with
      | last :: _ when last = p -> ()
      | _ -> buf := p :: !buf
    ) ring;
    let arr = Array.of_list (List.rev !buf) in
    let n = Array.length arr in
    (* Drop wrap-around duplicate of first vertex *)
    let arr =
      if n >= 2 && arr.(0) = arr.(n - 1) then Array.sub arr 0 (n - 1)
      else arr
    in
    if Array.length arr >= 3 then Some arr else None
  ) ps

let clone_nondegenerate (ps : polygon_set) : polygon_set =
  List.filter (fun r -> Array.length r >= 3) ps

(* ------------------------------------------------------------------ *)
(* List helpers (queue / status implemented as int lists)              *)
(* ------------------------------------------------------------------ *)

(* Insert idx into a list sorted in ascending order by [less]. *)
let rec list_insert_sorted less idx = function
  | [] -> [idx]
  | x :: rest as lst ->
    if less idx x then idx :: lst
    else x :: list_insert_sorted less idx rest

(* Insert idx at position pos in lst. *)
let list_insert_at pos idx lst =
  let rec go i = function
    | lst when i = pos -> idx :: lst
    | [] -> [idx]
    | x :: rest -> x :: go (i + 1) rest
  in
  go 0 lst

(* Remove the first occurrence of idx from lst. Returns the new list. *)
let rec list_remove idx = function
  | [] -> []
  | x :: rest when x = idx -> rest
  | x :: rest -> x :: list_remove idx rest

(* Find the position of idx in lst, or -1 if not found. *)
let list_position idx lst =
  let rec go i = function
    | [] -> -1
    | x :: _ when x = idx -> i
    | _ :: rest -> go (i + 1) rest
  in
  go 0 lst

(* Get element at position pos. Caller must ensure 0 <= pos < length. *)
let list_at pos lst =
  let rec go i = function
    | [] -> failwith "list_at: out of bounds"
    | x :: _ when i = pos -> x
    | _ :: rest -> go (i + 1) rest
  in
  go 0 lst

(* ------------------------------------------------------------------ *)
(* Sweep state and edge insertion                                      *)
(* ------------------------------------------------------------------ *)

let make_events () : sweep_event Dynarray.t = Dynarray.create ()

let add_edge events p1 p2 polygon =
  if p1 = p2 then ()
  else
    let lp, rp =
      if point_lex_less p1 p2 then (p1, p2) else (p2, p1)
    in
    let l = Dynarray.length events in
    let r = l + 1 in
    let le = make_sweep_event lp true polygon in
    let re = make_sweep_event rp false polygon in
    le.other_event <- r;
    re.other_event <- l;
    Dynarray.add_last events le;
    Dynarray.add_last events re

let add_polygon_set events ps polygon =
  List.iter (fun ring ->
    let n = Array.length ring in
    if n >= 3 then
      for i = 0 to n - 1 do
        add_edge events ring.(i) ring.((i + 1) mod n) polygon
      done
  ) ps

(* ------------------------------------------------------------------ *)
(* Forward declaration for the normalize hook                          *)
(* ------------------------------------------------------------------ *)

(* Set by Boolean_normalize at module init time. *)
let normalize_hook : (polygon_set -> polygon_set) ref =
  ref (fun ps -> ps)

(* ------------------------------------------------------------------ *)
(* Top-level dispatch                                                  *)
(* ------------------------------------------------------------------ *)

let rec run_boolean (a : polygon_set) (b : polygon_set) (op : operation) : polygon_set =
  let a_snap, b_snap =
    match snap_grid a b with
    | Some grid -> snap_round a ~grid, snap_round b ~grid
    | None -> clone_nondegenerate a, clone_nondegenerate b
  in
  let a_norm = !normalize_hook a_snap in
  let b_norm = !normalize_hook b_snap in
  let a_final, b_final =
    match snap_grid a_norm b_norm with
    | Some grid -> snap_round a_norm ~grid, snap_round b_norm ~grid
    | None -> a_norm, b_norm
  in
  run_boolean_sweep a_final b_final op

and run_boolean_sweep (a : polygon_set) (b : polygon_set) (op : operation) : polygon_set =
  let a_empty = List.for_all (fun r -> Array.length r < 3) a in
  let b_empty = List.for_all (fun r -> Array.length r < 3) b in
  if a_empty && b_empty then []
  else if a_empty then begin
    match op with
    | Union | Xor -> clone_nondegenerate b
    | Intersection | Difference -> []
  end
  else if b_empty then begin
    match op with
    | Union | Xor | Difference -> clone_nondegenerate a
    | Intersection -> []
  end
  else begin
    let events = make_events () in
    add_polygon_set events a Subject;
    add_polygon_set events b Clipping;

    (* Sort events ascending by event_less so List head is smallest. *)
    let n = Dynarray.length events in
    let initial = List.init n (fun i -> i) in
    let queue = ref (List.sort (fun a b ->
      if event_less events a b then -1
      else if event_less events b a then 1
      else 0
    ) initial) in

    let processed = ref [] in
    let status = ref [] in

    let pop_queue () =
      match !queue with
      | [] -> None
      | x :: rest -> queue := rest; Some x
    in

    let rec loop () =
      match pop_queue () with
      | None -> ()
      | Some idx ->
        processed := idx :: !processed;
        let ev = Dynarray.get events idx in
        if ev.is_left then begin
          let pos = status_insert_pos events !status idx in
          status := list_insert_at pos idx !status;
          compute_fields events !status pos;
          let len = List.length !status in
          if pos + 1 < len then begin
            let above = list_at (pos + 1) !status in
            possible_intersection events queue idx above op
          end;
          if pos > 0 then begin
            let below = list_at (pos - 1) !status in
            possible_intersection events queue below idx op
          end;
          (Dynarray.get events idx).in_result <-
            edge_in_result (Dynarray.get events idx) op
        end
        else begin
          let other = ev.other_event in
          let pos = list_position other !status in
          if pos >= 0 then begin
            let len = List.length !status in
            let above = if pos + 1 < len then Some (list_at (pos + 1) !status) else None in
            let below = if pos > 0 then Some (list_at (pos - 1) !status) else None in
            status := list_remove other !status;
            (match below, above with
             | Some b, Some a -> possible_intersection events queue b a op
             | _ -> ())
          end;
          (Dynarray.get events idx).in_result <-
            (Dynarray.get events other).in_result
        end;
        loop ()
    in
    loop ();

    connect_edges events (List.rev !processed)
  end

and status_insert_pos events status idx =
  (* Linear scan since the status list is small. *)
  let rec go i = function
    | [] -> i
    | x :: rest ->
      if status_less events x idx then go (i + 1) rest
      else i
  in
  go 0 status

and queue_push queue events idx =
  (* Maintain ascending event_less order. *)
  queue := list_insert_sorted (event_less events) idx !queue

(* ------------------------------------------------------------------ *)
(* Intersection detection                                              *)
(* ------------------------------------------------------------------ *)

and find_intersection (a1x, a1y) (a2x, a2y) (b1x, b1y) (b2x, b2y) =
  let dx_a = a2x -. a1x in
  let dy_a = a2y -. a1y in
  let dx_b = b2x -. b1x in
  let dy_b = b2y -. b1y in
  let denom = dx_a *. dy_b -. dy_a *. dx_b in
  if abs_float denom < 1e-12 then `Overlap
  else
    let dx_ab = a1x -. b1x in
    let dy_ab = a1y -. b1y in
    let s = (dx_b *. dy_ab -. dy_b *. dx_ab) /. denom in
    let t = (dx_a *. dy_ab -. dy_a *. dx_ab) /. denom in
    let eps = 1e-9 in
    if s < -. eps || s > 1.0 +. eps || t < -. eps || t > 1.0 +. eps then `None
    else
      let s = max 0.0 (min 1.0 s) in
      `Point (a1x +. s *. dx_a, a1y +. s *. dy_a)

and possible_intersection events queue e1 e2 op =
  let ev1 = Dynarray.get events e1 in
  let ev2 = Dynarray.get events e2 in
  if ev1.polygon = ev2.polygon then ()
  else begin
    let a1 = ev1.point in
    let a2 = (Dynarray.get events ev1.other_event).point in
    let b1 = ev2.point in
    let b2 = (Dynarray.get events ev2.other_event).point in
    match find_intersection a1 a2 b1 b2 with
    | `None -> ()
    | `Point p ->
      if not (points_eq p a1) && not (points_eq p a2) then
        ignore (divide_segment events queue e1 p);
      if not (points_eq p b1) && not (points_eq p b2) then
        ignore (divide_segment events queue e2 p)
    | `Overlap ->
      handle_collinear events queue e1 e2 op
  end

(* ------------------------------------------------------------------ *)
(* Collinear handling                                                  *)
(* ------------------------------------------------------------------ *)

and handle_collinear events queue e1 e2 op =
  let ev1 = Dynarray.get events e1 in
  let ev2 = Dynarray.get events e2 in
  let e1r = ev1.other_event in
  let e2r = ev2.other_event in
  let p1l = ev1.point in
  let p1r = (Dynarray.get events e1r).point in
  let p2l = ev2.point in
  let p2r = (Dynarray.get events e2r).point in

  (* Re-check true collinearity. *)
  if abs_float (signed_area p1l p1r p2l) > 1e-9
     || abs_float (signed_area p1l p1r p2r) > 1e-9 then ()
  else begin
    (* Overlap extent on dominant axis. *)
    let dx = abs_float (fst p1r -. fst p1l) in
    let dy = abs_float (snd p1r -. snd p1l) in
    let proj p = if dx >= dy then fst p else snd p in
    let s1_lo = min (proj p1l) (proj p1r) in
    let s1_hi = max (proj p1l) (proj p1r) in
    let s2_lo = min (proj p2l) (proj p2r) in
    let s2_hi = max (proj p2l) (proj p2r) in
    let lo = max s1_lo s2_lo in
    let hi = min s1_hi s2_hi in
    if hi -. lo <= 1e-9 then ()
    else begin
      let left_coincide = points_eq p1l p2l in
      let right_coincide = points_eq p1r p2r in
      let same_dir = ev1.in_out = ev2.in_out in
      let kept_type = if same_dir then Same_transition else Different_transition in

      if left_coincide && right_coincide then begin
        (* Case A *)
        ev1.edge_type <- Non_contributing;
        ev2.edge_type <- kept_type;
        ev1.in_result <- edge_in_result ev1 op;
        ev2.in_result <- edge_in_result ev2 op
      end
      else if left_coincide then begin
        (* Case B *)
        let longer_left, shorter_right_pt =
          if event_less events e1r e2r then (e2, p1r) else (e1, p2r)
        in
        let longer_left_pt = (Dynarray.get events longer_left).point in
        let longer_right_pt =
          (Dynarray.get events (Dynarray.get events longer_left).other_event).point
        in
        let shorter_right_pt =
          project_onto_segment longer_left_pt longer_right_pt shorter_right_pt
        in
        if longer_left = e1 then begin
          ev1.edge_type <- Non_contributing;
          ev2.edge_type <- kept_type
        end
        else begin
          ev1.edge_type <- kept_type;
          ev2.edge_type <- Non_contributing
        end;
        ev1.in_result <- edge_in_result ev1 op;
        ev2.in_result <- edge_in_result ev2 op;
        ignore (divide_segment events queue longer_left shorter_right_pt)
      end
      else if right_coincide then begin
        (* Case C *)
        let longer_left, later_left_pt =
          if event_less events e1 e2 then (e1, p2l) else (e2, p1l)
        in
        let longer_left_pt = (Dynarray.get events longer_left).point in
        let longer_right_pt =
          (Dynarray.get events (Dynarray.get events longer_left).other_event).point
        in
        let later_left_pt =
          project_onto_segment longer_left_pt longer_right_pt later_left_pt
        in
        let _, nr_idx = divide_segment events queue longer_left later_left_pt in
        let nr = Dynarray.get events nr_idx in
        nr.edge_type <- Non_contributing;
        let shorter = if longer_left = e1 then e2 else e1 in
        let sh = Dynarray.get events shorter in
        sh.edge_type <- kept_type;
        nr.in_result <- edge_in_result nr op;
        sh.in_result <- edge_in_result sh op
      end
      else begin
        (* Case D *)
        let endpoints = [e1; e1r; e2; e2r] in
        let endpoints = List.sort (fun a b ->
          if event_less events a b then -1
          else if event_less events b a then 1
          else 0
        ) endpoints in
        let first = List.nth endpoints 0 in
        let second = List.nth endpoints 1 in
        let third = List.nth endpoints 2 in
        let fourth = List.nth endpoints 3 in
        let first_ev = Dynarray.get events first in
        if first_ev.other_event = fourth then begin
          (* Case D1 — containment *)
          let first_pt = first_ev.point in
          let first_other_pt = (Dynarray.get events first_ev.other_event).point in
          let mid_left = project_onto_segment first_pt first_other_pt
            (Dynarray.get events second).point in
          let mid_right = project_onto_segment first_pt first_other_pt
            (Dynarray.get events third).point in
          let _, nr1 = divide_segment events queue first mid_left in
          let _, _ = divide_segment events queue nr1 mid_right in
          let nr1_ev = Dynarray.get events nr1 in
          nr1_ev.edge_type <- Non_contributing;
          let shorter = if first = e1 then e2 else e1 in
          let sh = Dynarray.get events shorter in
          sh.edge_type <- kept_type;
          nr1_ev.in_result <- edge_in_result nr1_ev op;
          sh.in_result <- edge_in_result sh op
        end
        else begin
          (* Case D2 — partial overlap *)
          let first_pt = first_ev.point in
          let first_other_pt = (Dynarray.get events first_ev.other_event).point in
          let split_a = project_onto_segment first_pt first_other_pt
            (Dynarray.get events second).point in
          let other_left = (Dynarray.get events fourth).other_event in
          let other_left_pt = (Dynarray.get events other_left).point in
          let other_right_pt =
            (Dynarray.get events (Dynarray.get events other_left).other_event).point
          in
          let split_b = project_onto_segment other_left_pt other_right_pt
            (Dynarray.get events third).point in
          let _, nr1 = divide_segment events queue first split_a in
          let _, _ = divide_segment events queue other_left split_b in
          let nr1_ev = Dynarray.get events nr1 in
          nr1_ev.edge_type <- Non_contributing;
          let kept_left = if first = e1 then e2 else e1 in
          let kl = Dynarray.get events kept_left in
          kl.edge_type <- kept_type;
          nr1_ev.in_result <- edge_in_result nr1_ev op;
          kl.in_result <- edge_in_result kl op
        end
      end
    end
  end

(* ------------------------------------------------------------------ *)
(* Segment subdivision                                                 *)
(* ------------------------------------------------------------------ *)

and divide_segment events queue edge_left_idx p =
  let edge_left = Dynarray.get events edge_left_idx in
  let edge_right_idx = edge_left.other_event in
  let polygon = edge_left.polygon in

  let l_idx = Dynarray.length events in
  let nr_idx = l_idx + 1 in
  let l_event = make_sweep_event p false polygon in
  l_event.other_event <- edge_left_idx;
  let nr_event = make_sweep_event p true polygon in
  nr_event.other_event <- edge_right_idx;
  Dynarray.add_last events l_event;
  Dynarray.add_last events nr_event;

  edge_left.other_event <- l_idx;
  (Dynarray.get events edge_right_idx).other_event <- nr_idx;

  queue_push queue events l_idx;
  queue_push queue events nr_idx;
  (l_idx, nr_idx)

(* ------------------------------------------------------------------ *)
(* Field computation                                                   *)
(* ------------------------------------------------------------------ *)

and compute_fields events status pos =
  let idx = list_at pos status in
  let ev = Dynarray.get events idx in
  if pos = 0 then begin
    ev.in_out <- false;
    ev.other_in_out <- true
  end
  else begin
    let prev_idx = list_at (pos - 1) status in
    let prev = Dynarray.get events prev_idx in
    let cur_polygon = ev.polygon in
    if cur_polygon = prev.polygon then begin
      ev.in_out <- not prev.in_out;
      ev.other_in_out <- prev.other_in_out
    end
    else begin
      let prev_other = Dynarray.get events prev.other_event in
      let prev_vertical = fst prev.point = fst prev_other.point in
      ev.in_out <- not prev.other_in_out;
      ev.other_in_out <- if prev_vertical then not prev.in_out else prev.in_out
    end;
    if prev.in_result then ev.prev_in_result <- prev_idx
    else ev.prev_in_result <- prev.prev_in_result
  end

(* ------------------------------------------------------------------ *)
(* Connection step                                                     *)
(* ------------------------------------------------------------------ *)

and connect_edges events order : polygon_set =
  let in_result = ref [] in
  List.iter (fun idx ->
    let e = Dynarray.get events idx in
    let is_in = if e.is_left then e.in_result
      else (Dynarray.get events e.other_event).in_result
    in
    if is_in then in_result := idx :: !in_result
  ) order;
  let in_result = List.rev !in_result in
  let in_result_arr = Array.of_list in_result in
  let n_in = Array.length in_result_arr in
  let pos_in_result = Hashtbl.create n_in in
  Array.iteri (fun i idx -> Hashtbl.add pos_in_result idx i) in_result_arr;
  let visited = Array.make n_in false in
  let result = ref [] in
  for start = 0 to n_in - 1 do
    if not visited.(start) then begin
      let ring = ref [] in
      let i = ref start in
      let break = ref false in
      while not !break do
        visited.(!i) <- true;
        let cur_event = in_result_arr.(!i) in
        ring := (Dynarray.get events cur_event).point :: !ring;
        let partner = (Dynarray.get events cur_event).other_event in
        match Hashtbl.find_opt pos_in_result partner with
        | None -> break := true
        | Some partner_pos ->
          visited.(partner_pos) <- true;
          let partner_point = (Dynarray.get events partner).point in
          let next = ref None in
          let j = ref (partner_pos + 1) in
          while !j < n_in && !next = None do
            if not visited.(!j) then begin
              if (Dynarray.get events in_result_arr.(!j)).point = partner_point then
                next := Some !j
              else if fst (Dynarray.get events in_result_arr.(!j)).point > fst partner_point then
                j := n_in (* break *)
            end;
            incr j
          done;
          if !next = None then begin
            let k = ref partner_pos in
            while !k > 0 && !next = None do
              decr k;
              if not visited.(!k) then begin
                if (Dynarray.get events in_result_arr.(!k)).point = partner_point then
                  next := Some !k
                else if fst (Dynarray.get events in_result_arr.(!k)).point < fst partner_point then
                  k := 0 (* break *)
              end
            done
          end;
          (match !next with
           | None -> break := true
           | Some j ->
             i := j;
             if !i = start then break := true)
      done;
      let ring_lst = List.rev !ring in
      if List.length ring_lst >= 3 then
        result := Array.of_list ring_lst :: !result
    end
  done;
  List.rev !result

(* ------------------------------------------------------------------ *)
(* Public API                                                          *)
(* ------------------------------------------------------------------ *)

let boolean_union a b = run_boolean a b Union
let boolean_intersect a b = run_boolean a b Intersection
let boolean_subtract a b = run_boolean a b Difference
let boolean_exclude a b = run_boolean a b Xor
