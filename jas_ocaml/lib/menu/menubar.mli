(** Menubar for the main window. *)

val is_untitled : string -> bool

val save : Model.model -> GWindow.window -> unit -> unit

val revert : (unit -> Model.model) -> GWindow.window -> unit -> unit

val create : (unit -> Model.model) -> GWindow.window -> on_open:(Model.model -> unit) -> ?dock_layout:Dock.dock_layout -> ?app_config:Dock.app_config -> ?refresh_dock:(unit -> unit) -> GPack.box -> unit
