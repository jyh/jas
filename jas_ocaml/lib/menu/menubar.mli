(** Menubar for the main window. *)

val create : (unit -> Model.model) -> GWindow.window -> on_open:(Model.model -> unit) -> GPack.box -> unit
