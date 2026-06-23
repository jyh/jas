open Jas

(* Unit tests for the toolbar tool-options double-click lookup/dispatch
   (Yaml_panel_view). These exercise the PURE, GUI-free surface:
     - [is_tool_button] (the discriminator that scopes the dblclick to
       toolbar tool buttons only), and
     - [tool_options_dispatch_for] (the bundle lookup + panel > action >
       dialog priority order).
   The actual panel/dialog opening + action run is GUI (user-verified). *)

module Y = Yaml_panel_view

(* Build a minimal icon_button element with the given behavior array. *)
let icon_button ~behavior =
  `Assoc [ ("type", `String "icon_button"); ("behavior", `List behavior) ]

let click_select_tool tool =
  `Assoc [ ("event", `String "click");
           ("action", `String "select_tool");
           ("params", `Assoc [ ("tool", `String tool) ]) ]

(* ── is_tool_button ──────────────────────────────────────────────── *)

let is_tool_button_tests = [
  Alcotest.test_case "tool_button_with_select_tool_click" `Quick (fun () ->
    let el = icon_button ~behavior:[ click_select_tool "pencil" ] in
    Alcotest.(check bool) "tool button" true (Y.is_tool_button el));

  Alcotest.test_case "slot_tool_button_with_long_press" `Quick (fun () ->
    (* A slot button has mouse_down/up flyout behaviors AND the click
       select_tool — still a tool button. *)
    let el = icon_button ~behavior:[
      `Assoc [ ("event", `String "mouse_down"); ("effects", `List []) ];
      `Assoc [ ("event", `String "mouse_up"); ("effects", `List []) ];
      click_select_tool "pen";
    ] in
    Alcotest.(check bool) "slot tool button" true (Y.is_tool_button el));

  Alcotest.test_case "fill_stroke_button_is_not_a_tool_button" `Quick (fun () ->
    (* The swap / reset / solid / gradient / none icon_buttons use other
       actions, not select_tool — must be excluded. *)
    let el = icon_button ~behavior:[
      `Assoc [ ("event", `String "click");
               ("action", `String "swap_fill_stroke") ];
    ] in
    Alcotest.(check bool) "fill/stroke button excluded"
      false (Y.is_tool_button el));

  Alcotest.test_case "panel_icon_button_without_behavior_excluded" `Quick (fun () ->
    let el = `Assoc [ ("type", `String "icon_button") ] in
    Alcotest.(check bool) "no behavior excluded" false (Y.is_tool_button el));

  Alcotest.test_case "plain_button_type_excluded" `Quick (fun () ->
    (* Even with a select_tool click, a non-icon_button type isn't a tool
       button (the toolbar grid stamps icon_button). *)
    let el = `Assoc [ ("type", `String "button");
                      ("behavior", `List [ click_select_tool "pencil" ]) ] in
    Alcotest.(check bool) "plain button excluded" false (Y.is_tool_button el));
]

(* ── tool_options_dispatch_for (bundle lookup + priority) ────────── *)

(* These read the compiled workspace.json, so they only run when the
   bundle loads. Guard each by checking the bundle is present; if not,
   skip the assertion (the cross-language corpus gate covers bundle
   presence elsewhere). The expected mappings come straight from the
   bundle's tools map:
     paintbrush/blob_brush/scale/rotate/shear/eyedropper -> dialog
     hand/zoom/artboard -> action
     magic_wand -> panel
     pencil/selection -> none. *)
let bundle_loaded () = Workspace_loader.load () <> None

let dispatch_tests = [
  Alcotest.test_case "magic_wand_opens_panel" `Quick (fun () ->
    if bundle_loaded () then
      match Y.tool_options_dispatch_for "magic_wand" with
      | Y.Show_panel Workspace_layout.Magic_wand -> ()
      | _ -> Alcotest.fail "magic_wand should resolve to Show_panel Magic_wand");

  Alcotest.test_case "hand_runs_action" `Quick (fun () ->
    if bundle_loaded () then
      match Y.tool_options_dispatch_for "hand" with
      | Y.Run_action "fit_active_artboard" -> ()
      | _ -> Alcotest.fail "hand should resolve to Run_action fit_active_artboard");

  Alcotest.test_case "zoom_runs_action" `Quick (fun () ->
    if bundle_loaded () then
      match Y.tool_options_dispatch_for "zoom" with
      | Y.Run_action "zoom_to_actual_size" -> ()
      | _ -> Alcotest.fail "zoom should resolve to Run_action zoom_to_actual_size");

  Alcotest.test_case "paintbrush_opens_dialog" `Quick (fun () ->
    if bundle_loaded () then
      match Y.tool_options_dispatch_for "paintbrush" with
      | Y.Open_dialog "paintbrush_tool_options" -> ()
      | _ -> Alcotest.fail "paintbrush should resolve to Open_dialog");

  Alcotest.test_case "scale_opens_dialog" `Quick (fun () ->
    if bundle_loaded () then
      match Y.tool_options_dispatch_for "scale" with
      | Y.Open_dialog "scale_options" -> ()
      | _ -> Alcotest.fail "scale should resolve to Open_dialog scale_options");

  Alcotest.test_case "eyedropper_opens_dialog" `Quick (fun () ->
    if bundle_loaded () then
      match Y.tool_options_dispatch_for "eyedropper" with
      | Y.Open_dialog "eyedropper_tool_options" -> ()
      | _ -> Alcotest.fail "eyedropper should resolve to Open_dialog");

  Alcotest.test_case "pencil_has_no_options" `Quick (fun () ->
    if bundle_loaded () then
      match Y.tool_options_dispatch_for "pencil" with
      | Y.No_options -> ()
      | _ -> Alcotest.fail "pencil declares no tool options -> No_options");

  Alcotest.test_case "selection_has_no_options" `Quick (fun () ->
    if bundle_loaded () then
      match Y.tool_options_dispatch_for "selection" with
      | Y.No_options -> ()
      | _ -> Alcotest.fail "selection declares no tool options -> No_options");

  Alcotest.test_case "unknown_tool_has_no_options" `Quick (fun () ->
    if bundle_loaded () then
      match Y.tool_options_dispatch_for "no_such_tool_xyz" with
      | Y.No_options -> ()
      | _ -> Alcotest.fail "unknown tool -> No_options");
]

(* ── panel_id_to_kind ────────────────────────────────────────────── *)

let panel_id_tests = [
  Alcotest.test_case "magic_wand_id_maps" `Quick (fun () ->
    Alcotest.(check bool) "magic_wand -> Magic_wand" true
      (Y.panel_id_to_kind "magic_wand" = Some Workspace_layout.Magic_wand));

  Alcotest.test_case "color_id_maps" `Quick (fun () ->
    Alcotest.(check bool) "color -> Color" true
      (Y.panel_id_to_kind "color" = Some Workspace_layout.Color));

  Alcotest.test_case "unknown_panel_id_is_none" `Quick (fun () ->
    Alcotest.(check bool) "unknown -> None" true
      (Y.panel_id_to_kind "no_such_panel" = None));
]

let () =
  Alcotest.run "tool_options_dispatch" [
    "is_tool_button", is_tool_button_tests;
    "dispatch_for", dispatch_tests;
    "panel_id_to_kind", panel_id_tests;
  ]
