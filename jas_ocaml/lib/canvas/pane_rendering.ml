(** Pane rendering helpers: pure functions that compute rendering data
    from PaneLayout state. No GTK code. *)

type pane_geometry = {
  id : int;
  kind : Pane.pane_kind;
  config : Pane.pane_config;
  x : float;
  y : float;
  width : float;
  height : float;
  z_index : int;
  visible : bool;
}

type shared_border = {
  snap_idx : int;
  bx : float;
  by : float;
  bw : float;
  bh : float;
  is_vertical : bool;
}

type snap_line = {
  lx : float;
  ly : float;
  lw : float;
  lh : float;
}

let pane_geometries (pl : Pane.pane_layout) : pane_geometry list =
  let maximized = pl.canvas_maximized in
  Array.to_list pl.panes |> List.map (fun (p : Pane.pane) ->
    let visible = Pane.is_pane_visible pl p.kind in
    let x, y, w, h, z =
      if p.config.double_click_action = Pane.Maximize && maximized then
        (0.0, 0.0, pl.viewport_width, pl.viewport_height, 0)
      else if maximized then
        (p.x, p.y, p.width, p.height, Pane.pane_z_index pl p.id + 50)
      else
        (p.x, p.y, p.width, p.height, Pane.pane_z_index pl p.id)
    in
    { id = p.id; kind = p.kind; config = p.config;
      x; y; width = w; height = h; z_index = z; visible }
  )

let shared_borders (pl : Pane.pane_layout) : shared_border list =
  if pl.canvas_maximized then []
  else
    let result = ref [] in
    List.iteri (fun i (snap : Pane.snap_constraint) ->
      match snap.target with
      | Pane.Pane_target (other_id, other_edge) ->
        let is_vert = snap.edge = Pane.Right && other_edge = Pane.Left in
        let is_horiz = snap.edge = Pane.Bottom && other_edge = Pane.Top in
        if is_vert || is_horiz then begin
          match Pane.find_pane pl snap.snap_pane, Pane.find_pane pl other_id with
          | Some pa, Some pb ->
            if not (pa.config.fixed_width && pb.config.fixed_width)
               && not (is_vert && abs_float (pa.x +. pa.width -. pb.x) > 1.0)
               && not (is_horiz && abs_float (pa.y +. pa.height -. pb.y) > 1.0) then begin
              if is_vert then begin
                let bx = pa.x +. pa.width in
                let by = max pa.y pb.y in
                let bh = min (pa.y +. pa.height) (pb.y +. pb.height) -. by in
                if bh > 0.0 then
                  result := { snap_idx = i; bx = bx -. 3.0; by; bw = 6.0; bh; is_vertical = true } :: !result
              end else begin
                let by = pa.y +. pa.height in
                let bx = max pa.x pb.x in
                let bw = min (pa.x +. pa.width) (pb.x +. pb.width) -. bx in
                if bw > 0.0 then
                  result := { snap_idx = i; bx; by = by -. 3.0; bw; bh = 6.0; is_vertical = false } :: !result
              end
            end
          | _ -> ()
        end
      | _ -> ()
    ) pl.snaps;
    List.rev !result

let snap_lines (preview : Pane.snap_constraint list) (pl : Pane.pane_layout) : snap_line list =
  List.filter_map (fun (snap : Pane.snap_constraint) ->
    match Pane.find_pane pl snap.snap_pane with
    | None -> None
    | Some p ->
      let coord = Pane.pane_edge_coord p snap.edge in
      match snap.edge with
      | Pane.Left | Pane.Right ->
        Some { lx = coord -. 2.0; ly = p.y; lw = 4.0; lh = p.height }
      | Pane.Top | Pane.Bottom ->
        Some { lx = p.x; ly = coord -. 2.0; lw = p.width; lh = 4.0 }
  ) preview
