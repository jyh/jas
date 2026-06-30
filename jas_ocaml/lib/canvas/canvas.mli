(** Main window with toolbar and tabbed canvas workspace. *)

(** [get_tab_count] reports the number of open document tabs, forwarded to
    the menubar so its [enabled_when] / [checked_when] predicates can read
    [state.tab_count]. Omitted, the menu treats the document as absent. *)
val create_main_window : get_model:(unit -> Model.model) -> get_fill_on_top:(unit -> bool) -> on_open:(Model.model -> unit) -> ?get_tab_count:(unit -> int) -> unit -> GWindow.window * GPack.fixed * GPack.notebook * GPack.box
