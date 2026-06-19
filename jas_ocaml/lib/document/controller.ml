(** Document controller (MVC pattern).

    The Controller provides mutation operations on the Model's document.
    Since Document is immutable, mutations produce a new Document that
    replaces the old one in the Model. *)

let point_in_rect = Hit_test.point_in_rect
let element_intersects_rect = Hit_test.element_intersects_rect
let element_intersects_polygon = Hit_test.element_intersects_polygon

(** Resolve the current selection to the stable [common.id]s of the selected
    elements, in document order (OP_LOG.md section 9 / Fork 4: the [targets] of
    a journaled op). Id-less selected elements are silently dropped ([id] is
    optional; a recorded source must carry an id — a documented prerequisite,
    not a bug). The selection is a [PathMap], whose [bindings] are sorted by
    path (document order), so the order is deterministic and cross-language
    stable. One definition reused by the production [op_apply] path and the
    cross-language harness so both populate [targets] identically. Mirrors Rust
    [controller::selection_to_ids] and Swift [selectionToIds]. *)
let selection_to_ids (doc : Document.document) : string list =
  Document.PathMap.bindings doc.Document.selection
  |> List.filter_map (fun (_path, (es : Document.element_selection)) ->
       match Document.get_element doc es.Document.es_path with
       | exception _ -> None
       | elem -> Element.id_of elem)

(* ── Opacity-mask helpers (OPACITY.md §States) ───────────── *)

(** Return the [mask] on the first selected element, if any. *)
let first_mask (doc : Document.document) : Element.mask option =
  match Document.PathMap.min_binding_opt doc.Document.selection with
  | None -> None
  | Some (path, _) ->
    try
      let elem = Document.get_element doc path in
      Element.get_mask elem
    with _ -> None

(** True when every selected element has a mask attached. Mixed
    selections (some masked, some not) count as "no mask" per
    OPACITY.md §States. *)
let selection_has_mask (doc : Document.document) : bool =
  if Document.PathMap.is_empty doc.Document.selection then false
  else
    Document.PathMap.for_all (fun path _ ->
      try
        let elem = Document.get_element doc path in
        match Element.get_mask elem with
        | Some _ -> true
        | None -> false
      with _ -> false
    ) doc.Document.selection

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

(** Find the first id-bearing element named [id], searching [doc.symbols]
    (sorted-by-id for determinism, matching every order-dependent symbols
    site) then [doc.layers] in pre-order. A pure lookup — no entropy — used by
    [detach] to resolve an instance target across both the off-canvas master
    store and the canvas tree (SYMBOLS.md section 7). Returns an owned copy so
    callers can mutate it independently. *)
let find_element_by_id (doc : Document.document) (id : string) :
    Element.element option =
  let rec walk elem =
    if Element.id_of elem = Some id then Some elem
    else
      (* Recurse into container children only (Group / Layer), mirroring the
         Rust [Element::children] which is [None] for every leaf kind. *)
      match elem with
      | Element.Group { children; _ } | Element.Layer { children; _ } ->
        let n = Array.length children in
        let rec loop i =
          if i >= n then None
          else match walk children.(i) with
            | Some _ as found -> found
            | None -> loop (i + 1)
        in
        loop 0
      | _ -> None
  in
  (* Symbols first, in sorted-by-id order (the section 2 deterministic-order
     rule). *)
  let sorted_masters = Array.copy doc.Document.symbols in
  Array.sort (fun a b ->
    let key e = match Element.id_of e with Some s -> s | None -> "" in
    String.compare (key a) (key b)) sorted_masters;
  let from_masters =
    Array.fold_left (fun acc master ->
      match acc with Some _ -> acc | None -> walk master)
      None sorted_masters
  in
  match from_masters with
  | Some _ as found -> found
  | None ->
    Array.fold_left (fun acc layer ->
      match acc with Some _ -> acc | None -> walk layer)
      None doc.Document.layers

class controller ?(model = Model.create ()) () =
  object (self)
    method model = model

    method document = model#document

    (* The general undoable mutator used by tool / effect handlers: they wrap an
       action in begin_txn / with_txn, so this JOINS that transaction; standalone
       it self-brackets (one undo step). Routes through [edit_document] (OP_LOG.md
       Increment 1, mirroring the Rust / Python Controller.set_document).
       Selection-only writes use the [select_*] / [set_selection] methods
       (non-undoable). *)
    method set_document (d : Document.document) =
      model#edit_document d

    method set_filename (filename : string) =
      model#set_filename filename

    method add_layer (layer : Element.element) =
      model#edit_document { model#document with Document.layers = Array.append model#document.Document.layers [|layer|] }

    method remove_layer (index : int) =
      let doc = model#document in
      let layers = Array.init (Array.length doc.Document.layers - 1) (fun i ->
        if i < index then doc.Document.layers.(i)
        else doc.Document.layers.(i + 1)) in
      model#edit_document { doc with Document.layers = layers }

    method add_element (elem : Element.element) =
      (* OPACITY.md \167Preview interactions: in mask-editing mode,
         route the new element into the masked element's mask
         subtree instead of the selected layer. On any "can't route
         here" failure, fall through to the content path so the
         user's stroke isn't lost. *)
      (match model#editing_target with
       | Model.Mask path when self#try_add_to_mask elem path -> ()
       | _ ->
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
         model#edit_document { doc with Document.layers = new_layers;
                                       Document.selection = sel })

    (** Stamp a stable [id] onto the element at [path] — the lazy
        assign-on-create primitive (REFERENCE_GRAPH.md \1674). The id is
        minted by the initiator and carried in the operation payload,
        never minted here, so every app applies the identical value. A
        no-op when the path is invalid. The caller owns identity: this
        overwrites any existing id (re-identification is the initiator
        responsibility; reference remapping arrives with the graph). *)
    method assign_id (path : Document.element_path) (id : string) =
      let doc = model#document in
      match (try Some (Document.get_element doc path) with _ -> None) with
      | None -> ()
      | Some elem ->
        let new_elem = Element.with_id elem (Some id) in
        model#edit_document (Document.replace_element doc path new_elem)

    (** Create a by-id reference to the element at [target_path]
        (REFERENCE_GRAPH.md \1674). Assign-on-create: stamp [target_id] onto the
        target iff it has no id yet (the lazy-mint trigger); if it already has
        one, that id names the edge and [target_id] is ignored. A new reference
        element (its own id = [ref_id]) is then appended via [add_element]. Both
        ids are minted by the initiator and carried in the op payload — never
        minted here — so every app applies identical values. No-op on an
        invalid path. *)
    method create_reference (target_path : Document.element_path)
        (target_id : string) (ref_id : string) =
      let doc = model#document in
      match (try Some (Document.get_element doc target_path) with _ -> None) with
      | None -> ()
      | Some target ->
        let resolved_id =
          match Element.id_of target with
          | Some existing -> existing
          | None ->
            (* Assign-on-create: stamp the carried id and use it. *)
            let stamped = Element.with_id target (Some target_id) in
            model#edit_document
              (Document.replace_element doc target_path stamped);
            target_id
        in
        let reference = Element.make_reference ~id:(Some ref_id) resolved_id in
        self#add_element reference

    (* ── Symbols P2 — operations (SYMBOLS.md section 7) ────────
       Value-in-op: every id is minted by the initiator/UI and carried in the
       op payload, never minted inside the Controller (same rule as
       create_reference / assign_id), so all apps apply identical values. Each
       clones the doc, mutates, and set_document — no internal snapshot; the
       caller owns undo. *)

    (** Make Symbol (promote): move the element at [path] into [doc.symbols] as
        a master and leave a reference instance in its place (SYMBOLS.md
        section 7, Fork S6 — the dual of Detach). Assign-on-create: if the
        element already has a [common] id, that id is KEPT as the master key
        and [master_id] is ignored (mirrors create_reference target rule);
        otherwise [master_id] is stamped. The instance carries id [ref_id] and
        targets the master id. Net: the master lives off-canvas in [symbols],
        an instance sits where the element was, so the canvas looks unchanged
        (the instance resolves to the master geometry). No-op on an invalid
        path. *)
    method make_symbol (path : Document.element_path)
        (master_id : string) (ref_id : string) =
      let doc = model#document in
      match (try Some (Document.get_element doc path) with _ -> None) with
      | None -> ()
      | Some target ->
        (* Resolve the master id: keep the element own id if it has one, else
           stamp the carried master_id (assign-on-create). *)
        let resolved_id =
          match Element.id_of target with
          | Some existing -> existing
          | None -> master_id
        in
        (* The master carries the resolved id. *)
        let master = Element.with_id target (Some resolved_id) in
        (* The in-place instance targets the master id, with its own ref_id. *)
        let reference =
          Element.make_reference ~id:(Some ref_id) resolved_id in
        (* Replace the element in place with the instance, then push the
           master into the off-canvas store. *)
        let new_doc = Document.replace_element doc path reference in
        let new_symbols =
          Array.append new_doc.Document.symbols [| master |] in
        model#edit_document
          { new_doc with Document.symbols = new_symbols }

    (** Place Instance: append a reference targeting an existing master
        ([master_id]) to the active layer via [add_element] (which auto-selects
        it) — exactly like create_reference final step (SYMBOLS.md section 7).
        No offset: placement offset is a UI concern. It is fine if [master_id]
        does not currently exist; the instance simply renders empty until the
        master appears (dangling is already handled by the resolver). The
        instance carries id [ref_id], minted by the initiator. *)
    method place_instance (master_id : string) (ref_id : string) =
      let reference =
        Element.make_reference ~id:(Some ref_id) master_id in
      self#add_element reference

    (** Detach (break the link / expand): replace the reference instance at
        [path] with an INDEPENDENT copy of its resolved target (SYMBOLS.md
        section 7, Fork S6 — the inverse of Make Symbol). The target id is
        resolved by a pure lookup over ALL id-bearing elements ([doc.symbols]
        AND [layers]; deterministic, no entropy). The copy is born id-less
        ([clear_ids], per the duplication rule) and the instance own overrides
        are applied onto it: its [common] transform (set, or compose if the
        copy already has one) and its paint (fill / stroke applied only when
        Some). The master and every other instance are untouched, and nothing
        is minted. No-op when the path is invalid, not a reference, or the
        target is unresolvable. *)
    method detach (path : Document.element_path) =
      let doc = model#document in
      match (try Some (Document.get_element doc path) with _ -> None) with
      | None -> ()
      | Some elem ->
        (* Must be a reference instance. *)
        match elem with
        | Element.Live (Element.Reference instance) ->
          (* Resolve the target id over symbols + layers (a pure
             id->element map). *)
          (match find_element_by_id doc instance.Element.ref_target with
           | None -> ()
           | Some target ->
             (* Independent copy of the resolved target, born id-less. *)
             let copy = Element.clear_ids target in
             (* Apply the instance transform overrides. The render
                composition is [ref_transform] (CTM) of
                [ref_instance_transform] (Symbols P4 / Fork F2); detach must
                fold BOTH onto the copy so neither is dropped. Build the
                instance-side transform first (common transform of instance
                field), then compose onto any transform the copy already
                carries. *)
             let inst_combined =
               match instance.Element.ref_transform,
                     instance.Element.ref_instance_transform with
               | Some ct, Some it -> Some (Element.multiply ct it)
               | Some ct, None -> Some ct
               | None, Some it -> Some it
               | None, None -> None
             in
             let copy =
               match inst_combined with
               | None -> copy
               | Some inst_t ->
                 let composed =
                   match Element.get_transform copy with
                   | Some copy_t -> Element.multiply inst_t copy_t
                   | None -> inst_t
                 in
                 Element.set_transform (Some composed) copy
             in
             (* Apply the instance paint overrides (only when Some). *)
             let copy =
               match instance.Element.ref_fill with
               | Some _ as f -> Element.with_fill copy f
               | None -> copy
             in
             let copy =
               match instance.Element.ref_stroke with
               | Some _ as s -> Element.with_stroke copy s
               | None -> copy
             in
             model#edit_document (Document.replace_element doc path copy))
        | _ -> ()

    (** Set the instance transform of the reference at [path] (Symbols P4,
        SYMBOLS.md section 4 / Fork F2). Value-in-op: the [transform] is
        carried in the payload (not minted), letting an instance be
        mirrored / scaled relative to its master. This is the instance
        transform, distinct from [ref_transform] (the render CTM); the
        render composition is [ref_transform] of the instance transform.
        No-op when [path] is invalid or the element there is not a
        reference. *)
    method set_instance_transform (path : Document.element_path)
        (transform : Element.transform) =
      let doc = model#document in
      match (try Some (Document.get_element doc path) with _ -> None) with
      | None -> ()
      | Some elem ->
        match elem with
        | Element.Live (Element.Reference instance) ->
          (* Rebuild the reference with the instance transform set,
             preserving the target, paint overrides, and common props. *)
          let updated =
            { instance with
              Element.ref_instance_transform = Some transform } in
          let new_elem = Element.Live (Element.Reference updated) in
          model#edit_document (Document.replace_element doc path new_elem)
        | _ -> ()

    (** Redefine: replace the master with id [master_id] in [doc.symbols] with
        a clone of the element at [path] (re-id the clone to [master_id]), then
        replace the element at [path] in place with a reference instance (id
        [ref_id], targeting [master_id]) — the selection becomes an instance of
        the redefined master (SYMBOLS.md section 7, Fork S2). All other
        instances of [master_id] re-resolve to the new definition on the next
        paint. No-op when [master_id] is not in [symbols] or [path] is
        invalid. *)
    method redefine (master_id : string)
        (path : Document.element_path) (ref_id : string) =
      let doc = model#document in
      (* The master must already exist. *)
      let master_idx =
        let rec find i =
          if i >= Array.length doc.Document.symbols then None
          else if Element.id_of doc.Document.symbols.(i) = Some master_id
          then Some i
          else find (i + 1)
        in
        find 0
      in
      match master_idx with
      | None -> ()
      | Some master_idx ->
        match (try Some (Document.get_element doc path) with _ -> None) with
        | None -> ()
        | Some source ->
          (* New master = clone of the selection, re-id to master_id. *)
          let new_master = Element.with_id source (Some master_id) in
          (* The selection becomes an instance of the redefined master. *)
          let reference =
            Element.make_reference ~id:(Some ref_id) master_id in
          let new_doc = Document.replace_element doc path reference in
          let new_symbols = Array.copy new_doc.Document.symbols in
          new_symbols.(master_idx) <- new_master;
          model#edit_document
            { new_doc with Document.symbols = new_symbols }

    (** Delete Symbol: remove the master whose [common.id = master_id] from
        [doc.symbols] (SYMBOLS.md section 7). No-op when no master carries that
        id. The instances ([Reference]s targeting [master_id]) are left
        untouched — they simply become dangling and resolve to empty until the
        master returns (recoverable via undo, since the caller owns the
        snapshot). The Symbols-panel confirm-before-delete warning is a UI
        concern, not part of this op. *)
    method delete_symbol (master_id : string) =
      let doc = model#document in
      let idx =
        let rec find i =
          if i >= Array.length doc.Document.symbols then None
          else if Element.id_of doc.Document.symbols.(i) = Some master_id
          then Some i
          else find (i + 1)
        in
        find 0
      in
      match idx with
      | None -> ()
      | Some idx ->
        let new_symbols =
          Array.append
            (Array.sub doc.Document.symbols 0 idx)
            (Array.sub doc.Document.symbols (idx + 1)
               (Array.length doc.Document.symbols - idx - 1))
        in
        model#edit_document
          { doc with Document.symbols = new_symbols }

    (** Append [elem] to the mask subtree of the element at [path].
        Returns [true] on success, [false] when the target has no
        mask or the subtree root isn't a [Group] — the caller then
        falls back to layer-append. OPACITY.md \167Preview
        interactions. *)
    method private try_add_to_mask (elem : Element.element) (path : int list) : bool =
      let doc = model#document in
      try
        let target = Document.get_element doc path in
        match Element.get_mask target with
        | None -> false
        | Some mask ->
          (match mask.Element.subtree with
           | Element.Group g ->
             let new_group =
               Element.Group { g with children = Array.append g.children [| elem |] } in
             let new_mask = { mask with Element.subtree = new_group } in
             let new_target = Element.with_mask target (Some new_mask) in
             let new_doc = Document.replace_element doc path new_target in
             (* No canonical "inside a mask" path — select the
                mask-target element itself after the add. *)
             let es = Document.element_selection_all path in
             let sel = Document.PathMap.singleton path es in
             model#edit_document { new_doc with Document.selection = sel };
             true
           | _ -> false)
      with _ -> false

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
      (* Selection-only: a non-undoable write (OP_LOG.md sections 7 and 8). *)
      model#set_document_unbracketed { doc with Document.selection = new_sel }

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
      (* Selection-only: a non-undoable write (OP_LOG.md sections 7 and 8). *)
      model#set_document_unbracketed { doc with Document.selection = new_sel }

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
      (* Selection-only: a non-undoable write (OP_LOG.md sections 7 and 8). *)
      model#set_document_unbracketed { model#document with Document.selection }

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
            (* Selection-only: non-undoable (OP_LOG.md sections 7 and 8). *)
            model#set_document_unbracketed { doc with Document.selection = selection }
          | _ ->
            (* Selection-only: non-undoable (OP_LOG.md sections 7 and 8). *)
            model#set_document_unbracketed { doc with Document.selection =
              Document.PathMap.singleton path
                (Document.element_selection_all path) }
        else
          (* Selection-only: non-undoable (OP_LOG.md sections 7 and 8). *)
          model#set_document_unbracketed { doc with Document.selection =
            Document.PathMap.singleton path
              (Document.element_selection_all path) }

    method select_control_point (path : Document.element_path) (index : int) =
      match path with
      | [] -> ()
      | _ ->
        let es = Document.element_selection_partial path [index] in
        (* Selection-only: non-undoable (OP_LOG.md sections 7 and 8). *)
        model#set_document_unbracketed { model#document with Document.selection =
          Document.PathMap.singleton path es }

    method move_path_handle (path : int list) (anchor_idx : int)
        (handle_type : string) (dx : float) (dy : float) =
      let doc = model#document in
      let elem = Document.get_element doc path in
      (match elem with
       | Element.Path ({ d; _ } as r) ->
         let new_d = Element.move_path_handle d anchor_idx handle_type dx dy in
         let new_elem = Element.Path { r with d = new_d } in
         model#edit_document (Document.replace_element doc path new_elem)
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
        model#edit_document { new_doc with Document.selection = Document.PathMap.empty }
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
      model#edit_document { new_doc with Document.selection = new_sel }

    method hide_selection =
      let doc = model#document in
      if Document.PathMap.is_empty doc.Document.selection then ()
      else begin
        let new_doc = Document.PathMap.fold (fun path _ acc ->
          let elem = Document.get_element acc path in
          let hidden = Element.set_visibility Element.Invisible elem in
          Document.replace_element acc path hidden
        ) doc.Document.selection doc in
        model#edit_document
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
      model#edit_document { doc with Document.layers = new_layers;
                                     Document.selection = new_sel }

    method move_selection (dx : float) (dy : float) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path es acc ->
        let elem = Document.get_element acc path in
        let new_elem = move_kind elem es.Document.es_kind dx dy in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc in
      model#edit_document new_doc

    method copy_selection (dx : float) (dy : float) =
      let doc = model#document in
      (* Sort paths in reverse so insertions don't shift earlier paths *)
      let sorted_sels = Document.PathMap.bindings doc.Document.selection
        |> List.sort (fun (a, _) (b, _) -> compare b a) in
      let (new_doc, new_sel) = List.fold_left (fun (acc_doc, acc_sel) (_path, es) ->
        let elem = Document.get_element acc_doc es.Document.es_path in
        let copied = move_kind elem es.Document.es_kind dx dy in
        (* A copy must not inherit the source stable id (no two elements
           may share an identity); it is born id-less. *)
        let copied = Element.clear_ids copied in
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
      model#edit_document { new_doc with Document.selection = new_sel }

    (** Simplify the geometry of each selected Polygon / Path element in
        place by running the Schneider curve fit
        ([Simplify.simplify_polyline]) on its vertices. Other element
        kinds are left alone. [precision] is the Schneider max-error
        tolerance in points.

        Polygons are replaced with Paths carrying the refitted CurveTo /
        LineTo commands; existing Paths are re-issued with refitted
        geometry. Selection is preserved (the tree paths are unchanged).

        Like the other controller mutators this does NOT push an undo
        snapshot — the caller/harness brackets the transaction. Mirrors
        jas_dioxus controller.rs simplify_selection. *)
    method simplify_selection (precision : float) =
      let doc = model#document in
      if Document.PathMap.is_empty doc.Document.selection then ()
      else begin
        (* Flush a buffered run of straight-line points into [new_cmds],
           refitting via Simplify when it has at least two points. *)
        let flush new_cmds buf closed =
          (if List.length !buf >= 2 then
             let sub = Simplify.simplify_polyline (List.rev !buf) precision !closed in
             (* [new_cmds] accumulates in reverse; [List.rev_append sub acc]
                prepends [sub] (forward order) so the final [List.rev] yields
                the commands in order. *)
             new_cmds := List.rev_append sub !new_cmds);
          buf := [];
          closed := false
        in
        let new_doc = Document.PathMap.fold (fun path _ acc ->
          match (try Some (Document.get_element acc path) with _ -> None) with
          | None -> acc
          | Some elem ->
            (match elem with
             | Element.Polygon p ->
               let cmds = Simplify.simplify_polyline p.points precision true in
               if cmds = [] then acc
               else
                 let new_path = Element.Path {
                   name = p.name; id = p.id;
                   d = cmds;
                   fill = p.fill; stroke = p.stroke;
                   width_points = [];
                   opacity = p.opacity; transform = p.transform;
                   locked = p.locked; visibility = p.visibility;
                   blend_mode = p.blend_mode; mask = p.mask;
                   fill_gradient = p.fill_gradient;
                   stroke_gradient = p.stroke_gradient;
                   stroke_brush = None;
                   stroke_brush_overrides = None;
                   tool_origin = None;
                 } in
                 Document.replace_element acc path new_path
             | Element.Path p ->
               (* Walk the path command list, splitting at every MoveTo /
                  ClosePath into subpaths of 2D points. Each subpath is
                  refit independently; already-curved commands (CurveTo,
                  ArcTo, ...) are passed through verbatim, with the
                  buffered run spliced in before them so refit and
                  pre-existing curves sit in order. *)
               let new_cmds = ref [] in
               let buf = ref [] in
               let closed = ref false in
               List.iter (fun (c : Element.path_command) ->
                 match c with
                 | Element.MoveTo (x, y) ->
                   flush new_cmds buf closed;
                   buf := (x, y) :: !buf
                 | Element.LineTo (x, y) -> buf := (x, y) :: !buf
                 | Element.ClosePath ->
                   closed := true;
                   flush new_cmds buf closed
                 | other ->
                   flush new_cmds buf closed;
                   new_cmds := other :: !new_cmds
               ) p.d;
               flush new_cmds buf closed;
               let cmds = List.rev !new_cmds in
               if cmds = [] then acc
               else
                 let new_path = Element.Path { p with d = cmds } in
                 Document.replace_element acc path new_path
             | _ -> acc)
        ) doc.Document.selection doc in
        model#edit_document new_doc
      end

    (* Pure: the document with [f] applied to every selected element (no write).
       Mirrors the Rust [fill_applied]. *)
    method private fill_applied (f : Element.fill option) : Document.document =
      let doc = model#document in
      Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        let new_elem = Element.with_fill elem f in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc

    (* Pure: the document with [s] applied to every selected element (no write).
       Mirrors the Rust [stroke_applied]. *)
    method private stroke_applied (s : Element.stroke option) : Document.document =
      let doc = model#document in
      Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        let new_elem = Element.with_stroke elem s in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc

    method set_selection_fill (f : Element.fill option) =
      model#edit_document (self#fill_applied f)

    (* Live, NON-undoable fill set for per-tick color-slider drag
       ([set_active_color_live]). Undo is captured once on pointer-up by
       [set_active_color], so the drag must NOT push checkpoints. Mirrors the
       Rust [set_selection_fill_live] (OP_LOG.md sections 7 and 8 live-drag). *)
    method set_selection_fill_live (f : Element.fill option) =
      model#set_document_unbracketed (self#fill_applied f)

    method set_selection_stroke (s : Element.stroke option) =
      model#edit_document (self#stroke_applied s)

    (* Live, NON-undoable stroke set for per-tick color drag (see
       [set_selection_fill_live]). Mirrors the Rust [set_selection_stroke_live]. *)
    method set_selection_stroke_live (s : Element.stroke option) =
      model#set_document_unbracketed (self#stroke_applied s)

    (* Brush attribute writeback — Path-only. Used by
       apply_brush_to_selection / remove_brush_from_selection. *)
    method set_selection_stroke_brush (slug : string option) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        let new_elem = Element.with_stroke_brush elem slug in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc in
      model#edit_document new_doc

    method set_selection_stroke_brush_overrides (overrides : string option) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        let new_elem = Element.with_stroke_brush_overrides elem overrides in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc in
      model#edit_document new_doc

    (* Phase 5: gradient writeback. Pass [None] to clear (demote). *)
    method set_selection_fill_gradient (g : Element.gradient option) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        let new_elem = Element.with_fill_gradient elem g in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc in
      model#edit_document new_doc

    method set_selection_stroke_gradient (g : Element.gradient option) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        let new_elem = Element.with_stroke_gradient elem g in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc in
      model#edit_document new_doc

    method set_selection_width_profile (wp : Element.stroke_width_point list) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        let new_elem = Element.with_width_points elem wp in
        Document.replace_element acc path new_elem
      ) doc.Document.selection doc in
      model#edit_document new_doc

    (* ── Opacity mask lifecycle (OPACITY.md §States) ─────────── *)

    (** Create an opacity mask on every selected element that does
        not already have one. The subtree starts as an empty [Group];
        users populate it via the MASK_PREVIEW click (Phase 4).
        [clip] and [invert] come from the document preferences
        [new_masks_clipping] / [new_masks_inverted]. *)
    method make_mask_on_selection ~clip ~invert =
      let doc = model#document in
      let empty_group =
        Element.Group { name = None; id = None; children = [||]; opacity = 1.0; transform = None;
                        locked = false; visibility = Element.Preview;
                        blend_mode = Element.Normal; mask = None;
                        isolated_blending = false; knockout_group = false }
      in
      let new_doc = Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        match Element.get_mask elem with
        | Some _ -> acc
        | None ->
          let m : Element.mask = {
            subtree = empty_group;
            clip; invert;
            disabled = false;
            linked = true;
            unlink_transform = None;
          } in
          Document.replace_element acc path
            (Element.with_mask elem (Some m))
      ) doc.Document.selection doc in
      model#edit_document new_doc

    (** Remove the opacity mask from every selected element. *)
    method release_mask_on_selection =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        match Element.get_mask elem with
        | None -> acc
        | Some _ -> Document.replace_element acc path
                      (Element.with_mask elem None)
      ) doc.Document.selection doc in
      model#edit_document new_doc

    (** Internal: apply [f] to every selected element's mask. Elements
        without a mask are skipped. *)
    method private update_mask_on_selection (f : Element.mask -> Element.mask) =
      let doc = model#document in
      let new_doc = Document.PathMap.fold (fun path _ acc ->
        let elem = Document.get_element acc path in
        match Element.get_mask elem with
        | None -> acc
        | Some m -> Document.replace_element acc path
                      (Element.with_mask elem (Some (f m)))
      ) doc.Document.selection doc in
      model#edit_document new_doc

    (** Set [mask.clip] on every selected element that has a mask. *)
    method set_mask_clip_on_selection (clip : bool) =
      self#update_mask_on_selection (fun m -> { m with clip })

    (** Set [mask.invert] on every selected element that has a mask. *)
    method set_mask_invert_on_selection (invert : bool) =
      self#update_mask_on_selection (fun m -> { m with invert })

    (** Toggle [mask.disabled] on every selected mask, driven by the
        first selected element's current state. *)
    method toggle_mask_disabled_on_selection =
      match first_mask model#document with
      | None -> ()
      | Some m ->
        let new_state = not m.Element.disabled in
        self#update_mask_on_selection (fun m -> { m with disabled = new_state })

    (** Toggle [mask.linked] on every selected mask. On unlink, captures
        each element's current transform into [unlink_transform] so the
        mask stays fixed in document coordinates. On relink, clears
        [unlink_transform]. *)
    method toggle_mask_linked_on_selection =
      match first_mask model#document with
      | None -> ()
      | Some m ->
        let new_linked = not m.Element.linked in
        let doc = model#document in
        let new_doc = Document.PathMap.fold (fun path _ acc ->
          let elem = Document.get_element acc path in
          match Element.get_mask elem with
          | None -> acc
          | Some old ->
            let capture =
              if new_linked then None
              else Element.get_transform elem
            in
            let new_mask = { old with
              Element.linked = new_linked;
              Element.unlink_transform = capture;
            } in
            Document.replace_element acc path
              (Element.with_mask elem (Some new_mask))
        ) doc.Document.selection doc in
        model#edit_document new_doc
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
  | Element.Live (Element.Reference r) -> Some r.Element.ref_fill
  | Element.Live (Element.Recorded rec_) -> Some rec_.Element.rec_fill
  | Element.Line _ | Element.Group _ | Element.Layer _ -> None

let element_stroke = function
  | Element.Line { stroke; _ } | Element.Rect { stroke; _ }
  | Element.Circle { stroke; _ } | Element.Ellipse { stroke; _ }
  | Element.Polyline { stroke; _ } | Element.Polygon { stroke; _ }
  | Element.Path { stroke; _ } | Element.Text { stroke; _ }
  | Element.Text_path { stroke; _ } -> Some stroke
  | Element.Live (Element.Compound_shape cs) -> Some cs.stroke
  | Element.Live (Element.Reference r) -> Some r.Element.ref_stroke
  | Element.Live (Element.Recorded rec_) -> Some rec_.Element.rec_stroke
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
