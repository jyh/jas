(** Eyedropper extract / apply helpers.

    Pure functions plus an [appearance] data container:

    - [extract_appearance element] returns a snapshot of the source
      element's relevant attrs as a serialisable [appearance],
      suitable for [state.eyedropper_cache].

    - [apply_appearance target appearance config] returns a copy of
      [target] with attrs from [appearance] written onto it, gated by
      the master / sub toggles in [config].

    See [transcripts/EYEDROPPER_TOOL.md] for the full spec.
    Cross-language parity is mechanical — the Rust / Swift / Python
    ports of this module follow the same shape.

    Phase 1 limitations:

    - Character / Paragraph extraction / apply is stubbed; the
      [appearance] carries [character] / [paragraph] as opaque JSON
      so the cache can round-trip without losing data, but Phase 1
      writes don't yet thread through Text / Text_path internals.

    - Stroke profile copies [width_points] on Line / Path only; other
      element types have no profile and the call is a no-op.

    - Gradient / pattern fills are not sampled — only solid fills
      round-trip. A non-solid source fill is treated as "no fill data
      sampled" (cached as [None]). *)

(** Snapshot of a source element's attrs. Round-trips through JSON
    via [state.eyedropper_cache].

    Fields are wrapped in [option] (or empty list) so the cache can
    encode "not sampled" distinctly from "sampled as default". *)
type appearance = {
  app_fill : Element.fill option;
  app_stroke : Element.stroke option;
  app_opacity : float option;
  app_blend_mode : Element.blend_mode option;
  app_stroke_brush : string option;
  app_width_points : Element.stroke_width_point list;
  (** Phase 1 stub: character data is round-tripped as opaque JSON.
      A follow-up phase replaces this with concrete fields and full
      Text-element extract / apply. *)
  app_character : Yojson.Safe.t option;
  (** Phase 1 stub for paragraph data — same caveat as
      [app_character]. *)
  app_paragraph : Yojson.Safe.t option;
}

(** An empty appearance — every field [None] / empty list. Useful as
    a "nothing sampled" sentinel and as a starting point for tests. *)
val empty_appearance : appearance

(** Toggle configuration mirroring the 25 [state.eyedropper_*]
    boolean keys. Master toggles gate entire groups; sub-toggles
    gate individual attrs within a group. Both must be true for an
    attribute to be applied. *)
type config = {
  fill : bool;

  stroke : bool;
  stroke_color : bool;
  stroke_weight : bool;
  stroke_cap_join : bool;
  stroke_align : bool;
  stroke_dash : bool;
  stroke_arrowheads : bool;
  stroke_profile : bool;
  stroke_brush : bool;

  opacity : bool;
  opacity_alpha : bool;
  opacity_blend : bool;

  character : bool;
  character_font : bool;
  character_size : bool;
  character_leading : bool;
  character_kerning : bool;
  character_tracking : bool;
  character_color : bool;

  paragraph : bool;
  paragraph_align : bool;
  paragraph_indent : bool;
  paragraph_space : bool;
  paragraph_hyphenate : bool;
}

(** Reference defaults — every toggle on, mirroring the workspace
    default for [state.eyedropper_*] keys. *)
val default_config : config

(** Read the fill on an element variant, returning [None] for
    fill-less variants (Line / Group / Layer). *)
val fill_of : Element.element -> Element.fill option

(** Read the stroke on an element variant, returning [None] for
    stroke-less variants (Group / Layer). *)
val stroke_of : Element.element -> Element.stroke option

(** Read the opacity on any element variant. Defaults to 1.0 only
    for unhandled variants (none today). *)
val opacity_of : Element.element -> float

(** Source-side eligibility per EYEDROPPER_TOOL.md §Eligibility.
    Locked is OK (we read, don't write); Hidden ([Invisible]) is not
    (no hit-test). [Group] / [Layer] are never sources — the caller
    is responsible for descending to the innermost element under
    the cursor. *)
val is_source_eligible : Element.element -> bool

(** Target-side eligibility per EYEDROPPER_TOOL.md §Eligibility.
    Locked is not OK (writes need permission); Hidden is OK (writes
    persist). [Group] / [Layer] are never targets — the caller
    recurses into them and applies to leaves. *)
val is_target_eligible : Element.element -> bool

(** Snapshot the source element's attrs into an [appearance]. The
    caller is responsible for source-eligibility; this function does
    not filter. *)
val extract_appearance : Element.element -> appearance

(** Return a copy of [target] with attrs from [appearance] applied
    per [config]. Master OFF skips the entire group; master ON +
    sub OFF skips that sub-attribute. The caller is responsible for
    target-eligibility (locked / container check); this function
    applies to whatever it is given. *)
val apply_appearance : Element.element -> appearance -> config -> Element.element

(** Serialise [appearance] to a JSON object compatible with the
    Rust serde-derived form. Empty fields are omitted; the dict
    only carries values that were actually sampled. *)
val appearance_to_json : appearance -> Yojson.Safe.t

(** Parse a JSON object back into an [appearance]. Missing or
    malformed fields decode as [None] / empty. Returns
    [empty_appearance] when the JSON is not an object. *)
val appearance_of_json : Yojson.Safe.t -> appearance
