(** SVG opacity normalizer.

    Extracts color alpha into fill/stroke opacity (multiplicative),
    then sets color alpha to 1.0.  This ensures that element
    transparency is expressed through opacity attributes rather than
    color alpha channels. *)

let rec normalize_document (doc : Document.document) =
  Document.make_document
    ~document_setup:doc.Document.document_setup
    ~print_preferences:doc.Document.print_preferences
    (Array.map normalize_element doc.Document.layers)

and normalize_fill (f : Element.fill) =
  let alpha = Element.color_alpha f.fill_color in
  Element.make_fill ~opacity:(f.fill_opacity *. alpha) (Element.color_with_alpha 1.0 f.fill_color)

and normalize_stroke (s : Element.stroke) =
  (* Preserve every Stroke field — only the color alpha is folded
     into opacity. Earlier versions of this function dropped
     stroke_dash_pattern, stroke_miter_limit, stroke_align, arrows,
     and stroke_dash_align_anchors, silently losing them on every
     SVG round-trip. *)
  let alpha = Element.color_alpha s.stroke_color in
  Element.make_stroke
    ~width:s.stroke_width
    ~linecap:s.stroke_linecap
    ~linejoin:s.stroke_linejoin
    ~miter_limit:s.stroke_miter_limit
    ~align:s.stroke_align
    ~dash_pattern:s.stroke_dash_pattern
    ~dash_align_anchors:s.stroke_dash_align_anchors
    ~start_arrow:s.stroke_start_arrow
    ~end_arrow:s.stroke_end_arrow
    ~start_arrow_scale:s.stroke_start_arrow_scale
    ~end_arrow_scale:s.stroke_end_arrow_scale
    ~arrow_align:s.stroke_arrow_align
    ~opacity:(s.stroke_opacity *. alpha)
    (Element.color_with_alpha 1.0 s.stroke_color)

and normalize_element = function
  | Element.Line e ->
    Element.Line { e with stroke = Option.map normalize_stroke e.stroke }
  | Element.Rect e ->
    Element.Rect { e with fill = Option.map normalize_fill e.fill;
                          stroke = Option.map normalize_stroke e.stroke }
  | Element.Circle e ->
    Element.Circle { e with fill = Option.map normalize_fill e.fill;
                            stroke = Option.map normalize_stroke e.stroke }
  | Element.Ellipse e ->
    Element.Ellipse { e with fill = Option.map normalize_fill e.fill;
                             stroke = Option.map normalize_stroke e.stroke }
  | Element.Polyline e ->
    Element.Polyline { e with fill = Option.map normalize_fill e.fill;
                              stroke = Option.map normalize_stroke e.stroke }
  | Element.Polygon e ->
    Element.Polygon { e with fill = Option.map normalize_fill e.fill;
                             stroke = Option.map normalize_stroke e.stroke }
  | Element.Path e ->
    Element.Path { e with fill = Option.map normalize_fill e.fill;
                          stroke = Option.map normalize_stroke e.stroke }
  | Element.Text e ->
    Element.Text { e with fill = Option.map normalize_fill e.fill;
                          stroke = Option.map normalize_stroke e.stroke }
  | Element.Text_path e ->
    Element.Text_path { e with fill = Option.map normalize_fill e.fill;
                               stroke = Option.map normalize_stroke e.stroke }
  | Element.Group e ->
    Element.Group { e with children = Array.map normalize_element e.children }
  | Element.Layer e ->
    Element.Layer { e with children = Array.map normalize_element e.children }
  | Element.Live v ->
    (* Phase 1: pass through unchanged. Phase 2 will recursively
       normalize operands + fill / stroke. *)
    Element.Live v

(* Enforce the unique-id invariant after import (REFERENCE_GRAPH.md section 2.5):
   walk the document in canonical pre-order; the FIRST element to use a given
   id keeps it, and every later element carrying the same id has its id cleared
   to None (first-pre-order-wins). Element ids are then unique within the
   document, so the live-reference index never collides. A no-op on a document
   whose ids are already unique (the normal case) — well-formed documents
   round-trip unchanged; only ill-formed (e.g. foreign-SVG) duplicates are
   normalized. Recurse into Group and Layer children only, mirroring clear_ids.
   Called by every document reader. *)
let dedupe_element_ids (doc : Document.document) =
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  let rec walk elem =
    let elem =
      match Element.id_of elem with
      | Some id when Hashtbl.mem seen id ->
        (* Already seen — this is a later duplicate, so clear its id. *)
        Element.with_id elem None
      | Some id ->
        Hashtbl.replace seen id ();
        elem
      | None -> elem
    in
    match elem with
    | Element.Group r -> Element.Group { r with children = Array.map walk r.children }
    | Element.Layer r -> Element.Layer { r with children = Array.map walk r.children }
    | _ -> elem
  in
  { doc with Document.layers = Array.map walk doc.Document.layers }
