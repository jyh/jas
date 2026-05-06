(** Per-document Print dialog state (PRINT.md §Phase 1B). *)

type artboard_range_mode = All | Range
type media_size =
  | Defined_by_driver | Letter | Legal | Tabloid | A3 | A4 | A5 | Custom_media
type orientation = Portrait | Landscape
type print_layers = Visible_printable | Visible | All_layers
type scaling_mode = Do_not_scale | Fit_to_page | Custom_scale

(* Stable snake_case strings for cross-language wire format. *)

val artboard_range_mode_to_string : artboard_range_mode -> string
val artboard_range_mode_of_string : string -> artboard_range_mode
val media_size_to_string : media_size -> string
val media_size_of_string : string -> media_size
val orientation_to_string : orientation -> string
val orientation_of_string : string -> orientation
val print_layers_to_string : print_layers -> string
val print_layers_of_string : string -> print_layers
val scaling_mode_to_string : scaling_mode -> string
val scaling_mode_of_string : string -> scaling_mode

type printer_mark_type = Roman | Japanese

val printer_mark_type_to_string : printer_mark_type -> string
val printer_mark_type_of_string : string -> printer_mark_type

type output_mode = Composite | Separations

val output_mode_to_string : output_mode -> string
val output_mode_of_string : string -> output_mode

type emulsion = Up_right | Down_right

val emulsion_to_string : emulsion -> string
val emulsion_of_string : string -> emulsion

type image_polarity = Positive | Negative

val image_polarity_to_string : image_polarity -> string
val image_polarity_of_string : string -> image_polarity

type dot_shape =
  | Dot_round
  | Dot_square
  | Dot_ellipse
  | Dot_diamond
  | Dot_line
  | Dot_cross
  | Dot_euclidean

val dot_shape_to_string : dot_shape -> string
val dot_shape_of_string : string -> dot_shape

type ink_override = {
  name : string;
  print : bool;
  frequency : float;
  angle : float;
  dot_shape : dot_shape;
}

val process_cmyk_default_inks : ink_override list

type output = {
  mode : output_mode;
  emulsion : emulsion;
  image_polarity : image_polarity;
  printer_resolution : string;
  convert_spot_to_process : bool;
  overprint_black : bool;
  inks : ink_override list;
}

val default_output : output

type flattener_preset =
  | Low_resolution
  | Medium_resolution
  | High_resolution
  | Custom_flattener

val flattener_preset_to_string : flattener_preset -> string
val flattener_preset_of_string : string -> flattener_preset

type advanced = {
  print_as_bitmap : bool;
  overprint_flattener_preset : flattener_preset;
}

val default_advanced : advanced

type color_handling =
  | Let_app_determine
  | Let_printer_determine
  | Postscript_color_management

val color_handling_to_string : color_handling -> string
val color_handling_of_string : string -> color_handling

type rendering_intent =
  | Perceptual
  | Relative_colorimetric
  | Saturation
  | Absolute_colorimetric

val rendering_intent_to_string : rendering_intent -> string
val rendering_intent_of_string : string -> rendering_intent

type color_management = {
  document_profile : string;
  color_handling : color_handling;
  printer_profile : string;
  rendering_intent : rendering_intent;
  preserve_rgb_numbers : bool;
}

val default_color_management : color_management

type font_download = Font_none | Font_subset | Font_complete

val font_download_to_string : font_download -> string
val font_download_of_string : string -> font_download

type postscript_level = Level_2 | Level_3

val postscript_level_to_string : postscript_level -> string
val postscript_level_of_string : string -> postscript_level

type data_format = Ascii | Binary

val data_format_to_string : data_format -> string
val data_format_of_string : string -> data_format

type graphics = {
  flatness : float;
  font_download : font_download;
  postscript_level : postscript_level;
  data_format : data_format;
  compatible_gradient_printing : bool;
  raster_effects_resolution : float;
}

val default_graphics : graphics

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

val default_marks_and_bleed : marks_and_bleed

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
  tile_overlap_h : float;
  tile_overlap_v : float;
  tile_range : string;
  marks_and_bleed : marks_and_bleed;
  output : output;
  graphics : graphics;
  color_management : color_management;
  advanced : advanced;
}

val default : t

(** Workspace-level named saved configuration. *)
type print_preset = {
  name : string;
  preferences : t;
}

val default_preset : print_preset
