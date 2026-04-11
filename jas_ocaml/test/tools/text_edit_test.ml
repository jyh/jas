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
