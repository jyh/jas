(** A floating toolbar subwindow embedded inside the workspace. *)

type tool = Selection | Partial_selection | Interior_selection | Magic_wand | Pen | Add_anchor_point | Delete_anchor_point | Anchor_point | Pencil | Paintbrush | Blob_brush | Path_eraser | Smooth | Type_tool | Type_on_path | Line | Rect | Rounded_rect | Polygon | Star | Lasso

(** Map a tool variant to its workspace/tools/*.yaml filename stem.
    Returns [None] for native-only tools (Type_tool / Type_on_path). *)
val tool_yaml_id : tool -> string option

(** Look up a tool's [tool_options_dialog] field in workspace.json.
    Returns the dialog id when set, [None] otherwise. Consumed by
    the toolbar-slot double-click handlers. *)
val tool_options_dialog_id : tool -> string option

class toolbar : title:string -> x:int -> y:int -> ?get_model:(unit -> Model.model) -> GPack.fixed -> object
  method current_tool : tool
  method widget : GObj.widget
  method x : int
  method y : int
  method select_tool : tool -> unit
  method fill_on_top : bool
  method set_fill_on_top : bool -> unit
  method toggle_fill_on_top : unit
  method reset_defaults : unit
  method swap_fill_stroke : unit
  method redraw_fill_stroke : unit
end

val create : title:string -> x:int -> y:int -> ?get_model:(unit -> Model.model) -> GPack.fixed -> toolbar
