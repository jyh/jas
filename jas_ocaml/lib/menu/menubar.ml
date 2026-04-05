(** Menubar for the main window. *)

let group_selection (model : Model.model) () =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    let paths = Document.PathMap.fold (fun path _ acc -> path :: acc) sel [] in
    let sorted_paths = List.sort compare paths in
    if List.length sorted_paths < 2 then ()
    else begin
      (* Check all selected elements are siblings *)
      let parent p = match List.rev p with _ :: rest -> List.rev rest | [] -> [] in
      let first_parent = parent (List.hd sorted_paths) in
      if List.for_all (fun p -> parent p = first_parent) sorted_paths then begin
        let elements = List.map (fun p -> Document.get_element doc p) sorted_paths in
        model#snapshot;
        (* Delete in reverse order *)
        let rev_paths = List.sort (fun a b -> compare b a) sorted_paths in
        let new_doc = List.fold_left Document.delete_element doc rev_paths in
        (* Create group and insert at position of first element *)
        let group = Element.make_group (Array.of_list elements) in
        let insert_path = List.hd sorted_paths in
        let layer_idx = List.hd insert_path in
        let child_idx = match insert_path with _ :: i :: _ -> i | _ -> 0 in
        let layer = new_doc.Document.layers.(layer_idx) in
        let old_children = Document.children_of layer in
        let n = Array.length old_children in
        let new_children = Array.init (n + 1) (fun i ->
          if i < child_idx then old_children.(i)
          else if i = child_idx then group
          else old_children.(i - 1)
        ) in
        let new_layer = Document.with_children layer new_children in
        let new_layers = Array.copy new_doc.Document.layers in
        new_layers.(layer_idx) <- new_layer;
        let new_sel = Document.PathMap.singleton insert_path
          (Document.make_element_selection insert_path) in
        model#set_document { new_doc with
          Document.layers = new_layers;
          Document.selection = new_sel }
      end
    end
  end

let ungroup_selection (model : Model.model) () =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    (* Collect selected paths that are Groups *)
    let group_paths = Document.PathMap.fold (fun path _ acc ->
      try
        let elem = Document.get_element doc path in
        (match elem with Element.Group _ -> path :: acc | _ -> acc)
      with _ -> acc
    ) sel [] in
    let sorted_paths = List.sort compare group_paths in
    if sorted_paths = [] then ()
    else begin
      model#snapshot;
      (* Process in reverse order to preserve indices *)
      let new_doc = List.fold_left (fun doc gpath ->
        let group_elem = Document.get_element doc gpath in
        let children = Document.children_of group_elem in
        (* Delete the group *)
        let doc = Document.delete_element doc gpath in
        let layer_idx = List.hd gpath in
        let child_idx = match gpath with _ :: i :: _ -> i | _ -> 0 in
        let layer = doc.Document.layers.(layer_idx) in
        let old_children = Document.children_of layer in
        let n_old = Array.length old_children in
        let n_new = Array.length children in
        let new_children = Array.init (n_old + n_new) (fun i ->
          if i < child_idx then old_children.(i)
          else if i < child_idx + n_new then children.(i - child_idx)
          else old_children.(i - n_new)
        ) in
        let new_layer = Document.with_children layer new_children in
        let new_layers = Array.copy doc.Document.layers in
        new_layers.(layer_idx) <- new_layer;
        { doc with Document.layers = new_layers }
      ) doc (List.rev sorted_paths) in
      (* Build selection for unpacked children *)
      let new_sel = ref Document.PathMap.empty in
      let offset = ref 0 in
      List.iter (fun gpath ->
        let group_elem = Document.get_element doc gpath in
        let children = Document.children_of group_elem in
        let n_children = Array.length children in
        let layer_idx = List.hd gpath in
        let child_idx = (match gpath with _ :: i :: _ -> i | _ -> 0) + !offset in
        for j = 0 to n_children - 1 do
          let path = [layer_idx; child_idx + j] in
          let elem = Document.get_element new_doc path in
          let n = Element.control_point_count elem in
          new_sel := Document.PathMap.add path
            (Document.make_element_selection ~control_points:(List.init n Fun.id) path)
            !new_sel
        done;
        offset := !offset + n_children - 1
      ) sorted_paths;
      model#set_document { new_doc with Document.selection = !new_sel }
    end
  end

let copy_selection (model : Model.model) () =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    let elements = Document.PathMap.fold (fun path _ acc ->
      try Document.get_element doc path :: acc
      with _ -> acc
    ) sel [] in
    match elements with
    | [] -> ()
    | elems ->
      let temp_doc = Document.make_document
        [|Element.make_layer (Array.of_list (List.rev elems))|] in
      let svg = Svg.document_to_svg temp_doc in
      let clipboard = GtkBase.Clipboard.get Gdk.Atom.clipboard in
      GtkBase.Clipboard.set_text clipboard svg
  end

let cut_selection (model : Model.model) () =
  model#snapshot;
  copy_selection model ();
  model#set_document (Document.delete_selection model#document)

let rec translate_element elem dx dy =
  if dx = 0.0 && dy = 0.0 then elem
  else
    match elem with
    | Element.Group { children; opacity; transform } ->
      Element.Group { children = Array.map (fun c -> translate_element c dx dy) children;
                      opacity; transform }
    | Element.Layer { name; children; opacity; transform } ->
      Element.Layer { name; children = Array.map (fun c -> translate_element c dx dy) children;
                      opacity; transform }
    | _ ->
      let n = Element.control_point_count elem in
      let indices = List.init n Fun.id in
      Element.move_control_points elem indices dx dy

let is_svg text =
  let s = String.trim text in
  let starts_with prefix =
    String.length s >= String.length prefix &&
    String.sub s 0 (String.length prefix) = prefix
  in
  starts_with "<?xml" || starts_with "<svg"

let paste_clipboard (model : Model.model) offset () =
  model#snapshot;
  let clipboard = GtkBase.Clipboard.get Gdk.Atom.clipboard in
  GtkBase.Clipboard.request_text clipboard ~callback:(fun text_opt ->
    match text_opt with
    | None -> ()
    | Some text when String.length text = 0 -> ()
    | Some text ->
      let doc = model#document in
      let new_sel = ref Document.PathMap.empty in
      if is_svg text then begin
        let pasted_doc = Svg.svg_to_document text in
        let new_layers = Array.copy doc.Document.layers in
        Array.iter (fun pasted_layer ->
          let children = match pasted_layer with
            | Element.Layer { children; _ } ->
              Array.map (fun c -> translate_element c offset offset) children
            | _ -> [||]
          in
          if Array.length children = 0 then ()
          else begin
            let name = match pasted_layer with
              | Element.Layer { name; _ } -> name
              | _ -> ""
            in
            (* Find matching layer by name *)
            let target_idx = ref (-1) in
            if name <> "" then
              Array.iteri (fun i existing ->
                if !target_idx < 0 then
                  match existing with
                  | Element.Layer { name = n; _ } when n = name ->
                    target_idx := i
                  | _ -> ()
              ) new_layers;
            if !target_idx < 0 then
              target_idx := doc.Document.selected_layer;
            let idx = !target_idx in
            (* Record paths for pasted elements *)
            let base = match new_layers.(idx) with
              | Element.Layer { children = ec; _ } -> Array.length ec
              | _ -> 0
            in
            Array.iteri (fun j child ->
              let path = [idx; base + j] in
              let n = Element.control_point_count child in
              new_sel := Document.PathMap.add path
                (Document.make_element_selection ~control_points:(List.init n Fun.id) path)
                !new_sel
            ) children;
            match new_layers.(idx) with
            | Element.Layer { name = n; children = ec; opacity; transform } ->
              new_layers.(idx) <- Element.Layer { name = n; children = Array.append ec children; opacity; transform }
            | _ -> ()
          end
        ) pasted_doc.Document.layers;
        model#set_document { doc with layers = new_layers;
                                      selection = !new_sel }
      end else begin
        (* Plain text: create a Text element *)
        let elem = Element.make_text (offset) (offset +. 16.0) text in
        let idx = doc.Document.selected_layer in
        let base = match doc.Document.layers.(idx) with
          | Element.Layer { children; _ } -> Array.length children
          | _ -> 0
        in
        let path = [idx; base] in
        let n = Element.control_point_count elem in
        new_sel := Document.PathMap.add path
          (Document.make_element_selection ~control_points:(List.init n Fun.id) path)
          !new_sel;
        let new_layers = Array.mapi (fun i l ->
          if i = idx then
            match l with
            | Element.Layer layer ->
              Element.Layer { layer with children = Array.append layer.children [| elem |] }
            | _ -> l
          else l
        ) doc.Document.layers in
        model#set_document { doc with layers = new_layers;
                                      selection = !new_sel }
      end
  )

let open_file on_open (parent : GWindow.window) () =
  let dialog = GWindow.file_chooser_dialog
    ~action:`OPEN
    ~title:"Open"
    ~parent
    () in
  dialog#add_button_stock `CANCEL `CANCEL;
  dialog#add_button_stock `OPEN `ACCEPT;
  let filter = GFile.filter ~name:"SVG Files" ~patterns:["*.svg"] () in
  dialog#add_filter filter;
  dialog#set_filter filter;
  begin match dialog#run () with
  | `ACCEPT ->
    begin match dialog#filename with
    | Some path ->
      let max_file_size = 100 * 1024 * 1024 in
      let ic = open_in path in
      let n = in_channel_length ic in
      if n > max_file_size then begin
        close_in ic;
        dialog#destroy ();
        let _ = GWindow.message_dialog ~message:"File too large (over 100 MB)."
          ~message_type:`ERROR ~buttons:GWindow.Buttons.ok ~parent () in ()
      end else begin
        let svg = really_input_string ic n in
        close_in ic;
        let new_model = Model.create
          ~document:(Svg.svg_to_document svg) ~filename:path () in
        dialog#destroy ();
        on_open new_model
      end
    | None -> dialog#destroy ()
    end
  | _ -> dialog#destroy ()
  end

let save_as (model : Model.model) (parent : GWindow.window) () =
  let dialog = GWindow.file_chooser_dialog
    ~action:`SAVE
    ~title:"Save As"
    ~parent
    () in
  dialog#add_button_stock `CANCEL `CANCEL;
  dialog#add_button_stock `SAVE `ACCEPT;
  dialog#set_current_name (Filename.basename model#filename);
  let filter = GFile.filter ~name:"SVG Files" ~patterns:["*.svg"] () in
  dialog#add_filter filter;
  dialog#set_filter filter;
  dialog#set_do_overwrite_confirmation true;
  begin match dialog#run () with
  | `ACCEPT ->
    begin match dialog#filename with
    | Some path ->
      let svg = Svg.document_to_svg model#document in
      let oc = open_out path in
      output_string oc svg;
      close_out oc;
      model#mark_saved;
      model#set_filename path
    | None -> ()
    end
  | _ -> ()
  end;
  dialog#destroy ()

let is_untitled filename =
  String.length filename >= 9 && String.sub filename 0 9 = "Untitled-"

let save (model : Model.model) (parent : GWindow.window) () =
  if is_untitled model#filename then
    save_as model parent ()
  else begin
    let svg = Svg.document_to_svg model#document in
    let oc = open_out model#filename in
    output_string oc svg;
    close_out oc;
    model#mark_saved
  end

let revert (get_model : unit -> Model.model) (parent : GWindow.window) () =
  let model = get_model () in
  if not model#is_modified then ()
  else if is_untitled model#filename then ()
  else begin
    let dialog = GWindow.message_dialog
      ~message:(Printf.sprintf "Revert to the saved version of \"%s\"?\n\nAll current modifications will be lost." model#filename)
      ~message_type:`WARNING
      ~buttons:GWindow.Buttons.ok_cancel
      ~parent
      () in
    let response = dialog#run () in
    dialog#destroy ();
    match response with
    | `OK ->
      let max_file_size = 100 * 1024 * 1024 in
      let ic = open_in model#filename in
      let n = in_channel_length ic in
      if n > max_file_size then begin
        close_in ic;
        let _ = GWindow.message_dialog ~message:"File too large (over 100 MB)."
          ~message_type:`ERROR ~buttons:GWindow.Buttons.ok ~parent () in ()
      end else begin
        let svg = really_input_string ic n in
        close_in ic;
        model#snapshot;
        model#set_document (Svg.svg_to_document svg);
        model#mark_saved
      end
    | _ -> ()
  end

let create (get_model : unit -> Model.model) (parent : GWindow.window) ~on_open (vbox : GPack.box) =
  let m () = get_model () in
  (* Menubar *)
  let menubar = GMenu.menu_bar ~packing:(fun w -> vbox#pack w) () in
  let factory = new GMenu.factory menubar in

  (* File menu *)
  let _file_menu = factory#add_submenu "File" in
  let file_factory = new GMenu.factory _file_menu in
  ignore (file_factory#add_item "New" ~key:GdkKeysyms._n ~callback:(fun () -> on_open (Model.create ())));
  ignore (file_factory#add_item "Open..." ~key:GdkKeysyms._o ~callback:(open_file on_open parent));
  ignore (file_factory#add_item "Save" ~key:GdkKeysyms._s ~callback:(fun () -> save (m ()) parent ()));
  ignore (file_factory#add_item "Save As..." ~key:GdkKeysyms._s ~callback:(fun () -> save_as (m ()) parent ()));
  ignore (file_factory#add_item "Revert" ~callback:(revert m parent));
  ignore (file_factory#add_separator ());
  ignore (file_factory#add_item "Quit" ~key:GdkKeysyms._q ~callback:(fun () -> GMain.quit ()));

  (* Edit menu *)
  let _edit_menu = factory#add_submenu "Edit" in
  let edit_factory = new GMenu.factory _edit_menu in
  ignore (edit_factory#add_item "Undo" ~key:GdkKeysyms._z ~callback:(fun () -> (m ())#undo));
  ignore (edit_factory#add_item "Redo" ~key:GdkKeysyms._y ~callback:(fun () -> (m ())#redo));
  ignore (edit_factory#add_separator ());
  ignore (edit_factory#add_item "Cut" ~key:GdkKeysyms._x ~callback:(fun () -> cut_selection (m ()) ()));
  ignore (edit_factory#add_item "Copy" ~key:GdkKeysyms._c ~callback:(fun () -> copy_selection (m ()) ()));
  ignore (edit_factory#add_item "Paste" ~key:GdkKeysyms._v ~callback:(fun () -> paste_clipboard (m ()) Canvas_tool.paste_offset ()));
  ignore (edit_factory#add_item "Paste in Place" ~callback:(fun () -> paste_clipboard (m ()) 0.0 ()));
  ignore (edit_factory#add_separator ());
  ignore (edit_factory#add_item "Select All" ~key:GdkKeysyms._a ~callback:(fun () -> print_endline "Select All"));

  (* Object menu *)
  let _object_menu = factory#add_submenu "Object" in
  let object_factory = new GMenu.factory _object_menu in
  ignore (object_factory#add_item "Group" ~key:GdkKeysyms._g ~callback:(fun () -> group_selection (m ()) ()));
  ignore (object_factory#add_item "Ungroup" ~callback:(fun () -> ungroup_selection (m ()) ()));

  (* View menu *)
  let _view_menu = factory#add_submenu "View" in
  let view_factory = new GMenu.factory _view_menu in
  ignore (view_factory#add_item "Zoom In" ~key:GdkKeysyms._plus ~callback:(fun () -> print_endline "Zoom In"));
  ignore (view_factory#add_item "Zoom Out" ~key:GdkKeysyms._minus ~callback:(fun () -> print_endline "Zoom Out"));
  ignore (view_factory#add_item "Fit in Window" ~key:GdkKeysyms._0 ~callback:(fun () -> print_endline "Fit in Window"))
