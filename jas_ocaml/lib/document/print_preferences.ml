(** Per-document Print dialog state (PRINT.md §Phase 1B). Remembers
    the last-used choices in the General tab so reopening Print
    restores them. Later phases extend with sub-records for marks,
    output, graphics, color management, advanced.

    [print_preset] is the workspace-level named saved configuration
    of the same fields. Phase 1 ships exactly one built-in
    [\[Default\]]; save / load / delete is deferred (PRINT.md
    §Phase 7+). *)

type artboard_range_mode = All | Range
type media_size =
  | Defined_by_driver | Letter | Legal | Tabloid | A3 | A4 | A5 | Custom_media
type orientation = Portrait | Landscape
type print_layers =
  | Visible_printable  (** Honor visibility != Invisible AND a future Layer.print flag. *)
  | Visible            (** Honor only visibility != Invisible. *)
  | All_layers
type scaling_mode = Do_not_scale | Fit_to_page | Custom_scale

(* Stable snake_case strings for cross-language wire format. *)

let artboard_range_mode_to_string = function
  | All -> "all" | Range -> "range"
let artboard_range_mode_of_string = function
  | "range" -> Range
  | _ -> All

let media_size_to_string = function
  | Defined_by_driver -> "defined_by_driver"
  | Letter -> "letter" | Legal -> "legal" | Tabloid -> "tabloid"
  | A3 -> "a3" | A4 -> "a4" | A5 -> "a5"
  | Custom_media -> "custom"
let media_size_of_string = function
  | "letter" -> Letter | "legal" -> Legal | "tabloid" -> Tabloid
  | "a3" -> A3 | "a4" -> A4 | "a5" -> A5 | "custom" -> Custom_media
  | _ -> Defined_by_driver

let orientation_to_string = function
  | Portrait -> "portrait" | Landscape -> "landscape"
let orientation_of_string = function
  | "landscape" -> Landscape
  | _ -> Portrait

let print_layers_to_string = function
  | Visible_printable -> "visible_printable"
  | Visible -> "visible"
  | All_layers -> "all"
let print_layers_of_string = function
  | "visible" -> Visible
  | "all" -> All_layers
  | _ -> Visible_printable

let scaling_mode_to_string = function
  | Do_not_scale -> "do_not_scale"
  | Fit_to_page -> "fit_to_page"
  | Custom_scale -> "custom"
let scaling_mode_of_string = function
  | "fit_to_page" -> Fit_to_page
  | "custom" -> Custom_scale
  | _ -> Do_not_scale

(** Two cultural variants of printer's marks. [Roman] ships the
    standard Western trim/registration marks; [Japanese] swaps in
    the kasen-style marks used by Japanese commercial print shops.
    Phase 2 stores the choice but the renderer only differentiates
    in a follow-up — the on-disk shape is stable now. *)
type printer_mark_type = Roman | Japanese

let printer_mark_type_to_string = function
  | Roman -> "roman" | Japanese -> "japanese"
let printer_mark_type_of_string = function
  | "japanese" -> Japanese
  | _ -> Roman

(** Output mode (PRINT.md §Phase 3): [Composite] renders the
    document as one PDF page per artboard (Phase 1B behavior);
    [Separations] renders one page per enabled ink in
    [Output.inks]. *)
type output_mode = Composite | Separations

let output_mode_to_string = function
  | Composite -> "composite"
  | Separations -> "separations"
let output_mode_of_string = function
  | "separations" -> Separations
  | _ -> Composite

(** Film emulsion side (PRINT.md §Phase 3). For PDF output this has
    no rendering effect, but the on-disk shape is stable. *)
type emulsion = Up_right | Down_right

let emulsion_to_string = function
  | Up_right -> "up_right"
  | Down_right -> "down_right"
let emulsion_of_string = function
  | "down_right" -> Down_right
  | _ -> Up_right

(** PDF page polarity (PRINT.md §Phase 3). [Negative] inverts the
    final rasterized output; for PDF this is recorded but not
    applied. *)
type image_polarity = Positive | Negative

let image_polarity_to_string = function
  | Positive -> "positive"
  | Negative -> "negative"
let image_polarity_of_string = function
  | "negative" -> Negative
  | _ -> Positive

(** Halftone dot shape for an [InkOverride] row (PRINT.md §Phase 3).
    Phase 3 stores the choice; halftone screen rendering itself is
    a Phase 7+ deferral. *)
type dot_shape =
  | Dot_round
  | Dot_square
  | Dot_ellipse
  | Dot_diamond
  | Dot_line
  | Dot_cross
  | Dot_euclidean

let dot_shape_to_string = function
  | Dot_round -> "round"
  | Dot_square -> "square"
  | Dot_ellipse -> "ellipse"
  | Dot_diamond -> "diamond"
  | Dot_line -> "line"
  | Dot_cross -> "cross"
  | Dot_euclidean -> "euclidean"
let dot_shape_of_string = function
  | "square" -> Dot_square
  | "ellipse" -> Dot_ellipse
  | "diamond" -> Dot_diamond
  | "line" -> Dot_line
  | "cross" -> Dot_cross
  | "euclidean" -> Dot_euclidean
  | _ -> Dot_round

(** One row in the per-ink overrides table (PRINT.md §Phase 3). *)
type ink_override = {
  name : string;
  print : bool;
  frequency : float;
  angle : float;
  dot_shape : dot_shape;
}

(** The default ink list shipped with a fresh Output: the four CMYK
    process inks at standard Western screen angles. *)
let process_cmyk_default_inks = [
  { name = "Process Cyan";    print = true; frequency = 75.0; angle = 105.0; dot_shape = Dot_round };
  { name = "Process Magenta"; print = true; frequency = 75.0; angle =  75.0; dot_shape = Dot_round };
  { name = "Process Yellow";  print = true; frequency = 75.0; angle =  90.0; dot_shape = Dot_round };
  { name = "Process Black";   print = true; frequency = 75.0; angle =  45.0; dot_shape = Dot_round };
]

(** Output sub-record on print_preferences (PRINT.md §Phase 3). The
    Output tab edits these 1:1; in Separations mode the PDF emitter
    produces one page per enabled [ink_override] instead of one page
    per artboard. *)
type output = {
  mode : output_mode;
  emulsion : emulsion;
  image_polarity : image_polarity;
  printer_resolution : string;
  convert_spot_to_process : bool;
  overprint_black : bool;
  inks : ink_override list;
}

let default_output = {
  mode = Composite;
  emulsion = Up_right;
  image_polarity = Positive;
  printer_resolution = "75 lpi / 600 dpi";
  convert_spot_to_process = false;
  overprint_black = false;
  inks = process_cmyk_default_inks;
}

(** Transparency / overprint flattener preset (PRINT.md §Phase 6).
    Used by both the Print Advanced tab and Document Setup. *)
type flattener_preset =
  | Low_resolution
  | Medium_resolution
  | High_resolution
  | Custom_flattener

let flattener_preset_to_string = function
  | Low_resolution -> "low_resolution"
  | Medium_resolution -> "medium_resolution"
  | High_resolution -> "high_resolution"
  | Custom_flattener -> "custom"
let flattener_preset_of_string = function
  | "low_resolution" -> Low_resolution
  | "high_resolution" -> High_resolution
  | "custom" -> Custom_flattener
  | _ -> Medium_resolution

(** Advanced sub-record on print_preferences (PRINT.md §Phase 6).
    Phase 6 v1 stores the values; rendering effects deferred. *)
type advanced = {
  print_as_bitmap : bool;
  overprint_flattener_preset : flattener_preset;
}

let default_advanced = {
  print_as_bitmap = false;
  overprint_flattener_preset = Medium_resolution;
}

(** Color-handling mode for the Color Management tab (PRINT.md §Phase 5).
    Three Adobe-standard choices. Stored only — full ICC profile
    management is a Phase 5+ deferral. *)
type color_handling =
  | Let_app_determine
  | Let_printer_determine
  | Postscript_color_management

let color_handling_to_string = function
  | Let_app_determine -> "let_app_determine"
  | Let_printer_determine -> "let_printer_determine"
  | Postscript_color_management -> "postscript_color_management"
let color_handling_of_string = function
  | "let_printer_determine" -> Let_printer_determine
  | "postscript_color_management" -> Postscript_color_management
  | _ -> Let_app_determine

(** PDF rendering intent (PRINT.md §Phase 5). Names match PDF
    1.7 §11.6.5.8 one-for-one (snake_case on disk; the PDF emitter
    writes the CamelCase form into a ``ri`` operator). *)
type rendering_intent =
  | Perceptual
  | Relative_colorimetric
  | Saturation
  | Absolute_colorimetric

let rendering_intent_to_string = function
  | Perceptual -> "perceptual"
  | Relative_colorimetric -> "relative_colorimetric"
  | Saturation -> "saturation"
  | Absolute_colorimetric -> "absolute_colorimetric"
let rendering_intent_of_string = function
  | "perceptual" -> Perceptual
  | "saturation" -> Saturation
  | "absolute_colorimetric" -> Absolute_colorimetric
  | _ -> Relative_colorimetric

(** Color Management sub-record on print_preferences (PRINT.md §Phase 5). *)
type color_management = {
  document_profile : string;
  color_handling : color_handling;
  printer_profile : string;
  rendering_intent : rendering_intent;
  preserve_rgb_numbers : bool;
}

let default_color_management = {
  document_profile = "sRGB IEC61966-2.1";
  color_handling = Let_app_determine;
  printer_profile = "";
  rendering_intent = Relative_colorimetric;
  preserve_rgb_numbers = false;
}

(** Font-download mode for the Graphics tab (PRINT.md §Phase 4).
    PostScript-era concept; stored for on-disk shape stability but
    not applied by the PDF emitter (we always embed-by-subset). *)
type font_download = Font_none | Font_subset | Font_complete

let font_download_to_string = function
  | Font_none -> "none"
  | Font_subset -> "subset"
  | Font_complete -> "complete"
let font_download_of_string = function
  | "none" -> Font_none
  | "complete" -> Font_complete
  | _ -> Font_subset

(** PostScript output level (PRINT.md §Phase 4). Stored but not
    applied — we emit PDF, not PostScript. *)
type postscript_level = Level_2 | Level_3

let postscript_level_to_string = function
  | Level_2 -> "level_2"
  | Level_3 -> "level_3"
let postscript_level_of_string = function
  | "level_2" -> Level_2
  | _ -> Level_3

(** Stream encoding for PostScript output (PRINT.md §Phase 4).
    Stored but not applied — we emit PDF. *)
type data_format = Ascii | Binary

let data_format_to_string = function
  | Ascii -> "ascii"
  | Binary -> "binary"
let data_format_of_string = function
  | "ascii" -> Ascii
  | _ -> Binary

(** Graphics sub-record on print_preferences (PRINT.md §Phase 4).
    [flatness] is consulted by the PDF emitter as a path-flattening
    tolerance; the others are stored for cross-app round-trip but
    not applied (PostScript-specific). *)
type graphics = {
  flatness : float;
  font_download : font_download;
  postscript_level : postscript_level;
  data_format : data_format;
  compatible_gradient_printing : bool;
  raster_effects_resolution : float;
}

let default_graphics = {
  flatness = 1.0;
  font_download = Font_subset;
  postscript_level = Level_3;
  data_format = Binary;
  compatible_gradient_printing = false;
  raster_effects_resolution = 300.0;
}

(** Marks-and-bleed sub-record on print_preferences (PRINT.md §Phase 2).
    The Marks tab exposes these 1:1 as widgets; the PDF renderer
    extends each page by the active bleed and overlays mark geometry
    around the trim rect.

    [use_document_bleed] controls whether bleeds come from the
    document-level [Document_setup] or from the per-print [bleed_*]
    overrides on this record. Defaulting to true keeps document and
    print in lockstep until the user opts out. *)
type marks_and_bleed = {
  all_printer_marks : bool;
  trim_marks : bool;
  registration_marks : bool;
  color_bars : bool;
  page_information : bool;
  printer_mark_type : printer_mark_type;
  trim_mark_weight : float;
  mark_offset : float;
  use_document_bleed : bool;
  bleed_top : float;
  bleed_right : float;
  bleed_bottom : float;
  bleed_left : float;
}

let default_marks_and_bleed = {
  all_printer_marks = false;
  trim_marks = false;
  registration_marks = false;
  color_bars = false;
  page_information = false;
  printer_mark_type = Roman;
  trim_mark_weight = 0.25;
  mark_offset = 6.0;
  use_document_bleed = true;
  bleed_top = 0.0;
  bleed_right = 0.0;
  bleed_bottom = 0.0;
  bleed_left = 0.0;
}

type t = {
  preset_name : string;
  printer_name : string option;
  copies : int;
  collate : bool;
  reverse_order : bool;
  artboard_range_mode : artboard_range_mode;
  artboard_range : string;
  ignore_artboards : bool;
  skip_blank_artboards : bool;
  media_size : media_size;
  media_width : float;
  media_height : float;
  orientation : orientation;
  auto_rotate : bool;
  transverse : bool;
  print_layers : print_layers;
  placement_x : float;
  placement_y : float;
  scaling_mode : scaling_mode;
  custom_scale : float;
  (* Reserved for Phase 7 tiling. Stored now so the on-disk shape is
     stable across phases. *)
  tile_overlap_h : float;
  tile_overlap_v : float;
  tile_range : string;
  (* Marks-and-bleed sub-record (PRINT.md §Phase 2). *)
  marks_and_bleed : marks_and_bleed;
  (* Output sub-record (PRINT.md §Phase 3). *)
  output : output;
  (* Graphics sub-record (PRINT.md §Phase 4). *)
  graphics : graphics;
  (* Color Management sub-record (PRINT.md §Phase 5). *)
  color_management : color_management;
  (* Advanced sub-record (PRINT.md §Phase 6). *)
  advanced : advanced;
}

let default = {
  preset_name = "[Default]";
  printer_name = None;
  copies = 1;
  collate = false;
  reverse_order = false;
  artboard_range_mode = All;
  artboard_range = "";
  ignore_artboards = false;
  skip_blank_artboards = false;
  media_size = Defined_by_driver;
  media_width = 612.0;
  media_height = 792.0;
  orientation = Portrait;
  auto_rotate = true;
  transverse = false;
  print_layers = Visible_printable;
  placement_x = 0.0;
  placement_y = 0.0;
  scaling_mode = Do_not_scale;
  custom_scale = 100.0;
  tile_overlap_h = 0.0;
  tile_overlap_v = 0.0;
  tile_range = "";
  marks_and_bleed = default_marks_and_bleed;
  output = default_output;
  graphics = default_graphics;
  color_management = default_color_management;
  advanced = default_advanced;
}

(** Workspace-level named saved configuration. Phase 1 ships only
    the built-in [\[Default\]]; save / load / delete is deferred. *)
type print_preset = {
  name : string;
  preferences : t;
}

let default_preset = {
  name = "[Default]";
  preferences = default;
}
