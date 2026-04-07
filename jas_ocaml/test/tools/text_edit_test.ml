(* Tests for the Text_edit session module. Mirrors jas/tools/text_edit_test.py. *)

let run_test name f =
  f ();
  Printf.printf "  PASS: %s\n" name

let session content =
  Jas.Text_edit.create
    ~path:[0; 0] ~target:Jas.Text_edit.Edit_text ~content ~insertion:0

let () =
  Printf.printf "Text_edit tests:\n";

  run_test "new session caret" (fun () ->
    let s = Jas.Text_edit.create
      ~path:[0; 0] ~target:Jas.Text_edit.Edit_text
      ~content:"abc" ~insertion:2 in
    assert (Jas.Text_edit.insertion s = 2);
    assert (Jas.Text_edit.anchor s = 2);
    assert (not (Jas.Text_edit.has_selection s)));

  run_test "insert advances" (fun () ->
    let s = session "hello" in
    Jas.Text_edit.set_insertion s 5 ~extend:false;
    Jas.Text_edit.insert s " world";
    assert (Jas.Text_edit.content s = "hello world");
    assert (Jas.Text_edit.insertion s = 11));

  run_test "insert replaces selection" (fun () ->
    let s = session "hello" in
    Jas.Text_edit.set_insertion s 0 ~extend:false;
    Jas.Text_edit.set_insertion s 5 ~extend:true;
    Jas.Text_edit.insert s "hi";
    assert (Jas.Text_edit.content s = "hi");
    assert (Jas.Text_edit.insertion s = 2));

  run_test "backspace" (fun () ->
    let s = session "hello" in
    Jas.Text_edit.set_insertion s 5 ~extend:false;
    Jas.Text_edit.backspace s;
    assert (Jas.Text_edit.content s = "hell");
    assert (Jas.Text_edit.insertion s = 4));

  run_test "backspace at start is noop" (fun () ->
    let s = session "hi" in
    Jas.Text_edit.set_insertion s 0 ~extend:false;
    Jas.Text_edit.backspace s;
    assert (Jas.Text_edit.content s = "hi"));

  run_test "backspace with selection deletes range" (fun () ->
    let s = session "hello" in
    Jas.Text_edit.set_insertion s 1 ~extend:false;
    Jas.Text_edit.set_insertion s 4 ~extend:true;
    Jas.Text_edit.backspace s;
    assert (Jas.Text_edit.content s = "ho");
    assert (Jas.Text_edit.insertion s = 1));

  run_test "delete forward" (fun () ->
    let s = session "hello" in
    Jas.Text_edit.set_insertion s 0 ~extend:false;
    Jas.Text_edit.delete_forward s;
    assert (Jas.Text_edit.content s = "ello"));

  run_test "delete forward at end is noop" (fun () ->
    let s = session "hi" in
    Jas.Text_edit.set_insertion s 2 ~extend:false;
    Jas.Text_edit.delete_forward s;
    assert (Jas.Text_edit.content s = "hi"));

  run_test "select all" (fun () ->
    let s = session "hello" in
    Jas.Text_edit.select_all s;
    assert (Jas.Text_edit.selection_range s = (0, 5)));

  run_test "copy selection" (fun () ->
    let s = session "hello" in
    Jas.Text_edit.set_insertion s 1 ~extend:false;
    Jas.Text_edit.set_insertion s 4 ~extend:true;
    assert (Jas.Text_edit.copy_selection s = Some "ell"));

  run_test "copy with no selection returns None" (fun () ->
    assert (Jas.Text_edit.copy_selection (session "hello") = None));

  run_test "undo and redo" (fun () ->
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

  run_test "new edit clears redo" (fun () ->
    let s = session "" in
    Jas.Text_edit.insert s "a";
    Jas.Text_edit.undo s;
    Jas.Text_edit.insert s "b";
    Jas.Text_edit.redo s;
    assert (Jas.Text_edit.content s = "b"));

  run_test "set_insertion clamps" (fun () ->
    let s = session "hi" in
    Jas.Text_edit.set_insertion s 99 ~extend:false;
    assert (Jas.Text_edit.insertion s = 2));

  run_test "extend selection keeps anchor" (fun () ->
    let s = session "hello" in
    Jas.Text_edit.set_insertion s 2 ~extend:false;
    Jas.Text_edit.set_insertion s 4 ~extend:true;
    assert (Jas.Text_edit.anchor s = 2);
    assert (Jas.Text_edit.insertion s = 4);
    assert (Jas.Text_edit.selection_range s = (2, 4)));

  run_test "reverse selection orders" (fun () ->
    let s = session "hello" in
    Jas.Text_edit.set_insertion s 4 ~extend:false;
    Jas.Text_edit.set_insertion s 1 ~extend:true;
    assert (Jas.Text_edit.selection_range s = (1, 4)));

  run_test "select all then insert replaces" (fun () ->
    let s = session "hello" in
    Jas.Text_edit.select_all s;
    Jas.Text_edit.insert s "X";
    assert (Jas.Text_edit.content s = "X");
    assert (Jas.Text_edit.insertion s = 1));

  Printf.printf "All text_edit tests passed.\n"
