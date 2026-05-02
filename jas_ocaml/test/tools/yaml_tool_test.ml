(** Phase 5 of the OCaml YAML tool-runtime migration. Covers the
    [Yaml_tool] class — [tool_spec] parsing, state-defaults
    seeding, and event dispatch through [Yaml_tool_effects.build]. *)

open Jas

let () = ignore (GMain.init ())

let make_ctx ?model () =
  let model = match model with
    | Some m -> m | None -> Model.create ()
  in
  let ctrl = new Controller.controller ~model () in
  let ctx : Canvas_tool.tool_context = {
    model;
    controller = ctrl;
    hit_test_selection = (fun _ _ -> false);
    hit_test_handle = (fun _ _ -> None);
    hit_test_text = (fun _ _ -> None);
    hit_test_path_curve = (fun _ _ -> None);
    request_update = (fun () -> ());
    draw_element_overlay = (fun _cr _elem ~is_partial:_ _cps -> ());
  } in
  (ctx, model, ctrl)

let simple_spec (id : string)
    (handlers : (string * Yojson.Safe.t list) list)
    ?(state : (string * Yojson.Safe.t) list = [])
    () : Yojson.Safe.t =
  let state_json = `Assoc state in
  let handlers_json = `Assoc (List.map (fun (k, v) -> (k, `List v)) handlers) in
  `Assoc [
    ("id", `String id);
    ("state", state_json);
    ("handlers", handlers_json);
  ]

(* ── ToolSpec parsing ─────────────────────────────────── *)

let tool_spec_tests = [
  Alcotest.test_case "requires_id" `Quick (fun () ->
    assert (Yaml_tool.tool_spec_from_workspace (`Assoc []) = None);
    assert (Yaml_tool.tool_spec_from_workspace
              (`Assoc [("id", `String "foo")]) <> None));

  Alcotest.test_case "parses_cursor_and_menu_label" `Quick (fun () ->
    match Yaml_tool.tool_spec_from_workspace (`Assoc [
      ("id", `String "foo");
      ("cursor", `String "crosshair");
      ("menu_label", `String "Foo Tool");
      ("shortcut", `String "F");
    ]) with
    | Some s ->
      assert (s.cursor = Some "crosshair");
      assert (s.menu_label = Some "Foo Tool");
      assert (s.shortcut = Some "F")
    | None -> assert false);

  Alcotest.test_case "parses_state_shorthand" `Quick (fun () ->
    match Yaml_tool.tool_spec_from_workspace (`Assoc [
      ("id", `String "foo");
      ("state", `Assoc [
        ("count", `Int 3);
        ("active", `Bool false);
      ]);
    ]) with
    | Some s ->
      assert (List.assoc "count" s.state_defaults = `Int 3);
      assert (List.assoc "active" s.state_defaults = `Bool false)
    | None -> assert false);

  Alcotest.test_case "parses_state_long_form" `Quick (fun () ->
    match Yaml_tool.tool_spec_from_workspace (`Assoc [
      ("id", `String "foo");
      ("state", `Assoc [
        ("mode", `Assoc [
          ("default", `String "idle");
          ("enum", `List [`String "idle"; `String "busy"]);
        ]);
      ]);
    ]) with
    | Some s ->
      assert (List.assoc "mode" s.state_defaults = `String "idle")
    | None -> assert false);

  Alcotest.test_case "parses_handlers" `Quick (fun () ->
    match Yaml_tool.tool_spec_from_workspace (`Assoc [
      ("id", `String "foo");
      ("handlers", `Assoc [
        ("on_mousedown", `List [
          `Assoc [("doc.snapshot", `Null)]
        ]);
      ]);
    ]) with
    | Some s ->
      assert (List.length (Yaml_tool.handler s "on_mousedown") = 1);
      assert (Yaml_tool.handler s "on_mousemove" = [])
    | None -> assert false);

  Alcotest.test_case "parses_overlay" `Quick (fun () ->
    match Yaml_tool.tool_spec_from_workspace (`Assoc [
      ("id", `String "foo");
      ("overlay", `Assoc [
        ("if", `String "tool.foo.show");
        ("render", `Assoc [("type", `String "rect")]);
      ]);
    ]) with
    | Some s ->
      (match s.overlay with
       | [ov] ->
         assert (ov.guard = Some "tool.foo.show");
         (match ov.render with
          | `Assoc r -> assert (List.assoc "type" r = `String "rect")
          | _ -> assert false)
       | _ -> assert false)
    | None -> assert false);
]

(* ── Yaml_tool dispatch ──────────────────────────────── *)

let dispatch_tests = [
  Alcotest.test_case "seeds_state_defaults" `Quick (fun () ->
    let spec_json = simple_spec "foo" [] ~state:[("count", `Int 7)] () in
    match Yaml_tool.from_workspace_tool spec_json with
    | Some tool ->
      assert (tool#tool_state "count" = `Int 7)
    | None -> assert false);

  Alcotest.test_case "mousedown_dispatches_handler" `Quick (fun () ->
    let spec_json = simple_spec "foo" [
      ("on_mousedown", [
        `Assoc [("set", `Assoc [("$tool.foo.pressed", `String "true")])];
      ]);
    ] () in
    match Yaml_tool.from_workspace_tool spec_json with
    | Some tool ->
      let (ctx, _, _) = make_ctx () in
      tool#on_press ctx 10.0 20.0 ~shift:false ~alt:false;
      assert (tool#tool_state "pressed" = `Bool true)
    | None -> assert false);

  Alcotest.test_case "mouseup_payload_carries_coordinates" `Quick (fun () ->
    let spec_json = simple_spec "foo" [
      ("on_mouseup", [
        `Assoc [("set", `Assoc [("$tool.foo.x_at_release", `String "event.x")])];
      ]);
    ] () in
    match Yaml_tool.from_workspace_tool spec_json with
    | Some tool ->
      let (ctx, _, _) = make_ctx () in
      tool#on_release ctx 42.0 0.0 ~shift:false ~alt:false;
      (match tool#tool_state "x_at_release" with
       | `Float f -> assert (f = 42.0)
       | `Int n -> assert (n = 42)
       | _ -> assert false)
    | None -> assert false);

  Alcotest.test_case "empty_handler_is_noop" `Quick (fun () ->
    let spec_json = simple_spec "foo" [] () in
    match Yaml_tool.from_workspace_tool spec_json with
    | Some tool ->
      let (ctx, model, _) = make_ctx () in
      tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
      assert (Document.PathMap.is_empty model#document.selection)
    | None -> assert false);

  Alcotest.test_case "activate_resets_state_defaults" `Quick (fun () ->
    let spec_json = simple_spec "foo" [
      ("on_mousedown", [
        `Assoc [("set", `Assoc [("$tool.foo.mode", `String "'busy'")])];
      ]);
    ] ~state:[("mode", `String "idle")] () in
    match Yaml_tool.from_workspace_tool spec_json with
    | Some tool ->
      let (ctx, _, _) = make_ctx () in
      tool#on_press ctx 0.0 0.0 ~shift:false ~alt:false;
      assert (tool#tool_state "mode" = `String "busy");
      tool#activate ctx;
      assert (tool#tool_state "mode" = `String "idle")
    | None -> assert false);

  Alcotest.test_case "keydown_dispatches_when_declared" `Quick (fun () ->
    let spec_json = simple_spec "foo" [
      ("on_keydown", [
        `Assoc [("set", `Assoc [("$tool.foo.last_key", `String "event.key")])];
      ]);
    ] () in
    match Yaml_tool.from_workspace_tool spec_json with
    | Some tool ->
      let (ctx, _, _) = make_ctx () in
      let consumed = tool#on_key_event ctx "Escape"
        { shift = false; ctrl = false; alt = false; meta = false } in
      assert consumed;
      assert (tool#tool_state "last_key" = `String "Escape")
    | None -> assert false);

  Alcotest.test_case "keydown_returns_false_when_undeclared" `Quick (fun () ->
    let spec_json = simple_spec "foo" [] () in
    match Yaml_tool.from_workspace_tool spec_json with
    | Some tool ->
      let (ctx, _, _) = make_ctx () in
      assert (not (tool#on_key_event ctx "Escape"
        { shift = false; ctrl = false; alt = false; meta = false }))
    | None -> assert false);

  Alcotest.test_case "cursor_override_reflects_spec" `Quick (fun () ->
    match Yaml_tool.from_workspace_tool (`Assoc [
      ("id", `String "foo");
      ("cursor", `String "crosshair");
    ]) with
    | Some tool ->
      assert (tool#cursor_css_override () = Some "crosshair")
    | None -> assert false);

  Alcotest.test_case "dispatches_doc_effects" `Quick (fun () ->
    let spec_json = `Assoc [
      ("id", `String "foo");
      ("handlers", `Assoc [
        ("on_mousedown", `List [
          `Assoc [("doc.add_element", `Assoc [
            ("element", `Assoc [
              ("type", `String "rect");
              ("x", `String "event.x"); ("y", `String "event.y");
              ("width", `Int 10); ("height", `Int 10);
            ])
          ])]
        ]);
      ]);
    ] in
    match Yaml_tool.from_workspace_tool spec_json with
    | Some tool ->
      let model = Model.create () in
      let layer = Element.Layer {
        name = Some "L"; children = [||];
        transform = None; locked = false; opacity = 1.0;
        visibility = Preview; blend_mode = Normal; mask = None;
        isolated_blending = false; knockout_group = false;
      } in
      model#set_document (Document.make_document [| layer |]);
      let (ctx, _, _) = make_ctx ~model () in
      tool#on_press ctx 5.0 7.0 ~shift:false ~alt:false;
      (match model#document.layers.(0) with
       | Element.Layer { children; _ } ->
         assert (Array.length children = 1)
       | _ -> assert false)
    | None -> assert false);
]

(* Phase 5b: overlay style + color parsing. *)

let overlay_style_tests = [
  Alcotest.test_case "parse_style_empty" `Quick (fun () ->
    let s = Yaml_tool.parse_style "" in
    assert (s.fill = None);
    assert (s.stroke = None);
    assert (s.stroke_width = None);
    assert (s.stroke_dasharray = None));

  Alcotest.test_case "parse_style_fill_and_stroke" `Quick (fun () ->
    let s = Yaml_tool.parse_style
      "fill: rgba(0,120,215,0.1); stroke: rgb(0,120,215); stroke-width: 2" in
    assert (s.fill = Some "rgba(0,120,215,0.1)");
    assert (s.stroke = Some "rgb(0,120,215)");
    assert (s.stroke_width = Some 2.0));

  Alcotest.test_case "parse_style_dasharray" `Quick (fun () ->
    let s = Yaml_tool.parse_style "stroke: black; stroke-dasharray: 4 4" in
    assert (s.stroke_dasharray = Some [4.0; 4.0]));

  Alcotest.test_case "parse_style_dasharray_comma" `Quick (fun () ->
    let s = Yaml_tool.parse_style "stroke-dasharray: 3, 5, 2" in
    assert (s.stroke_dasharray = Some [3.0; 5.0; 2.0]));

  Alcotest.test_case "parse_style_ignores_unknown" `Quick (fun () ->
    let s = Yaml_tool.parse_style "fill: red; opacity: 0.5; foo: bar" in
    assert (s.fill = Some "red"));
]

let overlay_color_tests = [
  Alcotest.test_case "parse_color_hex6" `Quick (fun () ->
    match Yaml_tool.parse_color "#ff0000" with
    | Some (r, g, b, a) ->
      assert (abs_float (r -. 1.0) < 1e-6);
      assert (abs_float g < 1e-6);
      assert (abs_float b < 1e-6);
      assert (abs_float (a -. 1.0) < 1e-9)
    | None -> assert false);

  Alcotest.test_case "parse_color_hex3" `Quick (fun () ->
    match Yaml_tool.parse_color "#fff" with
    | Some (r, g, b, _) ->
      assert (abs_float (r -. 1.0) < 1e-6);
      assert (abs_float (g -. 1.0) < 1e-6);
      assert (abs_float (b -. 1.0) < 1e-6)
    | None -> assert false);

  Alcotest.test_case "parse_color_rgb" `Quick (fun () ->
    match Yaml_tool.parse_color "rgb(0, 120, 215)" with
    | Some (r, g, b, a) ->
      assert (abs_float r < 1e-9);
      assert (abs_float (g -. (120.0 /. 255.0)) < 1e-6);
      assert (abs_float (b -. (215.0 /. 255.0)) < 1e-6);
      assert (abs_float (a -. 1.0) < 1e-9)
    | None -> assert false);

  Alcotest.test_case "parse_color_rgba" `Quick (fun () ->
    match Yaml_tool.parse_color "rgba(0, 120, 215, 0.1)" with
    | Some (_, _, _, a) ->
      assert (abs_float (a -. 0.1) < 1e-6)
    | None -> assert false);

  Alcotest.test_case "parse_color_none" `Quick (fun () ->
    assert (Yaml_tool.parse_color "none" = None));

  Alcotest.test_case "parse_color_named_black" `Quick (fun () ->
    assert (Yaml_tool.parse_color "black" = Some (0.0, 0.0, 0.0, 1.0)));

  Alcotest.test_case "parse_color_invalid" `Quick (fun () ->
    assert (Yaml_tool.parse_color "garbage" = None));
]

let () =
  Alcotest.run "Yaml_tool" [
    "ToolSpec parsing", tool_spec_tests;
    "Dispatch", dispatch_tests;
    "Overlay style parse", overlay_style_tests;
    "Overlay color parse", overlay_color_tests;
  ]
