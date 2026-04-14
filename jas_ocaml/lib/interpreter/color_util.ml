(** Color conversion utilities matching the Python workspace_interpreter. *)

let parse_hex (c : string) : int * int * int =
  let h =
    if String.length c > 0 && c.[0] = '#' then
      String.sub c 1 (String.length c - 1)
    else
      c
  in
  let h =
    if String.length h = 3 then
      let expand i = let ch = h.[i] in String.make 2 ch in
      expand 0 ^ expand 1 ^ expand 2
    else
      h
  in
  if String.length h <> 6 then (0, 0, 0)
  else
    try
      let r = int_of_string ("0x" ^ String.sub h 0 2) in
      let g = int_of_string ("0x" ^ String.sub h 2 2) in
      let b = int_of_string ("0x" ^ String.sub h 4 2) in
      (r, g, b)
    with _ -> (0, 0, 0)

let rgb_to_hex (r : int) (g : int) (b : int) : string =
  let clamp v = max 0 (min 255 v) in
  Printf.sprintf "#%02x%02x%02x" (clamp r) (clamp g) (clamp b)

let rgb_to_hsb (r : int) (g : int) (b : int) : int * int * int =
  let r1 = float_of_int r /. 255.0 in
  let g1 = float_of_int g /. 255.0 in
  let b1 = float_of_int b /. 255.0 in
  let mx = max r1 (max g1 b1) in
  let mn = min r1 (min g1 b1) in
  let d = mx -. mn in
  let s = if mx = 0.0 then 0.0 else d /. mx in
  let v = mx in
  let h =
    if d <= 0.0 then 0.0
    else if mx = r1 then
      ((g1 -. b1) /. d +. (if g1 < b1 then 6.0 else 0.0)) /. 6.0
    else if mx = g1 then
      ((b1 -. r1) /. d +. 2.0) /. 6.0
    else
      ((r1 -. g1) /. d +. 4.0) /. 6.0
  in
  let hue = (Float.to_int (Float.round (h *. 360.0))) mod 360 in
  (hue, Float.to_int (Float.round (s *. 100.0)),
   Float.to_int (Float.round (v *. 100.0)))

let hsb_to_rgb (h : float) (s : float) (b : float) : int * int * int =
  let s1 = s /. 100.0 in
  let b1 = b /. 100.0 in
  let c = b1 *. s1 in
  let x = c *. (1.0 -. Float.abs (Float.rem (h /. 60.0) 2.0 -. 1.0)) in
  let m = b1 -. c in
  let r1, g1, b1_ =
    if h < 60.0 then (c, x, 0.0)
    else if h < 120.0 then (x, c, 0.0)
    else if h < 180.0 then (0.0, c, x)
    else if h < 240.0 then (0.0, x, c)
    else if h < 300.0 then (x, 0.0, c)
    else (c, 0.0, x)
  in
  (Float.to_int (Float.round ((r1 +. m) *. 255.0)),
   Float.to_int (Float.round ((g1 +. m) *. 255.0)),
   Float.to_int (Float.round ((b1_ +. m) *. 255.0)))

let rgb_to_cmyk (r : int) (g : int) (b : int) : int * int * int * int =
  if r = 0 && g = 0 && b = 0 then (0, 0, 0, 100)
  else
    let c1 = 1.0 -. float_of_int r /. 255.0 in
    let m1 = 1.0 -. float_of_int g /. 255.0 in
    let y1 = 1.0 -. float_of_int b /. 255.0 in
    let k1 = min c1 (min m1 y1) in
    let denom = 1.0 -. k1 in
    (Float.to_int (Float.round ((c1 -. k1) /. denom *. 100.0)),
     Float.to_int (Float.round ((m1 -. k1) /. denom *. 100.0)),
     Float.to_int (Float.round ((y1 -. k1) /. denom *. 100.0)),
     Float.to_int (Float.round (k1 *. 100.0)))
