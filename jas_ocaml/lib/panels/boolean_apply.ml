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

let apply_make_compound_shape_with_op (model : Model.model)
    (operation : compound_operation) : unit =
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
          operation;
          operands;
          fill;
          stroke;
          opacity = 1.0;
          transform = Element.transform_of frontmost;
          locked = false;
          visibility = Element.get_visibility frontmost;
          blend_mode = Element.Normal;
          mask = None;
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

let apply_make_compound_shape (model : Model.model) : unit =
  apply_make_compound_shape_with_op model Op_union

let apply_compound_creation (model : Model.model) (op_name : string) : unit =
  let operation = match op_name with
    | "union" -> Some Op_union
    | "subtract_front" -> Some Op_subtract_front
    | "intersection" -> Some Op_intersection
    | "exclude" -> Some Op_exclude
    | _ -> None
  in
  match operation with
  | None -> ()
  | Some op -> apply_make_compound_shape_with_op model op

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

(* ── Boolean options ─────────────────────────────────────────── *)

type boolean_options = {
  precision : float;
  remove_redundant_points : bool;
  divide_remove_unpainted : bool;
}

let default_boolean_options = {
  precision = Live.default_precision;
  remove_redundant_points = true;
  divide_remove_unpainted = false;
}

(** Single-pass removal of collinear / near-duplicate points within
    [tol]. Returns the original ring if collapse would leave fewer
    than 3 points. *)
let collapse_collinear_points ring tol =
  let n = Array.length ring in
  if n < 3 then ring
  else begin
    let keep = Array.make n true in
    for i = 0 to n - 1 do
      let (px, py) = ring.((i - 1 + n) mod n) in
      let (cx, cy) = ring.(i) in
      let (nx, ny) = ring.((i + 1) mod n) in
      let dx = nx -. px in
      let dy = ny -. py in
      let seg_len = sqrt (dx *. dx +. dy *. dy) in
      if seg_len = 0.0 then keep.(i) <- false
      else begin
        let num = abs_float (dy *. cx -. dx *. cy +. nx *. py -. ny *. px) in
        if num /. seg_len < tol then keep.(i) <- false
      end
    done;
    let buf = Array.to_list ring |> List.mapi (fun i p -> (i, p))
              |> List.filter (fun (i, _) -> keep.(i))
              |> List.map snd in
    if List.length buf < 3 then ring
    else Array.of_list buf
  end

(* ── Destructive boolean operations ──────────────────────────── *)

(** Return (fill, stroke, opacity, transform, locked, visibility) for
    an element. Used when emitting output polygons so each survivor
    keeps its own paint, or so the single combined result of UNION /
    INTERSECTION / EXCLUDE carries the frontmost operand's paint. *)
let paint_of (elem : element) =
  let fill = match elem with
    | Rect r -> r.fill | Circle r -> r.fill | Ellipse r -> r.fill
    | Polyline r -> r.fill | Polygon r -> r.fill | Path r -> r.fill
    | Text r -> r.fill | Text_path r -> r.fill
    | Live (Compound_shape cs) -> cs.fill
    | _ -> None
  in
  let stroke = match elem with
    | Line r -> r.stroke | Rect r -> r.stroke | Circle r -> r.stroke
    | Ellipse r -> r.stroke | Polyline r -> r.stroke | Polygon r -> r.stroke
    | Path r -> r.stroke | Text r -> r.stroke | Text_path r -> r.stroke
    | Live (Compound_shape cs) -> cs.stroke
    | _ -> None
  in
  let transform = Element.transform_of elem in
  let visibility = Element.get_visibility elem in
  (fill, stroke, 1.0, transform, false, visibility)

let polygon_from_ring ring (fill, stroke, opacity, transform, locked, visibility) =
  let points = Array.to_list ring in
  Polygon { points; fill; stroke; opacity; transform; locked; visibility; blend_mode = Element.Normal; mask = None; fill_gradient = None; stroke_gradient = None }

(* Return (outputs) as a list of (polygon_set, paint) pairs for the
   given op. Returns None for unknown ops. *)
let compute_destructive_outputs op_name elements precision =
  let module B = Boolean in
  let to_set e = Live.element_to_polygon_set e precision in
  let n = List.length elements in
  match op_name with
  | "union" ->
    let sets = List.map to_set elements in
    let frontmost = List.nth elements (n - 1) in
    let result = List.fold_left B.boolean_union
      (List.hd sets) (List.tl sets) in
    Some [result, paint_of frontmost]
  | "intersection" ->
    let sets = List.map to_set elements in
    let frontmost = List.nth elements (n - 1) in
    let result = List.fold_left B.boolean_intersect
      (List.hd sets) (List.tl sets) in
    Some [result, paint_of frontmost]
  | "exclude" ->
    let sets = List.map to_set elements in
    let frontmost = List.nth elements (n - 1) in
    let result = List.fold_left B.boolean_exclude
      (List.hd sets) (List.tl sets) in
    Some [result, paint_of frontmost]
  | "subtract_front" | "crop" ->
    let frontmost = List.nth elements (n - 1) in
    let cutter = to_set frontmost in
    let survivors =
      List.filteri (fun i _ -> i < n - 1) elements
    in
    let outputs = List.map (fun s ->
      let s_set = to_set s in
      let res =
        if op_name = "crop" then B.boolean_intersect s_set cutter
        else B.boolean_subtract s_set cutter
      in
      (res, paint_of s)
    ) survivors in
    Some outputs
  | "subtract_back" ->
    let backmost = List.hd elements in
    let cutter = to_set backmost in
    let survivors =
      List.filteri (fun i _ -> i > 0) elements
    in
    let outputs = List.map (fun s ->
      let s_set = to_set s in
      let res = B.boolean_subtract s_set cutter in
      (res, paint_of s)
    ) survivors in
    Some outputs
  | "divide" ->
    (* Walk operands back-to-front, maintaining a partition of the
       union-so-far as (region, frontmost-covering-operand-index)
       pairs. Each incoming operand splits every existing region
       into overlap / non-overlap; overlap relabels to the incoming
       index (now frontmost). *)
    let operand_sets = Array.of_list (List.map to_set elements) in
    let elements_arr = Array.of_list elements in
    let accumulator = ref [] in
    for i = 0 to n - 1 do
      let op_set = operand_sets.(i) in
      let new_acc = ref [] in
      let remaining = ref op_set in
      List.iter (fun (existing_region, existing_idx) ->
        let overlap = B.boolean_intersect existing_region op_set in
        if overlap <> [] then
          new_acc := (overlap, i) :: !new_acc;
        let non_overlap = B.boolean_subtract existing_region op_set in
        if non_overlap <> [] then
          new_acc := (non_overlap, existing_idx) :: !new_acc;
        remaining := B.boolean_subtract !remaining existing_region
      ) !accumulator;
      if !remaining <> [] then
        new_acc := (!remaining, i) :: !new_acc;
      accumulator := List.rev !new_acc
    done;
    Some (List.map (fun (region, paint_idx) ->
      (region, paint_of elements_arr.(paint_idx))
    ) !accumulator)
  | "trim" | "merge" ->
    let operand_sets = Array.of_list (List.map to_set elements) in
    let elements_arr = Array.of_list elements in
    (* For each operand i, subtract the union of all later operands. *)
    let trimmed = ref [] in
    for i = 0 to n - 1 do
      let region = ref operand_sets.(i) in
      for j = i + 1 to n - 1 do
        region := B.boolean_subtract !region operand_sets.(j)
      done;
      if !region <> [] then
        trimmed := (!region, elements_arr.(i)) :: !trimmed
    done;
    let trimmed = List.rev !trimmed in
    if op_name = "trim" then
      Some (List.map (fun (r, e) -> (r, paint_of e)) trimmed)
    else begin
      (* MERGE: unify touching same-fill survivors. *)
      let arr = Array.of_list trimmed in
      let len = Array.length arr in
      let consumed = Array.make len false in
      let outputs = ref [] in
      for i = 0 to len - 1 do
        if not consumed.(i) then begin
          consumed.(i) <- true;
          let (region_i, elem_i) = arr.(i) in
          let (fill_i, _, _, _, _, _) = paint_of elem_i in
          let merged = ref region_i in
          let paint_src = ref elem_i in
          (match fill_i with
           | None -> ()
           | Some fa ->
             for j = i + 1 to len - 1 do
               if not consumed.(j) then begin
                 let (region_j, elem_j) = arr.(j) in
                 let (fill_j, _, _, _, _, _) = paint_of elem_j in
                 match fill_j with
                 | Some fb when fa.fill_color = fb.fill_color ->
                   merged := B.boolean_union !merged region_j;
                   (* j > i in z-order; j wins stroke/common on merged
                      output. Its fill equals i's by predicate. *)
                   paint_src := elem_j;
                   consumed.(j) <- true
                 | _ -> ()
               end
             done);
          let (_, stroke_w, opacity_w, transform_w, locked_w, vis_w) =
            paint_of !paint_src in
          outputs := (!merged, (fill_i, stroke_w, opacity_w,
                                transform_w, locked_w, vis_w)) :: !outputs
        end
      done;
      Some (List.rev !outputs)
    end
  | _ -> None

let apply_destructive_boolean ?(options = default_boolean_options)
    (model : Model.model) (op_name : string) : unit =
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
        match compute_destructive_outputs op_name elements options.precision with
        | None -> ()
        | Some outputs ->
          (* Flatten to Polygon elements; drop rings with < 3 pts.
             Apply BooleanOptions: divide_remove_unpainted drops
             unpainted DIVIDE fragments; remove_redundant_points
             collapses near-collinear vertices. *)
          let new_elements = List.concat_map (fun (ps, paint) ->
            let (fill, stroke, _, _, _, _) = paint in
            if op_name = "divide" && options.divide_remove_unpainted
               && fill = None && stroke = None then []
            else
              List.filter_map (fun ring ->
                let r = if options.remove_redundant_points
                  then collapse_collinear_points ring options.precision
                  else ring
                in
                if Array.length r < 3 then None
                else Some (polygon_from_ring r paint)
              ) ps
          ) outputs in
          model#snapshot;
          let rev_paths = List.sort (fun a b -> compare b a) paths in
          let new_doc = List.fold_left Document.delete_element doc rev_paths in
          let insert_path = List.hd paths in
          let layer_idx = List.hd insert_path in
          let child_idx = match insert_path with _ :: i :: _ -> i | _ -> 0 in
          let new_doc = insert_many_at_layer new_doc layer_idx child_idx
            (Array.of_list new_elements) in
          (* Build selection of the inserted polygons. *)
          let new_sel = ref Document.PathMap.empty in
          List.iteri (fun j _ ->
            let path = [layer_idx; child_idx + j] in
            try
              let e = Document.get_element new_doc path in
              let k = Element.control_point_count e in
              new_sel := Document.PathMap.add path
                (Document.make_element_selection ~control_points:(List.init k Fun.id) path)
                !new_sel
            with _ -> ()
          ) new_elements;
          model#set_document { new_doc with Document.selection = !new_sel }
      end
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

(* ── Repeat + Reset ──────────────────────────────────────────── *)

let compound_suffix = "_compound"

let apply_repeat_boolean_operation ?(options = default_boolean_options)
    (model : Model.model) (last_op : string option) : unit =
  match last_op with
  | None | Some "" -> ()
  | Some op ->
    let suffix_len = String.length compound_suffix in
    let op_len = String.length op in
    if op_len > suffix_len
       && String.sub op (op_len - suffix_len) suffix_len = compound_suffix
    then
      let base = String.sub op 0 (op_len - suffix_len) in
      apply_compound_creation model base
    else
      apply_destructive_boolean ~options model op
