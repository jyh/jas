(* Pattern brush tiling. See pattern_along_path.mli. Faithful port of
   jas_dioxus/src/algorithms/pattern_along_path.rs. *)

type t = {
  tile_width : float;
  tile_height : float;
  side : (float * float) list list;
  scale : float;
  spacing : float;
  flip_across : bool;
  flip_along : bool;
  stroke_weight : float;
}

let tile (commands : Element.path_command list) (brush : t) :
    (float * float) list list =
  if brush.tile_width <= 0.0 || brush.tile_height <= 0.0 then []
  else
    let pts = Art_along_path.flatten commands in
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
        let ribbon = (brush.scale /. 100.0) *. brush.stroke_weight in
        let tile_w = ribbon *. (brush.tile_width /. brush.tile_height) in
        if tile_w <= 0.0 then []
        else
          let gap = tile_w *. (brush.spacing /. 100.0) in
          let step = tile_w +. gap in
          if step <= 0.0 then []
          else
            let count = max 1 (int_of_float (Float.floor (total /. step))) in
            let warp_poly start poly =
              List.map
                (fun (ax, ay) ->
                  let u = ax /. brush.tile_width in
                  let u = if u < 0.0 then 0.0 else if u > 1.0 then 1.0 else u in
                  let u = if brush.flip_along then 1.0 -. u else u in
                  let s = start +. (u *. tile_w) in
                  let px, py, tan =
                    Art_along_path.point_at_arclength pts cum total s
                  in
                  let off =
                    (ay -. (brush.tile_height /. 2.0)) /. brush.tile_height
                    *. ribbon
                  in
                  let off = if brush.flip_across then -.off else off in
                  let nx = -.sin tan and ny = cos tan in
                  (px +. (nx *. off), py +. (ny *. off)))
                poly
            in
            List.concat_map
              (fun i ->
                let start = float_of_int i *. step in
                List.map (warp_poly start) brush.side)
              (List.init count Fun.id)
    end
