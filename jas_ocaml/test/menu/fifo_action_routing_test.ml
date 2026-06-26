(* Native-first routing for the test-only FIFO [action <name>] channel.

   The [--test-fifo] [action <name>] command dispatches a named workspace
   action. It USED to route every name through the generic panel dispatcher
   ([Panel_menu.dispatch_yaml_action]), which runs only an action's YAML
   [effects]. But document-mutating menubar / edit actions ([select_all],
   [delete_selection], ...) are NATIVE-INTERCEPTED: their actions.yaml
   [effects] are deliberate [log] / [if] stubs, and the real behavior lives
   in native code (the menubar [on_menu_action] closure and the keyboard
   delete path in bin/main.ml). So a FIFO [action select_all] /
   [delete_selection] logged-and-no-op-ed, while a real menu click or
   keystroke worked.

   These tests pin the fix: [Fifo_action_routing.dispatch] routes
   [select_all] / [delete_selection] through the SAME native ops the menu /
   keyboard handlers use, and falls through to the generic dispatcher for
   genuine panel / generic-effect actions. Mirrors the Python
   FifoActionRoutingTest in jas/menu/menu_test.py. *)

open Jas

let make_rect_elem x y w h = Element.make_rect x y w h

(* Build (and return) a model with [n] rects in one layer; [selected]
   toggles whether all of them start selected (full element selection,
   matching Document.element_selection_all). *)
let model_with_rects ~n ~selected =
  let rects = List.init n (fun i -> make_rect_elem (float_of_int (i * 20)) 0.0 10.0 10.0) in
  let layer = Element.make_layer (Array.of_list rects) in
  let selection =
    if selected then
      List.fold_left (fun acc i ->
        let path = [ 0; i ] in
        Document.PathMap.add path (Document.make_element_selection path) acc
      ) Document.PathMap.empty (List.init n (fun i -> i))
    else Document.PathMap.empty
  in
  let doc = Document.make_document ~selection [| layer |] in
  Model.create ~document:doc ()

let selection_count (m : Model.model) =
  Document.PathMap.cardinal m#document.Document.selection

let child_count (m : Model.model) =
  match m#document.Document.layers.(0) with
  | Element.Layer { children; _ } -> Array.length children
  | _ -> Alcotest.fail "expected a Layer at index 0"

let tests = [
  (* select_all over the FIFO must run the NATIVE Controller#select_all
     (NOT the actions.yaml log stub), so all elements become selected. *)
  Alcotest.test_case "fifo select_all selects all via native handler" `Quick (fun () ->
    let m = model_with_rects ~n:2 ~selected:false in
    Alcotest.(check int) "starts unselected" 0 (selection_count m);
    Fifo_action_routing.dispatch ~params:[] "select_all" m;
    Alcotest.(check int) "both selected" 2 (selection_count m));

  (* delete_selection over the FIFO must run the native delete (the shared
     op_apply [delete_selection] path the keyboard Delete uses), removing
     the selected elements. *)
  Alcotest.test_case "fifo delete_selection removes selected via native handler" `Quick (fun () ->
    let m = model_with_rects ~n:2 ~selected:true in
    Alcotest.(check int) "starts with two children" 2 (child_count m);
    Fifo_action_routing.dispatch ~params:[] "delete_selection" m;
    Alcotest.(check int) "children gone" 0 (child_count m));

  (* delete_selection journals exactly ONE named undo step (mirrors the
     keyboard Delete: a single delete_selection op via op_apply), so a
     single undo restores the elements. *)
  Alcotest.test_case "fifo delete_selection is one undoable step" `Quick (fun () ->
    let m = model_with_rects ~n:2 ~selected:true in
    Fifo_action_routing.dispatch ~params:[] "delete_selection" m;
    Alcotest.(check int) "children gone" 0 (child_count m);
    m#undo;
    Alcotest.(check int) "one undo restores both" 2 (child_count m));

  (* A genuine panel / generic action is NOT native-intercepted, so it must
     fall through to the generic dispatcher. We inject a spy in place of the
     default fall-through (Panel_menu.dispatch_yaml_action) and assert the
     unknown name + params reach it verbatim (mirrors the Python
     spy/replace of dock_panel._dispatch_yaml_action). *)
  Alcotest.test_case "fifo unknown action falls through to generic dispatcher" `Quick (fun () ->
    let m = model_with_rects ~n:1 ~selected:false in
    let calls = ref [] in
    let spy ~params name _model = calls := (name, params) :: !calls in
    Fifo_action_routing.dispatch ~fallthrough:spy
      ~params:[ ("k", `Int 1) ] "some_panel_action" m;
    Alcotest.(check int) "exactly one fall-through call" 1 (List.length !calls);
    (match !calls with
     | [ (name, params) ] ->
       Alcotest.(check string) "name forwarded" "some_panel_action" name;
       Alcotest.(check bool) "params forwarded" true
         (List.assoc_opt "k" params = Some (`Int 1))
     | _ -> Alcotest.fail "expected one call"));

  (* The native arms must NOT leak into the fall-through: select_all is
     handled natively, so the generic dispatcher is never consulted. *)
  Alcotest.test_case "fifo select_all does not reach generic dispatcher" `Quick (fun () ->
    let m = model_with_rects ~n:2 ~selected:false in
    let reached = ref false in
    let spy ~params:_ _name _model = reached := true in
    Fifo_action_routing.dispatch ~fallthrough:spy ~params:[] "select_all" m;
    Alcotest.(check bool) "generic dispatcher not consulted" false !reached;
    Alcotest.(check int) "still selected natively" 2 (selection_count m));
]

let () =
  Alcotest.run "FifoActionRouting" [
    "Native-first FIFO action routing", tests;
  ]
