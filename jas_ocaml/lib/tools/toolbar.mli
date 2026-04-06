(** A floating toolbar subwindow embedded inside the workspace. *)

type tool = Selection | Direct_selection | Group_selection | Pen | Add_anchor_point | Delete_anchor_point | Pencil | Path_eraser | Text_tool | Text_path | Line | Rect | Polygon

class toolbar : title:string -> x:int -> y:int -> GPack.fixed -> object
  method current_tool : tool
  method widget : GObj.widget
  method x : int
  method y : int
  method select_tool : tool -> unit
end

val create : title:string -> x:int -> y:int -> GPack.fixed -> toolbar
