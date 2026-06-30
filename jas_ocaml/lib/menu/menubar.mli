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

(** Body text of the reference-aware delete/cut confirm (the
    warn-then-orphan CONFIRM half). [delete_orphan_warning_body ~verb n]
    is verbatim, pinned cross-language:
    [<Verb> ^ " will leave N live instance(s) empty."], singular for
    [n = 1]. [verb] is the gerund of the action (["Deleting"] for delete,
    ["Cutting"] for cut). Pure; exposed for testing. *)
val delete_orphan_warning_body : verb:string -> int -> string

(** Show the modal confirm for a delete that would orphan [n] (> 0) live
    references. Title ["Delete"], body
    [delete_orphan_warning_body ~verb:"Deleting" n], buttons ["Cancel"]
    (focused default) and ["Delete"] (destructive). Returns [true] only
    when the user confirms with [Delete]. *)
val confirm_delete_orphans : int -> GWindow.window -> bool

(** [get_tab_count] supplies the number of open document tabs, driving the
    menu evaluation context's [state.tab_count] (the analog of Python's
    [window.tab_widget.count()]); omitted, it defaults to 0 and every
    document-dependent menu item evaluates as disabled. *)
val create : (unit -> Model.model) -> GWindow.window -> on_open:(Model.model -> unit) -> ?workspace_layout:Workspace_layout.workspace_layout -> ?app_config:Workspace_layout.app_config -> ?refresh_dock:(unit -> unit) -> ?get_tab_count:(unit -> int) -> GPack.box -> unit

(** Re-evaluate the menu's bundle [enabled_when] / [checked_when] predicates
    against live document + layout state and re-apply each item's sensitivity
    + check mark (through the shared expression evaluator). Call this after any
    external change to panel/pane visibility (right-click Close, layout
    restore, etc.) so the menu stays truthful. No-op until [create] has been
    invoked. *)
val sync_panel_checks : unit -> unit
