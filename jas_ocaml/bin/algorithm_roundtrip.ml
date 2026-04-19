(* CLI tool for cross-language algorithm testing.
 *
 * Usage:
 *   algorithm_roundtrip <algorithm> <fixture.json>
 *)

open Yojson.Safe.Util

(* ---------------------------------------------------------------
 * JSON helpers
 * --------------------------------------------------------------- *)

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = Bytes.create n in
  really_input ic s 0 n;
  close_in ic;
  Bytes.to_string s

let to_float_lenient = function
  | `Float f -> f
  | `Int i -> Float.of_int i
  | _ -> failwith "expected number"

let parse_point v =
  match to_list v with
  | [x; y] -> (to_float_lenient x, to_float_lenient y)
  | _ -> failwith "expected [x, y]"

let parse_points v =
  List.map parse_point (to_list v)

let parse_polygon_set v =
  List.map (fun ring ->
    Array.of_list (List.map parse_point (to_list ring))
  ) (to_list v)

let parse_path_commands v =
  List.map (fun c ->
    let cmd = member "cmd" c |> to_string in
    match cmd with
    | "M" -> Jas.Element.MoveTo (member "x" c |> to_float_lenient,
                             member "y" c |> to_float_lenient)
    | "L" -> Jas.Element.LineTo (member "x" c |> to_float_lenient,
                             member "y" c |> to_float_lenient)
    | "C" -> Jas.Element.CurveTo (member "x1" c |> to_float_lenient,
                              member "y1" c |> to_float_lenient,
                              member "x2" c |> to_float_lenient,
                              member "y2" c |> to_float_lenient,
                              member "x" c |> to_float_lenient,
                              member "y" c |> to_float_lenient)
    | "Q" -> Jas.Element.QuadTo (member "x1" c |> to_float_lenient,
                             member "y1" c |> to_float_lenient,
                             member "x" c |> to_float_lenient,
                             member "y" c |> to_float_lenient)
    | "Z" -> Jas.Element.ClosePath
    | _ -> failwith ("Unknown path command: " ^ cmd)
  ) (to_list v)

let json_of_bool b = `Bool b
let json_of_int i = `Int i
let json_of_float f = `Float f
let json_of_string s = `String s
let json_of_point (x, y) = `List [`Float x; `Float y]

let is_skipped tc =
  match member "_skip" tc with
  | `Bool true -> true
  | _ -> false

(* ---------------------------------------------------------------
 * Geometry helpers
 * --------------------------------------------------------------- *)

let ring_signed_area (ring : Jas.Boolean.ring) =
  let n = Array.length ring in
  if n < 3 then 0.0
  else begin
    let sum = ref 0.0 in
    for i = 0 to n - 1 do
      let (x1, y1) = ring.(i) in
      let (x2, y2) = ring.((i + 1) mod n) in
      sum := !sum +. x1 *. y2 -. x2 *. y1
    done;
    !sum *. 0.5
  end

let point_in_ring (ring : Jas.Boolean.ring) (px, py) =
  let n = Array.length ring in
  if n < 3 then false
  else begin
    let inside = ref false in
    let j = ref (n - 1) in
    for i = 0 to n - 1 do
      let (xi, yi) = ring.(i) in
      let (xj, yj) = ring.(!j) in
      if ((yi > py) <> (yj > py)) &&
         (px < (xj -. xi) *. (py -. yi) /. (yj -. yi) +. xi) then
        inside := not !inside;
      j := i
    done;
    !inside
  end

let point_in_polygon_set (ps : Jas.Boolean.polygon_set) pt =
  let count = List.fold_left (fun acc ring ->
    if point_in_ring ring pt then acc + 1 else acc
  ) 0 ps in
  count mod 2 = 1

let polygon_set_area (ps : Jas.Boolean.polygon_set) =
  let total = ref 0.0 in
  List.iteri (fun i ring ->
    let a = Float.abs (ring_signed_area ring) in
    let depth = ref 0 in
    (match ring.(0) with
     | pt ->
       List.iteri (fun j other ->
         if i <> j && point_in_ring other pt then
           incr depth
       ) ps
     | exception Invalid_argument _ -> ());
    if !depth mod 2 = 0 then
      total := !total +. a
    else
      total := !total -. a
  ) ps;
  !total

let proper_crossing ax1 ay1 ax2 ay2 bx1 by1 bx2 by2 =
  let cross ux uy vx vy = ux *. vy -. uy *. vx in
  let d1 = cross (bx2 -. bx1) (by2 -. by1) (ax1 -. bx1) (ay1 -. by1) in
  let d2 = cross (bx2 -. bx1) (by2 -. by1) (ax2 -. bx1) (ay2 -. by1) in
  let d3 = cross (ax2 -. ax1) (ay2 -. ay1) (bx1 -. ax1) (by1 -. ay1) in
  let d4 = cross (ax2 -. ax1) (ay2 -. ay1) (bx2 -. ax1) (by2 -. ay1) in
  d1 *. d2 < 0.0 && d3 *. d4 < 0.0

let is_ring_simple (ring : Jas.Boolean.ring) =
  let n = Array.length ring in
  if n < 3 then true
  else begin
    let found = ref false in
    for i = 0 to n - 1 do
      if not !found then begin
        let (ax1, ay1) = ring.(i) in
        let (ax2, ay2) = ring.((i + 1) mod n) in
        for j = i + 2 to n - 1 do
          if not !found && not (i = 0 && j = n - 1) then begin
            let (bx1, by1) = ring.(j) in
            let (bx2, by2) = ring.((j + 1) mod n) in
            if proper_crossing ax1 ay1 ax2 ay2 bx1 by1 bx2 by2 then
              found := true
          end
        done
      end
    done;
    not !found
  end

let all_rings_simple ps =
  List.for_all is_ring_simple ps

(* ---------------------------------------------------------------
 * Algorithm runners
 * --------------------------------------------------------------- *)

let parse_unit s = match s with
  | "px" -> Jas.Measure.Px | "pt" -> Jas.Measure.Pt
  | "pc" -> Jas.Measure.Pc | "in" -> Jas.Measure.In
  | "cm" -> Jas.Measure.Cm | "mm" -> Jas.Measure.Mm
  | "em" -> Jas.Measure.Em | "rem" -> Jas.Measure.Rem
  | _ -> Printf.eprintf "Unknown unit: %s\n" s; exit 1

let run_element_bounds vectors =
  List.map (fun tc ->
    let name = member "name" tc |> to_string in
    let elem_json = member "element" tc in
    let elem = Jas.Test_json.parse_element elem_json in
    let (x, y, w, h) = Jas.Element.bounds elem in
    `Assoc [("name", `String name); ("result", `List [`Float x; `Float y; `Float w; `Float h])]
  ) vectors

let run_measure vectors =
  List.map (fun tc ->
    let name = member "name" tc |> to_string in
    let unit_str = member "unit" tc |> to_string in
    let value = member "value" tc |> to_float_lenient in
    let font_size = try member "font_size" tc |> to_float_lenient with _ -> 16.0 in
    let u = parse_unit unit_str in
    let m = { Jas.Measure.value; unit = u } in
    let result = Jas.Measure.to_px ~font_size m in
    `Assoc [("name", `String name); ("result", `Float result)]
  ) vectors

let run_hit_test vectors =
  List.map (fun tc ->
    let name = member "name" tc |> to_string in
    let func = member "function" tc |> to_string in
    let args = member "args" tc |> to_list |> List.map to_float_lenient in
    let a = Array.of_list args in
    let result = match func with
      | "point_in_rect" ->
        Jas.Hit_test.point_in_rect a.(0) a.(1) a.(2) a.(3) a.(4) a.(5)
      | "segments_intersect" ->
        Jas.Hit_test.segments_intersect a.(0) a.(1) a.(2) a.(3) a.(4) a.(5) a.(6) a.(7)
      | "segment_intersects_rect" ->
        Jas.Hit_test.segment_intersects_rect a.(0) a.(1) a.(2) a.(3) a.(4) a.(5) a.(6) a.(7)
      | "rects_intersect" ->
        Jas.Hit_test.rects_intersect a.(0) a.(1) a.(2) a.(3) a.(4) a.(5) a.(6) a.(7)
      | "circle_intersects_rect" ->
        let filled = (try member "filled" tc |> to_bool with _ -> true) in
        Jas.Hit_test.circle_intersects_rect a.(0) a.(1) a.(2) a.(3) a.(4) a.(5) a.(6) filled
      | "ellipse_intersects_rect" ->
        let filled = (try member "filled" tc |> to_bool with _ -> true) in
        Jas.Hit_test.ellipse_intersects_rect a.(0) a.(1) a.(2) a.(3) a.(4) a.(5) a.(6) a.(7) filled
      | "point_in_polygon" ->
        let poly = member "polygon" tc |> to_list
          |> List.map parse_point |> Array.of_list in
        Jas.Hit_test.point_in_polygon a.(0) a.(1) poly
      | _ -> failwith ("Unknown hit_test function: " ^ func)
    in
    `Assoc [("name", json_of_string name); ("result", json_of_bool result)]
  ) vectors

let run_boolean vectors =
  List.map (fun tc ->
    let name = member "name" tc |> to_string in
    let func = member "function" tc |> to_string in
    let a = parse_polygon_set (member "a" tc) in
    let b = parse_polygon_set (member "b" tc) in
    let res = match func with
      | "union" -> Jas.Boolean.boolean_union a b
      | "intersect" -> Jas.Boolean.boolean_intersect a b
      | "subtract" -> Jas.Boolean.boolean_subtract a b
      | "exclude" -> Jas.Boolean.boolean_exclude a b
      | _ -> failwith ("Unknown boolean function: " ^ func)
    in
    let expected = member "expected" tc in
    let sample_pts = try member "sample_points" expected |> to_list with _ -> [] in
    let samples = List.map (fun sp ->
      let pt = parse_point (member "point" sp) in
      let inside = point_in_polygon_set res pt in
      `Assoc [("point", json_of_point pt); ("inside", json_of_bool inside)]
    ) sample_pts in
    `Assoc [
      ("name", json_of_string name);
      ("result", `Assoc [
        ("area", json_of_float (polygon_set_area res));
        ("ring_count", json_of_int (List.length res));
        ("sample_points", `List samples)
      ])
    ]
  ) vectors

let run_boolean_normalize vectors =
  List.map (fun tc ->
    let name = member "name" tc |> to_string in
    let input = parse_polygon_set (member "input" tc) in
    let res = Jas.Boolean_normalize.normalize input in
    `Assoc [
      ("name", json_of_string name);
      ("result", `Assoc [
        ("area", json_of_float (polygon_set_area res));
        ("ring_count", json_of_int (List.length res));
        ("all_rings_simple", json_of_bool (all_rings_simple res))
      ])
    ]
  ) vectors

let run_fit_curve vectors =
  List.map (fun tc ->
    let name = member "name" tc |> to_string in
    let points = parse_points (member "points" tc) in
    let error = member "error" tc |> to_float_lenient in
    let segs = Jas.Fit_curve.fit_curve points error in
    let seg_json = List.map (fun s ->
      `List [
        `Float s.Jas.Fit_curve.p1x; `Float s.Jas.Fit_curve.p1y;
        `Float s.Jas.Fit_curve.c1x; `Float s.Jas.Fit_curve.c1y;
        `Float s.Jas.Fit_curve.c2x; `Float s.Jas.Fit_curve.c2y;
        `Float s.Jas.Fit_curve.p2x; `Float s.Jas.Fit_curve.p2y
      ]
    ) segs in
    `Assoc [
      ("name", json_of_string name);
      ("result", `Assoc [
        ("segment_count", json_of_int (List.length segs));
        ("segments", `List seg_json)
      ])
    ]
  ) vectors

let shape_to_json shape =
  let open Jas.Shape_recognize in
  match shape with
  | Recognized_line { a; b } ->
    `Assoc [("kind", `String "line");
      ("params", `Assoc [
        ("ax", `Float (fst a)); ("ay", `Float (snd a));
        ("bx", `Float (fst b)); ("by", `Float (snd b))])]
  | Recognized_triangle { pts = (p0, p1, p2) } ->
    `Assoc [("kind", `String "triangle");
      ("params", `Assoc [("pts", `List [json_of_point p0; json_of_point p1; json_of_point p2])])]
  | Recognized_rectangle { x; y; w; h } ->
    let kind = if Float.abs (w -. h) < 1e-9 then "square" else "rectangle" in
    `Assoc [("kind", `String kind);
      ("params", `Assoc [("h", `Float h); ("w", `Float w); ("x", `Float x); ("y", `Float y)])]
  | Recognized_round_rect { x; y; w; h; r } ->
    `Assoc [("kind", `String "round_rect");
      ("params", `Assoc [("h", `Float h); ("r", `Float r); ("w", `Float w); ("x", `Float x); ("y", `Float y)])]
  | Recognized_circle { cx; cy; r } ->
    `Assoc [("kind", `String "circle");
      ("params", `Assoc [("cx", `Float cx); ("cy", `Float cy); ("r", `Float r)])]
  | Recognized_ellipse { cx; cy; rx; ry } ->
    `Assoc [("kind", `String "ellipse");
      ("params", `Assoc [("cx", `Float cx); ("cy", `Float cy); ("rx", `Float rx); ("ry", `Float ry)])]
  | Recognized_arrow { tail; tip; head_len; head_half_width; shaft_half_width } ->
    `Assoc [("kind", `String "arrow");
      ("params", `Assoc [
        ("head_half_width", `Float head_half_width);
        ("head_len", `Float head_len);
        ("shaft_half_width", `Float shaft_half_width);
        ("tail_x", `Float (fst tail)); ("tail_y", `Float (snd tail));
        ("tip_x", `Float (fst tip)); ("tip_y", `Float (snd tip))])]
  | Recognized_lemniscate { center; a; horizontal } ->
    `Assoc [("kind", `String "lemniscate");
      ("params", `Assoc [("a", `Float a); ("cx", `Float (fst center));
        ("cy", `Float (snd center)); ("horizontal", `Bool horizontal)])]
  | Recognized_scribble { points } ->
    let pts = List.map json_of_point points in
    `Assoc [("kind", `String "scribble");
      ("params", `Assoc [("points", `List pts)])]

let run_shape_recognize vectors =
  List.map (fun tc ->
    let name = member "name" tc |> to_string in
    let points = parse_points (member "points" tc) in
    let cfg = match member "config" tc with
      | `Null -> Jas.Shape_recognize.default_config
      | cfg_obj ->
        let base = Jas.Shape_recognize.default_config in
        let tol = try member "tolerance" cfg_obj |> to_float_lenient with _ -> base.tolerance in
        { base with tolerance = tol }
    in
    let result = Jas.Shape_recognize.recognize points cfg in
    let result_json = match result with
      | None -> `Null
      | Some shape -> shape_to_json shape
    in
    `Assoc [("name", json_of_string name); ("result", result_json)]
  ) vectors

let run_planar vectors =
  List.map (fun tc ->
    let name = member "name" tc |> to_string in
    let polylines = member "polylines" tc |> to_list |> List.map (fun pl ->
      parse_points pl |> Array.of_list
    ) in
    let graph = Jas.Planar.build polylines in
    let fc = Jas.Planar.face_count graph in
    let areas = List.init fc (fun i -> Jas.Planar.face_net_area graph i) in
    let areas_sorted = List.sort Float.compare areas in
    let expected = member "expected" tc in
    let sample_pts = try member "sample_points" expected |> to_list with _ -> [] in
    let samples = List.map (fun sp ->
      let pt = parse_point (member "point" sp) in
      let hit = Jas.Planar.hit_test graph pt in
      `Assoc [("inside_any_face", json_of_bool (hit <> None));
              ("point", json_of_point pt)]
    ) sample_pts in
    `Assoc [
      ("name", json_of_string name);
      ("result", `Assoc [
        ("face_areas_sorted", `List (List.map json_of_float areas_sorted));
        ("face_count", json_of_int fc);
        ("sample_points", `List samples)
      ])
    ]
  ) vectors

let run_text_layout vectors =
  List.map (fun tc ->
    let name = member "name" tc |> to_string in
    let content = member "content" tc |> to_string in
    let max_width = member "max_width" tc |> to_float_lenient in
    let font_size = member "font_size" tc |> to_float_lenient in
    let char_width = member "char_width" tc |> to_float_lenient in
    let measure s = Float.of_int (String.length s) *. char_width in
    let layout = Jas.Text_layout.layout content max_width font_size measure in
    let glyphs = Array.to_list layout.glyphs |> List.map (fun g ->
      `Assoc [
        ("idx", json_of_int g.Jas.Text_layout.idx);
        ("line", json_of_int g.Jas.Text_layout.line);
        ("right", json_of_float g.Jas.Text_layout.right);
        ("x", json_of_float g.Jas.Text_layout.x)
      ]
    ) in
    `Assoc [
      ("name", json_of_string name);
      ("result", `Assoc [
        ("char_count", json_of_int layout.char_count);
        ("glyphs", `List glyphs);
        ("line_count", json_of_int (Array.length layout.lines))
      ])
    ]
  ) vectors

let _parse_align value : Jas.Text_layout.text_align =
  match value with
  | `String "center" -> Jas.Text_layout.Center
  | `String "right" -> Jas.Text_layout.Right
  | `String "justify" -> Jas.Text_layout.Justify
  | _ -> Jas.Text_layout.Left

let run_text_layout_paragraph vectors =
  let dflt = Jas.Text_layout.default_segment in
  let parse_seg j =
    let f k def =
      match member k j with
      | `Null -> def
      | x -> to_float_lenient x
    in
    let i k def =
      match member k j with
      | `Null -> def
      | x -> int_of_float (to_float_lenient x)
    in
    let b k = match member k j with
      | `Bool v -> v
      | _ -> false
    in
    let s k = match member k j with
      | `String v -> Some v
      | _ -> None
    in
    {
      Jas.Text_layout.char_start = i "char_start" 0;
      char_end = i "char_end" 0;
      left_indent = f "left_indent" dflt.left_indent;
      right_indent = f "right_indent" dflt.right_indent;
      first_line_indent = f "first_line_indent" dflt.first_line_indent;
      space_before = f "space_before" dflt.space_before;
      space_after = f "space_after" dflt.space_after;
      text_align = _parse_align (member "text_align" j);
      list_style = s "list_style";
      marker_gap = f "marker_gap" dflt.marker_gap;
      hanging_punctuation = b "hanging_punctuation";
      word_spacing_min = f "word_spacing_min" dflt.word_spacing_min;
      word_spacing_desired = f "word_spacing_desired" dflt.word_spacing_desired;
      word_spacing_max = f "word_spacing_max" dflt.word_spacing_max;
      last_line_align = _parse_align (member "last_line_align" j);
      hyphenate = b "hyphenate";
      hyphenate_min_word = i "hyphenate_min_word" dflt.hyphenate_min_word;
      hyphenate_min_before = i "hyphenate_min_before" dflt.hyphenate_min_before;
      hyphenate_min_after = i "hyphenate_min_after" dflt.hyphenate_min_after;
      hyphenate_bias = i "hyphenate_bias" dflt.hyphenate_bias;
    }
  in
  List.map (fun tc ->
    let name = member "name" tc |> to_string in
    let content = member "content" tc |> to_string in
    let max_width = member "max_width" tc |> to_float_lenient in
    let font_size = member "font_size" tc |> to_float_lenient in
    let char_width = member "char_width" tc |> to_float_lenient in
    let segs = match member "paragraphs" tc with
      | `List xs -> List.map parse_seg xs
      | _ -> []
    in
    let measure s = Float.of_int (Jas.Text_layout.utf8_char_count s) *. char_width in
    let layout = Jas.Text_layout.layout_with_paragraphs content max_width
                   font_size segs measure in
    let glyphs = Array.to_list layout.glyphs |> List.map (fun g ->
      `Assoc [
        ("idx", json_of_int g.Jas.Text_layout.idx);
        ("line", json_of_int g.Jas.Text_layout.line);
        ("right", json_of_float g.Jas.Text_layout.right);
        ("x", json_of_float g.Jas.Text_layout.x)
      ]
    ) in
    `Assoc [
      ("name", json_of_string name);
      ("result", `Assoc [
        ("char_count", json_of_int layout.char_count);
        ("glyphs", `List glyphs);
        ("line_count", json_of_int (Array.length layout.lines))
      ])
    ]
  ) vectors

let run_path_text_layout vectors =
  List.map (fun tc ->
    let name = member "name" tc |> to_string in
    let path_cmds = parse_path_commands (member "path" tc) in
    let content = member "content" tc |> to_string in
    let start_offset = member "start_offset" tc |> to_float_lenient in
    let font_size = member "font_size" tc |> to_float_lenient in
    let char_width = member "char_width" tc |> to_float_lenient in
    let measure s = Float.of_int (String.length s) *. char_width in
    let layout = Jas.Path_text_layout.layout path_cmds content start_offset font_size measure in
    let glyphs = Array.to_list layout.glyphs |> List.map (fun g ->
      `Assoc [
        ("angle", json_of_float g.Jas.Path_text_layout.angle);
        ("cx", json_of_float g.Jas.Path_text_layout.cx);
        ("cy", json_of_float g.Jas.Path_text_layout.cy);
        ("idx", json_of_int g.Jas.Path_text_layout.idx);
        ("overflow", json_of_bool g.Jas.Path_text_layout.overflow)
      ]
    ) in
    `Assoc [
      ("name", json_of_string name);
      ("result", `Assoc [
        ("char_count", json_of_int layout.char_count);
        ("glyphs", `List glyphs);
        ("total_length", json_of_float layout.total_length)
      ])
    ]
  ) vectors

(* ---------------------------------------------------------------
 * Main
 * --------------------------------------------------------------- *)

let () =
  if Array.length Sys.argv < 3 then begin
    Printf.eprintf "Usage: %s <algorithm> <fixture.json>\n" Sys.argv.(0);
    exit 1
  end;
  let algo = Sys.argv.(1) in
  let path = Sys.argv.(2) in
  let json_str = read_file path in
  let fixture = Yojson.Safe.from_string json_str in
  let vectors = match fixture with
    | `List arr -> arr
    | `Assoc _ -> member "vectors" fixture |> to_list
    | _ -> Printf.eprintf "Expected JSON array or object\n"; exit 1
  in
  let vectors = List.filter (fun v -> not (is_skipped v)) vectors in
  let results = match algo with
    | "measure" -> run_measure vectors
    | "element_bounds" -> run_element_bounds vectors
    | "hit_test" -> run_hit_test vectors
    | "boolean" -> run_boolean vectors
    | "boolean_normalize" -> run_boolean_normalize vectors
    | "fit_curve" -> run_fit_curve vectors
    | "shape_recognize" -> run_shape_recognize vectors
    | "planar" -> run_planar vectors
    | "text_layout" -> run_text_layout vectors
    | "text_layout_paragraph" -> run_text_layout_paragraph vectors
    | "path_text_layout" -> run_path_text_layout vectors
    | _ -> Printf.eprintf "Unknown algorithm: %s\n" algo; exit 1
  in
  print_string (Yojson.Safe.to_string (`List results))
