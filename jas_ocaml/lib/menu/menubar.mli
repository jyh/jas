(** Menubar for the main window. *)

val group_selection : Model.model -> unit -> unit

(** "Make Instance": create a by-id reference to the single selected
    whole element, offset by the paste offset and selected. Native UI
    glue composing [Controller.create_reference] + [move_selection] under
    one snapshot; a no-op unless exactly one element is selected as a
    whole (SelKindAll). See REFERENCE_GRAPH.md §4. *)
val make_instance : Model.model -> unit -> unit

val ungroup_selection : Model.model -> unit -> unit

val ungroup_all : Model.model -> unit -> unit

val is_svg : string -> bool

val is_untitled : string -> bool

val save : Model.model -> GWindow.window -> unit -> unit

val revert : (unit -> Model.model) -> GWindow.window -> unit -> unit

val create : (unit -> Model.model) -> GWindow.window -> on_open:(Model.model -> unit) -> ?workspace_layout:Workspace_layout.workspace_layout -> ?app_config:Workspace_layout.app_config -> ?refresh_dock:(unit -> unit) -> GPack.box -> unit

(** Resync the Window-menu panel check items against the live
    workspace_layout. Call this after any external change to panel
    visibility (right-click Close, layout restore, etc.) so the
    checkmarks stay truthful. No-op until [create] has been invoked. *)
val sync_panel_checks : unit -> unit
