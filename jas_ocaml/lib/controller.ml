(** Document controller (MVC pattern).

    The Controller provides mutation operations on the Model's document.
    Since Document is immutable, mutations produce a new Document that
    replaces the old one in the Model. *)

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
  end

let create ?model () = new controller ?model ()
