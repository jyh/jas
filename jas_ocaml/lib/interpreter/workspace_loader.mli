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

val panel : workspace -> string -> Yojson.Safe.t option
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
val panel_kind_to_content_id : Workspace_layout.panel_kind -> string
