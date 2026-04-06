(** Document controller (MVC pattern).

    The Controller provides mutation operations on the Model's document.
    Since Document is immutable, mutations produce a new Document that
    replaces the old one in the Model. *)

let point_in_rect = Hit_test.point_in_rect
let element_intersects_rect = Hit_test.element_intersects_rect
let all_cps = Hit_test.all_cps

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
      let new_layers = Array.mapi (fun i l ->
        if i = idx then
          match l with
          | Element.Layer layer ->
            Element.Layer { layer with children = Array.append layer.children [| elem |] }
          | _ -> l
        else l
      ) doc.Document.layers in
      model#set_document { doc with Document.layers = new_layers }

    method private toggle_selection current new_sel =
      (* Toggle at the control-point level.
         For elements in both sets, toggle individual CPs (symmetric difference).
         If no CPs remain, remove the element. *)
      let merged = Document.PathMap.merge (fun _path cur nw ->
        match cur, nw with
        | Some cur_es, Some new_es ->
          let cur_set = List.sort_uniq compare cur_es.Document.es_control_points in
          let new_set = List.sort_uniq compare new_es.Document.es_control_points in
          let toggled = List.filter (fun cp -> not (List.mem cp new_set)) cur_set
                      @ List.filter (fun cp -> not (List.mem cp cur_set)) new_set in
          if toggled = [] then None
          else Some { cur_es with Document.es_control_points = toggled }
        | None, Some v -> Some v
        | Some v, None -> Some v
        | None, None -> None
      ) current new_sel in
      merged

    method select_rect ?(extend=false) x y w h =
      let doc = model#document in
      let selection = ref Document.PathMap.empty in
      Array.iteri (fun li layer ->
        match layer with
        | Element.Layer { children; _ } ->
          Array.iteri (fun ci child ->
            if Element.is_locked child then ()
            else
            match child with
            | Element.Group { children = gc; _ } as grp ->
              let any_hit = Array.exists (fun c ->
                element_intersects_rect c x y w h
              ) gc in
              if any_hit then begin
                let grp_path = [li; ci] in
                selection := Document.PathMap.add grp_path
                  (Document.make_element_selection ~control_points:(all_cps grp) grp_path) !selection;
                Array.iteri (fun gi gc_elem ->
                  let path = [li; ci; gi] in
                  selection := Document.PathMap.add path
                    (Document.make_element_selection ~control_points:(all_cps gc_elem) path) !selection
                ) gc
              end
            | _ ->
              if element_intersects_rect child x y w h then
                let path = [li; ci] in
                selection := Document.PathMap.add path
                  (Document.make_element_selection ~control_points:(all_cps child) path) !selection
          ) children
        | _ -> ()
      ) doc.Document.layers;
      let new_sel = if extend then self#toggle_selection doc.Document.selection !selection else !selection in
      model#set_document { doc with Document.selection = new_sel }

    method group_select_rect ?(extend=false) x y w h =
      let doc = model#document in
      let selection = ref Document.PathMap.empty in
      let rec check path (elem : Element.element) =
        if Element.is_locked elem then ()
        else
        match elem with
        | Element.Layer { children; _ } | Element.Group { children; _ } ->
          Array.iteri (fun i child -> check (path @ [i]) child) children
        | _ ->
          if element_intersects_rect elem x y w h then
            selection := Document.PathMap.add path
              (Document.make_element_selection ~control_points:(all_cps elem) path) !selection
      in
      Array.iteri (fun li layer -> check [li] layer) doc.Document.layers;
      let new_sel = if extend then self#toggle_selection doc.Document.selection !selection else !selection in
      model#set_document { doc with Document.selection = new_sel }

    method direct_select_rect ?(extend=false) x y w h =
      let doc = model#document in
      let selection = ref Document.PathMap.empty in
      let rec check path (elem : Element.element) =
        if Element.is_locked elem then ()
        else
        match elem with
        | Element.Layer { children; _ } | Element.Group { children; _ } ->
          Array.iteri (fun i child -> check (path @ [i]) child) children
        | _ ->
          let cps = Element.control_points elem in
          let hit_cps =
            List.mapi (fun i (px, py) -> (i, px, py)) cps
            |> List.filter (fun (_i, px, py) -> point_in_rect px py x y w h)
            |> List.map (fun (i, _, _) -> i) in
          let hit = hit_cps <> [] || element_intersects_rect elem x y w h in
          if hit then
            selection := Document.PathMap.add path
              (Document.make_element_selection ~control_points:hit_cps path) !selection
      in
      Array.iteri (fun li layer -> check [li] layer) doc.Document.layers;
      let new_sel = if extend then self#toggle_selection doc.Document.selection !selection else !selection in
      model#set_document { doc with Document.selection = new_sel }

    method set_selection (selection : Document.selection) =
      model#set_document { model#document with Document.selection }

    method select_element (path : Document.element_path) =
      match path with
      | [] -> failwith "path must be non-empty"
      | _ ->
        let doc = model#document in
        let elem = Document.get_element doc path in
        if Element.is_locked elem then ()
        else
        let parent_path = List.filteri (fun i _ -> i < List.length path - 1) path in
        if List.length path >= 2 then
          let parent = Document.get_element doc parent_path in
          match parent with
          | Element.Group { children; _ } as grp ->
            let selection = Document.PathMap.singleton parent_path
              (Document.make_element_selection ~control_points:(all_cps grp) parent_path) in
            let selection = Array.fold_left (fun acc i ->
              let p = parent_path @ [i] in
              let elem = children.(i) in
              Document.PathMap.add p
                (Document.make_element_selection ~control_points:(all_cps elem) p) acc
            ) selection (Array.init (Array.length children) Fun.id) in
            model#set_document { doc with Document.selection = selection }
          | _ ->
            let elem = Document.get_element doc path in
            model#set_document { doc with Document.selection =
              Document.PathMap.singleton path
                (Document.make_element_selection ~control_points:(all_cps elem) path) }
        else
          let elem = Document.get_element doc path in
          model#set_document { doc with Document.selection =
            Document.PathMap.singleton path
              (Document.make_element_selection ~control_points:(all_cps elem) path) }

    method select_control_point (path : Document.element_path) (index : int) =
      match path with
      | [] -> failwith "path must be non-empty"
      | _ ->
        let es = Document.make_element_selection ~control_points:[index] path in
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
        let elem = Document.get_element new_doc path in
        let n = Element.control_point_count elem in
        Document.PathMap.add path
          (Document.make_element_selection ~control_points:(List.init n Fun.id) path) acc
      ) Document.PathMap.empty !locked_paths in
      model#set_document { new_doc with Document.selection = new_sel }

    method move_selection (dx : float) (dy : float) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path es acc ->
        let elem = Document.get_element acc path in
        let new_elem = Element.move_control_points elem es.Document.es_control_points dx dy in
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
        let copied = Element.move_control_points elem es.Document.es_control_points dx dy in
        let doc' = Document.insert_element_after acc_doc es.Document.es_path copied in
        let copy_path = match List.rev es.Document.es_path with
          | last :: rest -> List.rev ((last + 1) :: rest)
          | [] -> failwith "empty path"
        in
        let all_cps = List.init (Element.control_point_count copied) Fun.id in
        let copy_es = Document.make_element_selection
          ~control_points:all_cps copy_path in
        (doc', Document.PathMap.add copy_path copy_es acc_sel)
      ) (doc, Document.PathMap.empty) sorted_sels in
      model#set_document { new_doc with Document.selection = new_sel }
  end

let create ?model () = new controller ?model ()
