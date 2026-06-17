(** Symbols panel native glue (SYMBOLS.md section 8, P3 first slice).

    The panel body is rendered generically from
    [workspace/panels/symbols.yaml]; this module supplies only the native
    action arms (value-in-op symbol-store operations, like Make Instance)
    plus the panel-selection accessors. Panel-selection
    ([selected_symbol]) is a single master id stored in the panel's own
    State_store scope under [symbols_panel_content]. *)

(** The Symbols panel content id ([symbols_panel_content]). *)
val content_id : string

(** Menu items for the Symbols panel, read from its [menu:] block in the
    compiled workspace bundle. *)
val menu_items : unit -> Panel_menu_yaml.panel_menu_item list

(** The panel-selected master id, or [None] when none is selected. *)
val selected_symbol : State_store.t -> string option

(** Replace the panel selection with the given master id. *)
val set_selected_symbol : State_store.t -> string -> unit

(** Clear the panel selection. *)
val clear_selected_symbol : State_store.t -> unit

(** Number of live instances of [master_id] = the length of its
    reverse-dependency list in the dependency index (the reference-aware
    delete signal). *)
val usage_count : Document.document -> string -> int

(** NEW SYMBOL: promote the single selected canvas element to a master.
    Enabled only when exactly one whole element is selected; mints
    master + instance ids, snapshots, calls [make_symbol], and keeps the
    new master panel-selected. *)
val new_symbol : State_store.t -> Model.model -> unit

(** PLACE INSTANCE: append a new instance of the panel-selected master.
    No-op when none is selected; mints the instance id, snapshots, and
    calls [place_instance]. *)
val place_instance : State_store.t -> Model.model -> unit

(** DELETE SYMBOL: remove the panel-selected master. Reference-aware:
    when the master still has instances, [confirm] is consulted with the
    count and the delete proceeds only on OK; with no instances it
    deletes silently. Snapshots, calls [delete_symbol], and clears the
    panel selection. *)
val delete_symbol_action :
  State_store.t -> Model.model -> confirm:(int -> bool) -> unit
