(** Magic Wand match predicate.

    Pure function: given a seed element, a candidate element, and the
    nine [state.magic_wand_*] configuration values, decide whether
    the candidate is "similar" to the seed under the enabled
    criteria.

    See [transcripts/MAGIC_WAND_TOOL.md] §Predicate for the rules.
    Cross-language parity is mechanical with the Rust / Swift /
    Python ports. *)

(** The five-criterion configuration mirrors [state.magic_wand_*].
    Each criterion has an enabled flag and, where applicable, a
    tolerance. *)
type config = {
  fill_color : bool;
  fill_tolerance : float;
  stroke_color : bool;
  stroke_tolerance : float;
  stroke_weight : bool;
  stroke_weight_tolerance : float;
  opacity : bool;
  opacity_tolerance : float;
  blending_mode : bool;
}

(** Reference defaults — four "obvious" criteria on, blending mode
    off, plus the published tolerances. *)
val default_config : config

(** [magic_wand_match seed cand cfg] returns [true] iff [cand] is
    similar to [seed] under every enabled criterion. AND across all
    enabled criteria. When all criteria are disabled the function
    returns [false]; the click handler treats that case as
    "select only the seed itself", but that is the caller's
    responsibility. *)
val magic_wand_match : Element.element -> Element.element -> config -> bool
