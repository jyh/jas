(** Per-document settings edited from the Document Setup dialog
    (PRINT.md §Phase 1A). Bleed values are in points and represent
    the amount of artwork that extends past each artboard edge for
    trim tolerance during commercial printing. *)

type t = {
  bleed_top : float;
  bleed_right : float;
  bleed_bottom : float;
  bleed_left : float;
  (* Chain-link state for the bleed inputs in the dialog. When true,
     editing any one side propagates to all four. Persisted because
     the user expects the chain to stay where they left it across
     sessions. *)
  bleed_uniform : bool;
  (* Render image elements as their bounding outline rather than
     rasterized content (canvas display only; export ignores this). *)
  show_images_outline : bool;
  (* Tint glyphs that were rendered with a substituted font so the
     user can spot missing-font cases. *)
  highlight_substituted_glyphs : bool;
  (* Phase 6 additions (deferred Phase 1A items). *)
  grid_size : float;
  grid_color : string;
  paper_color : string;
  simulate_colored_paper : bool;
  transparency_flattener_preset : Print_preferences.flattener_preset;
  discard_white_overprint : bool;
}

let default = {
  bleed_top = 0.0;
  bleed_right = 0.0;
  bleed_bottom = 0.0;
  bleed_left = 0.0;
  bleed_uniform = true;
  show_images_outline = false;
  highlight_substituted_glyphs = false;
  grid_size = 72.0;
  grid_color = "#cccccc";
  paper_color = "#ffffff";
  simulate_colored_paper = false;
  transparency_flattener_preset = Print_preferences.Medium_resolution;
  discard_white_overprint = false;
}

(** Compute the on-canvas bleed guide rectangle for one artboard, in
    document points. Returns None when all four bleeds are zero (the
    no-bleed case is the default and elides the guide entirely). *)
let bleed_rect_for_artboard (s : t) (ab : Artboard.artboard) =
  if s.bleed_top = 0.0 && s.bleed_right = 0.0
     && s.bleed_bottom = 0.0 && s.bleed_left = 0.0
  then None
  else
    Some (
      ab.Artboard.x -. s.bleed_left,
      ab.Artboard.y -. s.bleed_top,
      ab.Artboard.width +. s.bleed_left +. s.bleed_right,
      ab.Artboard.height +. s.bleed_top +. s.bleed_bottom
    )
