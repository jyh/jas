(** Load and query the compiled workspace JSON.

    Provides access to panels, menus, content, and state defaults
    from the [workspace/workspace.json] file produced by the YAML compiler. *)

type workspace = {
  data : Yojson.Safe.t;
}

(** Try to load [workspace.json] from the project workspace directory.
    Searches relative to the executable, then the current directory. *)
val load : unit -> workspace option

(** Return a member of a JSON object, or [None] if missing or not an object. *)
val json_member : string -> Yojson.Safe.t -> Yojson.Safe.t option

(** [menubar ws] returns the top-level menu bar definition (menubar.yaml)
    as a list of menu JSON objects in declaration order. Empty when the
    bundle ships no [menubar] key. *)
val menubar : workspace -> Yojson.Safe.t list

(** [shortcuts ws] returns the top-level key-to-action table (shortcuts.yaml)
    as a list of entry JSON objects ({key, action, params?}) in declaration
    order. Empty when the bundle ships no [shortcuts] key. Read the same way as
    [menubar]; consumed by the pure key resolver (Key_resolver). *)
val shortcuts : workspace -> Yojson.Safe.t list

val panel : workspace -> string -> Yojson.Safe.t option

(** [tool ws name] returns the compiled tool entry [tools.<name>] from the
    bundle, or [None] when the tool is unknown. The entry carries the tool's
    declarative ``tool_options_panel`` / ``tool_options_action`` /
    ``tool_options_dialog`` fields, read by the toolbar double-click handler. *)
val tool : workspace -> string -> Yojson.Safe.t option

(** [concept ws id] returns the concept pack [id] from the registry, or [None]. *)
val concept : workspace -> string -> Yojson.Safe.t option

(** [concepts ws] returns the whole concept registry as [(id, spec)] pairs sorted
    by id, for code that iterates every concept (e.g. promote trying each
    concept's [fitter] in a deterministic order). Empty when none ship. *)
val concepts : workspace -> (string * Yojson.Safe.t) list

val panel_menu : workspace -> string -> Yojson.Safe.t list
val panel_content : workspace -> string -> Yojson.Safe.t option
val state_defaults : workspace -> (string * Yojson.Safe.t) list
val panel_state_defaults :
  workspace -> string -> (string * Yojson.Safe.t) list
val icons : workspace -> Yojson.Safe.t
val dialogs : workspace -> Yojson.Safe.t
val dialog : workspace -> string -> Yojson.Safe.t option
val dialog_state_defaults :
  workspace -> string -> (string * Yojson.Safe.t) list
val swatch_libraries : workspace -> Yojson.Safe.t

(** [concepts_list ws] returns the concept-pack registry as a sorted list of
    [{id, name, description}] objects (by id) for the Concepts panel. *)
val concepts_list : workspace -> Yojson.Safe.t

val brush_libraries : workspace -> Yojson.Safe.t
(* Brush libraries map keyed by slug; reads
   workspace_data["brush_libraries"]. Returns an empty Assoc when
   the workspace ships without brushes. *)

val panel_kind_to_content_id : Workspace_layout.panel_kind -> string
