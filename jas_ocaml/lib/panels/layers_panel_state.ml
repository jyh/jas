(** Shared mutable state for the Layers panel.

    Lives in its own module to avoid a dependency cycle between
    panel_menu (which dispatches YAML actions that mutate the stack)
    and yaml_panel_view (which reads the stack when rendering). *)

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
