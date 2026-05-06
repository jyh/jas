(** Render a named workspace icon (from icons.yaml) as a pixbuf,
    suitable for use as a GTK button image. *)

(** Build a pixbuf for the named icon at the given pixel size,
    tinting ``currentColor`` strokes/fills with the supplied hex
    color (e.g. ``"#cccccc"``).
    Raises [Not_found] when the icon doesn't exist in the workspace
    icons map; [Failure] when librsvg can't parse the constructed SVG. *)
val pixbuf_for_name : string -> int -> string -> GdkPixbuf.pixbuf
