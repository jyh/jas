(** Tests that the four Align panel state keys load with their
    expected defaults from workspace/workspace.json. OCaml
    mirrors the Swift approach: panel state is stored in the
    shared [State_store] as generic Yojson values; there is no
    typed AlignPanelState struct. *)

open Jas

let bool_of json = match json with `Bool b -> b | _ -> failwith "not bool"
let string_of json = match json with `String s -> s | _ -> failwith "not string"
let number_of json = match json with
  | `Float f -> f
  | `Int i -> float_of_int i
  | _ -> failwith "not number"

let tests = [
  Alcotest.test_case "align_state_keys_load_with_expected_defaults" `Quick (fun () ->
    match Workspace_loader.load () with
    | None -> failwith "workspace failed to load"
    | Some ws ->
      let d = Workspace_loader.state_defaults ws in
      assert (string_of (List.assoc "align_to" d) = "selection");
      assert (List.assoc "align_key_object_path" d = `Null);
      assert (number_of (List.assoc "align_distribute_spacing" d) = 0.0);
      assert (bool_of (List.assoc "align_use_preview_bounds" d) = false));

  Alcotest.test_case "align_panel_state_defaults_match_spec" `Quick (fun () ->
    match Workspace_loader.load () with
    | None -> failwith "workspace failed to load"
    | Some ws ->
      let d = Workspace_loader.panel_state_defaults ws "align_panel_content" in
      assert (string_of (List.assoc "align_to" d) = "selection");
      assert (List.assoc "key_object_path" d = `Null);
      assert (number_of (List.assoc "distribute_spacing_value" d) = 0.0);
      assert (bool_of (List.assoc "use_preview_bounds" d) = false));
]

let () =
  Alcotest.run "align_panel_state" [ "defaults", tests ]
