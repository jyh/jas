(** Pane layout: floating, movable, resizable panes.

    A {!pane_layout} manages the positions, sizes, and snap constraints
    for the top-level panes (toolbar, canvas, dock). Each {!pane} carries
    a {!pane_config} that drives generic behavior like tiling, resizing,
    and title bar chrome.

    This module contains only pure data types and state operations — no
    rendering code. *)

(* ------------------------------------------------------------------ *)
(* Constants                                                          *)
(* ------------------------------------------------------------------ *)

let min_toolbar_width = 72.0
let min_toolbar_height = 200.0
let min_canvas_width = 200.0
let min_canvas_height = 200.0
let min_pane_dock_width = 150.0
let min_pane_dock_height = 100.0
let default_toolbar_width = 72.0
let default_pane_dock_width = 240.0
let snap_distance = 20.0
let border_hit_tolerance = 6.0
let min_pane_visible = 50.0

(* ------------------------------------------------------------------ *)
(* Types                                                              *)
(* ------------------------------------------------------------------ *)

type pane_id = int

type pane_kind = Toolbar | Canvas | Dock

(** How a pane's width is allocated during the Tile operation.
    Derived at tile time from pane_config fields, not stored. *)
type tile_width = Fixed of float | Keep_current of float | Flex

(** Action triggered by double-clicking a pane's title bar. *)
type double_click_action = Maximize | Redock | No_action

type pane_config = {
  label : string;
  min_width : float;
  min_height : float;
  fixed_width : bool;
  (** Width when in collapsed state; None means not collapsible. *)
  collapsed_width : float option;
  (** Action triggered by double-clicking the title bar. *)
  double_click_action : double_click_action;
}

type pane = {
  id : pane_id;
  kind : pane_kind;
  mutable config : pane_config;
  mutable x : float;
  mutable y : float;
  mutable width : float;
  mutable height : float;
}

type edge_side = Left | Right | Top | Bottom

type snap_target =
  | Window_target of edge_side
  | Pane_target of pane_id * edge_side

type snap_constraint = {
  snap_pane : pane_id;
  edge : edge_side;
  target : snap_target;
}

type pane_layout = {
  mutable panes : pane array;
  mutable snaps : snap_constraint list;
  mutable z_order : pane_id list;
  mutable hidden_panes : pane_kind list;
  mutable canvas_maximized : bool;
  mutable viewport_width : float;
  mutable viewport_height : float;
  mutable next_pane_id : int;
}

(* ------------------------------------------------------------------ *)
(* Config                                                             *)
(* ------------------------------------------------------------------ *)

let config_for_kind = function
  | Toolbar -> {
      label = "Tools"; min_width = min_toolbar_width; min_height = min_toolbar_height;
      fixed_width = true; collapsed_width = None;
      double_click_action = No_action;
    }
  | Canvas -> {
      label = "Canvas"; min_width = min_canvas_width; min_height = min_canvas_height;
      fixed_width = false; collapsed_width = None;
      double_click_action = Maximize;
    }
  | Dock -> {
      label = "Panels"; min_width = min_pane_dock_width; min_height = min_pane_dock_height;
      fixed_width = false; collapsed_width = Some 36.0;
      double_click_action = Redock;
    }

(* ------------------------------------------------------------------ *)
(* Construction                                                       *)
(* ------------------------------------------------------------------ *)

let default_three_pane ~viewport_w ~viewport_h =
  let toolbar_w = default_toolbar_width in
  let dock_w = default_pane_dock_width in
  let canvas_w = max (viewport_w -. toolbar_w -. dock_w) min_canvas_width in
  let toolbar_id = 0 in
  let canvas_id = 1 in
  let dock_id = 2 in
  let panes = [|
    { id = toolbar_id; kind = Toolbar; config = config_for_kind Toolbar;
      x = 0.0; y = 0.0; width = toolbar_w; height = viewport_h };
    { id = canvas_id; kind = Canvas; config = config_for_kind Canvas;
      x = toolbar_w; y = 0.0; width = canvas_w; height = viewport_h };
    { id = dock_id; kind = Dock; config = config_for_kind Dock;
      x = toolbar_w +. canvas_w; y = 0.0; width = dock_w; height = viewport_h };
  |] in
  let snaps = [
    { snap_pane = toolbar_id; edge = Left; target = Window_target Left };
    { snap_pane = toolbar_id; edge = Top; target = Window_target Top };
    { snap_pane = toolbar_id; edge = Bottom; target = Window_target Bottom };
    { snap_pane = toolbar_id; edge = Right; target = Pane_target (canvas_id, Left) };
    { snap_pane = canvas_id; edge = Top; target = Window_target Top };
    { snap_pane = canvas_id; edge = Bottom; target = Window_target Bottom };
    { snap_pane = canvas_id; edge = Right; target = Pane_target (dock_id, Left) };
    { snap_pane = dock_id; edge = Right; target = Window_target Right };
    { snap_pane = dock_id; edge = Top; target = Window_target Top };
    { snap_pane = dock_id; edge = Bottom; target = Window_target Bottom };
  ] in
  { panes; snaps;
    z_order = [canvas_id; toolbar_id; dock_id];
    hidden_panes = []; canvas_maximized = false;
    viewport_width = viewport_w; viewport_height = viewport_h;
    next_pane_id = 3; }

(* ------------------------------------------------------------------ *)
(* Lookup                                                             *)
(* ------------------------------------------------------------------ *)

let find_pane pl id =
  Array.to_seq pl.panes |> Seq.find (fun p -> p.id = id)

let pane_by_kind pl kind =
  Array.to_seq pl.panes |> Seq.find (fun p -> p.kind = kind)

let pane_mut pl id f =
  Array.iter (fun p -> if p.id = id then f p) pl.panes

(* ------------------------------------------------------------------ *)
(* Move                                                               *)
(* ------------------------------------------------------------------ *)

let set_pane_position pl id ~x ~y =
  pane_mut pl id (fun p -> p.x <- x; p.y <- y);
  pl.snaps <- List.filter (fun s ->
    s.snap_pane <> id &&
    (match s.target with Pane_target (pid, _) -> pid <> id | _ -> true)
  ) pl.snaps

(* ------------------------------------------------------------------ *)
(* Resize                                                             *)
(* ------------------------------------------------------------------ *)

let resize_pane pl id ~width ~height =
  pane_mut pl id (fun p ->
    p.width <- max width p.config.min_width;
    p.height <- max height p.config.min_height)

(* ------------------------------------------------------------------ *)
(* Snap detection                                                     *)
(* ------------------------------------------------------------------ *)

let pane_edge_coord p edge =
  match edge with
  | Left -> p.x
  | Right -> p.x +. p.width
  | Top -> p.y
  | Bottom -> p.y +. p.height

let window_edge_coord edge vw vh =
  match edge with
  | Left | Top -> 0.0
  | Right -> vw
  | Bottom -> vh

let edges_can_snap a b =
  match a, b with
  | Right, Left | Left, Right | Bottom, Top | Top, Bottom -> true
  | _ -> false

let all_edges = [Left; Right; Top; Bottom]

let detect_snaps pl ~dragged ~viewport_w ~viewport_h =
  match find_pane pl dragged with
  | None -> []
  | Some dp ->
    let result = ref [] in
    (* Check window edges *)
    List.iter (fun edge ->
      let coord = pane_edge_coord dp edge in
      let win_coord = window_edge_coord edge viewport_w viewport_h in
      if abs_float (coord -. win_coord) <= snap_distance then
        result := { snap_pane = dragged; edge; target = Window_target edge } :: !result
    ) all_edges;
    (* Check other panes *)
    Array.iter (fun other ->
      if other.id <> dragged then
        List.iter (fun d_edge ->
          List.iter (fun o_edge ->
            if edges_can_snap d_edge o_edge then begin
              let d_coord = pane_edge_coord dp d_edge in
              let o_coord = pane_edge_coord other o_edge in
              if abs_float (d_coord -. o_coord) <= snap_distance then begin
                let overlaps = match d_edge with
                  | Left | Right ->
                    dp.y < other.y +. other.height && dp.y +. dp.height > other.y
                  | Top | Bottom ->
                    dp.x < other.x +. other.width && dp.x +. dp.width > other.x
                in
                if overlaps then begin
                  let snap =
                    if d_edge = Right || d_edge = Bottom then
                      { snap_pane = dragged; edge = d_edge; target = Pane_target (other.id, o_edge) }
                    else
                      { snap_pane = other.id; edge = o_edge; target = Pane_target (dragged, d_edge) }
                  in
                  result := snap :: !result
                end
              end
            end
          ) all_edges
        ) all_edges
    ) pl.panes;
    List.rev !result

(* ------------------------------------------------------------------ *)
(* Snap application                                                   *)
(* ------------------------------------------------------------------ *)

let align_pane_impl pl pane_id snaps viewport_w viewport_h =
  List.iter (fun snap ->
    if snap.snap_pane = pane_id then begin
      let target_coord = match snap.target with
        | Window_target we -> window_edge_coord we viewport_w viewport_h
        | Pane_target (other_id, other_edge) ->
          match find_pane pl other_id with
          | Some other -> pane_edge_coord other other_edge
          | None -> nan
      in
      if Float.is_finite target_coord then
        pane_mut pl pane_id (fun p ->
          match snap.edge with
          | Left -> p.x <- target_coord
          | Right -> p.x <- target_coord -. p.width
          | Top -> p.y <- target_coord
          | Bottom -> p.y <- target_coord -. p.height)
    end else begin
      match snap.target with
      | Pane_target (target_pid, target_edge) when target_pid = pane_id ->
        (match find_pane pl snap.snap_pane with
         | Some anchor ->
           let anchor_coord = pane_edge_coord anchor snap.edge in
           pane_mut pl pane_id (fun p ->
             match target_edge with
             | Left -> p.x <- anchor_coord
             | Right -> p.x <- anchor_coord -. p.width
             | Top -> p.y <- anchor_coord
             | Bottom -> p.y <- anchor_coord -. p.height)
         | None -> ())
      | _ -> ()
    end
  ) snaps

let align_to_snaps pl pane_id ~snaps ~viewport_w ~viewport_h =
  align_pane_impl pl pane_id snaps viewport_w viewport_h

let apply_snaps pl pane_id ~new_snaps ~viewport_w ~viewport_h =
  pl.snaps <- List.filter (fun s ->
    s.snap_pane <> pane_id &&
    (match s.target with Pane_target (pid, _) -> pid <> pane_id | _ -> true)
  ) pl.snaps;
  align_pane_impl pl pane_id new_snaps viewport_w viewport_h;
  pl.snaps <- pl.snaps @ new_snaps

(* ------------------------------------------------------------------ *)
(* Shared border                                                      *)
(* ------------------------------------------------------------------ *)

let shared_border_at pl ~x ~y ~tolerance =
  let snaps = pl.snaps in
  let len = List.length snaps in
  let rec go i = function
    | [] -> None
    | snap :: rest ->
      let other_id, other_edge = match snap.target with
        | Pane_target (pid, oe) -> pid, oe
        | _ -> -1, Left
      in
      if other_id < 0 then go (i + 1) rest
      else
        let is_vertical = snap.edge = Right && other_edge = Left in
        let is_horizontal = snap.edge = Bottom && other_edge = Top in
        if not is_vertical && not is_horizontal then go (i + 1) rest
        else
          match find_pane pl snap.snap_pane, find_pane pl other_id with
          | Some pane_a, Some pane_b ->
            if is_vertical then begin
              let border_x = pane_a.x +. pane_a.width in
              let min_y = max pane_a.y pane_b.y in
              let max_y = min (pane_a.y +. pane_a.height) (pane_b.y +. pane_b.height) in
              if abs_float (x -. border_x) <= tolerance && y >= min_y && y <= max_y then
                Some (i, Left)
              else go (i + 1) rest
            end else begin
              let border_y = pane_a.y +. pane_a.height in
              let min_x = max pane_a.x pane_b.x in
              let max_x = min (pane_a.x +. pane_a.width) (pane_b.x +. pane_b.width) in
              if abs_float (y -. border_y) <= tolerance && x >= min_x && x <= max_x then
                Some (i, Top)
              else go (i + 1) rest
            end
          | _ -> go (i + 1) rest
  in
  ignore len; go 0 snaps

(* ------------------------------------------------------------------ *)
(* Border dragging                                                    *)
(* ------------------------------------------------------------------ *)

let propagate_border_shift pl source_pane source_edge is_vertical =
  let chained = List.filter_map (fun s ->
    if s.snap_pane = source_pane && s.edge = source_edge then
      match s.target with
      | Pane_target (pid, pe) -> Some (pid, pe)
      | _ -> None
    else None
  ) pl.snaps in
  match find_pane pl source_pane with
  | None -> ()
  | Some source ->
    let edge_coord = pane_edge_coord source source_edge in
    List.iter (fun (pid, pe) ->
      pane_mut pl pid (fun p ->
        if is_vertical then
          (match pe with
           | Left -> p.x <- edge_coord
           | Right -> p.x <- edge_coord -. p.width
           | _ -> ())
        else
          (match pe with
           | Top -> p.y <- edge_coord
           | Bottom -> p.y <- edge_coord -. p.height
           | _ -> ()))
    ) chained

let drag_shared_border pl ~snap_idx ~delta =
  let snap = List.nth_opt pl.snaps snap_idx in
  match snap with
  | None -> ()
  | Some snap ->
    let other_id = match snap.target with
      | Pane_target (pid, _) -> pid
      | _ -> -1
    in
    if other_id < 0 then ()
    else
      match find_pane pl snap.snap_pane, find_pane pl other_id with
      | Some pa, Some pb ->
        let a_fixed = pa.config.fixed_width in
        let b_fixed = pb.config.fixed_width in
        let is_vertical = snap.edge = Right in
        if is_vertical then begin
          let a_w = pa.width and b_x = pb.x and b_w = pb.width in
          let max_expand = if b_fixed then 0.0 else b_w -. pb.config.min_width in
          let max_shrink = if a_fixed then 0.0 else a_w -. pa.config.min_width in
          let clamped = min (max delta (-.max_shrink)) max_expand in
          if not a_fixed then
            pane_mut pl snap.snap_pane (fun a -> a.width <- a.width +. clamped);
          if not b_fixed then
            pane_mut pl other_id (fun b ->
              b.x <- b_x +. clamped;
              b.width <- b.width -. clamped);
          propagate_border_shift pl other_id Right true
        end else begin
          let a_h = pa.height and b_y = pb.y and b_h = pb.height in
          let max_expand = if b_fixed then 0.0 else b_h -. pb.config.min_height in
          let max_shrink = if a_fixed then 0.0 else a_h -. pa.config.min_height in
          let clamped = min (max delta (-.max_shrink)) max_expand in
          if not a_fixed then
            pane_mut pl snap.snap_pane (fun a -> a.height <- a.height +. clamped);
          if not b_fixed then
            pane_mut pl other_id (fun b ->
              b.y <- b_y +. clamped;
              b.height <- b.height -. clamped);
          propagate_border_shift pl other_id Bottom false
        end;
      | _ -> ()

(* ------------------------------------------------------------------ *)
(* Canvas maximization                                                *)
(* ------------------------------------------------------------------ *)

let toggle_canvas_maximized pl =
  pl.canvas_maximized <- not pl.canvas_maximized

(* ------------------------------------------------------------------ *)
(* Tiling                                                             *)
(* ------------------------------------------------------------------ *)

let tile_panes pl ~collapsed_override =
  let vw = pl.viewport_width in
  let vh = pl.viewport_height in
  pl.canvas_maximized <- false;
  pl.hidden_panes <- [];
  (* Sort by position: ascending x, tiebreak by descending y *)
  let visible = Array.to_list pl.panes
    |> List.map (fun p -> (p.id, p.x, p.y))
    |> List.sort (fun (_, x1, y1) (_, x2, y2) ->
         let c = compare x1 x2 in
         if c <> 0 then c else compare y2 y1)
  in
  if visible = [] then ()
  else begin
    (* Derive tile widths from config *)
    let tile_widths = List.map (fun (id, _, _) ->
      match collapsed_override with
      | Some (oid, cw) when oid = id -> Fixed cw
      | _ ->
        match find_pane pl id with
        | Some p when p.config.fixed_width -> Fixed p.width
        | Some p when p.config.collapsed_width <> None -> Keep_current p.width
        | _ -> Flex
    ) visible in
    (* Compute widths *)
    let fixed_total = ref 0.0 in
    let flex_count = ref 0 in
    let widths = List.map (fun tw ->
      match tw with
      | Fixed w -> fixed_total := !fixed_total +. w; w
      | Keep_current w -> fixed_total := !fixed_total +. w; w
      | Flex -> incr flex_count; 0.0
    ) tile_widths in
    let flex_each =
      if !flex_count > 0 then
        let min_flex = List.fold_left2 (fun acc (id, _, _) tw ->
          match tw with
          | Flex -> (match find_pane pl id with Some p -> max acc p.config.min_width | None -> acc)
          | _ -> acc
        ) 0.0 visible tile_widths in
        max ((vw -. !fixed_total) /. float_of_int !flex_count) min_flex
      else 0.0
    in
    let widths = List.map2 (fun tw w ->
      match tw with Flex -> flex_each | _ -> w
    ) tile_widths widths in
    (* Assign positions *)
    let x = ref 0.0 in
    List.iter2 (fun (id, _, _) w ->
      pane_mut pl id (fun p ->
        p.x <- !x;
        p.y <- 0.0;
        p.width <- w;
        p.height <- vh);
      x := !x +. w
    ) visible widths;
    (* Rebuild snaps *)
    pl.snaps <- [];
    let len = List.length visible in
    List.iteri (fun i (id, _, _) ->
      if i = 0 then
        pl.snaps <- pl.snaps @ [{ snap_pane = id; edge = Left; target = Window_target Left }];
      if i = len - 1 then
        pl.snaps <- pl.snaps @ [{ snap_pane = id; edge = Right; target = Window_target Right }];
      pl.snaps <- pl.snaps @ [
        { snap_pane = id; edge = Top; target = Window_target Top };
        { snap_pane = id; edge = Bottom; target = Window_target Bottom };
      ];
      if i + 1 < len then begin
        let next_id = let (nid, _, _) = List.nth visible (i + 1) in nid in
        pl.snaps <- pl.snaps @ [{ snap_pane = id; edge = Right; target = Pane_target (next_id, Left) }]
      end
    ) visible
  end

(* ------------------------------------------------------------------ *)
(* Z-order                                                            *)
(* ------------------------------------------------------------------ *)

let bring_pane_to_front pl id =
  if List.mem id pl.z_order then begin
    pl.z_order <- List.filter (fun zid -> zid <> id) pl.z_order;
    pl.z_order <- pl.z_order @ [id]
  end

(* ------------------------------------------------------------------ *)
(* Pane visibility                                                    *)
(* ------------------------------------------------------------------ *)

(** Hide a pane (close it). If the pane is maximized, unmaximize first. *)
let hide_pane pl kind =
  if pl.canvas_maximized then
    (match pane_by_kind pl kind with
     | Some p when p.config.double_click_action = Maximize ->
       pl.canvas_maximized <- false
     | _ -> ());
  if not (List.mem kind pl.hidden_panes) then
    pl.hidden_panes <- pl.hidden_panes @ [kind]

(** Show a hidden pane and bring it to the front. *)
let show_pane pl kind =
  pl.hidden_panes <- List.filter (fun k -> k <> kind) pl.hidden_panes;
  match pane_by_kind pl kind with
  | Some p -> bring_pane_to_front pl p.id
  | None -> ()

let is_pane_visible pl kind =
  not (List.mem kind pl.hidden_panes)

let pane_z_index pl id =
  let rec go i = function
    | [] -> 0
    | zid :: _ when zid = id -> i
    | _ :: rest -> go (i + 1) rest
  in
  go 0 pl.z_order

(* ------------------------------------------------------------------ *)
(* Viewport resize                                                    *)
(* ------------------------------------------------------------------ *)

let clamp_panes pl ~viewport_w ~viewport_h =
  Array.iter (fun p ->
    p.x <- min (max p.x (-.p.width +. min_pane_visible)) (viewport_w -. min_pane_visible);
    p.y <- min (max p.y (-.p.height +. min_pane_visible)) (viewport_h -. min_pane_visible)
  ) pl.panes

let on_viewport_resize pl ~new_w ~new_h =
  if pl.viewport_width <= 0.0 || pl.viewport_height <= 0.0 then begin
    pl.viewport_width <- new_w;
    pl.viewport_height <- new_h
  end else begin
    let sx = new_w /. pl.viewport_width in
    let sy = new_h /. pl.viewport_height in
    Array.iter (fun p ->
      p.x <- p.x *. sx;
      p.y <- p.y *. sy;
      if not p.config.fixed_width then
        p.width <- max (p.width *. sx) p.config.min_width;
      p.height <- max (p.height *. sy) p.config.min_height
    ) pl.panes;
    pl.viewport_width <- new_w;
    pl.viewport_height <- new_h;
    clamp_panes pl ~viewport_w:new_w ~viewport_h:new_h
  end

(* ------------------------------------------------------------------ *)
(* Repair snaps                                                       *)
(* ------------------------------------------------------------------ *)

let repair_snaps pl ~viewport_w ~viewport_h =
  let tolerance = snap_distance in
  let pane_copies = Array.copy pl.panes in
  Array.iter (fun a ->
    (* Window edges *)
    List.iter (fun edge ->
      let coord = pane_edge_coord a edge in
      let win_coord = window_edge_coord edge viewport_w viewport_h in
      if abs_float (coord -. win_coord) <= tolerance then begin
        let exists = List.exists (fun s ->
          s.snap_pane = a.id && s.edge = edge && s.target = Window_target edge
        ) pl.snaps in
        if not exists then
          pl.snaps <- pl.snaps @ [{ snap_pane = a.id; edge; target = Window_target edge }]
      end
    ) all_edges;
    (* Other panes — canonical Right->Left / Bottom->Top *)
    Array.iter (fun b ->
      if a.id <> b.id then begin
        (* Vertical: a.Right near b.Left *)
        if abs_float (pane_edge_coord a Right -. pane_edge_coord b Left) <= tolerance then begin
          if a.y < b.y +. b.height && a.y +. a.height > b.y then begin
            let exists = List.exists (fun s ->
              s.snap_pane = a.id && s.edge = Right && s.target = Pane_target (b.id, Left)
            ) pl.snaps in
            if not exists then
              pl.snaps <- pl.snaps @ [{ snap_pane = a.id; edge = Right; target = Pane_target (b.id, Left) }]
          end
        end;
        (* Horizontal: a.Bottom near b.Top *)
        if abs_float (pane_edge_coord a Bottom -. pane_edge_coord b Top) <= tolerance then begin
          if a.x < b.x +. b.width && a.x +. a.width > b.x then begin
            let exists = List.exists (fun s ->
              s.snap_pane = a.id && s.edge = Bottom && s.target = Pane_target (b.id, Top)
            ) pl.snaps in
            if not exists then
              pl.snaps <- pl.snaps @ [{ snap_pane = a.id; edge = Bottom; target = Pane_target (b.id, Top) }]
          end
        end
      end
    ) pane_copies
  ) pane_copies
