(** SVG opacity normalizer.

    Extracts color alpha into fill/stroke opacity (multiplicative),
    then sets color alpha to 1.0.  This ensures that element
    transparency is expressed through opacity attributes rather than
    color alpha channels. *)

let rec normalize_document (doc : Document.document) =
  Document.make_document (Array.map normalize_element doc.Document.layers)

and normalize_fill (f : Element.fill) =
  let alpha = Element.color_alpha f.fill_color in
  Element.make_fill ~opacity:(f.fill_opacity *. alpha) (Element.color_with_alpha 1.0 f.fill_color)

and normalize_stroke (s : Element.stroke) =
  let alpha = Element.color_alpha s.stroke_color in
  Element.make_stroke ~width:s.stroke_width ~linecap:s.stroke_linecap ~linejoin:s.stroke_linejoin
    ~opacity:(s.stroke_opacity *. alpha) (Element.color_with_alpha 1.0 s.stroke_color)

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
