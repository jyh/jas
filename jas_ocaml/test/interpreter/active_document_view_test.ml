open Jas

let j_member key json =
  match json with
  | `Assoc pairs -> List.assoc_opt key pairs
  | _ -> None

let j_bool json =
  match json with `Bool b -> b | _ -> failwith "not bool"

let j_int json =
  match json with `Int i -> i | _ -> failwith "not int"

let j_list json =
  match json with `List l -> l | _ -> failwith "not list"

let j_string json =
  match json with `String s -> s | _ -> failwith "not string"

(* Helper: build a minimal model with the given top-level layers and
   canvas selection. *)
let make_model ~layer_names ~selection_paths =
  let layers = Array.of_list (List.map (fun name ->
    Element.make_layer ~name [||]
  ) layer_names) in
  let selection = List.fold_left (fun acc path ->
    Document.PathMap.add path (Document.element_selection_all path) acc
  ) Document.PathMap.empty selection_paths in
  let document = Document.make_document ~selection layers in
  Model.create ~document ()

let tests = [
  Alcotest.test_case "no_model_yields_no_selection" `Quick (fun () ->
    let view = Active_document_view.build None in
    assert (j_bool (Option.get (j_member "has_selection" view)) = false);
    assert (j_int (Option.get (j_member "selection_count" view)) = 0);
    assert (j_list (Option.get (j_member "element_selection" view)) = []));

  Alcotest.test_case "empty_selection_yields_no_selection" `Quick (fun () ->
    let m = make_model ~layer_names:["A"] ~selection_paths:[] in
    let view = Active_document_view.build (Some m) in
    assert (j_bool (Option.get (j_member "has_selection" view)) = false);
    assert (j_int (Option.get (j_member "selection_count" view)) = 0));

  Alcotest.test_case "selection_count_matches_selection_size" `Quick (fun () ->
    let m = make_model ~layer_names:["A"]
      ~selection_paths:[[0]; [0; 1]; [0; 2]] in
    let view = Active_document_view.build (Some m) in
    assert (j_bool (Option.get (j_member "has_selection" view)) = true);
    assert (j_int (Option.get (j_member "selection_count" view)) = 3));

  Alcotest.test_case "element_selection_contains_path_markers_in_sorted_order" `Quick (fun () ->
    let m = make_model ~layer_names:["A"]
      ~selection_paths:[[0; 2]; [0]] in
    let view = Active_document_view.build (Some m) in
    let entries = j_list (Option.get (j_member "element_selection" view)) in
    assert (List.length entries = 2);
    let first_path = j_list (Option.get (j_member "__path__" (List.nth entries 0))) in
    let second_path = j_list (Option.get (j_member "__path__" (List.nth entries 1))) in
    (* Sorted: [0] before [0; 2]. *)
    assert (List.map j_int first_path = [0]);
    assert (List.map j_int second_path = [0; 2]));

  Alcotest.test_case "layers_rollups_populated_from_model" `Quick (fun () ->
    let m = make_model ~layer_names:["A"; "B"] ~selection_paths:[] in
    let view = Active_document_view.build (Some m) in
    let top_level = j_list (Option.get (j_member "top_level_layers" view)) in
    assert (List.length top_level = 2);
    assert (j_string (Option.get (j_member "name" (List.nth top_level 0))) = "A");
    assert (j_string (Option.get (j_member "name" (List.nth top_level 1))) = "B"));

  Alcotest.test_case "next_layer_name_skips_existing" `Quick (fun () ->
    let m = make_model ~layer_names:["Layer 1"; "Layer 2"] ~selection_paths:[] in
    let view = Active_document_view.build (Some m) in
    assert (j_string (Option.get (j_member "next_layer_name" view)) = "Layer 3"));

  Alcotest.test_case "layers_panel_selection_count_reflects_argument" `Quick (fun () ->
    let m = make_model ~layer_names:["A"] ~selection_paths:[] in
    let view = Active_document_view.build ~panel_selection:[[0]; [0; 2]] (Some m) in
    assert (j_int (Option.get (j_member "layers_panel_selection_count" view)) = 2));

  Alcotest.test_case "new_layer_insert_index_above_selected_top_level" `Quick (fun () ->
    let m = make_model ~layer_names:["A"; "B"; "C"] ~selection_paths:[] in
    let view = Active_document_view.build ~panel_selection:[[1]] (Some m) in
    assert (j_int (Option.get (j_member "new_layer_insert_index" view)) = 2));
]

let () = Alcotest.run "active_document_view" [ "view", tests ]
