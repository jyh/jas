(** Phase 4a of the OCaml YAML tool-runtime migration. Covers
    Path_ops and Regular_shapes — the shared geometry kernels. *)

open Jas
open Jas.Element

let close f1 f2 = Float.abs (f1 -. f2) < 1e-9

(* ── Basic helpers ───────────────────────────────────── *)

let basic_tests = [
  Alcotest.test_case "lerp_midpoint" `Quick (fun () ->
    assert (Path_ops.lerp 0.0 10.0 0.5 = 5.0);
    assert (Path_ops.lerp 4.0 8.0 0.0 = 4.0);
    assert (Path_ops.lerp 4.0 8.0 1.0 = 8.0));

  Alcotest.test_case "eval_cubic_endpoints" `Quick (fun () ->
    let (sx, sy) = Path_ops.eval_cubic 0.0 0.0 10.0 0.0 20.0 0.0 30.0 0.0 0.0 in
    assert (sx = 0.0 && sy = 0.0);
    let (ex, ey) = Path_ops.eval_cubic 0.0 0.0 10.0 0.0 20.0 0.0 30.0 0.0 1.0 in
    assert (ex = 30.0 && ey = 0.0));
]

(* ── Endpoint / start-point ──────────────────────────── *)

let endpoint_tests = [
  Alcotest.test_case "cmd_endpoint_variants" `Quick (fun () ->
    assert (Path_ops.cmd_endpoint (MoveTo (1.0, 2.0)) = Some (1.0, 2.0));
    assert (Path_ops.cmd_endpoint (LineTo (3.0, 4.0)) = Some (3.0, 4.0));
    assert (Path_ops.cmd_endpoint (CurveTo (0.0, 0.0, 0.0, 0.0, 5.0, 6.0))
            = Some (5.0, 6.0));
    assert (Path_ops.cmd_endpoint ClosePath = None));

  Alcotest.test_case "cmd_start_points_chain" `Quick (fun () ->
    let cmds = [MoveTo (1.0, 1.0); LineTo (5.0, 1.0); LineTo (5.0, 5.0)] in
    let starts = Path_ops.cmd_start_points cmds in
    assert (List.length starts = 3);
    assert (List.nth starts 0 = (0.0, 0.0));
    assert (List.nth starts 1 = (1.0, 1.0));
    assert (List.nth starts 2 = (5.0, 1.0)));

  Alcotest.test_case "cmd_start_point_at_index" `Quick (fun () ->
    let cmds = [MoveTo (10.0, 10.0); LineTo (20.0, 10.0)] in
    assert (Path_ops.cmd_start_point cmds 0 = (0.0, 0.0));
    assert (Path_ops.cmd_start_point cmds 1 = (10.0, 10.0)));
]

(* ── Flattening ──────────────────────────────────────── *)

let flatten_tests = [
  Alcotest.test_case "flatten_line_segments" `Quick (fun () ->
    let cmds = [MoveTo (0.0, 0.0); LineTo (10.0, 0.0); LineTo (10.0, 10.0)] in
    let (pts, map) = Path_ops.flatten_with_cmd_map cmds in
    assert (List.length pts = 3);
    assert (map = [0; 1; 2]));

  Alcotest.test_case "flatten_curve_20_samples" `Quick (fun () ->
    let cmds = [MoveTo (0.0, 0.0);
                CurveTo (0.0, 10.0, 10.0, 10.0, 10.0, 0.0)] in
    let (pts, map) = Path_ops.flatten_with_cmd_map cmds in
    (* 1 point from moveTo + 20 samples from curveTo = 21 total. *)
    assert (List.length pts = 21);
    assert (List.length (List.filter (fun i -> i = 1) map) = 20));
]

(* ── Projection ──────────────────────────────────────── *)

let projection_tests = [
  Alcotest.test_case "closest_on_line_midpoint" `Quick (fun () ->
    let (d, t) = Path_ops.closest_on_line 0.0 0.0 10.0 0.0 5.0 5.0 in
    assert (close d 5.0);
    assert (close t 0.5));

  Alcotest.test_case "closest_on_line_clamped" `Quick (fun () ->
    let (d, t) = Path_ops.closest_on_line 0.0 0.0 10.0 0.0 (-. 5.0) 0.0 in
    assert (close d 5.0);
    assert (t = 0.0));

  Alcotest.test_case "closest_segment_and_t_picks_correct" `Quick (fun () ->
    let cmds = [MoveTo (0.0, 0.0); LineTo (10.0, 0.0); LineTo (10.0, 10.0)] in
    (match Path_ops.closest_segment_and_t cmds 10.0 5.0 with
     | Some (seg, t) ->
       assert (seg = 2);
       assert (close t 0.5)
     | None -> assert false));
]

(* ── Splitting ───────────────────────────────────────── *)

let split_tests = [
  Alcotest.test_case "split_cubic_midpoint_symmetric_bell" `Quick (fun () ->
    let (first, second) =
      Path_ops.split_cubic 0.0 0.0 0.0 10.0 10.0 10.0 10.0 0.0 0.5 in
    let (_, _, _, _, mx, my) = first in
    let (_, _, _, _, ex, ey) = second in
    assert (close mx 5.0);
    assert (close my 7.5);
    assert (ex = 10.0 && ey = 0.0));

  Alcotest.test_case "split_cubic_cmd_at_produces_curves" `Quick (fun () ->
    let (a, b) = Path_ops.split_cubic_cmd_at (0.0, 0.0)
      0.0 10.0 10.0 10.0 10.0 0.0 0.5 in
    (match a with
     | CurveTo (_, _, _, _, x, y) -> assert (close x 5.0 && close y 7.5)
     | _ -> assert false);
    (match b with
     | CurveTo (_, _, _, _, x, y) -> assert (x = 10.0 && y = 0.0)
     | _ -> assert false));
]

(* ── Anchor deletion ─────────────────────────────────── *)

let delete_tests = [
  Alcotest.test_case "delete_interior_merges" `Quick (fun () ->
    let cmds = [MoveTo (0.0, 0.0); LineTo (10.0, 0.0);
                LineTo (20.0, 0.0); LineTo (30.0, 0.0)] in
    match Path_ops.delete_anchor_from_path cmds 1 with
    | Some r ->
      assert (List.length r = 3);
      (match List.nth r 1 with
       | LineTo (x, _) -> assert (x = 20.0)
       | _ -> assert false)
    | None -> assert false);

  Alcotest.test_case "delete_first_promotes_second" `Quick (fun () ->
    let cmds = [MoveTo (0.0, 0.0); LineTo (10.0, 0.0); LineTo (20.0, 0.0)] in
    match Path_ops.delete_anchor_from_path cmds 0 with
    | Some r ->
      (match List.hd r with
       | MoveTo (x, _) -> assert (x = 10.0)
       | _ -> assert false)
    | None -> assert false);

  Alcotest.test_case "delete_with_two_anchors_returns_none" `Quick (fun () ->
    let cmds = [MoveTo (0.0, 0.0); LineTo (10.0, 0.0)] in
    assert (Path_ops.delete_anchor_from_path cmds 0 = None));
]

(* ── Anchor insertion ────────────────────────────────── *)

let insert_tests = [
  Alcotest.test_case "insert_line_segment_at_half" `Quick (fun () ->
    let cmds = [MoveTo (0.0, 0.0); LineTo (10.0, 0.0)] in
    let r = Path_ops.insert_point_in_path cmds 1 0.5 in
    assert (List.length r.commands = 3);
    assert (r.anchor_x = 5.0);
    assert (r.anchor_y = 0.0);
    assert (r.first_new_idx = 1));

  Alcotest.test_case "insert_curve_split" `Quick (fun () ->
    let cmds = [MoveTo (0.0, 0.0);
                CurveTo (0.0, 10.0, 10.0, 10.0, 10.0, 0.0)] in
    let r = Path_ops.insert_point_in_path cmds 1 0.5 in
    assert (List.length r.commands = 3);
    assert (close r.anchor_x 5.0);
    assert (close r.anchor_y 7.5));
]

(* ── Liang-Barsky ────────────────────────────────────── *)

let liang_barsky_tests = [
  Alcotest.test_case "line_intersects_rect_hits_and_misses" `Quick (fun () ->
    assert (Path_ops.line_segment_intersects_rect
              (-. 1.0) 5.0 20.0 5.0 0.0 0.0 10.0 10.0);
    assert (not (Path_ops.line_segment_intersects_rect
                   (-. 5.0) (-. 5.0) (-. 1.0) (-. 1.0)
                   0.0 0.0 10.0 10.0));
    assert (Path_ops.line_segment_intersects_rect
              5.0 5.0 20.0 20.0 0.0 0.0 10.0 10.0));

  Alcotest.test_case "entry_exit_parameters" `Quick (fun () ->
    let t_min = Path_ops.liang_barsky_t_min
      (-. 5.0) 5.0 15.0 5.0 0.0 0.0 10.0 10.0 in
    let t_max = Path_ops.liang_barsky_t_max
      (-. 5.0) 5.0 15.0 5.0 0.0 0.0 10.0 10.0 in
    assert (close t_min 0.25);
    assert (close t_max 0.75));
]

(* ── Regular shapes ──────────────────────────────────── *)

let regular_shape_tests = [
  Alcotest.test_case "regular_polygon_triangle" `Quick (fun () ->
    let pts = Regular_shapes.regular_polygon_points 0.0 0.0 10.0 0.0 3 in
    assert (List.length pts = 3);
    let (p0x, p0y) = List.nth pts 0 in
    let (p1x, p1y) = List.nth pts 1 in
    let (_, p2y) = List.nth pts 2 in
    assert (close p0x 0.0 && close p0y 0.0);
    assert (close p1x 10.0 && close p1y 0.0);
    (* Equilateral triangle apex height = edge * sqrt(3)/2. *)
    assert (Float.abs (p2y -. (10.0 *. Float.sqrt 3.0 /. 2.0)) < 1e-6));

  Alcotest.test_case "regular_polygon_degenerate" `Quick (fun () ->
    let pts = Regular_shapes.regular_polygon_points 3.0 4.0 3.0 4.0 5 in
    assert (List.length pts = 5);
    List.iter (fun (x, y) -> assert (x = 3.0 && y = 4.0)) pts);

  Alcotest.test_case "star_first_outer_at_top_center" `Quick (fun () ->
    let pts = Regular_shapes.star_points 0.0 0.0 100.0 100.0 5 in
    assert (List.length pts = 10);
    let (x0, y0) = List.hd pts in
    assert (close x0 50.0);
    assert (close y0 0.0));

  Alcotest.test_case "star_inner_ratio_is_forty_percent" `Quick (fun () ->
    assert (Regular_shapes.star_inner_ratio = 0.4));
]

(* Path to PolygonSet adapters — Blob Brush Phase 1.1. *)

let polygon_set_tests = [
  Alcotest.test_case "path_to_polygon_set_single_square" `Quick (fun () ->
    let cmds = [
      MoveTo (0.0, 0.0);
      LineTo (10.0, 0.0);
      LineTo (10.0, 10.0);
      LineTo (0.0, 10.0);
      ClosePath;
    ] in
    let ps = Path_ops.path_to_polygon_set cmds in
    assert (List.length ps = 1);
    let ring = List.hd ps in
    assert (Array.length ring = 4);
    assert (ring.(0) = (0.0, 0.0));
    assert (ring.(2) = (10.0, 10.0)));

  Alcotest.test_case "path_to_polygon_set_multiple_subpaths" `Quick (fun () ->
    let cmds = [
      MoveTo (0.0, 0.0);  LineTo (10.0, 0.0); LineTo (5.0, 10.0);  ClosePath;
      MoveTo (20.0, 0.0); LineTo (30.0, 0.0); LineTo (25.0, 10.0); ClosePath;
    ] in
    let ps = Path_ops.path_to_polygon_set cmds in
    assert (List.length ps = 2);
    let r0 = List.nth ps 0 in
    let r1 = List.nth ps 1 in
    assert (Array.length r0 = 3);
    assert (Array.length r1 = 3);
    assert (r0.(0) = (0.0, 0.0));
    assert (r1.(0) = (20.0, 0.0)));

  Alcotest.test_case "polygon_set_to_path_single_ring" `Quick (fun () ->
    let ring = [| (0.0, 0.0); (10.0, 0.0); (10.0, 10.0); (0.0, 10.0) |] in
    let cmds = Path_ops.polygon_set_to_path [ring] in
    assert (List.length cmds = 5);
    (match List.nth cmds 0 with
     | MoveTo (0.0, 0.0) -> ()
     | _ -> assert false);
    (match List.nth cmds 4 with
     | ClosePath -> ()
     | _ -> assert false));

  Alcotest.test_case "polygon_set_to_path_drops_degenerate_rings" `Quick (fun () ->
    let ps = [
      [| (0.0, 0.0); (10.0, 0.0); (5.0, 10.0) |];
      [| (20.0, 0.0); (30.0, 0.0) |];
    ] in
    let cmds = Path_ops.polygon_set_to_path ps in
    assert (List.length cmds = 4));

  Alcotest.test_case "polygon_set_roundtrip_through_path" `Quick (fun () ->
    let cmds = [
      MoveTo (0.0, 0.0);
      LineTo (10.0, 0.0);
      LineTo (10.0, 10.0);
      LineTo (0.0, 10.0);
      ClosePath;
    ] in
    let ps1 = Path_ops.path_to_polygon_set cmds in
    let cmds2 = Path_ops.polygon_set_to_path ps1 in
    let ps2 = Path_ops.path_to_polygon_set cmds2 in
    assert (List.length ps1 = List.length ps2);
    List.iter2 (fun a b ->
      assert (Array.length a = Array.length b);
      Array.iter2 (fun pa pb -> assert (pa = pb)) a b
    ) ps1 ps2);
]

let () =
  Alcotest.run "Path ops + Regular shapes" [
    "Basic", basic_tests;
    "Endpoint", endpoint_tests;
    "Flatten", flatten_tests;
    "Projection", projection_tests;
    "Split", split_tests;
    "Delete", delete_tests;
    "Insert", insert_tests;
    "Liang-Barsky", liang_barsky_tests;
    "Regular shapes", regular_shape_tests;
    "PolygonSet", polygon_set_tests;
  ]
