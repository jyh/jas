(** Boolean panel apply pipeline.

    Port of the Rust / Swift / Python Controller.make_compound_shape /
    release_compound_shape / expand_compound_shape. Invoked from the
    Boolean panel's hamburger-menu dispatch.

    See [transcripts/BOOLEAN.md] § Compound shape data model. *)

open Element

(** Replace a layer's children with [new_children], returning a new
    document. *)
let replace_layer_children (doc : Document.document) (layer_idx : int)
    (new_children : element array) : Document.document =
  let layer = doc.Document.layers.(layer_idx) in
  let new_layer = Document.with_children layer new_children in
  let new_layers = Array.copy doc.Document.layers in
  new_layers.(layer_idx) <- new_layer;
  { doc with Document.layers = new_layers }

(** Insert a single element at position [child_idx] in layer
    [layer_idx]. *)
let insert_at_layer (doc : Document.document) (layer_idx : int)
    (child_idx : int) (elem : element) : Document.document =
  let layer = doc.Document.layers.(layer_idx) in
  let old_children = Document.children_of layer in
  let n = Array.length old_children in
  let new_children = Array.init (n + 1) (fun i ->
    if i < child_idx then old_children.(i)
    else if i = child_idx then elem
    else old_children.(i - 1))
  in
  replace_layer_children doc layer_idx new_children

(** Insert a sequence of elements starting at position [child_idx]
    in layer [layer_idx]. *)
let insert_many_at_layer (doc : Document.document) (layer_idx : int)
    (child_idx : int) (elems : element array) : Document.document =
  let layer = doc.Document.layers.(layer_idx) in
  let old_children = Document.children_of layer in
  let n_old = Array.length old_children in
  let n_new = Array.length elems in
  let new_children = Array.init (n_old + n_new) (fun i ->
    if i < child_idx then old_children.(i)
    else if i < child_idx + n_new then elems.(i - child_idx)
    else old_children.(i - n_new))
  in
  replace_layer_children doc layer_idx new_children

(* ── Make Compound Shape ─────────────────────────────────────── *)

let apply_make_compound_shape (model : Model.model) : unit =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    let paths =
      Document.PathMap.fold (fun p _ acc -> p :: acc) sel []
      |> List.sort compare
    in
    if List.length paths < 2 then ()
    else begin
      let parent p = match List.rev p with _ :: rest -> List.rev rest | [] -> [] in
      let first_parent = parent (List.hd paths) in
      if not (List.for_all (fun p -> parent p = first_parent) paths) then ()
      else begin
        let elements = List.map (fun p -> Document.get_element doc p) paths in
        let operands = Array.of_list elements in
        let frontmost = List.nth elements (List.length elements - 1) in
        (* Inherit paint from the frontmost operand. *)
        let fill = match frontmost with
          | Rect r -> r.fill | Circle r -> r.fill | Ellipse r -> r.fill
          | Polyline r -> r.fill | Polygon r -> r.fill | Path r -> r.fill
          | Text r -> r.fill | Text_path r -> r.fill
          | Live (Compound_shape cs) -> cs.fill
          | _ -> None
        in
        let stroke = match frontmost with
          | Line r -> r.stroke | Rect r -> r.stroke | Circle r -> r.stroke
          | Ellipse r -> r.stroke | Polyline r -> r.stroke | Polygon r -> r.stroke
          | Path r -> r.stroke | Text r -> r.stroke | Text_path r -> r.stroke
          | Live (Compound_shape cs) -> cs.stroke
          | _ -> None
        in
        let cs = {
          operation = Op_union;
          operands;
          fill;
          stroke;
          opacity = 1.0;
          transform = Element.transform_of frontmost;
          locked = false;
          visibility = Element.get_visibility frontmost;
        } in
        let compound = Live (Compound_shape cs) in
        model#snapshot;
        (* Delete selected elements in reverse order. *)
        let rev_paths = List.sort (fun a b -> compare b a) paths in
        let new_doc = List.fold_left Document.delete_element doc rev_paths in
        let insert_path = List.hd paths in
        let layer_idx = List.hd insert_path in
        let child_idx = match insert_path with _ :: i :: _ -> i | _ -> 0 in
        let new_doc = insert_at_layer new_doc layer_idx child_idx compound in
        let new_sel = Document.PathMap.singleton insert_path
          (Document.make_element_selection insert_path) in
        model#set_document { new_doc with Document.selection = new_sel }
      end
    end
  end

(* ── Release Compound Shape ──────────────────────────────────── *)

let apply_release_compound_shape (model : Model.model) : unit =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    let cs_paths =
      Document.PathMap.fold (fun p _ acc ->
        try
          let elem = Document.get_element doc p in
          match elem with
          | Live _ -> p :: acc
          | _ -> acc
        with _ -> acc
      ) sel []
      |> List.sort compare
    in
    if cs_paths = [] then ()
    else begin
      model#snapshot;
      (* Process in reverse to preserve indices. *)
      let new_doc = List.fold_left (fun doc cs_path ->
        let elem = Document.get_element doc cs_path in
        match elem with
        | Live (Compound_shape cs) ->
          let operands = cs.operands in
          let doc = Document.delete_element doc cs_path in
          let layer_idx = List.hd cs_path in
          let child_idx = match cs_path with _ :: i :: _ -> i | _ -> 0 in
          insert_many_at_layer doc layer_idx child_idx operands
        | _ -> doc
      ) doc (List.rev cs_paths) in
      (* Build selection of released operands (forward pass). *)
      let new_sel = ref Document.PathMap.empty in
      let offset = ref 0 in
      List.iter (fun cs_path ->
        let elem = Document.get_element doc cs_path in
        match elem with
        | Live (Compound_shape cs) ->
          let n = Array.length cs.operands in
          let layer_idx = List.hd cs_path in
          let child_idx = (match cs_path with _ :: i :: _ -> i | _ -> 0) + !offset in
          for j = 0 to n - 1 do
            let path = [layer_idx; child_idx + j] in
            let e = Document.get_element new_doc path in
            let k = Element.control_point_count e in
            new_sel := Document.PathMap.add path
              (Document.make_element_selection ~control_points:(List.init k Fun.id) path)
              !new_sel
          done;
          offset := !offset + n - 1
        | _ -> ()
      ) cs_paths;
      model#set_document { new_doc with Document.selection = !new_sel }
    end
  end

(* ── Expand Compound Shape ───────────────────────────────────── *)

let apply_expand_compound_shape (model : Model.model) : unit =
  let doc = model#document in
  let sel = doc.Document.selection in
  if Document.PathMap.is_empty sel then ()
  else begin
    let cs_paths =
      Document.PathMap.fold (fun p _ acc ->
        try
          let elem = Document.get_element doc p in
          match elem with
          | Live _ -> p :: acc
          | _ -> acc
        with _ -> acc
      ) sel []
      |> List.sort compare
    in
    if cs_paths = [] then ()
    else begin
      model#snapshot;
      let expanded_counts = ref [] in
      let new_doc = List.fold_left (fun doc cs_path ->
        let elem = Document.get_element doc cs_path in
        match elem with
        | Live (Compound_shape cs) ->
          let expanded = Live.expand cs Live.default_precision in
          expanded_counts := List.length expanded :: !expanded_counts;
          let doc = Document.delete_element doc cs_path in
          let layer_idx = List.hd cs_path in
          let child_idx = match cs_path with _ :: i :: _ -> i | _ -> 0 in
          insert_many_at_layer doc layer_idx child_idx (Array.of_list expanded)
        | _ ->
          expanded_counts := 0 :: !expanded_counts;
          doc
      ) doc (List.rev cs_paths) in
      (* Reversed iteration pushed counts in reverse; flip back. *)
      let counts = List.rev !expanded_counts in
      (* Build selection of expanded polygons (forward pass). *)
      let new_sel = ref Document.PathMap.empty in
      let offset = ref 0 in
      List.iter2 (fun cs_path n ->
        let layer_idx = List.hd cs_path in
        let child_idx = (match cs_path with _ :: i :: _ -> i | _ -> 0) + !offset in
        for j = 0 to n - 1 do
          let path = [layer_idx; child_idx + j] in
          try
            let e = Document.get_element new_doc path in
            let k = Element.control_point_count e in
            new_sel := Document.PathMap.add path
              (Document.make_element_selection ~control_points:(List.init k Fun.id) path)
              !new_sel
          with _ -> ()
        done;
        offset := !offset + n - 1
      ) cs_paths counts;
      model#set_document { new_doc with Document.selection = !new_sel }
    end
  end
