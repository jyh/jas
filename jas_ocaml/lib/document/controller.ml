(** Document controller (MVC pattern).

    The Controller provides mutation operations on the Model's document.
    Since Document is immutable, mutations produce a new Document that
    replaces the old one in the Model. *)

let point_in_rect = Hit_test.point_in_rect
let element_intersects_rect = Hit_test.element_intersects_rect
let element_intersects_polygon = Hit_test.element_intersects_polygon

(* Move helper: collapse a SelectionKind into the (is_all, indices)
   pair that [Element.move_control_points] consumes. *)
let move_kind elem (kind : Document.selection_kind) dx dy =
  let n = Element.control_point_count elem in
  match kind with
  | Document.SelKindAll ->
    Element.move_control_points ~is_all:true elem (List.init n Fun.id) dx dy
  | Document.SelKindPartial s ->
    let indices = Document.SortedCps.to_list s in
    Element.move_control_points elem indices dx dy

class controller ?(model = Model.create ()) () =
  object (self)
    method model = model

    method document = model#document

    method set_document (d : Document.document) =
      model#set_document d

    method set_filename (filename : string) =
      model#set_filename filename

    method add_layer (layer : Element.element) =
      model#set_document { model#document with Document.layers = Array.append model#document.Document.layers [|layer|] }

    method remove_layer (index : int) =
      let doc = model#document in
      let layers = Array.init (Array.length doc.Document.layers - 1) (fun i ->
        if i < index then doc.Document.layers.(i)
        else doc.Document.layers.(i + 1)) in
      model#set_document { doc with Document.layers = layers }

    method add_element (elem : Element.element) =
      let doc = model#document in
      let idx = doc.Document.selected_layer in
      let child_idx = match doc.Document.layers.(idx) with
        | Element.Layer layer -> Array.length layer.children
        | _ -> 0 in
      let new_layers = Array.mapi (fun i l ->
        if i = idx then
          match l with
          | Element.Layer layer ->
            Element.Layer { layer with children = Array.append layer.children [| elem |] }
          | _ -> l
        else l
      ) doc.Document.layers in
      let path = [idx; child_idx] in
      let es = Document.element_selection_all path in
      let sel = Document.PathMap.singleton path es in
      model#set_document { doc with Document.layers = new_layers;
                                    Document.selection = sel }

    method private toggle_selection current new_sel =
      (* XOR per element.
         - Two [SelKindAll]s cancel out — element-level deselect
           gesture (shift-click an already-fully-selected element).
         - Two [SelKindPartial]s XOR their CP sets. If the result is
           empty, the element stays selected as [SelKindPartial []]
           ("element selected, no CPs highlighted") rather than being
           dropped.
         - Mixed kinds collapse to [SelKindAll]. *)
      Document.PathMap.merge (fun _path cur nw ->
        match cur, nw with
        | Some cur_es, Some new_es ->
          (match cur_es.Document.es_kind, new_es.Document.es_kind with
           | Document.SelKindAll, Document.SelKindAll ->
             (* cancel out *)
             None
           | Document.SelKindPartial a, Document.SelKindPartial b ->
             (* Keep the element even when the XOR is empty. *)
             let xor = Document.SortedCps.symmetric_difference a b in
             Some { cur_es with Document.es_kind =
               Document.SelKindPartial xor }
           | _ ->
             (* mixed All/Partial -> keep All *)
             Some (Document.element_selection_all cur_es.Document.es_path))
        | None, Some v -> Some v
        | Some v, None -> Some v
        | None, None -> None
      ) current new_sel

    method private select_flat predicate extend =
      let doc = model#document in
      let selection = ref Document.PathMap.empty in
      Array.iteri (fun li layer ->
        match layer with
        | Element.Layer { children; visibility = layer_vis; _ } ->
          if layer_vis = Element.Invisible then ()
          else
          Array.iteri (fun ci child ->
            if Element.is_locked child then ()
            else
            let child_vis =
              let cv = Element.get_visibility child in
              if compare cv layer_vis < 0 then cv else layer_vis
            in
            if child_vis = Element.Invisible then ()
            else
            match child with
            | Element.Group { children = gc; _ } ->
              let any_hit = Array.exists (fun c -> predicate c) gc in
              if any_hit then begin
                let grp_path = [li; ci] in
                selection := Document.PathMap.add grp_path
                  (Document.element_selection_all grp_path) !selection;
                Array.iteri (fun gi _gc_elem ->
                  let path = [li; ci; gi] in
                  selection := Document.PathMap.add path
                    (Document.element_selection_all path) !selection
                ) gc
              end
            | _ ->
              if predicate child then
                let path = [li; ci] in
                selection := Document.PathMap.add path
                  (Document.element_selection_all path) !selection
          ) children
        | _ -> ()
      ) doc.Document.layers;
      let new_sel = if extend then self#toggle_selection doc.Document.selection !selection else !selection in
      model#set_document { doc with Document.selection = new_sel }

    method private select_recursive leaf_handler extend =
      let doc = model#document in
      let selection = ref Document.PathMap.empty in
      let rec check path (elem : Element.element) ancestor_vis =
        if Element.is_locked elem then ()
        else
        let effective =
          let v = Element.get_visibility elem in
          if compare v ancestor_vis < 0 then v else ancestor_vis
        in
        if effective = Element.Invisible then ()
        else
        match elem with
        | Element.Layer { children; _ } | Element.Group { children; _ } ->
          Array.iteri (fun i child -> check (path @ [i]) child effective) children
        | _ ->
          (match leaf_handler path elem with
           | Some es -> selection := Document.PathMap.add path es !selection
           | None -> ())
      in
      Array.iteri (fun li layer -> check [li] layer Element.Preview) doc.Document.layers;
      let new_sel = if extend then self#toggle_selection doc.Document.selection !selection else !selection in
      model#set_document { doc with Document.selection = new_sel }

    method select_all =
      self#select_flat (fun _ -> true) false

    method select_rect ?(extend=false) x y w h =
      self#select_flat (fun elem -> element_intersects_rect elem x y w h) extend

    method select_polygon ?(extend=false) (polygon : (float * float) array) =
      self#select_flat (fun elem -> element_intersects_polygon elem polygon) extend

    method interior_select_rect ?(extend=false) x y w h =
      self#select_recursive (fun path elem ->
        if element_intersects_rect elem x y w h then
          Some (Document.element_selection_all path)
        else
          None
      ) extend

    method partial_select_rect ?(extend=false) x y w h =
      self#select_recursive (fun path elem ->
        let cps = Element.control_points elem in
        let hit_cps =
          List.mapi (fun i (px, py) -> (i, px, py)) cps
          |> List.filter (fun (_i, px, py) -> point_in_rect px py x y w h)
          |> List.map (fun (i, _, _) -> i) in
        if hit_cps <> [] then
          Some (Document.element_selection_partial path hit_cps)
        else if element_intersects_rect elem x y w h then
          (* Marquee crosses the body but no CPs. Select the
             element with an empty CP set — the Partial Selection
             tool must not promote "body intersects" to "every CP
             selected" (which is what `element_selection_all` would
             mean). *)
          Some (Document.element_selection_partial path [])
        else
          None
      ) extend

    method set_selection (selection : Document.selection) =
      model#set_document { model#document with Document.selection }

    method select_element (path : Document.element_path) =
      match path with
      | [] -> ()
      | _ ->
        let doc = model#document in
        let elem = Document.get_element doc path in
        if Element.is_locked elem then ()
        else if Document.effective_visibility doc path = Element.Invisible then ()
        else
        let parent_path = List.filteri (fun i _ -> i < List.length path - 1) path in
        if List.length path >= 2 then
          let parent = Document.get_element doc parent_path in
          match parent with
          | Element.Group { children; _ } ->
            let selection = Document.PathMap.singleton parent_path
              (Document.element_selection_all parent_path) in
            let selection = Array.fold_left (fun acc i ->
              let p = parent_path @ [i] in
              Document.PathMap.add p
                (Document.element_selection_all p) acc
            ) selection (Array.init (Array.length children) Fun.id) in
            model#set_document { doc with Document.selection = selection }
          | _ ->
            model#set_document { doc with Document.selection =
              Document.PathMap.singleton path
                (Document.element_selection_all path) }
        else
          model#set_document { doc with Document.selection =
            Document.PathMap.singleton path
              (Document.element_selection_all path) }

    method select_control_point (path : Document.element_path) (index : int) =
      match path with
      | [] -> ()
      | _ ->
        let es = Document.element_selection_partial path [index] in
        model#set_document { model#document with Document.selection =
          Document.PathMap.singleton path es }

    method move_path_handle (path : int list) (anchor_idx : int)
        (handle_type : string) (dx : float) (dy : float) =
      let doc = model#document in
      let elem = Document.get_element doc path in
      (match elem with
       | Element.Path ({ d; _ } as r) ->
         let new_d = Element.move_path_handle d anchor_idx handle_type dx dy in
         let new_elem = Element.Path { r with d = new_d } in
         model#set_document (Document.replace_element doc path new_elem)
       | _ -> ())

    method lock_selection =
      let doc = model#document in
      if Document.PathMap.is_empty doc.Document.selection then ()
      else begin
        let rec lock elem =
          match elem with
          | Element.Group r ->
            Element.Group { r with children = Array.map lock r.children; locked = true }
          | _ -> Element.set_locked true elem
        in
        let new_doc = Document.PathMap.fold (fun path _ acc ->
          let elem = Document.get_element acc path in
          Document.replace_element acc path (lock elem)
        ) doc.Document.selection doc in
        model#set_document { new_doc with Document.selection = Document.PathMap.empty }
      end

    method unlock_all =
      let doc = model#document in
      let locked_paths = ref [] in
      let rec collect_locked path elem =
        match elem with
        | Element.Group { locked = true; children; _ } ->
          locked_paths := path :: !locked_paths;
          Array.iteri (fun i c -> collect_locked (path @ [i]) c) children
        | Element.Group { children; _ } | Element.Layer { children; _ } ->
          Array.iteri (fun i c -> collect_locked (path @ [i]) c) children
        | _ ->
          if Element.is_locked elem then
            locked_paths := path :: !locked_paths
      in
      Array.iteri (fun li layer ->
        match layer with
        | Element.Layer { children; _ } ->
          Array.iteri (fun ci child -> collect_locked [li; ci] child) children
        | _ -> ()
      ) doc.Document.layers;
      let rec unlock elem =
        match elem with
        | Element.Group r ->
          Element.Group { r with children = Array.map unlock r.children; locked = false }
        | Element.Layer r ->
          Element.Layer { r with children = Array.map unlock r.children; locked = false }
        | _ -> Element.set_locked false elem
      in
      let new_layers = Array.map (fun layer ->
        match layer with
        | Element.Layer r ->
          Element.Layer { r with children = Array.map unlock r.children }
        | _ -> layer
      ) doc.Document.layers in
      let new_doc = { doc with Document.layers = new_layers } in
      let new_sel = List.fold_left (fun acc path ->
        Document.PathMap.add path
          (Document.element_selection_all path) acc
      ) Document.PathMap.empty !locked_paths in
      model#set_document { new_doc with Document.selection = new_sel }

    method hide_selection =
      let doc = model#document in
      if Document.PathMap.is_empty doc.Document.selection then ()
      else begin
        let new_doc = Document.PathMap.fold (fun path _ acc ->
          let elem = Document.get_element acc path in
          let hidden = Element.set_visibility Element.Invisible elem in
          Document.replace_element acc path hidden
        ) doc.Document.selection doc in
        model#set_document
          { new_doc with Document.selection = Document.PathMap.empty }
      end

    method show_all =
      let doc = model#document in
      let shown_paths = ref [] in
      let rec show_in path elem =
        let elem =
          if Element.get_visibility elem = Element.Invisible then begin
            shown_paths := path :: !shown_paths;
            Element.set_visibility Element.Preview elem
          end else elem
        in
        match elem with
        | Element.Group r ->
          let new_children = Array.mapi (fun i c -> show_in (path @ [i]) c) r.children in
          Element.Group { r with children = new_children }
        | Element.Layer r ->
          let new_children = Array.mapi (fun i c -> show_in (path @ [i]) c) r.children in
          Element.Layer { r with children = new_children }
        | _ -> elem
      in
      let new_layers = Array.mapi (fun li layer -> show_in [li] layer) doc.Document.layers in
      let new_sel = List.fold_left (fun acc path ->
        Document.PathMap.add path
          (Document.element_selection_all path) acc
      ) Document.PathMap.empty !shown_paths in
      model#set_document { doc with Document.layers = new_layers;
                                     Document.selection = new_sel }

    method move_selection (dx : float) (dy : float) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path es acc ->
        let elem = Document.get_element acc path in
        let new_elem = move_kind elem es.Document.es_kind dx dy in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc in
      model#set_document new_doc

    method copy_selection (dx : float) (dy : float) =
      let doc = model#document in
      (* Sort paths in reverse so insertions don't shift earlier paths *)
      let sorted_sels = Document.PathMap.bindings doc.Document.selection
        |> List.sort (fun (a, _) (b, _) -> compare b a) in
      let (new_doc, new_sel) = List.fold_left (fun (acc_doc, acc_sel) (_path, es) ->
        let elem = Document.get_element acc_doc es.Document.es_path in
        let copied = move_kind elem es.Document.es_kind dx dy in
        let doc' = Document.insert_element_after acc_doc es.Document.es_path copied in
        let copy_path = match List.rev es.Document.es_path with
          | last :: rest -> List.rev ((last + 1) :: rest)
          (* Precondition: selection paths are always non-empty (set by select_element/select_control_point). *)
          | [] -> failwith "empty path"
        in
        (* Copying always selects the new element as a whole. *)
        let copy_es = Document.element_selection_all copy_path in
        (doc', Document.PathMap.add copy_path copy_es acc_sel)
      ) (doc, Document.PathMap.empty) sorted_sels in
      model#set_document { new_doc with Document.selection = new_sel }

    method set_selection_fill (f : Element.fill option) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        let new_elem = Element.with_fill elem f in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc in
      model#set_document new_doc

    method set_selection_stroke (s : Element.stroke option) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        let new_elem = Element.with_stroke elem s in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc in
      model#set_document new_doc

    method set_selection_width_profile (wp : Element.stroke_width_point list) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        let new_elem = Element.with_width_points elem wp in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc in
      model#set_document new_doc
  end

(* ------------------------------------------------------------------ *)
(* Fill/stroke summary                                                 *)
(* ------------------------------------------------------------------ *)

type fill_summary = FillNoSelection | FillUniform of Element.fill option | FillMixed
type stroke_summary = StrokeNoSelection | StrokeUniform of Element.stroke option | StrokeMixed

let element_fill = function
  | Element.Rect { fill; _ } | Element.Circle { fill; _ }
  | Element.Ellipse { fill; _ } | Element.Polyline { fill; _ }
  | Element.Polygon { fill; _ } | Element.Path { fill; _ }
  | Element.Text { fill; _ } | Element.Text_path { fill; _ } -> Some fill
  | Element.Live (Element.Compound_shape cs) -> Some cs.fill
  | Element.Line _ | Element.Group _ | Element.Layer _ -> None

let element_stroke = function
  | Element.Line { stroke; _ } | Element.Rect { stroke; _ }
  | Element.Circle { stroke; _ } | Element.Ellipse { stroke; _ }
  | Element.Polyline { stroke; _ } | Element.Polygon { stroke; _ }
  | Element.Path { stroke; _ } | Element.Text { stroke; _ }
  | Element.Text_path { stroke; _ } -> Some stroke
  | Element.Live (Element.Compound_shape cs) -> Some cs.stroke
  | Element.Group _ | Element.Layer _ -> None

let selection_fill_summary (doc : Document.document) =
  if Document.PathMap.is_empty doc.Document.selection then FillNoSelection
  else
    let first = ref true in
    let uniform = ref None in
    let mixed = ref false in
    Document.PathMap.iter (fun path _ ->
      if not !mixed then
        let elem = Document.get_element doc path in
        match element_fill elem with
        | None -> ()
        | Some f ->
          if !first then begin
            first := false;
            uniform := Some f
          end else if !uniform <> Some f then
            mixed := true
    ) doc.Document.selection;
    if !first then FillNoSelection
    else if !mixed then FillMixed
    else FillUniform (match !uniform with Some f -> f | None -> None)

let selection_stroke_summary (doc : Document.document) =
  if Document.PathMap.is_empty doc.Document.selection then StrokeNoSelection
  else
    let first = ref true in
    let uniform = ref None in
    let mixed = ref false in
    Document.PathMap.iter (fun path _ ->
      if not !mixed then
        let elem = Document.get_element doc path in
        match element_stroke elem with
        | None -> ()
        | Some s ->
          if !first then begin
            first := false;
            uniform := Some s
          end else if !uniform <> Some s then
            mixed := true
    ) doc.Document.selection;
    if !first then StrokeNoSelection
    else if !mixed then StrokeMixed
    else StrokeUniform (match !uniform with Some s -> s | None -> None)

let create ?model () = new controller ?model ()
