(** Observable model that holds the current document.

    Views register callbacks via on_document_changed to be notified
    whenever the document is replaced. *)

(** Structural view of an in-place text-editing session, exposed to
    callers (the Character panel pipeline) that need to detect an
    active bare-caret editor and prime its next-typed-character
    state. The concrete [Text_edit.t] lives in [lib/tools] — we use
    an object type here to keep the layering pointed the right way
    (tools may see Document/Model, but not the other way round). *)
type edit_session_ref = <
  has_selection : bool;
  selection_range : int * int;
  path : int list;
  set_pending_override : Element.tspan -> unit;
  clear_pending_override : unit -> unit
>

(** The target that drawing tools operate on. The default is the
    document's normal content; mask-editing mode switches the
    target to a specific element's mask subtree so new shapes land
    inside [element.mask.subtree] instead of the selected layer.
    Mirrors [EditingTarget] in [jas_dioxus] / [EditingTarget] in
    JasSwift. OPACITY.md \167Preview interactions. *)
type editing_target =
  | Content
  | Mask of int list

let max_undo = 100

let next_untitled = ref 1

let fresh_filename () =
  let name = Printf.sprintf "Untitled-%d" !next_untitled in
  incr next_untitled;
  name

(** Bump [next_untitled] past any [Untitled-N] entries already in use
    (e.g. from session restore). Without this, restoring a session
    with [Untitled-2] in it then File→New produces a second
    [Untitled-2] tab — clicking × on the duplicate becomes ambiguous
    and the session save+reload loop snowballs duplicates. *)
let advance_next_untitled_past (existing_filenames : string list) : unit =
  let max_n = ref (!next_untitled - 1) in
  List.iter (fun fn ->
    let prefix = "Untitled-" in
    let pl = String.length prefix in
    if String.length fn > pl
    && String.sub fn 0 pl = prefix then
      match int_of_string_opt (String.sub fn pl (String.length fn - pl)) with
      | Some n when n > !max_n -> max_n := n
      | _ -> ()
  ) existing_filenames;
  next_untitled := !max_n + 1

(* Persistent id->element index for the document [doc]. Phase 4b
   (REFERENCE_GRAPH.md section 2.4): a pure function of the document
   (always equal to [rebuild_index doc]; checked by the [assert] gate
   below), so it is never serialized and never part of Document equality.
   Held alongside [doc] on the Model so paint reads it without rebuilding
   each frame, and paired with each undo/redo entry so a snapshot carries
   it in O(1) (Map structure sharing). Mirrors the Rust [Model.id_index]. *)
let rebuild_index (d : Document.document) : Live.id_index =
  Live.rebuild_id_index d.Document.layers d.Document.symbols

class model ?(document = Document.default_document ()) ?filename () =
  let filename = match filename with Some f -> f | None -> fresh_filename () in
  object (_self)
    val mutable doc = document
    val mutable id_index = rebuild_index document
    val mutable saved_doc = document
    val mutable current_filename = filename
    val mutable listeners : (Document.document -> unit) list = []
    val mutable filename_listeners : (string -> unit) list = []
    (* Each undo/redo entry pairs the document with its index so undo/redo
       restore the index in O(1) without a rebuild (Map clone is O(1)
       structure sharing). Mirrors the Rust [Vec<(Document, IdIndex)>]. *)
    val mutable undo_stack : (Document.document * Live.id_index) list = []
    val mutable redo_stack : (Document.document * Live.id_index) list = []
    val mutable default_fill : Element.fill option = None
    val mutable default_stroke : Element.stroke option =
      Some (Element.make_stroke Element.black)
    val mutable recent_colors : string list = []
    val mutable current_edit_session : edit_session_ref option = None
    (* Mask-editing mode state. [Content] is the default; flipped
       to [Mask path] when the user clicks the Opacity panel's
       MASK_PREVIEW. OPACITY.md \167Preview interactions. *)
    val mutable editing_target : editing_target = Content
    (* Mask-isolation path. When [Some path], the canvas renders
       only the mask subtree of the element at [path], hiding
       everything else. Entered by Alt/Option-clicking
       MASK_PREVIEW; exited by Alt-clicking again.
       OPACITY.md \167Preview interactions. *)
    val mutable mask_isolation_path : int list option = None
    (* Per-document view state per ZOOM_TOOL.md State persistence.
       Persists across tab switches within a session; reset to
       defaults on document open. Not serialized to disk in
       Phase 1. *)
    val mutable zoom_level : float = 1.0
    val mutable view_offset_x : float = 0.0
    val mutable view_offset_y : float = 0.0
    (* Canvas viewport dimensions in screen-space pixels. Updated
       by the canvas widget on layout / resize. Read by
       doc.zoom.fit_* effects. Defaults match
       workspace/layout.yaml canvas_pane default_position. *)
    val mutable viewport_w : float = 888.0
    val mutable viewport_h : float = 900.0

    method document = doc

    (* Borrow the persistent id->element index paired with the current
       document (REFERENCE_GRAPH.md section 2.4). Equal to
       [rebuild_index doc] at all observable points. The canvas paint path
       reads this (via [Live.resolver_of_index]) instead of rebuilding the
       index per frame. Mirrors the Rust [Model.id_index]. *)
    method id_index : Live.id_index = id_index

    (* Phase 4b gate: after any path that sets [id_index], assert the stored
       index equals a from-scratch rebuild of [doc]. OCaml [assert] is on by
       default and the whole test suite runs with it active, so this proves
       the stored index always matches a fresh rebuild — pinning resolve()
       results unchanged. Mirrors the Rust [debug_assert!]. The polymorphic
       [=] is exact here: [element] has no functional fields. *)
    method private assert_index_matches_rebuild =
      assert (Live.Id_map.equal ( = ) id_index (rebuild_index doc))

    method filename = current_filename

    method set_filename (f : string) =
      current_filename <- f;
      List.iter (fun cb -> cb f) filename_listeners

    method set_document (d : Document.document) =
      (* The mutation chokepoint: all document edits funnel through here
         (the controller always clones, mutates, and [set_document]s).
         Rebuild the paired index here so paint never rebuilds it
         (REFERENCE_GRAPH.md section 2.4 Phase 4b). *)
      doc <- d;
      id_index <- rebuild_index d;
      _self#assert_index_matches_rebuild;
      List.iter (fun f -> f doc) listeners

    method on_document_changed (f : Document.document -> unit) =
      listeners <- f :: listeners

    method on_filename_changed (f : string -> unit) =
      filename_listeners <- f :: filename_listeners

    method snapshot =
      (* Pair the index with the document on the stack so undo/redo restore
         it in O(1) without a rebuild (Map clone is O(1) structure
         sharing). Phase 4b. *)
      undo_stack <- (doc, id_index) :: undo_stack;
      if List.length undo_stack > max_undo then
        undo_stack <- List.filteri (fun i _ -> i < max_undo) undo_stack;
      redo_stack <- []

    (* Out-of-band document snapshot for dialog Preview flows
       (Scale Options, Rotate Options, Shear Options). Captured at
       dialog open, restored on Cancel, cleared on OK. Distinct
       from undo_stack so preview-driven applies do not pollute
       undo history. See SCALE_TOOL.md \167 Preview. *)
    val mutable preview_doc_snapshot : Document.document option = None

    method capture_preview_snapshot =
      preview_doc_snapshot <- Some doc

    method restore_preview_snapshot =
      (match preview_doc_snapshot with
       | Some snap ->
         doc <- snap;
         (* The preview snapshot carries no index (it is out-of-band from
            the undo stack), so rebuild it from the restored document.
            Phase 4b; mirrors the Rust [refresh_id_index] here. *)
         id_index <- rebuild_index snap;
         _self#assert_index_matches_rebuild;
         List.iter (fun f -> f doc) listeners
       | None -> ())

    method clear_preview_snapshot =
      preview_doc_snapshot <- None

    method has_preview_snapshot = preview_doc_snapshot <> None

    method undo =
      match undo_stack with
      | [] -> ()
      | (prev_doc, prev_index) :: rest ->
        (* Carry the current (doc, index) onto redo and restore the paired
           index in O(1) — no rebuild (Phase 4b). The gate confirms the
           carried index equals a from-scratch rebuild of the restored
           document. *)
        redo_stack <- (doc, id_index) :: redo_stack;
        undo_stack <- rest;
        doc <- prev_doc;
        id_index <- prev_index;
        _self#assert_index_matches_rebuild;
        List.iter (fun f -> f doc) listeners

    method redo =
      match redo_stack with
      | [] -> ()
      | (next_doc, next_index) :: rest ->
        undo_stack <- (doc, id_index) :: undo_stack;
        redo_stack <- rest;
        doc <- next_doc;
        id_index <- next_index;
        _self#assert_index_matches_rebuild;
        List.iter (fun f -> f doc) listeners

    method is_modified = doc != saved_doc

    method mark_saved =
      saved_doc <- doc;
      List.iter (fun f -> f doc) listeners

    method can_undo = undo_stack <> []
    method can_redo = redo_stack <> []

    method default_fill = default_fill
    method set_default_fill (f : Element.fill option) = default_fill <- f
    method default_stroke = default_stroke
    method set_default_stroke (s : Element.stroke option) = default_stroke <- s
    method recent_colors = recent_colors
    method set_recent_colors (c : string list) = recent_colors <- c

    method current_edit_session = current_edit_session
    method set_current_edit_session (s : edit_session_ref option) =
      current_edit_session <- s

    method editing_target = editing_target
    method set_editing_target (t : editing_target) =
      editing_target <- t

    method mask_isolation_path = mask_isolation_path
    method set_mask_isolation_path (p : int list option) =
      mask_isolation_path <- p

    (* View state accessors per ZOOM_TOOL.md State persistence. *)
    method zoom_level = zoom_level
    method set_zoom_level (z : float) = zoom_level <- z
    method view_offset_x = view_offset_x
    method set_view_offset_x (x : float) = view_offset_x <- x
    method view_offset_y = view_offset_y
    method set_view_offset_y (y : float) = view_offset_y <- y
    method viewport_w = viewport_w
    method set_viewport_w (w : float) = viewport_w <- w
    method viewport_h = viewport_h
    method set_viewport_h (h : float) = viewport_h <- h

    (* Center the canvas view on the current artboard using the
       stored viewport_w / viewport_h. If the artboard fits at the
       current zoom, set pan to center it; otherwise apply
       fit-inside semantics with 20px screen-space padding.
       Per ZOOM_TOOL.md Document-open behavior. *)
    method center_view_on_current_artboard =
      let abs_list = doc.Document.artboards in
      if abs_list <> [] && viewport_w > 0.0 && viewport_h > 0.0 then begin
        let ab = List.hd abs_list in
        let abw = ab.Artboard.width in
        let abh = ab.Artboard.height in
        let abx = ab.Artboard.x in
        let aby = ab.Artboard.y in
        let fits =
          abw *. zoom_level <= viewport_w
          && abh *. zoom_level <= viewport_h
        in
        if fits then begin
          view_offset_x <-
            viewport_w /. 2.0 -. (abx +. abw /. 2.0) *. zoom_level;
          view_offset_y <-
            viewport_h /. 2.0 -. (aby +. abh /. 2.0) *. zoom_level
        end else begin
          let pad = 20.0 in
          let avail_w = viewport_w -. 2.0 *. pad in
          let avail_h = viewport_h -. 2.0 *. pad in
          if avail_w > 0.0 && avail_h > 0.0 then begin
            let z_fit = min (avail_w /. abw) (avail_h /. abh) in
            let z_clamped = max 0.1 (min 64.0 z_fit) in
            zoom_level <- z_clamped;
            view_offset_x <-
              viewport_w /. 2.0 -. (abx +. abw /. 2.0) *. z_clamped;
            view_offset_y <-
              viewport_h /. 2.0 -. (aby +. abh /. 2.0) *. z_clamped
          end
        end
      end
  end

let create ?document ?filename () = new model ?document ?filename ()
