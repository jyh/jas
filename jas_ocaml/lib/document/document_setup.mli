(** Per-document settings edited from the Document Setup dialog
    (PRINT.md §Phase 1A). *)

type t = {
  bleed_top : float;
  bleed_right : float;
  bleed_bottom : float;
  bleed_left : float;
  bleed_uniform : bool;
  show_images_outline : bool;
  highlight_substituted_glyphs : bool;
}

val default : t

(** Outset rect of one artboard by the per-side bleed values, in
    document points. Returns [None] when all four bleeds are zero. *)
val bleed_rect_for_artboard :
  t -> Artboard.artboard -> (float * float * float * float) option
