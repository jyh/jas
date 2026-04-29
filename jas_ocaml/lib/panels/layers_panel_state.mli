(** Shared mutable state for the Layers panel.

    Lives in its own module to avoid a dependency cycle between
    panel_menu (which dispatches YAML actions that mutate the stack)
    and yaml_panel_view (which reads the stack when rendering). All
    access happens on the GTK main thread. *)

(* ── Isolation stack ───────────────────────────────────────── *)

val push_isolation_level : int list -> unit
val pop_isolation_level : unit -> unit
val get_isolation_stack : unit -> int list list
val set_isolation_stack : int list list -> unit
val clear_isolation_stack : unit -> unit

(* ── Path / type collections ───────────────────────────────── *)

module PathKey : sig
  type t = int list
  val compare : t -> t -> int
end

module PathSet : Set.S with type elt = int list
module PathMap : Map.S with type key = int list
module StrSet : Set.S with type elt = string

(* ── Panel UI state ────────────────────────────────────────── *)

(** Set of collapsed element paths in the tree. *)
val collapsed : PathSet.t ref

(** Set of panel-selected element paths (distinct from the document's
    element selection). *)
val panel_selection : PathSet.t ref

(** Path of the layer currently being inline-renamed, or None. *)
val renaming : int list option ref

(** Drag-and-drop reordering source / target. *)
val drag_source : int list option ref
val drag_target : int list option ref

(** Search query for filtering the layers tree by name. *)
val search_query : string ref

(** Lowercased element type names currently hidden by the filter. *)
val hidden_types : StrSet.t ref

(** Saved direct-child lock states for restore-on-undo of
    toggle-all-layers-lock. *)
val saved_lock_states : bool list PathMap.t ref

(** Solo/unsolo state: (soloed path, per-sibling saved visibility). *)
val solo_state :
  (int list * (int list * Element.visibility) list) option ref

(** Re-render thunk wired by yaml_panel_view on mount. *)
val rerender : (unit -> unit) ref

(** Current panel selection as a list of paths. *)
val get_panel_selection : unit -> int list list
