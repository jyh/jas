(** Render a named workspace icon (from icons.yaml) as a [GdkPixbuf.pixbuf].

    Looks up the icon's [viewbox] + [svg] fragment, substitutes
    [currentColor] with the supplied tint hex, builds a complete SVG
    document, writes it to a tempfile, and loads it via
    [GdkPixbuf.from_file_at_size]. GdkPixbuf's SVG support (via
    librsvg) handles the same primitive set the canvas uses
    (rect / line / circle / ellipse / polyline / polygon / path /
    text), so unlike the Swift port we don't need a hand-rolled SVG
    parser.

    Used by [Yaml_panel_view.render_button] when an ``icon_button``
    widget needs a glyph image instead of a long summary-text label. *)

(** Build a pixbuf for the named icon at [size] x [size] pixels,
    tinting [currentColor] strokes/fills with [tint] (a "#rrggbb"
    string).
    Raises [Not_found] if the icon name doesn't exist in the
    workspace icons map, or [Failure] if librsvg fails to parse the
    constructed SVG. The caller's ``try ... with _ -> None`` is the
    intended fallback path. *)
let pixbuf_for_name (name : string) (size : int) (tint : string) :
    GdkPixbuf.pixbuf =
  let ws = match Workspace_loader.load () with
    | Some w -> w
    | None -> raise Not_found
  in
  let icons = Workspace_loader.icons ws in
  let icon_def = match icons with
    | `Assoc pairs -> List.assoc_opt name pairs
    | _ -> None
  in
  let viewbox, svg_fragment = match icon_def with
    | Some (`Assoc pairs) ->
      let vb = match List.assoc_opt "viewbox" pairs with
        | Some (`String s) -> s
        | _ -> "0 0 16 16"
      in
      let svg = match List.assoc_opt "svg" pairs with
        | Some (`String s) -> s
        | _ -> ""
      in
      vb, svg
    | _ -> raise Not_found
  in
  if svg_fragment = "" then raise Not_found;
  (* librsvg rejects `currentColor` at the document root with no
     stylesheet to resolve it against; substitute the tint hex
     directly so the icon renders with the active theme color. *)
  let tinted = Str.global_replace
    (Str.regexp_string "currentColor") tint svg_fragment in
  let svg_doc = Printf.sprintf
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"%s\" \
     width=\"%d\" height=\"%d\">%s</svg>" viewbox size size tinted in
  let tmp = Filename.temp_file "jas_icon" ".svg" in
  let oc = open_out tmp in
  output_string oc svg_doc;
  close_out oc;
  let result =
    try
      let pb = GdkPixbuf.from_file_at_size tmp ~width:size ~height:size in
      Some pb
    with _ -> None
  in
  (try Sys.remove tmp with _ -> ());
  match result with
  | Some pb -> pb
  | None -> failwith ("Workspace_icon: failed to load " ^ name)
