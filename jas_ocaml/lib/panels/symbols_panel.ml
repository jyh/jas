(** Symbols panel native glue (SYMBOLS.md section 8, P3 first slice).

    The panel body (master row list + footer) is rendered by the generic
    YAML interpreter from [workspace/panels/symbols.yaml] — a [foreach]
    over [active_document.symbols], one row per master (name + usage
    count + select), plus a footer of three actions. This module supplies
    only the native action arms: the symbol-store operations are
    value-in-op (like Make Instance) so the YAML actions are [log] stubs
    and the real work is intercepted here.

    Panel-selection ([selected_symbol]) is a single master id (or none)
    stored in the panel's own State_store scope under
    [symbols_panel_content]. The render reads [panel.selected_symbol]
    from there (driving the row highlight and the footer buttons'
    [bind.disabled]); the actions below read / clear it to know the
    target of Place Instance and Delete Symbol. *)

let content_id = "symbols_panel_content"
let selected_key = "selected_symbol"

(** Menu items for the Symbols panel — read from the panel's [menu:]
    block in the compiled workspace bundle (the single source of truth),
    exactly like every other panel. *)
let menu_items () =
  Panel_menu_yaml.menu_items_from_yaml content_id

(** The panel-selected master id, or [None] when none is selected. Read
    from the panel's State_store scope. *)
let selected_symbol (store : State_store.t) : string option =
  match State_store.get_panel store content_id selected_key with
  | `String s when s <> "" -> Some s
  | _ -> None

(** Replace the panel selection with [id] (Place / Delete target). *)
let set_selected_symbol (store : State_store.t) (id : string) : unit =
  State_store.set_panel store content_id selected_key (`String id)

(** Clear the panel selection. *)
let clear_selected_symbol (store : State_store.t) : unit =
  State_store.set_panel store content_id selected_key `Null

(* Gather every existing element id (layers + master store) so a freshly
   minted id avoids collisions. Recurses into Group / Layer children
   only, mirroring the Make Instance gather loop and the Rust
   existing_ids walk. *)
let existing_ids (doc : Document.document) : (string, unit) Hashtbl.t =
  let set = Hashtbl.create 16 in
  let rec gather elem =
    (match Element.id_of elem with
     | Some id -> Hashtbl.replace set id ()
     | None -> ());
    match elem with
    | Element.Group { children; _ } | Element.Layer { children; _ } ->
      Array.iter gather children
    | _ -> ()
  in
  Array.iter gather doc.Document.layers;
  Array.iter gather doc.Document.symbols;
  set

(* Mint a collision-free stable-element id, retrying up to 100 times.
   [None] when all attempts collide (mirrors the Make Instance / Rust
   mint loop). *)
let mint (existing : (string, unit) Hashtbl.t) : string option =
  let rec loop n =
    if n <= 0 then None
    else
      let c = Element.generate_id () in
      if Hashtbl.mem existing c then loop (n - 1)
      else Some c
  in
  loop 100

(* Count the live instances of [master_id] = the length of its
   reverse-dependency list (rdeps) in the dependency index. The
   reference-aware delete signal. *)
let usage_count (doc : Document.document) (master_id : string) : int =
  let idx = Dependency_index.build doc in
  match List.assoc_opt master_id idx.Dependency_index.rdeps with
  | Some refs -> List.length refs
  | None -> 0

(** NEW SYMBOL: promote the single selected canvas element to a master
    (SYMBOLS.md section 7 Make Symbol). Enabled only when EXACTLY ONE
    whole element is selected ([es_kind = SelKindAll]); a no-op
    otherwise, mirroring Make Instance's guard. Mints master_id + ref_id
    (value-in-op, collision-retry), snapshots once, then
    [make_symbol path master_id ref_id]. Keeps the new master
    panel-selected so Place / Delete target it immediately; the resolved
    master id is read back from the in-place instance's [ref_target]
    (make_symbol keeps an element's own id when it already has one). *)
let new_symbol (store : State_store.t) (m : Model.model) : unit =
  let doc = m#document in
  match Document.PathMap.bindings doc.Document.selection with
  | [ (path, es) ] when es.Document.es_kind = Document.SelKindAll ->
    let existing = existing_ids doc in
    (match mint existing with
     | None -> ()
     | Some master_id ->
       Hashtbl.replace existing master_id ();
       (match mint existing with
        | None -> ()
        | Some ref_id ->
          m#snapshot;
          let ctrl = new Controller.controller ~model:m () in
          ctrl#make_symbol path master_id ref_id;
          (* Resolve which id actually became the master from the
             in-place reference instance's target. *)
          let resolved =
            match (try Some (Document.get_element m#document path)
                   with _ -> None) with
            | Some (Element.Live (Element.Reference r)) -> r.Element.ref_target
            | _ -> master_id
          in
          set_selected_symbol store resolved))
  | _ -> ()

(** PLACE INSTANCE: append a new instance of the panel-selected master
    to the active layer (SYMBOLS.md section 7 Place Instance). No-op when
    no master is panel-selected. Mints ref_id (value-in-op), snapshots
    once, then [place_instance master_id ref_id]. *)
let place_instance (store : State_store.t) (m : Model.model) : unit =
  match selected_symbol store with
  | None -> ()
  | Some master_id ->
    let existing = existing_ids m#document in
    (match mint existing with
     | None -> ()
     | Some ref_id ->
       m#snapshot;
       let ctrl = new Controller.controller ~model:m () in
       ctrl#place_instance master_id ref_id)

(** DELETE SYMBOL: remove the panel-selected master from the master
    store (SYMBOLS.md section 7 Delete Symbol). Reference-aware: when the
    master still has live instances ([usage_count > 0]), first consult
    [confirm] with the count — the SAME native modal the reference-aware
    layers delete uses, whose body reads
    "Deleting will leave N live instance(s) empty." — and proceed only on
    OK. With no instances it deletes silently. Snapshots once on the
    delete path, then [delete_symbol master_id]; clears the panel
    selection afterward. *)
let delete_symbol_action
    (store : State_store.t) (m : Model.model)
    ~(confirm : int -> bool) : unit =
  match selected_symbol store with
  | None -> ()
  | Some master_id ->
    let usage = usage_count m#document master_id in
    let proceed = if usage > 0 then confirm usage else true in
    if proceed then begin
      m#snapshot;
      let ctrl = new Controller.controller ~model:m () in
      ctrl#delete_symbol master_id;
      clear_selected_symbol store
    end
