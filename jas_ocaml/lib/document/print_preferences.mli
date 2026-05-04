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
}

val default : t

(** Workspace-level named saved configuration. *)
type print_preset = {
  name : string;
  preferences : t;
}

val default_preset : print_preset
