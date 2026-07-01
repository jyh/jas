(* Bristle brush. See bristle_stroke.mli. Faithful port of
   jas_dioxus/src/algorithms/bristle_stroke.rs. *)

type t = {
  size : float;
  density : float;
  thickness : float;
  opacity : float;
  stroke_weight : float;
}

let count b = max 2 (min 12 (int_of_float (Float.round (b.density /. 12.5))))

let line_width b =
  let bw = b.size *. b.stroke_weight in
  let n = float_of_int (count b) in
  Float.max ((b.thickness /. 100.0) *. (bw /. n)) 0.5

let alpha b = Float.max 0.0 (Float.min 1.0 (b.opacity /. 100.0))

let stroke (commands : Element.path_command list) (b : t) :
    (float * float) list list =
  let pts = Art_along_path.flatten commands in
  let m = Array.length pts in
  if m < 2 then []
  else
    let bw = b.size *. b.stroke_weight in
    if bw <= 0.0 then []
    else
      let n = count b in
      let normals =
        Array.init m (fun i ->
            let tx, ty =
              if i + 1 < m then
                (fst pts.(i + 1) -. fst pts.(i), snd pts.(i + 1) -. snd pts.(i))
              else (fst pts.(i) -. fst pts.(i - 1), snd pts.(i) -. snd pts.(i - 1))
            in
            let len = sqrt ((tx *. tx) +. (ty *. ty)) in
            if len > 0.0 then (-.ty /. len, tx /. len) else (0.0, 1.0))
      in
      List.init n (fun bi ->
          let oc =
            ((float_of_int bi /. (float_of_int n -. 1.0)) -. 0.5) *. bw
          in
          List.init m (fun i ->
              let nx, ny = normals.(i) in
              (fst pts.(i) +. (nx *. oc), snd pts.(i) +. (ny *. oc))))
