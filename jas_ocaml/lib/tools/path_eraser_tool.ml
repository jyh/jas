(** Path Eraser tool for splitting and removing path segments.

    Algorithm:

    The eraser sweeps a rectangular region (derived from the cursor position and
    eraser_size) across the canvas. For each path that intersects this region:

    1. Flatten — The path's commands (LineTo, CurveTo, QuadTo, etc.) are
       flattened into a polyline of straight segments. Bezier curves are
       approximated with flatten_steps (20) line segments each.

    2. Hit detection — Walk the flattened segments to find the first and
       last segments that intersect the eraser rectangle (using Liang-Barsky
       line-rectangle clipping). This gives the contiguous "hit range."

    3. Boundary intersection — Compute the exact entry and exit points
       where the path crosses the eraser boundary. Liang-Barsky gives t_min
       (entry) and t_max (exit) parameters on the first/last hit flat segments.

    4. Map back to original commands — flat_index_to_cmd_and_t converts
       each flat segment index + t-on-segment into a (command index, t) pair.
       For a CurveTo with N flatten steps, flat segment j spans
       t = [j/N, (j+1)/N], so command-level t = (j + t_seg) / N.

    5. Curve-preserving split — De Casteljau's algorithm splits Bezier
       curves at the entry/exit t parameters, producing two sub-curves that
       exactly reconstruct the original.

    6. Reassembly — For open paths, the result is two sub-paths: one from
       the original start to the entry point, and one from the exit point to the
       original end. For closed paths, the path is "unwrapped" into a single
       open path that runs from the exit point around the non-erased portion
       back to the entry point.

    Paths whose bounding box is smaller than the eraser are deleted entirely. *)

let eraser_size = 2.0
let flatten_steps = 20

let line_segment_intersects_rect x1 y1 x2 y2 min_x min_y max_x max_y =
  if x1 >= min_x && x1 <= max_x && y1 >= min_y && y1 <= max_y then true
  else if x2 >= min_x && x2 <= max_x && y2 >= min_y && y2 <= max_y then true
  else begin
    let t_min = ref 0.0 in
    let t_max = ref 1.0 in
    let dx = x2 -. x1 in
    let dy = y2 -. y1 in
    let clips = [
      (-. dx, x1 -. min_x);
      (dx, max_x -. x1);
      (-. dy, y1 -. min_y);
      (dy, max_y -. y1);
    ] in
    let reject = ref false in
    List.iter (fun (p, q) ->
      if not !reject then begin
        if abs_float p < 1e-12 then begin
          if q < 0.0 then reject := true
        end else begin
          let t = q /. p in
          if p < 0.0 then
            t_min := max !t_min t
          else
            t_max := min !t_max t;
          if !t_min > !t_max then reject := true
        end
      end
    ) clips;
    not !reject
  end

(** Find the range of flattened segments that intersect the eraser rectangle,
    and compute entry/exit points where the path crosses the eraser boundary. *)
type eraser_hit = {
  first_flat_idx: int;
  last_flat_idx: int;
  entry_t_seg: float;
  entry: float * float;
  exit_t_seg: float;
  exit_pt: float * float;
}

let liang_barsky_t_min x1 y1 x2 y2 min_x min_y max_x max_y =
  let dx = x2 -. x1 in
  let dy = y2 -. y1 in
  let t_min = ref 0.0 in
  List.iter (fun (p, q) ->
    if abs_float p >= 1e-12 && p < 0.0 then
      t_min := max !t_min (q /. p)
  ) [(-. dx, x1 -. min_x); (dx, max_x -. x1);
     (-. dy, y1 -. min_y); (dy, max_y -. y1)];
  max 0.0 (min 1.0 !t_min)

let liang_barsky_t_max x1 y1 x2 y2 min_x min_y max_x max_y =
  let dx = x2 -. x1 in
  let dy = y2 -. y1 in
  let t_max = ref 1.0 in
  List.iter (fun (p, q) ->
    if abs_float p >= 1e-12 && p > 0.0 then
      t_max := min !t_max (q /. p)
  ) [(-. dx, x1 -. min_x); (dx, max_x -. x1);
     (-. dy, y1 -. min_y); (dy, max_y -. y1)];
  max 0.0 (min 1.0 !t_max)

let find_eraser_hit flat min_x min_y max_x max_y =
  let arr = Array.of_list flat in
  let n = Array.length arr in
  let first_hit = ref (-1) in
  let last_hit = ref (-1) in
  let stop = ref false in
  for i = 0 to n - 2 do
    if not !stop then begin
      let (x1, y1) = arr.(i) in
      let (x2, y2) = arr.(i + 1) in
      if line_segment_intersects_rect x1 y1 x2 y2 min_x min_y max_x max_y then begin
        if !first_hit < 0 then first_hit := i;
        last_hit := i
      end else if !first_hit >= 0 then
        stop := true
    end
  done;
  if !first_hit < 0 then None
  else begin
    let first = !first_hit in
    let last = !last_hit in
    let (x1, y1) = arr.(first) in
    let (x2, y2) = arr.(first + 1) in
    let entry_t_seg =
      if x1 >= min_x && x1 <= max_x && y1 >= min_y && y1 <= max_y then 0.0
      else liang_barsky_t_min x1 y1 x2 y2 min_x min_y max_x max_y
    in
    let entry = (x1 +. entry_t_seg *. (x2 -. x1), y1 +. entry_t_seg *. (y2 -. y1)) in
    let (x1, y1) = arr.(last) in
    let (x2, y2) = arr.(last + 1) in
    let exit_t_seg =
      if x2 >= min_x && x2 <= max_x && y2 >= min_y && y2 <= max_y then 1.0
      else liang_barsky_t_max x1 y1 x2 y2 min_x min_y max_x max_y
    in
    let exit_pt = (x1 +. exit_t_seg *. (x2 -. x1), y1 +. exit_t_seg *. (y2 -. y1)) in
    Some { first_flat_idx = first; last_flat_idx = last;
           entry_t_seg; entry; exit_t_seg; exit_pt }
  end

let cmd_endpoint cmd =
  match cmd with
  | Element.MoveTo (x, y) | Element.LineTo (x, y) -> Some (x, y)
  | Element.CurveTo (_, _, _, _, x, y) -> Some (x, y)
  | Element.QuadTo (_, _, x, y) -> Some (x, y)
  | Element.SmoothCurveTo (_, _, x, y) -> Some (x, y)
  | Element.SmoothQuadTo (x, y) -> Some (x, y)
  | Element.ArcTo (_, _, _, _, _, x, y) -> Some (x, y)
  | Element.ClosePath -> None

let flat_index_to_cmd_and_t cmds flat_idx t_on_seg =
  let cmd_arr = Array.of_list cmds in
  let n = Array.length cmd_arr in
  let flat_count = ref 0 in
  let result = ref (max 0 (n - 1), 1.0) in
  let found = ref false in
  for cmd_idx = 0 to n - 1 do
    if not !found then begin
      let segs = match cmd_arr.(cmd_idx) with
        | Element.MoveTo _ -> 0
        | Element.LineTo _ -> 1
        | Element.CurveTo _ | Element.QuadTo _ -> flatten_steps
        | Element.ClosePath -> 1
        | _ -> 1
      in
      if segs > 0 && flat_idx < !flat_count + segs then begin
        let local = flat_idx - !flat_count in
        let t = (float_of_int local +. t_on_seg) /. float_of_int segs in
        result := (cmd_idx, max 0.0 (min 1.0 t));
        found := true
      end;
      flat_count := !flat_count + segs
    end
  done;
  !result

(** Split a cubic Bezier at parameter t using De Casteljau's algorithm. *)
let split_cubic_at (p0x, p0y) x1 y1 x2 y2 x y t =
  let lerp a b = a +. t *. (b -. a) in
  (* Level 1 *)
  let ax = lerp p0x x1 in let ay = lerp p0y y1 in
  let bx = lerp x1 x2 in let by = lerp y1 y2 in
  let cx = lerp x2 x in let cy = lerp y2 y in
  (* Level 2 *)
  let dx = lerp ax bx in let dy = lerp ay by in
  let ex = lerp bx cx in let ey = lerp by cy in
  (* Level 3 — point on curve *)
  let fx = lerp dx ex in let fy = lerp dy ey in
  let first = Element.CurveTo (ax, ay, dx, dy, fx, fy) in
  let second = Element.CurveTo (ex, ey, cx, cy, x, y) in
  (first, second)

(** Split a quadratic Bezier at parameter t using De Casteljau's algorithm. *)
let split_quad_at (p0x, p0y) qx1 qy1 x y t =
  let lerp a b = a +. t *. (b -. a) in
  let ax = lerp p0x qx1 in let ay = lerp p0y qy1 in
  let bx = lerp qx1 x in let by = lerp qy1 y in
  let cx = lerp ax bx in let cy = lerp ay by in
  let first = Element.QuadTo (ax, ay, cx, cy) in
  let second = Element.QuadTo (bx, by, x, y) in
  (first, second)

(** Build the command start points array. *)
let cmd_start_points cmds =
  let arr = Array.of_list cmds in
  let n = Array.length arr in
  let starts = Array.make n (0.0, 0.0) in
  let cur = ref (0.0, 0.0) in
  for i = 0 to n - 1 do
    starts.(i) <- !cur;
    (match cmd_endpoint arr.(i) with
     | Some pt -> cur := pt
     | None -> ())
  done;
  starts

(** Generate the first-half command ending at the entry point, preserving curves. *)
let entry_cmd cmd start t =
  match cmd with
  | Element.CurveTo (x1, y1, x2, y2, x, y) ->
    fst (split_cubic_at start x1 y1 x2 y2 x y t)
  | Element.QuadTo (x1, y1, x, y) ->
    fst (split_quad_at start x1 y1 x y t)
  | _ ->
    let endpt = match cmd_endpoint cmd with Some p -> p | None -> start in
    let (sx, sy) = start in
    Element.LineTo (sx +. t *. (fst endpt -. sx), sy +. t *. (snd endpt -. sy))

(** Generate the second-half command starting from the exit point, preserving curves. *)
let exit_cmd cmd start t =
  match cmd with
  | Element.CurveTo (x1, y1, x2, y2, x, y) ->
    snd (split_cubic_at start x1 y1 x2 y2 x y t)
  | Element.QuadTo (x1, y1, x, y) ->
    snd (split_quad_at start x1 y1 x y t)
  | _ ->
    let endpt = match cmd_endpoint cmd with Some p -> p | None -> start in
    Element.LineTo (fst endpt, snd endpt)

(** Split a path at the eraser hit, with endpoints hugging the eraser boundary
    and curves preserved via De Casteljau splitting. *)
let split_path_at_eraser cmds (hit : eraser_hit) is_closed =
  let (entry_cmd_idx, entry_t) = flat_index_to_cmd_and_t cmds hit.first_flat_idx hit.entry_t_seg in
  let (exit_cmd_idx, exit_t) = flat_index_to_cmd_and_t cmds hit.last_flat_idx hit.exit_t_seg in
  let starts = cmd_start_points cmds in
  let cmd_arr = Array.of_list cmds in

  if is_closed then begin
    let drawing_cmds = List.mapi (fun i c -> (i, c)) cmds
      |> List.filter (fun (_, c) -> c <> Element.ClosePath) in
    match drawing_cmds with
    | [] -> []
    | _ ->
      let open_cmds = ref [] in
      let (ex, ey) = hit.exit_pt in
      open_cmds := [Element.MoveTo (ex, ey)];

      (* If the exit command has a remaining portion, add it as a curve. *)
      if exit_t < 1.0 -. 1e-9 then begin
        match List.find_opt (fun (i, _) -> i = exit_cmd_idx) drawing_cmds with
        | Some (orig_idx, cmd) ->
          open_cmds := !open_cmds @ [exit_cmd cmd starts.(orig_idx) exit_t]
        | None -> ()
      end;

      (* Commands after the last erased command. *)
      let resume_from = exit_cmd_idx + 1 in
      List.iter (fun (orig_idx, cmd) ->
        if orig_idx >= resume_from && orig_idx < Array.length cmd_arr then
          open_cmds := !open_cmds @ [cmd]
      ) drawing_cmds;

      (* Wrap around: line to original start, then commands before the erased region. *)
      (match List.hd drawing_cmds with
       | (_, Element.MoveTo (x, y)) -> open_cmds := !open_cmds @ [Element.LineTo (x, y)]
       | _ -> ());
      List.iter (fun (orig_idx, cmd) ->
        if orig_idx >= 1 && orig_idx < entry_cmd_idx then
          open_cmds := !open_cmds @ [cmd]
      ) drawing_cmds;

      (* End with the entry portion of the entry command. *)
      if entry_t > 1e-9 then
        open_cmds := !open_cmds @ [entry_cmd cmd_arr.(entry_cmd_idx) starts.(entry_cmd_idx) entry_t]
      else begin
        let (nx, ny) = hit.entry in
        open_cmds := !open_cmds @ [Element.LineTo (nx, ny)]
      end;

      if List.length !open_cmds >= 2 then [!open_cmds]
      else []
  end else begin
    let n = Array.length cmd_arr in
    let part1 = ref [] in
    for i = 0 to entry_cmd_idx - 1 do
      part1 := cmd_arr.(i) :: !part1
    done;
    let part1 = List.rev !part1 in
    let part1 =
      if entry_t > 1e-9 then
        part1 @ [entry_cmd cmd_arr.(entry_cmd_idx) starts.(entry_cmd_idx) entry_t]
      else begin
        let (nx, ny) = hit.entry in
        part1 @ [Element.LineTo (nx, ny)]
      end
    in

    let (ex, ey) = hit.exit_pt in
    let part2 = ref [Element.MoveTo (ex, ey)] in
    if exit_t < 1.0 -. 1e-9 then
      part2 := !part2 @ [exit_cmd cmd_arr.(exit_cmd_idx) starts.(exit_cmd_idx) exit_t];
    for i = exit_cmd_idx + 1 to n - 1 do
      if cmd_arr.(i) <> Element.ClosePath then
        part2 := !part2 @ [cmd_arr.(i)]
    done;
    let part2 = !part2 in

    let result = ref [] in
    if List.length part1 >= 2 && List.exists (fun c ->
      match c with Element.MoveTo _ -> false | _ -> true) part1 then
      result := [part1];
    if List.length part2 >= 2 then
      result := !result @ [part2];
    !result
  end

class path_eraser_tool = object (_self)
  inherit Canvas_tool.default_methods
  val mutable erasing = false
  val mutable last_pos = (0.0, 0.0)

  method on_press (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    ctx.model#snapshot;
    erasing <- true;
    last_pos <- (x, y);
    _self#erase_at ctx x y

  method on_move (ctx : Canvas_tool.tool_context) x y ~(shift : bool) ~(dragging : bool) =
    ignore (shift, dragging);
    if erasing then
      _self#erase_at ctx x y;
    last_pos <- (x, y)

  method on_release (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    erasing <- false

  method on_double_click (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = ()
  method on_key (_ctx : Canvas_tool.tool_context) (_keycode : int) = false
  method on_key_release (_ctx : Canvas_tool.tool_context) (_keycode : int) = false
  method activate (_ctx : Canvas_tool.tool_context) = ()
  method deactivate (_ctx : Canvas_tool.tool_context) = ()

  method draw_overlay (_ctx : Canvas_tool.tool_context) cr =
    let (x, y) = last_pos in
    Cairo.set_source_rgba cr 1.0 0.0 0.0 0.5;
    Cairo.set_line_width cr 1.0;
    Cairo.arc cr x y ~r:eraser_size ~a1:0.0 ~a2:(2.0 *. Float.pi);
    Cairo.stroke cr

  method private erase_at (ctx : Canvas_tool.tool_context) x y =
    let doc = ctx.model#document in
    let half = eraser_size in
    let (lx, ly) = last_pos in
    let eraser_min_x = (min lx x) -. half in
    let eraser_min_y = (min ly y) -. half in
    let eraser_max_x = (max lx x) +. half in
    let eraser_max_y = (max ly y) +. half in
    let changed = ref false in
    let new_layers = Array.map (fun layer ->
      match layer with
      | Element.Layer { name; children; opacity; transform; locked; visibility; blend_mode;
                        isolated_blending; knockout_group } ->
        let new_children = ref [] in
        Array.iter (fun child ->
          match child with
          | Element.Path { d; fill; stroke; locked = path_locked; _ }
            when not path_locked ->
            let (fill : Element.fill option) = fill in
            let (stroke : Element.stroke option) = stroke in
            let flat = Element.flatten_path_commands d in
            if List.length flat < 2 then
              new_children := child :: !new_children
            else begin
              match find_eraser_hit flat eraser_min_x eraser_min_y eraser_max_x eraser_max_y with
              | None -> new_children := child :: !new_children
              | Some hit ->
                let (_bx, _by, bw, bh) = Element.bounds child in
                if bw <= eraser_size *. 2.0 && bh <= eraser_size *. 2.0 then begin
                  (* Delete the entire path *)
                  changed := true
                end else begin
                  let is_closed = List.exists (fun c -> c = Element.ClosePath) d in
                  let results = split_path_at_eraser d hit is_closed in
                  List.iter (fun cmds ->
                    if List.length cmds >= 2 then begin
                      let new_d = List.filter (fun c -> c <> Element.ClosePath) cmds in
                      let new_path = Element.make_path new_d
                        ~fill ~stroke in
                      new_children := new_path :: !new_children
                    end
                  ) results;
                  changed := true
                end
            end
          | _ -> new_children := child :: !new_children
        ) children;
        if !changed then
          Element.Layer { name; children = Array.of_list (List.rev !new_children); opacity; transform; locked; visibility; blend_mode;
                           isolated_blending; knockout_group }
        else layer
      | _ -> layer
    ) doc.Document.layers in
    if !changed then begin
      let new_doc = { doc with
        Document.layers = new_layers;
        Document.selection = Document.PathMap.empty;
      } in
      ctx.model#set_document new_doc;
      ctx.request_update ()
    end
end
