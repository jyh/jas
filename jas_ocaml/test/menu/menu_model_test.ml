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

(* --- Live menu enabled/checked evaluation (TESTING_STRATEGY.md chrome
   seam). These pin that [Menu_ctx.build] produces the canonical context
   shape and that evaluating the bundle predicates against it (the exact
   seam the live menu uses) agrees with the cross-app [Menu_state] gate. *)

(* Recursively sort object keys so equality is order-independent — same
   normalization the cross-language menu_state gate uses. *)
let rec normalize (v : Yojson.Safe.t) : Yojson.Safe.t =
  match v with
  | `Assoc fields ->
    `Assoc
      (List.sort (fun (a, _) (b, _) -> compare a b)
         (List.map (fun (k, x) -> (k, normalize x)) fields))
  | `List xs -> `List (List.map normalize xs)
  | other -> other

let bundle_menubar () : Yojson.Safe.t =
  match Jas.Workspace_loader.load () with
  | Some ws -> `List (Jas.Workspace_loader.menubar ws)
  | None -> Alcotest.fail "workspace bundle not found"

(* Enabled flag of the unique action item named [action] in a menu_state
   result array. Fails if absent or not unique enough to identify. *)
let enabled_of (records : Yojson.Safe.t) (action : string) : bool =
  let open Yojson.Safe.Util in
  match
    List.filter
      (fun r -> member "action" r |> to_string = action)
      (to_list records)
  with
  | [ r ] -> member "enabled" r |> to_bool
  | [] -> Alcotest.failf "action %S not in menu_state output" action
  | _ -> Alcotest.failf "action %S not unique in menu_state output" action

let model_with_selection (n : int) : Jas.Model.model =
  let rects =
    List.init n (fun i ->
        Jas.Element.make_rect (float_of_int (i * 20)) 0.0 10.0 10.0)
  in
  let layer = Jas.Element.make_layer (Array.of_list rects) in
  let doc = Jas.Document.make_document [| layer |] in
  let sel =
    List.fold_left
      (fun acc i ->
        Jas.Document.PathMap.add [ 0; i ]
          (Jas.Document.make_element_selection [ 0; i ])
          acc)
      Jas.Document.PathMap.empty
      (List.init n Fun.id)
  in
  Jas.Model.create ~document:{ doc with Jas.Document.selection = sel } ()

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

  (* The projector now carries each toggle item's bundle [checked_when]
     predicate so the renderer can drive its check mark. *)
  Alcotest.test_case "toggle_panel(color) carries checked_when" `Quick (fun () ->
    let model = menu_bar_model () in
    let window = find_menu model "&Window" in
    let color =
      List.find_opt
        (function
          | Action a ->
            a.action = "toggle_panel"
            && (match List.assoc_opt "panel" a.params with
                | Some (`String "color") -> true
                | _ -> false)
          | _ -> false)
        window.entries
    in
    match color with
    | Some (Action a) ->
      Alcotest.(check (option string))
        "checked_when" (Some "panels.color") a.checked_when;
      Alcotest.(check (option string)) "enabled_when" None a.enabled_when
    | _ -> Alcotest.fail "toggle_panel(color) not found");

  (* Menu_ctx.build with no open document + no layout reproduces the
     canonical "no_document" context shape pinned by the cross-app
     menu_state gate (test_fixtures/algorithms/menu_state.json). *)
  Alcotest.test_case "Menu_ctx.build no-document shape" `Quick (fun () ->
    let ctx =
      Jas.Menu_ctx.build ~tab_count:0 ~model:None ~workspace_layout:None
        ~app_config:None
    in
    let bools ids = List.map (fun id -> (id, `Bool false)) ids in
    let expected : Yojson.Safe.t =
      `Assoc
        [ ("state", `Assoc [ ("tab_count", `Int 0) ]);
          ( "active_document",
            `Assoc
              [ ("has_selection", `Bool false);
                ("selection_count", `Int 0);
                ("can_undo", `Bool false);
                ("can_redo", `Bool false);
                ("is_modified", `Bool false);
                ("has_filename", `Bool false) ] );
          ("workspace", `Assoc [ ("has_saved_layout", `Bool false) ]);
          ( "panels",
            `Assoc
              (bools
                 [ "artboards"; "layers"; "color"; "swatches"; "stroke";
                   "properties"; "character"; "paragraph"; "align"; "boolean";
                   "magic_wand"; "opacity"; "symbols"; "concepts" ]) );
          ("panes", `Assoc (bools [ "toolbar"; "dock" ])) ]
    in
    Alcotest.(check bool)
      "ctx == canonical no_document"
      true
      (normalize ctx = normalize expected));

  (* End-to-end: evaluate the bundle predicates against a Menu_ctx-built
     context (the exact live-menu seam) and confirm enable outcomes. With
     no document open, document-dependent items disable; new/quit stay
     enabled. *)
  Alcotest.test_case "no-document menu enables" `Quick (fun () ->
    let ctx =
      Jas.Menu_ctx.build ~tab_count:0 ~model:None ~workspace_layout:None
        ~app_config:None
    in
    let st = Jas.Menu_state.menu_state (bundle_menubar ()) ctx in
    Alcotest.(check bool) "new_document" true (enabled_of st "new_document");
    Alcotest.(check bool) "quit" true (enabled_of st "quit");
    Alcotest.(check bool) "save" false (enabled_of st "save");
    Alcotest.(check bool) "undo" false (enabled_of st "undo");
    Alcotest.(check bool) "select_all" false (enabled_of st "select_all");
    Alcotest.(check bool) "group" false (enabled_of st "group"));

  (* A seeded model with two whole-element selections drives the
     selection-count predicates: save/select_all enable (tab > 0), group
     enables (>= 2), make_instance stays disabled (== 1), undo stays
     disabled (a constructor-seeded doc has no journal), revert stays
     disabled (untitled + unmodified). *)
  Alcotest.test_case "two-selected menu enables" `Quick (fun () ->
    let m = model_with_selection 2 in
    let ctx =
      Jas.Menu_ctx.build ~tab_count:1 ~model:(Some m) ~workspace_layout:None
        ~app_config:None
    in
    (* Context reflects the seeded selection. *)
    let open Yojson.Safe.Util in
    Alcotest.(check int) "selection_count" 2
      (ctx |> member "active_document" |> member "selection_count" |> to_int);
    Alcotest.(check bool) "has_selection" true
      (ctx |> member "active_document" |> member "has_selection" |> to_bool);
    Alcotest.(check bool) "has_filename(untitled)" false
      (ctx |> member "active_document" |> member "has_filename" |> to_bool);
    let st = Jas.Menu_state.menu_state (bundle_menubar ()) ctx in
    Alcotest.(check bool) "save" true (enabled_of st "save");
    Alcotest.(check bool) "select_all" true (enabled_of st "select_all");
    Alcotest.(check bool) "group" true (enabled_of st "group");
    Alcotest.(check bool) "make_instance" false (enabled_of st "make_instance");
    Alcotest.(check bool) "undo" false (enabled_of st "undo");
    Alcotest.(check bool) "revert" false (enabled_of st "revert"));

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
