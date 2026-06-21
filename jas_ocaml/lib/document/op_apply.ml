(** The single op dispatcher — [op_apply] (OP_LOG.md section 4 / section 9).
    See [op_apply.mli] for the design rationale.

    Mirrors [jas_dioxus] [document/op_apply.rs] and the Swift [OpApply.swift].
    Param reads are hardened so production input never raises: numbers default
    to 0.0; a missing required field (a path, an id, a transform) skips the op.
    Free of [State_store] (the interpreter layer) to avoid a circular dep — it
    consumes only the raw Yojson op value plus local hardened extractors. *)

open Yojson.Safe.Util

(* Read an f64 field, defaulting to 0.0 (the non-raising number form). *)
let num_field (op : Yojson.Safe.t) (key : string) : float =
  match member key op with
  | `Float f -> f
  | `Int i -> float_of_int i
  | _ -> 0.0

(* Read a string field, or [None] if absent / not a string. *)
let str_field (op : Yojson.Safe.t) (key : string) : string option =
  match member key op with
  | `String s -> Some s
  | _ -> None

(* Read a bool field, defaulting to [false]. *)
let bool_field (op : Yojson.Safe.t) (key : string) : bool =
  match member key op with
  | `Bool b -> b
  | _ -> false

(* Parse a JSON array of indices into an element path. Returns [None] if the
   field is absent or not an array (a malformed production payload skips the op
   rather than raising). Non-integer entries default to 0. *)
let parse_path (op : Yojson.Safe.t) (key : string) : int list option =
  match member key op with
  | `List items ->
    Some (List.map (fun i ->
      match i with `Int n -> n | `Float f -> int_of_float f | _ -> 0) items)
  | _ -> None

(* Read the optional [value] field as a raw Yojson value, with hardened
   number/bool/string accessors. Mirrors the Rust [as_f64]/[as_bool]/[as_str]:
   a type mismatch yields [None], which the per-field setters treat as "skip". *)
let val_num (v : Yojson.Safe.t) : float option =
  match v with `Float f -> Some f | `Int i -> Some (float_of_int i) | _ -> None
let val_bool (v : Yojson.Safe.t) : bool option =
  match v with `Bool b -> Some b | _ -> None
let val_str (v : Yojson.Safe.t) : string option =
  match v with `String s -> Some s | _ -> None

(* Read a JSON array-of-strings field (the [ids] payload for the move verbs).
   Non-string entries are dropped; a missing/non-array field yields []. *)
let str_list_field (op : Yojson.Safe.t) (key : string) : string list =
  match member key op with
  | `List items ->
    List.filter_map (function `String s -> Some s | _ -> None) items
  | _ -> []

(* Parse the [paths] op param — a JSON array of index arrays ([[..],..]) —
   into a [int list list]. Returns [None] if the field is absent or is not an
   array of arrays of integers (a malformed payload skips the op rather than
   raising). An empty top-level array yields [Some []], which the caller
   treats as a no-op (journals nothing). *)
let parse_path_list (op : Yojson.Safe.t) (key : string) : int list list option =
  match member key op with
  | `List items ->
    (try
       Some (List.map (fun item ->
         match item with
         | `List inner ->
           List.map (function
             | `Int n -> n | `Float f -> int_of_float f
             | _ -> raise Exit) inner
         | _ -> raise Exit) items)
     with Exit -> None)
  | _ -> None

(* ── Element value-in-op (OP_LOG.md section 9 Phase P4) ───────────────────────
   The two inserting verbs carry the WHOLE element to insert as LITERAL JSON in
   the op params (value-in-op). The literal is the RUST SERDE externally-tagged
   shape ([{"Rect":{...,"common":{...}}}], colors as [{"Rgb":{...}}],
   PascalCase visibility), which is DISTINCT from this app's canonical test_json
   shape ([{"type":"rect",...}]). So we convert the serde shape to the canonical
   test_json shape and delegate to [Test_json.parse_element]. Only the variants
   the shared structural fixtures carry are mapped (Rect, Layer, Group + nested
   children); an unknown tag yields [None] (a malformed payload skips the op).
   Mirrors the Swift [parseSerdeElement] / [serdeElementToTestJson]. *)

(* Serde Color ([{"Rgb":{r,g,b,a}}] / [{"Hsb":...}] / [{"Cmyk":...}]) ->
   the test_json flat shape (with a [space] key). *)
let serde_color_to_test_json (v : Yojson.Safe.t) : Yojson.Safe.t option =
  match v with
  | `Assoc [ (tag, `Assoc fields) ] ->
    let space = match tag with
      | "Rgb" -> Some "rgb" | "Hsb" -> Some "hsb" | "Cmyk" -> Some "cmyk"
      | _ -> None in
    (match space with
     | Some s -> Some (`Assoc (fields @ [ ("space", `String s) ]))
     | None -> None)
  | _ -> None

(* Serde Fill ([{"color":{serde},"opacity":..}]) -> the test_json fill shape. *)
let serde_fill_to_test_json (v : Yojson.Safe.t) : Yojson.Safe.t =
  match v with
  | `Assoc fields ->
    let color = match List.assoc_opt "color" fields with
      | Some c -> (match serde_color_to_test_json c with Some c -> c | None -> `Null)
      | None -> `Null in
    let opacity = match List.assoc_opt "opacity" fields with
      | Some o -> o | None -> `Float 1.0 in
    `Assoc [ ("color", color); ("opacity", opacity) ]
  | _ -> `Null

(* Serde Stroke -> the test_json stroke shape. *)
let serde_stroke_to_test_json (v : Yojson.Safe.t) : Yojson.Safe.t =
  match v with
  | `Assoc fields ->
    let color = match List.assoc_opt "color" fields with
      | Some c -> (match serde_color_to_test_json c with Some c -> c | None -> `Null)
      | None -> `Null in
    let pick key = match List.assoc_opt key fields with Some x -> [ (key, x) ] | None -> [] in
    `Assoc ([ ("color", color) ]
            @ pick "width" @ pick "linecap" @ pick "linejoin" @ pick "opacity")
  | _ -> `Null

(* Serde [common] block -> the test_json flat common fields. *)
let serde_common_to_test_json (common : Yojson.Safe.t) : (string * Yojson.Safe.t) list =
  match common with
  | `Assoc c ->
    let pick key = match List.assoc_opt key c with Some x -> [ (key, x) ] | None -> [] in
    (* serde Visibility is PascalCase ("Preview"); test_json wants lowercase. *)
    let vis = match List.assoc_opt "visibility" c with
      | Some (`String s) -> [ ("visibility", `String (String.lowercase_ascii s)) ]
      | _ -> [] in
    pick "opacity" @ pick "locked" @ vis @ pick "transform"
    @ pick "name" @ pick "id"
  | _ -> []

(* Convert a serde externally-tagged element JSON into the canonical test_json
   flat dict. Returns [None] for an unrecognized variant tag. *)
let rec serde_element_to_test_json (el : Yojson.Safe.t) : Yojson.Safe.t option =
  match el with
  | `Assoc [ (tag, `Assoc fields) ] ->
    let get k = match List.assoc_opt k fields with Some x -> x | None -> `Null in
    let common = serde_common_to_test_json (get "common") in
    let children () =
      match get "children" with
      | `List kids -> `List (List.filter_map serde_element_to_test_json kids)
      | _ -> `List []
    in
    (match tag with
     | "Rect" ->
       Some (`Assoc (
         ("type", `String "rect")
         :: ("x", get "x") :: ("y", get "y")
         :: ("width", get "width") :: ("height", get "height")
         :: ("rx", get "rx") :: ("ry", get "ry")
         :: ("fill", serde_fill_to_test_json (get "fill"))
         :: ("stroke", serde_stroke_to_test_json (get "stroke"))
         :: common))
     | "Layer" ->
       Some (`Assoc (
         ("type", `String "layer") :: ("children", children ()) :: common))
     | "Group" ->
       Some (`Assoc (
         ("type", `String "group") :: ("children", children ()) :: common))
     | _ -> None)
  | _ -> None

(* ── Element value-in-op production fast path (OP_LOG.md section 9 Phase P4) ───
   The cross-language fixtures carry [element] as the RUST SERDE externally-tagged
   shape (a disk-shareable, app-agnostic dict). The OCaml PRODUCTION inserting
   handlers (doc.insert_after / doc.insert_at) already hold a live
   [Element.element] from a preceding NON-journaled clone_at / create_layer
   binder, and OCaml — like Swift — has NO serde-shape ENCODER (only the decoder
   above). So production stashes the live element HERE and carries an opaque
   marker dict (an [__element_ref__] key mapping to a token) under the SAME
   [element] key; the journal replays that SAME marker in-process and
   re-resolves the SAME element, so
   checkpoint_equivalence holds. This is additive and fixture-neutral: a fixture
   never stores an [__element_ref__] marker (it carries the serde dict), so the
   byte-gated dispatch arms below are UNCHANGED. Mirrors the Swift
   [parseSerdeElement] value-in-op fast path. *)
let element_value_stash : (string, Element.element) Hashtbl.t = Hashtbl.create 16
let next_value_token = ref 0

(* Stash a live element for value-in-op carriage and return the marker JSON the
   production handler puts under the [element] key of the op. *)
let stash_element_value (el : Element.element) : Yojson.Safe.t =
  let token = Printf.sprintf "__opval_elem_%d__" !next_value_token in
  incr next_value_token;
  Hashtbl.replace element_value_stash token el;
  `Assoc [ ("__element_ref__", `String token) ]

(* Deserialize the [element] op param into an [Element.element]. Returns [None]
   if absent or not a recognized variant (a malformed payload skips the op).
   The value-in-op marker fast path runs FIRST (production carriage), then the
   serde-shape conversion (the fixture path). *)
let parse_element (op : Yojson.Safe.t) : Element.element option =
  match member "element" op with
  | `Assoc [ ("__element_ref__", `String token) ] ->
    Hashtbl.find_opt element_value_stash token
  | `Null -> None
  | el ->
    (match serde_element_to_test_json el with
     | Some flat -> (try Some (Test_json.parse_element flat) with _ -> None)
     | None -> None)

(* The [common.id] of an element, or [None] (for [targets]). *)
let element_id (el : Element.element) : string option = Element.id_of el

(* ── OP_LOG.md section 5 Fork 4 / RECORDED_ELEMENTS.md — the id-primary op family
   ────────────────────────────────────────────────────────────────────────────

   The id-primary verbs [select_by_ids] / [move_by_ids] / [copy_by_ids] promote
   the recorded-recipe vocabulary (input-addressed, side-effect-free) to a
   first-class op family [op_apply] can execute, so a captured recipe IS a
   replayable journal segment (RECORDED_ELEMENTS.md section 7) and
   [Live.capture_recipe] collapses to a pass-through. They are ADDITIVE: the
   selection-relative verbs ([select_rect] / [move_selection] / [copy_selection])
   keep their params VERBATIM (OP_LOG.md section 7 — selection is serialized
   Document state, so the byte-gate reproduces it); this is a NEW family, not a
   params rewrite. The decisive property (OP_LOG.md section 7 determinism rule):
   the operand ids come from the OP-OWN PARAMS, never inferred from
   doc.selection, so snapshot and replay apply identical operands and a recorded
   recipe survives source edits with NO selection dependency.

   THE BYTE-GATE RECONCILIATION (OP_LOG.md section 6, the gate compares
   document_to_test_json INCLUDING selection): the family is committed as the
   canonical PAIR [select_by_ids, <op>_by_ids], AND each [<op>_by_ids] ALSO
   re-establishes the working selection from its OWN ids before mutating. So the
   replayed selection is byte-identical to [select_rect, move_selection] for the
   same elements: [select_by_ids] resolves ids to paths and writes
   [element_selection_all path] in DOCUMENT ORDER (the same order
   [select_flat] / [select_rect] produces), then the mutator routes through the
   SAME shared [Controller] body (no divergent second mutation path). Hardened
   reads: an unknown id / a non-array params is SKIPPED, never a raise. Mirrors
   the Rust [op_apply.rs] id-primary family. *)

(* Walk the element tree (Group / Layer children only — the SAME descent
   discipline as the id-index builder [Live.collect_ref_ids]) collecting
   [(common.id, path)] for every id-bearing element, in DOCUMENT ORDER. The
   id-primary selection builder uses this so a [select_by_ids] produces the SAME
   ordered selection a [select_rect] over the same elements would (the byte-gate
   reconciliation). Top-level layer ids are NOT resolution targets (mirroring the
   id-index), so the walk starts at each layer-child, exactly like
   [rebuild_id_index]. Mirrors the Rust [id_paths_in_document_order]. *)
let id_paths_in_document_order (doc : Document.document) :
    (string * int list) list =
  let out = ref [] in
  let rec walk (elem : Element.element) (path : int list) : unit =
    (match element_id elem with
     | Some id -> out := (id, path) :: !out
     | None -> ());
    match elem with
    | Element.Group { children; _ } | Element.Layer { children; _ } ->
      Array.iteri (fun i child -> walk child (path @ [i])) children
    | _ -> ()
  in
  Array.iteri (fun li layer ->
    match layer with
    | Element.Group { children; _ } | Element.Layer { children; _ } ->
      Array.iteri (fun ci child -> walk child [li; ci]) children
    | _ -> ()
  ) doc.Document.layers;
  List.rev !out

(* Build the selection (in DOCUMENT ORDER) for the elements whose [common.id] is
   in [ids], as [element_selection_all path] entries in a [PathMap]. Document
   order — NOT the order of [ids] — so the result is byte-identical to what
   [select_rect] would produce for the same set (the byte-gate reconciliation).
   An id that resolves to no element is silently dropped (hardened: a stale /
   unknown id is a skip). Mirrors the Rust [selection_for_ids]. *)
let selection_for_ids (doc : Document.document) (ids : string list) :
    Document.selection =
  List.fold_left (fun acc (id, path) ->
    if List.mem id ids then
      Document.PathMap.add path (Document.element_selection_all path) acc
    else acc
  ) Document.PathMap.empty (id_paths_in_document_order doc)

(* Resolve [ids] to their selection and write it BY PATH (selection-only,
   non-undoable — like [select_rect], this goes through the unbracketed selection
   write via [Controller.set_selection]). The id-primary [select_by_ids] body,
   SHARED by the standalone [select_by_ids] op and by [move_by_ids] /
   [copy_by_ids] (which re-establish the working selection from their own ids
   before the mutation). Returns the resolved selection ids (in document order)
   for [targets]. Mirrors the Rust [apply_select_by_ids]. *)
let apply_select_by_ids (model : Model.model) (ctrl : Controller.controller)
    (ids : string list) : string list =
  let selection = selection_for_ids model#document ids in
  ctrl#set_selection selection;
  Controller.selection_to_ids model#document

(* ── Print-config field setters (OP_LOG.md section 9 Phase P1) ────────────────
   The eight doc.* print-config verbs journal real ops. Each value is a
   RESOLVED literal; a type mismatch SKIPS (returns false), so a no-op edit
   journals nothing. SHARED mutation body with the production handler. *)

(* Apply one print-config field. Returns true iff the field matched AND the
   value coerced. Writes via [model#set_document] (the op_apply caller has
   already opened the transaction). *)
let apply_print_config_field (model : Model.model) (verb : string)
    (field : string) (value : Yojson.Safe.t) (index : int) : bool =
  let module PP = Print_preferences in
  let as_num = val_num value and as_bool = val_bool value and as_str = val_str value in
  let doc = model#document in
  let p = doc.Document.print_preferences in
  let new_p = ref p in
  (* [set_document_setup_field] writes [document_setup] directly (a different
     part of the document than [print_preferences]); this flag tells the
     trailing write to skip the print_preferences path for that verb. *)
  let wrote_setup = ref false in
  let applied =
    match verb with
    | "set_print_preferences_field" ->
      (match field with
       | "preset_name" -> (match as_str with Some s -> new_p := { p with PP.preset_name = s }; true | None -> false)
       | "printer_name" -> (match as_str with Some s -> new_p := { p with PP.printer_name = (if s = "" then None else Some s) }; true | None -> false)
       | "copies" -> (match as_num with Some n -> new_p := { p with PP.copies = max 0 (int_of_float n) }; true | None -> false)
       | "collate" -> (match as_bool with Some b -> new_p := { p with PP.collate = b }; true | None -> false)
       | "reverse_order" -> (match as_bool with Some b -> new_p := { p with PP.reverse_order = b }; true | None -> false)
       | "artboard_range_mode" -> (match as_str with Some s -> new_p := { p with PP.artboard_range_mode = PP.artboard_range_mode_of_string s }; true | None -> false)
       | "artboard_range" -> (match as_str with Some s -> new_p := { p with PP.artboard_range = s }; true | None -> false)
       | "ignore_artboards" -> (match as_bool with Some b -> new_p := { p with PP.ignore_artboards = b }; true | None -> false)
       | "skip_blank_artboards" -> (match as_bool with Some b -> new_p := { p with PP.skip_blank_artboards = b }; true | None -> false)
       | "media_size" -> (match as_str with Some s -> new_p := { p with PP.media_size = PP.media_size_of_string s }; true | None -> false)
       | "media_width" -> (match as_num with Some n -> new_p := { p with PP.media_width = n }; true | None -> false)
       | "media_height" -> (match as_num with Some n -> new_p := { p with PP.media_height = n }; true | None -> false)
       | "orientation" -> (match as_str with Some s -> new_p := { p with PP.orientation = PP.orientation_of_string s }; true | None -> false)
       | "auto_rotate" -> (match as_bool with Some b -> new_p := { p with PP.auto_rotate = b }; true | None -> false)
       | "transverse" -> (match as_bool with Some b -> new_p := { p with PP.transverse = b }; true | None -> false)
       | "print_layers" -> (match as_str with Some s -> new_p := { p with PP.print_layers = PP.print_layers_of_string s }; true | None -> false)
       | "placement_x" -> (match as_num with Some n -> new_p := { p with PP.placement_x = n }; true | None -> false)
       | "placement_y" -> (match as_num with Some n -> new_p := { p with PP.placement_y = n }; true | None -> false)
       | "scaling_mode" -> (match as_str with Some s -> new_p := { p with PP.scaling_mode = PP.scaling_mode_of_string s }; true | None -> false)
       | "custom_scale" -> (match as_num with Some n -> new_p := { p with PP.custom_scale = n }; true | None -> false)
       | "tile_overlap_h" -> (match as_num with Some n -> new_p := { p with PP.tile_overlap_h = n }; true | None -> false)
       | "tile_overlap_v" -> (match as_num with Some n -> new_p := { p with PP.tile_overlap_v = n }; true | None -> false)
       | "tile_range" -> (match as_str with Some s -> new_p := { p with PP.tile_range = s }; true | None -> false)
       | _ -> false)
    | "set_marks_and_bleed_field" ->
      let m = p.PP.marks_and_bleed in
      let set m' = new_p := { p with PP.marks_and_bleed = m' } in
      (match field with
       | "all_printer_marks" -> (match as_bool with Some b -> set { m with PP.all_printer_marks = b }; true | None -> false)
       | "trim_marks" -> (match as_bool with Some b -> set { m with PP.trim_marks = b }; true | None -> false)
       | "registration_marks" -> (match as_bool with Some b -> set { m with PP.registration_marks = b }; true | None -> false)
       | "color_bars" -> (match as_bool with Some b -> set { m with PP.color_bars = b }; true | None -> false)
       | "page_information" -> (match as_bool with Some b -> set { m with PP.page_information = b }; true | None -> false)
       | "printer_mark_type" -> (match as_str with Some s -> set { m with PP.printer_mark_type = PP.printer_mark_type_of_string s }; true | None -> false)
       | "trim_mark_weight" -> (match as_num with Some n -> set { m with PP.trim_mark_weight = n }; true | None -> false)
       | "mark_offset" -> (match as_num with Some n -> set { m with PP.mark_offset = n }; true | None -> false)
       | "use_document_bleed" -> (match as_bool with Some b -> set { m with PP.use_document_bleed = b }; true | None -> false)
       | "bleed_top" -> (match as_num with Some n -> set { m with PP.bleed_top = n }; true | None -> false)
       | "bleed_right" -> (match as_num with Some n -> set { m with PP.bleed_right = n }; true | None -> false)
       | "bleed_bottom" -> (match as_num with Some n -> set { m with PP.bleed_bottom = n }; true | None -> false)
       | "bleed_left" -> (match as_num with Some n -> set { m with PP.bleed_left = n }; true | None -> false)
       | _ -> false)
    | "set_output_field" ->
      let o = p.PP.output in
      let set o' = new_p := { p with PP.output = o' } in
      (match field with
       | "mode" -> (match as_str with Some s -> set { o with PP.mode = PP.output_mode_of_string s }; true | None -> false)
       | "emulsion" -> (match as_str with Some s -> set { o with PP.emulsion = PP.emulsion_of_string s }; true | None -> false)
       | "image_polarity" -> (match as_str with Some s -> set { o with PP.image_polarity = PP.image_polarity_of_string s }; true | None -> false)
       | "printer_resolution" -> (match as_str with Some s -> set { o with PP.printer_resolution = s }; true | None -> false)
       | "convert_spot_to_process" -> (match as_bool with Some b -> set { o with PP.convert_spot_to_process = b }; true | None -> false)
       | "overprint_black" -> (match as_bool with Some b -> set { o with PP.overprint_black = b }; true | None -> false)
       | _ -> false)
    | "set_output_ink_field" ->
      let o = p.PP.output in
      let inks = Array.of_list o.PP.inks in
      if index < 0 || index >= Array.length inks then false
      else begin
        let ink = inks.(index) in
        let applied = match field with
          | "print" -> (match as_bool with Some b -> inks.(index) <- { ink with PP.print = b }; true | None -> false)
          | "frequency" -> (match as_num with Some n -> inks.(index) <- { ink with PP.frequency = n }; true | None -> false)
          | "angle" -> (match as_num with Some n -> inks.(index) <- { ink with PP.angle = n }; true | None -> false)
          | "dot_shape" -> (match as_str with Some s -> inks.(index) <- { ink with PP.dot_shape = PP.dot_shape_of_string s }; true | None -> false)
          | "name" -> (match as_str with Some s -> inks.(index) <- { ink with PP.name = s }; true | None -> false)
          | _ -> false in
        if applied then new_p := { p with PP.output = { o with PP.inks = Array.to_list inks } };
        applied
      end
    | "set_graphics_field" ->
      let g = p.PP.graphics in
      let set g' = new_p := { p with PP.graphics = g' } in
      (match field with
       | "flatness" -> (match as_num with Some n -> set { g with PP.flatness = n }; true | None -> false)
       | "font_download" -> (match as_str with Some s -> set { g with PP.font_download = PP.font_download_of_string s }; true | None -> false)
       | "postscript_level" -> (match as_str with Some s -> set { g with PP.postscript_level = PP.postscript_level_of_string s }; true | None -> false)
       | "data_format" -> (match as_str with Some s -> set { g with PP.data_format = PP.data_format_of_string s }; true | None -> false)
       | "compatible_gradient_printing" -> (match as_bool with Some b -> set { g with PP.compatible_gradient_printing = b }; true | None -> false)
       | "raster_effects_resolution" -> (match as_num with Some n -> set { g with PP.raster_effects_resolution = n }; true | None -> false)
       | _ -> false)
    | "set_color_management_field" ->
      let c = p.PP.color_management in
      let set c' = new_p := { p with PP.color_management = c' } in
      (match field with
       | "document_profile" -> (match as_str with Some s -> set { c with PP.document_profile = s }; true | None -> false)
       | "color_handling" -> (match as_str with Some s -> set { c with PP.color_handling = PP.color_handling_of_string s }; true | None -> false)
       | "printer_profile" -> (match as_str with Some s -> set { c with PP.printer_profile = s }; true | None -> false)
       | "rendering_intent" -> (match as_str with Some s -> set { c with PP.rendering_intent = PP.rendering_intent_of_string s }; true | None -> false)
       | "preserve_rgb_numbers" -> (match as_bool with Some b -> set { c with PP.preserve_rgb_numbers = b }; true | None -> false)
       | _ -> false)
    | "set_advanced_field" ->
      let a = p.PP.advanced in
      let set a' = new_p := { p with PP.advanced = a' } in
      (match field with
       | "print_as_bitmap" -> (match as_bool with Some b -> set { a with PP.print_as_bitmap = b }; true | None -> false)
       | "overprint_flattener_preset" -> (match as_str with Some s -> set { a with PP.overprint_flattener_preset = PP.flattener_preset_of_string s }; true | None -> false)
       | _ -> false)
    | "set_document_setup_field" ->
      let module DS = Document_setup in
      let d = doc.Document.document_setup in
      let set d' = model#set_document { doc with Document.document_setup = d' }; wrote_setup := true in
      (match field with
        | "bleed_top" -> (match as_num with Some n -> set { d with DS.bleed_top = n }; true | None -> false)
        | "bleed_right" -> (match as_num with Some n -> set { d with DS.bleed_right = n }; true | None -> false)
        | "bleed_bottom" -> (match as_num with Some n -> set { d with DS.bleed_bottom = n }; true | None -> false)
        | "bleed_left" -> (match as_num with Some n -> set { d with DS.bleed_left = n }; true | None -> false)
        | "bleed_uniform" -> (match as_bool with Some b -> set { d with DS.bleed_uniform = b }; true | None -> false)
        | "show_images_outline" -> (match as_bool with Some b -> set { d with DS.show_images_outline = b }; true | None -> false)
        | "highlight_substituted_glyphs" -> (match as_bool with Some b -> set { d with DS.highlight_substituted_glyphs = b }; true | None -> false)
        | "simulate_colored_paper" -> (match as_bool with Some b -> set { d with DS.simulate_colored_paper = b }; true | None -> false)
        | "discard_white_overprint" -> (match as_bool with Some b -> set { d with DS.discard_white_overprint = b }; true | None -> false)
        | "grid_size" -> (match as_num with Some n -> set { d with DS.grid_size = n }; true | None -> false)
        | "grid_color" -> (match as_str with Some s -> set { d with DS.grid_color = s }; true | None -> false)
        | "paper_color" -> (match as_str with Some s -> set { d with DS.paper_color = s }; true | None -> false)
        | "transparency_flattener_preset" -> (match as_str with Some s -> set { d with DS.transparency_flattener_preset = PP.flattener_preset_of_string s }; true | None -> false)
        | _ -> false)
    | _ -> false
  in
  (* The print-config verbs (except set_document_setup_field, which wrote
     document_setup directly above) commit their new print_preferences here. *)
  if applied && not !wrote_setup then
    model#set_document { doc with Document.print_preferences = !new_p };
  applied

(* ── Artboard doc.* setters (OP_LOG.md section 9 Phase P2) ────────────────────
   The five no-id-minting artboard verbs. Each carries RESOLVED literals; a
   no-op edit (type mismatch / missing id / boundary swap / missing delete)
   journals nothing — the caller records only on an effective change. *)

(* Apply one RESOLVED field literal to an in-flight artboard (the create-path
   field application). A type mismatch or unknown field is silently skipped. *)
let apply_artboard_field_in_place (ab : Artboard.artboard) (field : string)
    (value : Yojson.Safe.t) : Artboard.artboard =
  let as_num = val_num value and as_bool = val_bool value and as_str = val_str value in
  match field with
  | "name" -> (match as_str with Some s -> { ab with Artboard.name = s } | None -> ab)
  | "x" -> (match as_num with Some n -> { ab with Artboard.x = n } | None -> ab)
  | "y" -> (match as_num with Some n -> { ab with Artboard.y = n } | None -> ab)
  | "width" -> (match as_num with Some n -> { ab with Artboard.width = n } | None -> ab)
  | "height" -> (match as_num with Some n -> { ab with Artboard.height = n } | None -> ab)
  | "fill" -> (match as_str with Some s -> { ab with Artboard.fill = Artboard.fill_from_canonical s } | None -> ab)
  | "show_center_mark" -> (match as_bool with Some b -> { ab with Artboard.show_center_mark = b } | None -> ab)
  | "show_cross_hairs" -> (match as_bool with Some b -> { ab with Artboard.show_cross_hairs = b } | None -> ab)
  | "show_video_safe_areas" -> (match as_bool with Some b -> { ab with Artboard.show_video_safe_areas = b } | None -> ab)
  | "video_ruler_pixel_aspect_ratio" -> (match as_num with Some n -> { ab with Artboard.video_ruler_pixel_aspect_ratio = n } | None -> ab)
  | _ -> ab

(* Apply one field of one artboard (by id). Returns true iff the artboard
   exists AND the field matched AND the value coerced. *)
let apply_set_artboard_field (model : Model.model) (id : string)
    (field : string) (value : Yojson.Safe.t) : bool =
  let as_num = val_num value and as_bool = val_bool value and as_str = val_str value in
  let doc = model#document in
  let found = ref false in
  let applied = ref false in
  let abs = List.map (fun ab ->
    if ab.Artboard.id = id then begin
      found := true;
      let updated, ok = match field with
        | "name" -> (match as_str with Some s -> { ab with Artboard.name = s }, true | None -> ab, false)
        | "x" -> (match as_num with Some n -> { ab with Artboard.x = n }, true | None -> ab, false)
        | "y" -> (match as_num with Some n -> { ab with Artboard.y = n }, true | None -> ab, false)
        | "width" -> (match as_num with Some n -> { ab with Artboard.width = n }, true | None -> ab, false)
        | "height" -> (match as_num with Some n -> { ab with Artboard.height = n }, true | None -> ab, false)
        | "fill" -> (match as_str with Some s -> { ab with Artboard.fill = Artboard.fill_from_canonical s }, true | None -> ab, false)
        | "show_center_mark" -> (match as_bool with Some b -> { ab with Artboard.show_center_mark = b }, true | None -> ab, false)
        | "show_cross_hairs" -> (match as_bool with Some b -> { ab with Artboard.show_cross_hairs = b }, true | None -> ab, false)
        | "show_video_safe_areas" -> (match as_bool with Some b -> { ab with Artboard.show_video_safe_areas = b }, true | None -> ab, false)
        | "video_ruler_pixel_aspect_ratio" -> (match as_num with Some n -> { ab with Artboard.video_ruler_pixel_aspect_ratio = n }, true | None -> ab, false)
        | _ -> ab, false in
      if ok then applied := true;
      updated
    end else ab
  ) doc.Document.artboards in
  if !found && !applied then begin
    model#set_document { doc with Document.artboards = abs };
    true
  end else false

(* Apply one document-global artboard-options field (bool only). *)
let apply_set_artboard_options_field (model : Model.model) (field : string)
    (value : Yojson.Safe.t) : bool =
  match val_bool value with
  | None -> false
  | Some flag ->
    let doc = model#document in
    let opts = doc.Document.artboard_options in
    let updated, ok = match field with
      | "fade_region_outside_artboard" -> { opts with Artboard.fade_region_outside_artboard = flag }, true
      | "update_while_dragging" -> { opts with Artboard.update_while_dragging = flag }, true
      | _ -> opts, false in
    if ok then begin
      model#set_document { doc with Document.artboard_options = updated };
      true
    end else false

(* Delete the artboard whose id == [id]. Returns true iff one was removed. *)
let apply_delete_artboard_by_id (model : Model.model) (id : string) : bool =
  let doc = model#document in
  let abs = List.filter (fun ab -> ab.Artboard.id <> id) doc.Document.artboards in
  if List.length abs < List.length doc.Document.artboards then begin
    model#set_document { doc with Document.artboards = abs };
    true
  end else false

(* Swap-with-neighbor-skipping-selected for Move Up, on the artboard list.
   Returns (new_list, changed). Pure helper. *)
let move_artboards_up_in_place (abs : Artboard.artboard list)
    (selected_ids : string list) : Artboard.artboard list * bool =
  let arr = Array.of_list abs in
  let is_sel id = List.mem id selected_ids in
  let changed = ref false in
  for i = 0 to Array.length arr - 1 do
    if is_sel arr.(i).Artboard.id && i > 0
       && not (is_sel arr.(i - 1).Artboard.id) then begin
      let tmp = arr.(i - 1) in arr.(i - 1) <- arr.(i); arr.(i) <- tmp;
      changed := true
    end
  done;
  (Array.to_list arr, !changed)

(* Symmetric Move Down. *)
let move_artboards_down_in_place (abs : Artboard.artboard list)
    (selected_ids : string list) : Artboard.artboard list * bool =
  let arr = Array.of_list abs in
  let n = Array.length arr in
  let is_sel id = List.mem id selected_ids in
  let changed = ref false in
  for i = n - 1 downto 0 do
    if is_sel arr.(i).Artboard.id && i + 1 < n
       && not (is_sel arr.(i + 1).Artboard.id) then begin
      let tmp = arr.(i + 1) in arr.(i + 1) <- arr.(i); arr.(i) <- tmp;
      changed := true
    end
  done;
  (Array.to_list arr, !changed)

let apply_move_artboards_up (model : Model.model) (ids : string list) : bool =
  let doc = model#document in
  let abs, changed = move_artboards_up_in_place doc.Document.artboards ids in
  if changed then (model#set_document { doc with Document.artboards = abs }; true) else false

let apply_move_artboards_down (model : Model.model) (ids : string list) : bool =
  let doc = model#document in
  let abs, changed = move_artboards_down_in_place doc.Document.artboards ids in
  if changed then (model#set_document { doc with Document.artboards = abs }; true) else false

(* ── Artboard id-minting verbs (OP_LOG.md section 9 Phase P3) ─────────────────
   VALUE-IN-OP: the id is minted ONCE at production capture time and recorded as
   a LITERAL; this layer reads id/new_id VERBATIM and NEVER mints / taps
   entropy / runs collision-retry. *)

(* Append a new artboard with the GIVEN id, applying RESOLVED [fields]
   overrides on top of the canonical default. Always an effective change. *)
let apply_create_artboard (model : Model.model) (id : string)
    (fields : Yojson.Safe.t) : unit =
  let doc = model#document in
  let ab0 = Artboard.default_with_id id in
  let ab = match fields with
    | `Assoc kvs -> List.fold_left (fun ab (field, value) ->
        apply_artboard_field_in_place ab field value) ab0 kvs
    | _ -> ab0 in
  model#set_document { doc with Document.artboards = doc.Document.artboards @ [ab] }

(* Clone the artboard whose id == [source_id], assign the GIVEN [new_id] /
   [name] VERBATIM, and offset by ([ox], [oy]). Returns true iff the source
   existed (a missing source is a no-op that journals nothing). *)
let apply_duplicate_artboard (model : Model.model) (source_id : string)
    (new_id : string) (name : string) (ox : float) (oy : float) : bool =
  let doc = model#document in
  match List.find_opt (fun ab -> ab.Artboard.id = source_id) doc.Document.artboards with
  | None -> false
  | Some source ->
    let dup = { source with
                Artboard.id = new_id; name;
                x = source.Artboard.x +. ox;
                y = source.Artboard.y +. oy } in
    model#set_document { doc with Document.artboards = doc.Document.artboards @ [dup] };
    true

(* ── Structural tree-mutation verbs (OP_LOG.md section 9 Phase P4) ────────────
   delete_at / delete_selection / insert_after / insert_at mutate the element
   TREE. The inserting verbs carry the WHOLE element as value-in-op. *)

(* Defensive get: returns [None] for a malformed / out-of-range path rather
   than raising (Document.get_element raises on a bad path). *)
let get_element_opt (doc : Document.document) (path : int list) :
    Element.element option =
  try Some (Document.get_element doc path) with _ -> None

(* Delete the element at [path]. Returns (changed, targets). *)
let apply_delete_element_at (model : Model.model) (path : int list) :
    bool * string list =
  let doc = model#document in
  match get_element_opt doc path with
  | None -> (false, [])
  | Some existing ->
    let targets = match element_id existing with Some id -> [id] | None -> [] in
    model#set_document (Document.delete_element doc path);
    (true, targets)

(* Delete every currently-selected element. Returns (changed, targets). *)
let apply_delete_selection (model : Model.model) : bool * string list =
  let doc = model#document in
  if Document.PathMap.is_empty doc.Document.selection then (false, [])
  else begin
    let targets = Controller.selection_to_ids doc in
    model#set_document (Document.delete_selection doc);
    (true, targets)
  end

(* Insert [element] immediately after [path] (value-in-op). Returns targets. *)
let apply_insert_element_after (model : Model.model) (path : int list)
    (element : Element.element) : string list =
  let targets = match element_id element with Some id -> [id] | None -> [] in
  model#set_document (Document.insert_element_after model#document path element);
  targets

(* Insert [element] at [index] under [parent_path] (an empty parent inserts
   into the top-level layers array). Returns targets. *)
let apply_insert_element_at (model : Model.model) (parent_path : int list)
    (index : int) (element : Element.element) : string list =
  let targets = match element_id element with Some id -> [id] | None -> [] in
  let doc = model#document in
  (* Both the top-level ([\[idx\]]) and nested ([parent @ \[index\]]) cases go
     through [insert_element_at], which clamps the final index to [0, len]. *)
  let new_doc = Document.insert_element_at doc (parent_path @ [index]) element in
  model#set_document new_doc;
  targets

(* ── Group/layer wrapping verbs (OP_LOG.md section 9 Phase P5) ────────────────
   wrap_in_group / wrap_in_layer / unpack_group_at: each is a MULTI-STEP
   mutation that replays as ONE deterministic op. *)

(* Collect (in sorted document order) clones of the elements at [paths], plus
   their ids. Returns (children, child_ids, sorted_paths). A path that resolves
   to nothing is silently dropped. *)
let collect_children_for_wrap (doc : Document.document) (paths : int list list) :
    Element.element list * string list * int list list =
  let sorted = List.sort compare paths in
  let children = ref [] and ids = ref [] in
  List.iter (fun p ->
    match get_element_opt doc p with
    | Some elem ->
      (match element_id elem with Some id -> ids := id :: !ids | None -> ());
      children := elem :: !children
    | None -> ()
  ) sorted;
  (List.rev !children, List.rev !ids, sorted)

(* Wrap the elements at [paths] in a new Group. Reverse-deletes the sources,
   builds a Group carrying them (with the optional value-in-op [id]), inserts
   it at the TOPMOST source index under the shared parent. *)
let apply_wrap_in_group (model : Model.model) (paths : int list list)
    (id : string option) : bool * string list =
  let doc = model#document in
  let children, child_ids, sorted = collect_children_for_wrap doc paths in
  if children = [] then (false, [])
  else
    match sorted with
    | first :: _ when first <> [] ->
      let rev_first = List.rev first in
      let insert_index = List.hd rev_first in
      let insert_parent = List.rev (List.tl rev_first) in
      (* Reverse-delete the sources (descending paths keep indices valid). *)
      let new_doc = ref doc in
      List.iter (fun p -> new_doc := Document.delete_element !new_doc p)
        (List.rev sorted);
      let group = Element.make_group (Array.of_list children) in
      let group = match id with Some i -> Element.with_id group (Some i) | None -> group in
      let targets = child_ids @ (match id with Some i -> [i] | None -> []) in
      (* Insert at the topmost source slot (empty parent -> top-level layers,
         handled uniformly by insert_element_at via the [\[idx\]] path). *)
      let final_doc =
        Document.insert_element_at !new_doc (insert_parent @ [insert_index]) group
      in
      model#set_document final_doc;
      (true, targets)
    | _ -> (false, [])

(* Wrap the elements at [paths] in a new top-level Layer with the RESOLVED
   [name] LITERAL. Always APPENDS the new Layer to the top-level layers. *)
let apply_wrap_in_layer (model : Model.model) (paths : int list list)
    (name : string) (id : string option) : bool * string list =
  let doc = model#document in
  let children, child_ids, sorted = collect_children_for_wrap doc paths in
  if children = [] then (false, [])
  else begin
    let new_doc = ref doc in
    List.iter (fun p -> new_doc := Document.delete_element !new_doc p)
      (List.rev sorted);
    let layer = Element.make_layer ~name (Array.of_list children) in
    let layer = match id with Some i -> Element.with_id layer (Some i) | None -> layer in
    let targets = child_ids @ (match id with Some i -> [i] | None -> []) in
    model#set_document
      { !new_doc with Document.layers =
          Array.append !new_doc.Document.layers [| layer |] };
    (true, targets)
  end

(* Unpack the Group at [path]: extract its children, delete the group, and
   re-insert the children at the vacated position with ascending indices
   (children keep their ids — NO minting). A non-Group target (or absent path)
   is a no-op. *)
let apply_unpack_group_at (model : Model.model) (path : int list) :
    bool * string list =
  let doc = model#document in
  match get_element_opt doc path with
  | Some (Element.Group { children; _ }) ->
    let children = Array.to_list children in
    let targets = List.filter_map element_id children in
    let new_doc = ref (Document.delete_element doc path) in
    (* Insert children at the vacated position, ascending the final index. *)
    let rev_path = List.rev path in
    let last0 = List.hd rev_path and prefix = List.rev (List.tl rev_path) in
    List.iteri (fun i child ->
      new_doc := Document.insert_element_at !new_doc (prefix @ [last0 + i]) child
    ) children;
    model#set_document !new_doc;
    (true, targets)
  | _ -> (false, [])

(* ── set_attr_on_selection (OP_LOG.md section 9 Phase P6) ─────────────────────
   Applies one brush attribute to every selected Path through a Controller
   mutator. Phase 1 supports stroke_brush / stroke_brush_overrides; the
   empty-string value clears (None). The no-op detection compares the element
   trees directly because document_to_test_json omits the brush fields. *)
let apply_set_attr_on_selection (model : Model.model) (ctrl : Controller.controller)
    (attr : string) (value : string option) : bool * string list =
  if attr <> "stroke_brush" && attr <> "stroke_brush_overrides" then (false, [])
  else begin
    let targets = Controller.selection_to_ids model#document in
    let before = model#document.Document.layers in
    (match attr with
     | "stroke_brush" -> ctrl#set_selection_stroke_brush value
     | "stroke_brush_overrides" -> ctrl#set_selection_stroke_brush_overrides value
     | _ -> ());
    let changed = model#document.Document.layers <> before in
    (changed, targets)
  end

(* ── Transform trio (OP_LOG.md section 9 Phase P7) ────────────────────────────
   scale_transform / rotate_transform / shear_transform journal the CONFIRM
   apply: each records one transform op carrying the RESOLVED matrix params and
   writes a BRACKETED edit. An IDENTITY transform is a no-op that journals
   nothing. The matrix compose is SHARED with the production confirm path. *)

(* The resolved selection path list (PathMap key order, sorted). *)
let selection_paths (doc : Document.document) : int list list =
  Document.PathMap.fold (fun path _ acc -> path :: acc) doc.Document.selection []
  |> List.rev

(* Multiply the element stroke width by [factor] (no-op without a stroke). *)
let scale_elem_stroke_width (factor : float) (elem : Element.element) :
    Element.element =
  match elem with
  | Element.Line { stroke = Some s; _ } | Element.Rect { stroke = Some s; _ }
  | Element.Circle { stroke = Some s; _ } | Element.Ellipse { stroke = Some s; _ }
  | Element.Polyline { stroke = Some s; _ } | Element.Polygon { stroke = Some s; _ }
  | Element.Path { stroke = Some s; _ } ->
    Element.with_stroke elem (Some { s with Element.stroke_width = s.Element.stroke_width *. factor })
  | _ -> elem

(* Scale a rounded-rect rx/ry in place (no-op on other element types). *)
let scale_elem_corners (sx_abs : float) (sy_abs : float) (elem : Element.element) :
    Element.element =
  match elem with
  | Element.Rect r -> Element.Rect { r with rx = r.rx *. sx_abs; ry = r.ry *. sy_abs }
  | _ -> elem

(* Compose [matrix] against every element at [paths] (pre-multiplying its
   existing transform), returning the new document. When [stroke_factor] is
   [Some], each element stroke width is multiplied by it; when [corners] is
   [Some (sx_abs, sy_abs)], rounded-rect radii are scaled. An absent element at
   a path is silently skipped. *)
let compose_matrix_over_paths (doc : Document.document) (paths : int list list)
    (matrix : Element.transform) (stroke_factor : float option)
    (corners : (float * float) option) : Document.document =
  List.fold_left (fun d path ->
    match get_element_opt d path with
    | None -> d
    | Some elem ->
      let elem = Element.with_transform_premultiplied matrix elem in
      let elem = match stroke_factor with Some f -> scale_elem_stroke_width f elem | None -> elem in
      let elem = match corners with Some (a, b) -> scale_elem_corners a b elem | None -> elem in
      Document.replace_element d path elem
  ) doc paths

let apply_scale (model : Model.model) (sx : float) (sy : float)
    (rx : float) (ry : float) (scale_strokes : bool) (scale_corners : bool) :
    bool * string list =
  if abs_float (sx -. 1.0) < 1e-9 && abs_float (sy -. 1.0) < 1e-9 then (false, [])
  else begin
    let targets = Controller.selection_to_ids model#document in
    let matrix = Transform_apply.scale_matrix ~sx ~sy ~rx ~ry in
    let stroke_factor =
      if scale_strokes then Some (Transform_apply.stroke_width_factor ~sx ~sy)
      else None in
    let corners = if scale_corners then Some (abs_float sx, abs_float sy) else None in
    let paths = selection_paths model#document in
    model#set_document
      (compose_matrix_over_paths model#document paths matrix stroke_factor corners);
    (true, targets)
  end

let apply_rotate (model : Model.model) (theta_deg : float)
    (rx : float) (ry : float) : bool * string list =
  if abs_float theta_deg < 1e-9 then (false, [])
  else begin
    let targets = Controller.selection_to_ids model#document in
    let matrix = Transform_apply.rotate_matrix ~theta_deg ~rx ~ry in
    let paths = selection_paths model#document in
    model#set_document (compose_matrix_over_paths model#document paths matrix None None);
    (true, targets)
  end

let apply_shear (model : Model.model) (angle_deg : float) (axis : string)
    (axis_angle_deg : float) (rx : float) (ry : float) : bool * string list =
  if abs_float angle_deg < 1e-9 then (false, [])
  else begin
    let targets = Controller.selection_to_ids model#document in
    let matrix = Transform_apply.shear_matrix ~angle_deg ~axis ~axis_angle_deg ~rx ~ry in
    let paths = selection_paths model#document in
    model#set_document (compose_matrix_over_paths model#document paths matrix None None);
    (true, targets)
  end

(* The eight print-config field setter verbs. *)
let print_config_verbs = [
  "set_color_management_field"; "set_document_setup_field"; "set_graphics_field";
  "set_marks_and_bleed_field"; "set_output_field"; "set_output_ink_field";
  "set_print_preferences_field"; "set_advanced_field";
]

let op_apply (model : Model.model) (ctrl : Controller.controller)
    (op : Yojson.Safe.t) : unit =
  match member "op" op with
  | `String name ->
    (* History-navigation ops (OP_LOG.md section 5): they manage transaction
       boundaries / the journal cursor and are NOT primitive ops, so they are
       never journaled. *)
    (match name with
     | "snapshot" -> model#commit_txn; model#begin_txn
     | "undo" -> model#undo
     | "redo" -> model#redo
     | _ ->
       (* OP_LOG.md section 9 — close the subsequent-drag-frame journaling hole.
          Every verb below except [select_rect] is an UNDOABLE mutation. OCaml
          [Model.set_document] does NOT self-bracket the way Rust [edit_document]
          does, so this lazy [begin_txn] is the ONLY safeguard against a bare
          drag frame losing its op. [begin_txn] is a no-op while one is already
          open. [select_rect] is EXCLUDED (selection-only, journal-neutral).
          [select_by_ids] is the id-primary twin (selection-only, non-undoable),
          so it is excluded for the identical reason. *)
       if name <> "select_rect" && name <> "select_by_ids" then model#begin_txn;
       (* Fork-4 [targets] (OP_LOG.md section 9). Populated for the replay-safe
          verbs; every other verb keeps it empty unless its arm sets it. *)
       let targets = ref [] in
       if name = "move_selection" || name = "copy_selection" then
         targets := Controller.selection_to_ids model#document;
       let proceed = ref true in
       (match name with
        | "select_rect" ->
          let extend = bool_field op "extend" in
          ctrl#select_rect ~extend
            (num_field op "x") (num_field op "y")
            (num_field op "width") (num_field op "height");
          targets := Controller.selection_to_ids model#document
        | "move_selection" ->
          ctrl#move_selection (num_field op "dx") (num_field op "dy")
        | "copy_selection" ->
          ctrl#copy_selection (num_field op "dx") (num_field op "dy")
        (* ── id-primary op family (OP_LOG.md section 5 Fork 4 /
           RECORDED_ELEMENTS.md) ──
           Operand ids come from the OP-OWN PARAMS (never doc.selection), so
           snapshot and replay apply identical operands (the section 7
           determinism rule). Each [*_by_ids] re-establishes the working
           selection from its own ids (via the SHARED [apply_select_by_ids]
           body) BEFORE routing through the SAME [Controller] mutator the
           selection-relative verb uses, so the replayed document+selection is
           byte-identical to [select_rect, move] (the byte-gate reconciliation,
           OP_LOG.md section 6). *)
        | "select_by_ids" ->
          (* Selection-only / non-undoable (like select_rect): write the
             resolved selection BY PATH in document order; targets = the
             resolved ids (the keystone the recipe seeds its working set from). *)
          targets := apply_select_by_ids model ctrl (str_list_field op "ids")
        | "move_by_ids" ->
          (* Set the working selection from the OP-OWN ids, then run the SAME
             mutator [move_selection] uses. targets = the operand ids (from
             params, resolved to the selection) — never inferred post-mutation. *)
          targets := apply_select_by_ids model ctrl (str_list_field op "ids");
          ctrl#move_selection (num_field op "dx") (num_field op "dy")
        | "copy_by_ids" ->
          (* Set the working selection from the OP-OWN [from] ids, then run the
             SAME mutator [copy_selection] uses. targets = the source ids (the
             produced copies are born id-less, so the source is the operand). *)
          targets := apply_select_by_ids model ctrl (str_list_field op "from");
          ctrl#copy_selection (num_field op "dx") (num_field op "dy")
        | "assign_id" ->
          (match parse_path op "path", str_field op "id" with
           | Some path, Some id -> ctrl#assign_id path id
           | _ -> proceed := false)
        | "create_reference" ->
          (match parse_path op "target_path",
                 str_field op "target_id", str_field op "ref_id" with
           | Some target_path, Some target_id, Some ref_id ->
             ctrl#create_reference target_path target_id ref_id
           | _ -> proceed := false)
        | "make_symbol" ->
          (match parse_path op "path",
                 str_field op "master_id", str_field op "ref_id" with
           | Some path, Some master_id, Some ref_id ->
             ctrl#make_symbol path master_id ref_id
           | _ -> proceed := false)
        | "place_instance" ->
          (match str_field op "master_id", str_field op "ref_id" with
           | Some master_id, Some ref_id ->
             ctrl#place_instance master_id ref_id
           | _ -> proceed := false)
        (* Concept-pack ops (CONCEPTS.md section 6-7). The two verbs the Concepts
           panel emits, given journal-replay arms so a placed/edited concept
           instance survives capture and replay byte-identically (the section 7
           determinism rule). Both carry every operand VALUE-IN-OP: the concept
           id, the RESOLVED default params, and the minted elem id (place); the
           path, param name, and committed value (set). Nothing is re-derived on
           replay (the registry could have changed), so replay reconstructs the
           exact Generated instance the live edit produced. A malformed payload
           SKIPS (never raises, never journals). *)
        | "place_concept_instance" ->
          (match str_field op "concept_id", str_field op "elem_id" with
           | Some concept_id, Some elem_id ->
             let params = match member "params" op with
               | `Assoc _ as p -> p
               | _ -> `Assoc [] in
             ctrl#place_concept_instance concept_id params elem_id
           | _ -> proceed := false)
        | "set_concept_param" ->
          (match parse_path op "path", str_field op "name" with
           | Some path, Some name ->
             ctrl#set_concept_param path name (num_field op "value")
           | _ -> proceed := false)
        (* Apply a concept operation (CONCEPTS.md section 9). [op_id] rides as
           journal metadata (the semantic verb) and is NOT consulted for the
           mutation; [changes] is the production-RESOLVED param map (value-in-op)
           that is actually applied — replay merges it and never re-evaluates the
           operation's expressions nor consults the registry. A malformed/missing
           path or non-object changes SKIPS (the controller also no-ops on an
           empty / non-object changes, so nothing journals). *)
        | "apply_concept_operation" ->
          (match parse_path op "path", member "changes" op with
           | Some path, (`Assoc _ as changes) ->
             ctrl#apply_concept_operation path changes
           | _ -> proceed := false)
        | "detach" ->
          (match parse_path op "path" with
           | Some path -> ctrl#detach path
           | None -> proceed := false)
        | "redefine" ->
          (match str_field op "master_id", parse_path op "path",
                 str_field op "ref_id" with
           | Some master_id, Some path, Some ref_id ->
             ctrl#redefine master_id path ref_id
           | _ -> proceed := false)
        | "delete_symbol" ->
          (match str_field op "master_id" with
           | Some master_id -> ctrl#delete_symbol master_id
           | None -> proceed := false)
        | "set_instance_transform" ->
          (match parse_path op "path", member "transform" op with
           | Some path, (`Assoc _ as t) ->
             let transform = {
               Element.a = num_field t "a"; b = num_field t "b";
               c = num_field t "c"; d = num_field t "d";
               e = num_field t "e"; f = num_field t "f";
             } in
             ctrl#set_instance_transform path transform
           | _ -> proceed := false)
        (* Structural tree-mutation verbs (Phase P4). *)
        | "delete_at" ->
          (match parse_path op "path" with
           | Some path ->
             let changed, t = apply_delete_element_at model path in
             if changed then targets := t else proceed := false
           | None -> proceed := false)
        | "delete_selection" ->
          let changed, t = apply_delete_selection model in
          if changed then targets := t else proceed := false
        | "insert_after" ->
          (match parse_path op "path", parse_element op with
           | Some path, Some element ->
             targets := apply_insert_element_after model path element
           | _ -> proceed := false)
        | "insert_at" ->
          (match parse_path op "parent_path", parse_element op with
           | Some parent_path, Some element ->
             let index = match member "index" op with
               | `Int n -> n | `Float f -> int_of_float f | _ -> 0 in
             targets := apply_insert_element_at model parent_path index element
           | _ -> proceed := false)
        (* Group/layer wrapping verbs (Phase P5). *)
        | "wrap_in_group" ->
          (match parse_path_list op "paths" with
           | Some [] -> proceed := false
           | Some paths ->
             let changed, t = apply_wrap_in_group model paths (str_field op "id") in
             if changed then targets := t else proceed := false
           | None -> proceed := false)
        | "wrap_in_layer" ->
          (match parse_path_list op "paths" with
           | Some [] -> proceed := false
           | Some paths ->
             let name = match str_field op "name" with Some s -> s | None -> "" in
             let changed, t = apply_wrap_in_layer model paths name (str_field op "id") in
             if changed then targets := t else proceed := false
           | None -> proceed := false)
        | "unpack_group_at" ->
          (match parse_path op "path" with
           | Some path ->
             let changed, t = apply_unpack_group_at model path in
             if changed then targets := t else proceed := false
           | None -> proceed := false)
        | "lock_selection" -> ctrl#lock_selection
        | "unlock_all" -> ctrl#unlock_all
        | "hide_selection" -> ctrl#hide_selection
        | "show_all" -> ctrl#show_all
        (* set_attr_on_selection (Phase P6). *)
        | "set_attr_on_selection" ->
          (match str_field op "attr", member "value" op with
           | Some attr, (`String _ as v) ->
             let value = match v with
               | `String "" -> None
               | `String s -> Some s
               | _ -> None in
             let changed, t = apply_set_attr_on_selection model ctrl attr value in
             if changed then targets := t else proceed := false
           | _ -> proceed := false)
        (* Transform trio (Phase P7). *)
        | "scale_transform" ->
          let sx = num_field op "sx" and sy = num_field op "sy" in
          let rx = num_field op "rx" and ry = num_field op "ry" in
          let scale_strokes = match member "scale_strokes" op with `Bool b -> b | _ -> true in
          let scale_corners = match member "scale_corners" op with `Bool b -> b | _ -> false in
          let changed, t = apply_scale model sx sy rx ry scale_strokes scale_corners in
          if changed then targets := t else proceed := false
        | "rotate_transform" ->
          let angle = num_field op "angle" in
          let rx = num_field op "rx" and ry = num_field op "ry" in
          let changed, t = apply_rotate model angle rx ry in
          if changed then targets := t else proceed := false
        | "shear_transform" ->
          let angle = num_field op "angle" in
          let axis = match str_field op "axis" with Some s -> s | None -> "horizontal" in
          let axis_angle = num_field op "axis_angle" in
          let rx = num_field op "rx" and ry = num_field op "ry" in
          let changed, t = apply_shear model angle axis axis_angle rx ry in
          if changed then targets := t else proceed := false
        | "boolean_union" ->
          Boolean_apply.apply_destructive_boolean model "union"
        | "simplify" ->
          let precision =
            match member "precision" op with
            | `Float f -> f | `Int i -> float_of_int i | _ -> 0.5 in
          ctrl#simplify_selection precision
        (* Print-config field setters (Phase P1). *)
        | _ when List.mem name print_config_verbs ->
          (match str_field op "field", member "value" op with
           | Some field, value when value <> `Null ->
             let index = match member "index" op with
               | `Int n -> n | `Float f -> int_of_float f | _ -> 0 in
             if not (apply_print_config_field model name field value index) then
               proceed := false
           | _ -> proceed := false)
        (* Artboard doc.* setters (Phase P2). *)
        | "set_artboard_field" ->
          (match str_field op "id", str_field op "field", member "value" op with
           | Some id, Some field, value when value <> `Null ->
             if apply_set_artboard_field model id field value then targets := [id]
             else proceed := false
           | _ -> proceed := false)
        | "set_artboard_options_field" ->
          (match str_field op "field", member "value" op with
           | Some field, value when value <> `Null ->
             if not (apply_set_artboard_options_field model field value) then proceed := false
           | _ -> proceed := false)
        | "delete_artboard_by_id" ->
          (match str_field op "id" with
           | Some id ->
             if apply_delete_artboard_by_id model id then targets := [id]
             else proceed := false
           | None -> proceed := false)
        | "move_artboards_up" ->
          let ids = str_list_field op "ids" in
          if apply_move_artboards_up model ids then targets := ids
          else proceed := false
        | "move_artboards_down" ->
          let ids = str_list_field op "ids" in
          if apply_move_artboards_down model ids then targets := ids
          else proceed := false
        (* Artboard id-minting verbs (Phase P3). *)
        | "create_artboard" ->
          (match str_field op "id" with
           | Some id when id <> "" ->
             let fields = member "fields" op in
             apply_create_artboard model id fields;
             targets := [id]
           | _ -> proceed := false)
        | "duplicate_artboard" ->
          (match str_field op "id", str_field op "new_id" with
           | Some source_id, Some new_id when source_id <> "" && new_id <> "" ->
             let name = match str_field op "name" with Some s -> s | None -> "" in
             let ox = num_field op "offset_x" and oy = num_field op "offset_y" in
             if apply_duplicate_artboard model source_id new_id name ox oy then
               targets := [new_id]
             else proceed := false
           | _ -> proceed := false)
        | _ ->
          (* Unknown verb: a malformed/unsupported production payload is skipped
             rather than raising. *)
          proceed := false);
       (* Capture the op into the open transaction so the journal replays to the
          same document — the checkpoint_equivalence gate. [record_op] is a
          no-op when no transaction is open. [params] carries the full op value
          verbatim; the journal serializer strips the redundant "op" key. *)
       if !proceed then
         model#record_op
           (Op_log.make_primitive_op ~op:name ~params:op ~targets:!targets ()))
  | _ ->
    (* A primitive op with no verb is malformed; skip it (never raise). *)
    ()
