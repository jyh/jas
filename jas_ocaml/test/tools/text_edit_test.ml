(* Tests for the Text_edit session module. Mirrors jas/tools/text_edit_test.py. *)

let session content =
  Jas.Text_edit.create
    ~path:[0; 0] ~target:Jas.Text_edit.Edit_text ~content ~insertion:0

let () =
  Alcotest.run "Text_edit" [
    "caret and insertion", [
      Alcotest.test_case "new session caret" `Quick (fun () ->
        let s = Jas.Text_edit.create
          ~path:[0; 0] ~target:Jas.Text_edit.Edit_text
          ~content:"abc" ~insertion:2 in
        assert (Jas.Text_edit.insertion s = 2);
        assert (Jas.Text_edit.anchor s = 2);
        assert (not (Jas.Text_edit.has_selection s)));

      Alcotest.test_case "insert advances" `Quick (fun () ->
        let s = session "hello" in
        Jas.Text_edit.set_insertion s 5 ~extend:false;
        Jas.Text_edit.insert s " world";
        assert (Jas.Text_edit.content s = "hello world");
        assert (Jas.Text_edit.insertion s = 11));

      Alcotest.test_case "insert replaces selection" `Quick (fun () ->
        let s = session "hello" in
        Jas.Text_edit.set_insertion s 0 ~extend:false;
        Jas.Text_edit.set_insertion s 5 ~extend:true;
        Jas.Text_edit.insert s "hi";
        assert (Jas.Text_edit.content s = "hi");
        assert (Jas.Text_edit.insertion s = 2));

      Alcotest.test_case "set_insertion clamps" `Quick (fun () ->
        let s = session "hi" in
        Jas.Text_edit.set_insertion s 99 ~extend:false;
        assert (Jas.Text_edit.insertion s = 2));
    ];

    "backspace and delete", [
      Alcotest.test_case "backspace" `Quick (fun () ->
        let s = session "hello" in
        Jas.Text_edit.set_insertion s 5 ~extend:false;
        Jas.Text_edit.backspace s;
        assert (Jas.Text_edit.content s = "hell");
        assert (Jas.Text_edit.insertion s = 4));

      Alcotest.test_case "backspace at start is noop" `Quick (fun () ->
        let s = session "hi" in
        Jas.Text_edit.set_insertion s 0 ~extend:false;
        Jas.Text_edit.backspace s;
        assert (Jas.Text_edit.content s = "hi"));

      Alcotest.test_case "backspace with selection deletes range" `Quick (fun () ->
        let s = session "hello" in
        Jas.Text_edit.set_insertion s 1 ~extend:false;
        Jas.Text_edit.set_insertion s 4 ~extend:true;
        Jas.Text_edit.backspace s;
        assert (Jas.Text_edit.content s = "ho");
        assert (Jas.Text_edit.insertion s = 1));

      Alcotest.test_case "delete forward" `Quick (fun () ->
        let s = session "hello" in
        Jas.Text_edit.set_insertion s 0 ~extend:false;
        Jas.Text_edit.delete_forward s;
        assert (Jas.Text_edit.content s = "ello"));

      Alcotest.test_case "delete forward at end is noop" `Quick (fun () ->
        let s = session "hi" in
        Jas.Text_edit.set_insertion s 2 ~extend:false;
        Jas.Text_edit.delete_forward s;
        assert (Jas.Text_edit.content s = "hi"));
    ];

    "selection", [
      Alcotest.test_case "select all" `Quick (fun () ->
        let s = session "hello" in
        Jas.Text_edit.select_all s;
        assert (Jas.Text_edit.selection_range s = (0, 5)));

      Alcotest.test_case "copy selection" `Quick (fun () ->
        let s = session "hello" in
        Jas.Text_edit.set_insertion s 1 ~extend:false;
        Jas.Text_edit.set_insertion s 4 ~extend:true;
        assert (Jas.Text_edit.copy_selection s = Some "ell"));

      Alcotest.test_case "copy with no selection returns None" `Quick (fun () ->
        assert (Jas.Text_edit.copy_selection (session "hello") = None));

      Alcotest.test_case "extend selection keeps anchor" `Quick (fun () ->
        let s = session "hello" in
        Jas.Text_edit.set_insertion s 2 ~extend:false;
        Jas.Text_edit.set_insertion s 4 ~extend:true;
        assert (Jas.Text_edit.anchor s = 2);
        assert (Jas.Text_edit.insertion s = 4);
        assert (Jas.Text_edit.selection_range s = (2, 4)));

      Alcotest.test_case "reverse selection orders" `Quick (fun () ->
        let s = session "hello" in
        Jas.Text_edit.set_insertion s 4 ~extend:false;
        Jas.Text_edit.set_insertion s 1 ~extend:true;
        assert (Jas.Text_edit.selection_range s = (1, 4)));

      Alcotest.test_case "select all then insert replaces" `Quick (fun () ->
        let s = session "hello" in
        Jas.Text_edit.select_all s;
        Jas.Text_edit.insert s "X";
        assert (Jas.Text_edit.content s = "X");
        assert (Jas.Text_edit.insertion s = 1));
    ];

    "undo and redo", [
      Alcotest.test_case "undo and redo" `Quick (fun () ->
        let s = session "" in
        Jas.Text_edit.insert s "a";
        Jas.Text_edit.insert s "b";
        assert (Jas.Text_edit.content s = "ab");
        Jas.Text_edit.undo s;
        assert (Jas.Text_edit.content s = "a");
        Jas.Text_edit.undo s;
        assert (Jas.Text_edit.content s = "");
        Jas.Text_edit.redo s;
        assert (Jas.Text_edit.content s = "a"));

      Alcotest.test_case "new edit clears redo" `Quick (fun () ->
        let s = session "" in
        Jas.Text_edit.insert s "a";
        Jas.Text_edit.undo s;
        Jas.Text_edit.insert s "b";
        Jas.Text_edit.redo s;
        assert (Jas.Text_edit.content s = "b"));
    ];

    "session tspan clipboard", [
      (* Mirrors TextEditSessionTests.swift. *)
      Alcotest.test_case "copy_selection_with_tspans captures and returns flat" `Quick (fun () ->
        let open Jas in
        let ts0 = { (Tspan.default_tspan ()) with id = 0; content = "foo" } in
        let ts1 = { (Tspan.default_tspan ()) with id = 1; content = "bar";
                                                  font_weight = Some "bold" } in
        let element_tspans = [| ts0; ts1 |] in
        let s = Text_edit.create
          ~path:[0; 0] ~target:Text_edit.Edit_text
          ~content:"foobar" ~insertion:0 in
        Text_edit.set_insertion s 1 ~extend:false;
        Text_edit.set_insertion s 5 ~extend:true;
        let flat = Text_edit.copy_selection_with_tspans s element_tspans in
        assert (flat = Some "ooba"));

      Alcotest.test_case "try_paste_tspans matches and splices" `Quick (fun () ->
        let open Jas in
        let element_tspans = [| { (Tspan.default_tspan ()) with id = 0; content = "foo" } |] in
        let s = Text_edit.create
          ~path:[0; 0] ~target:Text_edit.Edit_text
          ~content:"foo" ~insertion:0 in
        (* Prime the clipboard by doing a copy first, then overwrite
           content to simulate an external change-and-return scenario. *)
        let payload = [| { (Tspan.default_tspan ()) with id = 0; content = "X";
                                                         font_weight = Some "bold" } |] in
        let element_with_X = [| { (Tspan.default_tspan ()) with id = 0; content = "X";
                                                                font_weight = Some "bold" } |] in
        (* Simulate capture path: set selection and call copy_selection_with_tspans
           after priming content. *)
        Text_edit.set_content s "X" ~insertion:0 ~anchor:1;
        let _ = Text_edit.copy_selection_with_tspans s element_with_X in
        (* Now simulate paste at position 1 within "foo". *)
        Text_edit.set_content s "foo" ~insertion:1 ~anchor:1;
        (match Text_edit.try_paste_tspans s element_tspans "X" with
         | Some result ->
           assert (Array.length result = 3);
           assert (result.(0).content = "f");
           assert (result.(1).content = "X");
           assert (result.(1).font_weight = Some "bold");
           assert (result.(2).content = "oo")
         | None ->
           ignore payload;
           assert false));

      Alcotest.test_case "try_paste_tspans returns None when text doesn't match" `Quick (fun () ->
        let open Jas in
        let element_tspans = [| { (Tspan.default_tspan ()) with id = 0; content = "foo" } |] in
        let s = Text_edit.create
          ~path:[0; 0] ~target:Text_edit.Edit_text
          ~content:"foo" ~insertion:0 in
        (* With no prior copy, paste should return None. *)
        assert (Text_edit.try_paste_tspans s element_tspans "X" = None));
    ];

    "UTF-8 multibyte", [
      (* UTF-8 multibyte handling. 'é' is 2 bytes in UTF-8 but a single
         Unicode scalar; the editor must speak in chars throughout. *)
      Alcotest.test_case "insert before multibyte char advances by one" `Quick (fun () ->
        let s = session "aéb" in
        Jas.Text_edit.set_insertion s 2 ~extend:false;
        Jas.Text_edit.insert s "X";
        assert (Jas.Text_edit.content s = "aéXb");
        assert (Jas.Text_edit.insertion s = 3));

      Alcotest.test_case "backspace removes one multibyte char" `Quick (fun () ->
        let s = session "aéb" in
        Jas.Text_edit.set_insertion s 2 ~extend:false;
        Jas.Text_edit.backspace s;
        (* "ab", caret at 1 *)
        assert (Jas.Text_edit.content s = "ab");
        assert (Jas.Text_edit.insertion s = 1));

      Alcotest.test_case "delete_forward removes one multibyte char" `Quick (fun () ->
        let s = session "aéb" in
        Jas.Text_edit.set_insertion s 1 ~extend:false;
        Jas.Text_edit.delete_forward s;
        assert (Jas.Text_edit.content s = "ab"));

      Alcotest.test_case "copy_selection across multibyte" `Quick (fun () ->
        let s = session "aéb" in
        Jas.Text_edit.set_insertion s 0 ~extend:false;
        Jas.Text_edit.set_insertion s 2 ~extend:true;
        assert (Jas.Text_edit.copy_selection s = Some "aé"));

      Alcotest.test_case "select all then insert with multibyte content" `Quick (fun () ->
        let s = session "aébc" in
        Jas.Text_edit.set_insertion s 1 ~extend:false;
        Jas.Text_edit.set_insertion s 3 ~extend:true;
        Jas.Text_edit.backspace s;
        assert (Jas.Text_edit.content s = "ac"));
    ];
  ]
