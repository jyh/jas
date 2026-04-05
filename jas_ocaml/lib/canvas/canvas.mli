(** Main window with dark workspace and menubar. *)

val create_main_window : get_model:(unit -> Model.model) -> on_open:(Model.model -> unit) -> unit -> GWindow.window * GPack.fixed
