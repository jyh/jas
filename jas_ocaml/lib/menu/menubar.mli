(** Menubar for the main window. *)

val is_untitled : string -> bool

val save : Model.model -> GWindow.window -> unit -> unit

val create : (unit -> Model.model) -> GWindow.window -> on_open:(Model.model -> unit) -> GPack.box -> unit
