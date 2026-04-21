(** Artboards: print-page regions attached to the document root.
    ARTBOARDS.md for the full spec. *)

(** Fill: transparent sentinel or opaque colour literal. *)
type fill =
  | Transparent
  | Color of string

val fill_as_canonical : fill -> string
val fill_from_canonical : string -> fill

(** Per-artboard stored state. *)
type artboard = {
  id : string;
  name : string;
  x : float;
  y : float;
  width : float;
  height : float;
  fill : fill;
  show_center_mark : bool;
  show_cross_hairs : bool;
  show_video_safe_areas : bool;
  video_ruler_pixel_aspect_ratio : float;
}

val default_with_id : string -> artboard

(** Document-global artboard toggles. *)
type options = {
  fade_region_outside_artboard : bool;
  update_while_dragging : bool;
}

val default_options : options

(** Mint a fresh 8-char base36 id. Pass an rng returning a non-negative
    int per call for deterministic tests. *)
val generate_id : ?rng:(unit -> int) -> unit -> string

(** Parse "Artboard N" name and return N (case-sensitive single-space rule). *)
val parse_default_name : string -> int option

(** Next unused "Artboard N" name. *)
val next_name : artboard list -> string

(** Apply the at-least-one-artboard invariant. Returns (list, didRepair). *)
val ensure_invariant : ?id_gen:(unit -> string) -> artboard list -> artboard list * bool
