(** Path Eraser tool for splitting and removing path segments. *)

let eraser_size = 2.0
let flatten_steps = 20

let rec find_hit_segment flat min_x min_y max_x max_y =
  let rec check i = function
    | [] | [_] -> None
    | (x1, y1) :: ((x2, y2) :: _ as rest) ->
      if line_segment_intersects_rect x1 y1 x2 y2 min_x min_y max_x max_y then
        Some i
      else
        check (i + 1) rest
  in
  check 0 flat

and line_segment_intersects_rect x1 y1 x2 y2 min_x min_y max_x max_y =
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

let cmd_endpoint cmd =
  match cmd with
  | Element.MoveTo (x, y) | Element.LineTo (x, y) -> Some (x, y)
  | Element.CurveTo (_, _, _, _, x, y) -> Some (x, y)
  | Element.QuadTo (_, _, x, y) -> Some (x, y)
  | Element.SmoothCurveTo (_, _, x, y) -> Some (x, y)
  | Element.SmoothQuadTo (x, y) -> Some (x, y)
  | Element.ArcTo (_, _, _, _, _, x, y) -> Some (x, y)
  | Element.ClosePath -> None

let flat_index_to_cmd_index cmds flat_idx =
  let cmd_arr = Array.of_list cmds in
  let n = Array.length cmd_arr in
  let flat_count = ref 0 in
  let result = ref (max 0 (n - 1)) in
  let found = ref false in
  for cmd_idx = 0 to n - 1 do
    if not !found then begin
      let segs = match cmd_arr.(cmd_idx) with
        | Element.MoveTo _ -> 0
        | Element.LineTo _ -> 1
        | Element.CurveTo _ -> flatten_steps
        | Element.ClosePath -> 1
        | _ -> 1
      in
      if segs > 0 && flat_idx < !flat_count + segs then begin
        result := cmd_idx;
        found := true
      end;
      flat_count := !flat_count + segs
    end
  done;
  !result

let split_path_at_segment cmds flat_hit_idx is_closed =
  let cmd_idx = flat_index_to_cmd_index cmds flat_hit_idx in
  if is_closed then begin
    let drawing_cmds = List.filter (fun c -> c <> Element.ClosePath) cmds in
    match drawing_cmds with
    | [] -> []
    | _ ->
      let n = List.length drawing_cmds in
      let split_after = min (cmd_idx + 1) n in
      let after = List.filteri (fun i _ -> i >= split_after) drawing_cmds in
      let before = List.filteri (fun i _ -> i >= 1 && i < (min cmd_idx n)) drawing_cmds in
      let open_cmds = ref [] in
      let ref_idx = min (split_after - 1) (n - 1) in
      let ref_idx = max 0 ref_idx in
      let ref_cmd = List.nth drawing_cmds ref_idx in
      (match cmd_endpoint ref_cmd with
       | Some (x, y) -> open_cmds := [Element.MoveTo (x, y)]
       | None -> ());
      open_cmds := !open_cmds @ after;
      (match List.hd drawing_cmds with
       | Element.MoveTo (x, y) -> open_cmds := !open_cmds @ [Element.LineTo (x, y)]
       | _ -> ());
      open_cmds := !open_cmds @ before;
      if List.length !open_cmds >= 2 then [!open_cmds]
      else []
  end else begin
    let arr = Array.of_list cmds in
    let n = Array.length arr in
    let part1 = ref [] in
    let cur = ref (0.0, 0.0) in
    for i = 0 to cmd_idx - 1 do
      part1 := arr.(i) :: !part1;
      (match cmd_endpoint arr.(i) with
       | Some pt -> cur := pt
       | None -> ())
    done;
    let part1 = List.rev !part1 in
    let part2 = ref [] in
    if cmd_idx < n then begin
      (match cmd_endpoint arr.(cmd_idx) with
       | Some (x, y) -> part2 := [Element.MoveTo (x, y)]
       | None -> part2 := [Element.MoveTo (fst !cur, snd !cur)])
    end;
    for i = cmd_idx + 1 to n - 1 do
      if arr.(i) <> Element.ClosePath then
        part2 := arr.(i) :: !part2
    done;
    let part2 = List.rev !part2 in
    let result = ref [] in
    if List.length part1 >= 2 && List.exists (fun c ->
      match c with Element.MoveTo _ -> false | _ -> true) part1 then
      result := [part1];
    if List.length part2 >= 2 then
      result := !result @ [part2];
    !result
  end

class path_eraser_tool = object (_self)
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
    if erasing then begin
      _self#erase_at ctx x y;
      last_pos <- (x, y)
    end

  method on_release (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) ~(shift : bool) ~(alt : bool) =
    ignore (shift, alt);
    erasing <- false

  method on_double_click (_ctx : Canvas_tool.tool_context) (_x : float) (_y : float) = ()
  method on_key (_ctx : Canvas_tool.tool_context) (_keycode : int) = false
  method on_key_release (_ctx : Canvas_tool.tool_context) (_keycode : int) = false
  method activate (_ctx : Canvas_tool.tool_context) = ()
  method deactivate (_ctx : Canvas_tool.tool_context) = ()

  method draw_overlay (_ctx : Canvas_tool.tool_context) cr =
    if erasing then begin
      let (x, y) = last_pos in
      Cairo.set_source_rgba cr 1.0 0.0 0.0 0.5;
      Cairo.set_line_width cr 1.0;
      Cairo.arc cr x y ~r:eraser_size ~a1:0.0 ~a2:(2.0 *. Float.pi);
      Cairo.stroke cr
    end

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
      | Element.Layer { name; children; opacity; transform; locked } ->
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
              match find_hit_segment flat eraser_min_x eraser_min_y eraser_max_x eraser_max_y with
              | None -> new_children := child :: !new_children
              | Some hit_idx ->
                let (_bx, _by, bw, bh) = Element.bounds child in
                if bw <= eraser_size *. 2.0 && bh <= eraser_size *. 2.0 then begin
                  (* Delete the entire path *)
                  changed := true
                end else begin
                  let is_closed = List.exists (fun c -> c = Element.ClosePath) d in
                  let results = split_path_at_segment d hit_idx is_closed in
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
          Element.Layer { name; children = Array.of_list (List.rev !new_children); opacity; transform; locked }
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
