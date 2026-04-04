(** Document controller (MVC pattern).

    The Controller provides mutation operations on the Model's document.
    Since Document is immutable, mutations produce a new Document that
    replaces the old one in the Model. *)

let bounds_intersect (ax, ay, aw, ah) (bx, by, bw, bh) =
  ax < bx +. bw && ax +. aw > bx && ay < by +. bh && ay +. ah > by

class controller ?(model = Model.create ()) () =
  object (_self)
    method model = model

    method document = model#document

    method set_document (d : Document.document) =
      model#set_document d

    method set_title (title : string) =
      model#set_document { model#document with Document.title }

    method add_layer (layer : Element.element) =
      model#set_document { model#document with Document.layers = model#document.Document.layers @ [layer] }

    method remove_layer (index : int) =
      let layers = List.filteri (fun i _ -> i <> index) model#document.Document.layers in
      model#set_document { model#document with Document.layers = layers }

    method add_element (elem : Element.element) =
      let doc = model#document in
      let idx = doc.Document.selected_layer in
      let new_layers = List.mapi (fun i l ->
        if i = idx then
          match l with
          | Element.Layer layer ->
            Element.Layer { layer with children = layer.children @ [elem] }
          | _ -> l
        else l
      ) doc.Document.layers in
      model#set_document { doc with Document.layers = new_layers }

    method select_rect x y w h =
      let doc = model#document in
      let sel_rect = (x, y, w, h) in
      let selection = ref Document.PathSet.empty in
      List.iteri (fun li layer ->
        match layer with
        | Element.Layer { children; _ } ->
          List.iteri (fun ci child ->
            match child with
            | Element.Group { children = gc; _ } ->
              let any_hit = List.exists (fun c ->
                bounds_intersect (Element.bounds c) sel_rect
              ) gc in
              if any_hit then
                List.iteri (fun gi _ ->
                  selection := Document.PathSet.add [li; ci; gi] !selection
                ) gc
            | _ ->
              if bounds_intersect (Element.bounds child) sel_rect then
                selection := Document.PathSet.add [li; ci] !selection
          ) children
        | _ -> ()
      ) doc.Document.layers;
      model#set_document { doc with Document.selection = !selection }

    method set_selection (selection : Document.selection) =
      model#set_document { model#document with Document.selection }

    method select_element (path : Document.element_path) =
      match path with
      | [] -> failwith "path must be non-empty"
      | _ ->
        let doc = model#document in
        let parent_path = List.filteri (fun i _ -> i < List.length path - 1) path in
        if List.length path >= 2 then
          let parent = Document.get_element doc parent_path in
          match parent with
          | Element.Group { children; _ } ->
            let selection = List.init (List.length children) (fun i -> parent_path @ [i]) in
            let selection = Document.PathSet.of_list selection in
            model#set_document { doc with Document.selection = selection }
          | _ ->
            model#set_document { doc with Document.selection = Document.PathSet.singleton path }
        else
          model#set_document { doc with Document.selection = Document.PathSet.singleton path }
  end

let create ?model () = new controller ?model ()
