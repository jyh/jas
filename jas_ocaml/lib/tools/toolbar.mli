(** A floating toolbar subwindow embedded inside the workspace. *)

type tool = Selection | Direct_selection | Group_selection | Pen | Add_anchor_point | Delete_anchor_point | Anchor_point | Pencil | Path_eraser | Smooth | Type_tool | Type_on_path | Line | Rect | Rounded_rect | Polygon | Star

class toolbar : title:string -> x:int -> y:int -> GPack.fixed -> object
  method current_tool : tool
  method widget : GObj.widget
  method x : int
  method y : int
  method select_tool : tool -> unit
end

val create : title:string -> x:int -> y:int -> GPack.fixed -> toolbar
