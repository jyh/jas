(* Headless projector tests for the menubar render model.

   These pin the projection of the compiled bundle [menubar]
   (menubar.yaml) into [Menu_model.menu_bar_model] so the OCaml menu bar
   can never drift from the spec. No GTK display is touched: the model
   is pure data. Mirrors the Rust menu.rs host tests. *)

open Jas.Menu_model

let action_names (m : menu) : string list =
  List.filter_map (function
    | Action a -> Some a.action
    | _ -> None) m.entries

let find_menu (model : menu list) (label : string) : menu =
  match List.find_opt (fun m -> m.label = label) model with
  | Some m -> m
  | None -> Alcotest.failf "menu %S not present" label

let tests = [
  Alcotest.test_case "five menus File/Edit/Object/View/Window" `Quick (fun () ->
    let model = menu_bar_model () in
    let labels = List.map (fun m -> m.label) model in
    Alcotest.(check (list string)) "labels"
      ["&File"; "&Edit"; "&Object"; "&View"; "&Window"] labels);

  Alcotest.test_case "File menu has print + export" `Quick (fun () ->
    let model = menu_bar_model () in
    let acts = action_names (find_menu model "&File") in
    assert (List.mem "open_print_dialog" acts);
    assert (List.mem "export_to_pdf" acts));

  Alcotest.test_case "View menu has zoom_in + fit_active_artboard" `Quick (fun () ->
    let model = menu_bar_model () in
    let acts = action_names (find_menu model "&View") in
    assert (List.mem "zoom_in" acts);
    assert (List.mem "fit_active_artboard" acts));

  Alcotest.test_case "Object menu has promote_to_concept" `Quick (fun () ->
    let model = menu_bar_model () in
    let acts = action_names (find_menu model "&Object") in
    assert (List.mem "promote_to_concept" acts));

  Alcotest.test_case "Window menu has both dynamic submenus" `Quick (fun () ->
    let model = menu_bar_model () in
    let window = find_menu model "&Window" in
    let kinds = List.filter_map (function
      | Dynamic_submenu d -> Some d.kind
      | _ -> None) window.entries in
    assert (List.mem Workspace kinds);
    assert (List.mem Appearance kinds));

  Alcotest.test_case "Window menu has toggle_panel(color)" `Quick (fun () ->
    let model = menu_bar_model () in
    let window = find_menu model "&Window" in
    let has_color = List.exists (function
      | Action a ->
        a.action = "toggle_panel" &&
        (match List.assoc_opt "panel" a.params with
         | Some (`String "color") -> true
         | _ -> false)
      | _ -> false) window.entries in
    assert has_color);

  Alcotest.test_case "Window menu has separators" `Quick (fun () ->
    let model = menu_bar_model () in
    let window = find_menu model "&Window" in
    let seps = List.length (List.filter (function Separator -> true | _ -> false) window.entries) in
    assert (seps >= 1));

  Alcotest.test_case "File menu has separators" `Quick (fun () ->
    let model = menu_bar_model () in
    let file = find_menu model "&File" in
    let seps = List.length (List.filter (function Separator -> true | _ -> false) file.entries) in
    assert (seps >= 1));

  Alcotest.test_case "strip_mnemonic drops the marker" `Quick (fun () ->
    Alcotest.(check string) "File" "File" (strip_mnemonic "&File");
    Alcotest.(check string) "Zoom In" "Zoom In" (strip_mnemonic "Zoom &In");
    Alcotest.(check string) "Save As..." "Save As..." (strip_mnemonic "Save &As...");
    Alcotest.(check string) "Concepts" "Concepts" (strip_mnemonic "Co&ncepts");
    Alcotest.(check string) "escaped amp" "A & B" (strip_mnemonic "A && B"));
]

let () =
  Alcotest.run "MenuModel" [
    "Menu model tests", tests;
  ]
