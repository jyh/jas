(** Shared mutable state for the Layers panel.

    Lives in its own module to avoid a dependency cycle between
    panel_menu (which dispatches YAML actions that mutate the stack)
    and yaml_panel_view (which reads the stack when rendering).

    Invariant: the Layers panel is a singleton in the app, so treating
    these as module-level mutable state is safe. All access happens on
    the GTK main thread (render callbacks and menu-dispatch callbacks).
*)

(* ── Isolation stack ───────────────────────────────────────── *)

let _isolation_stack : int list list ref = ref []

(** Push a top-level isolation target onto the stack. *)
let push_isolation_level (path : int list) =
  _isolation_stack := path :: !_isolation_stack

(** Pop the innermost isolation level. No-op when the stack is empty. *)
let pop_isolation_level () =
  match !_isolation_stack with
  | _ :: rest -> _isolation_stack := rest
  | [] -> ()

(** The current stack, newest level first. *)
let get_isolation_stack () = !_isolation_stack

(** Replace the full stack (used by breadcrumb navigation). *)
let set_isolation_stack (stack : int list list) =
  _isolation_stack := stack

(** Clear all isolation levels. *)
let clear_isolation_stack () =
  _isolation_stack := []

(* ── Panel UI state ────────────────────────────────────────── *)

module PathKey = struct
  type t = int list
  let compare = compare
end
module PathSet = Set.Make(PathKey)
module PathMap = Map.Make(PathKey)
module StrSet = Set.Make(String)

(** Set of collapsed element paths in the tree. *)
let collapsed : PathSet.t ref = ref PathSet.empty

(** Set of panel-selected element paths (distinct from the document's
    element selection; drives context-menu and group actions). *)
let panel_selection : PathSet.t ref = ref PathSet.empty

(** Path of the layer currently being inline-renamed, or None. *)
let renaming : int list option ref = ref None

(** Drag source and target paths for drag-and-drop reordering. *)
let drag_source : int list option ref = ref None
let drag_target : int list option ref = ref None

(** Search query for filtering the layers tree by name. *)
let search_query : string ref = ref ""

(** Lowercased element type names currently hidden by the filter. *)
let hidden_types : StrSet.t ref = ref StrSet.empty

(** Saved direct-child lock states keyed by container path, used to
    restore locks when toggle-all-layers-lock is undone. *)
let saved_lock_states : bool list PathMap.t ref = ref PathMap.empty

(** Solo/unsolo state: (soloed path, per-sibling saved visibility). *)
let solo_state :
  (int list * (int list * Element.visibility) list) option ref = ref None

(** Callback that triggers a re-render when UI state changes. The
    yaml_panel_view wires this to the layers panel's own re-render
    thunk once the panel is mounted. *)
let rerender : (unit -> unit) ref = ref (fun () -> ())

(** Return the current panel selection as a list of paths. Called by
    the panel-menu dispatcher through dock_panel so Group B actions
    (delete/duplicate_layer_selection) can read the panel selection. *)
let get_panel_selection () : int list list =
  PathSet.elements !panel_selection
