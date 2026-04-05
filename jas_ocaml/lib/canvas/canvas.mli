(** Main window with toolbar and tabbed canvas workspace. *)

val create_main_window : get_model:(unit -> Model.model) -> on_open:(Model.model -> unit) -> unit -> GWindow.window * GPack.fixed * GPack.notebook
