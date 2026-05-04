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
