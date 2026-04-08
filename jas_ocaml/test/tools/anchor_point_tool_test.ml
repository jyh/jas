(** Anchor Point (Convert) tool tests. Mirrors the tests in
    jas_dioxus/src/tools/anchor_point_tool.rs. The meaningful coverage
    lives in the geometry helpers (convert_corner_to_smooth /
    convert_smooth_to_corner / move_path_handle_independent /
    is_smooth_point), which the tool just sequences. *)

open Jas.Element

let make_line_path () = [
  MoveTo (0.0, 0.0);
  LineTo (50.0, 0.0);
  LineTo (100.0, 0.0);
]

let make_smooth_path () = [
  MoveTo (0.0, 0.0);
  CurveTo (10.0, 20.0, 40.0, 20.0, 50.0, 0.0);
  CurveTo (60.0, -20.0, 90.0, -20.0, 100.0, 0.0);
]

let pass = ref 0
let fail = ref 0
let run name f =
  try
    f ();
    incr pass;
    Printf.printf "  PASS: %s\n" name
  with e ->
    incr fail;
    Printf.printf "  FAIL: %s — %s\n" name (Printexc.to_string e)

let nth d i = List.nth d i

let approx_eq a b = abs_float (a -. b) < 0.01

let () =
  Printf.printf "Anchor Point tool tests:\n";

  run "corner point is not smooth" (fun () ->
    let d = make_line_path () in
    assert (not (is_smooth_point d 0));
    assert (not (is_smooth_point d 1));
    assert (not (is_smooth_point d 2)));

  run "smooth point is smooth" (fun () ->
    let d = make_smooth_path () in
    assert (is_smooth_point d 1));

  run "convert corner to smooth creates handles" (fun () ->
    let d = make_line_path () in
    let result = convert_corner_to_smooth d 1 50.0 30.0 in
    (match nth result 1 with
     | CurveTo (_, _, x2, y2, _, _) ->
       assert (approx_eq x2 50.0);
       assert (approx_eq y2 (-30.0))
     | _ -> failwith "expected CurveTo at index 1");
    (match nth result 2 with
     | CurveTo (x1, y1, _, _, _, _) ->
       assert (approx_eq x1 50.0);
       assert (approx_eq y1 30.0)
     | _ -> failwith "expected CurveTo at index 2"));

  run "convert first anchor corner to smooth" (fun () ->
    let d = make_line_path () in
    let result = convert_corner_to_smooth d 0 10.0 20.0 in
    match nth result 1 with
    | CurveTo (x1, y1, _, _, _, _) ->
      assert (approx_eq x1 10.0);
      assert (approx_eq y1 20.0)
    | _ -> failwith "expected CurveTo");

  run "convert last anchor corner to smooth" (fun () ->
    let d = make_line_path () in
    let result = convert_corner_to_smooth d 2 100.0 30.0 in
    match nth result 2 with
    | CurveTo (_, _, x2, y2, x, y) ->
      (* Reflected of (100, 30) through (100, 0) = (100, -30) *)
      assert (approx_eq x2 100.0);
      assert (approx_eq y2 (-30.0));
      assert (approx_eq x 100.0);
      assert (approx_eq y 0.0)
    | _ -> failwith "expected CurveTo");

  run "convert smooth to corner collapses handles" (fun () ->
    let d = make_smooth_path () in
    let result = convert_smooth_to_corner d 1 in
    assert (not (is_smooth_point result 1));
    (match nth result 1 with
     | CurveTo (_, _, x2, y2, x, y) ->
       assert (approx_eq x2 x);
       assert (approx_eq y2 y)
     | _ -> ());
    (match nth result 2 with
     | CurveTo (x1, y1, _, _, _, _) ->
       assert (approx_eq x1 50.0);
       assert (approx_eq y1 0.0)
     | _ -> ()));

  run "independent handle move does not reflect" (fun () ->
    let d = make_smooth_path () in
    let result = move_path_handle_independent d 1 "out" 10.0 5.0 in
    (match nth result 2 with
     | CurveTo (x1, y1, _, _, _, _) ->
       assert (approx_eq x1 70.0);    (* 60 + 10 *)
       assert (approx_eq y1 (-15.0))  (* -20 + 5 *)
     | _ -> ());
    (* Incoming handle on cmd[1] is unchanged. *)
    (match nth result 1 with
     | CurveTo (_, _, x2, y2, _, _) ->
       assert (approx_eq x2 40.0);
       assert (approx_eq y2 20.0)
     | _ -> ()));

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
