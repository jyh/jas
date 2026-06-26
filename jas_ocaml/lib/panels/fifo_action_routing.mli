(** Native-first routing for named workspace actions reaching the app from a
    name-driven caller (today: the test-only [--test-fifo] [action <name>]
    channel in bin/main.ml).

    Document-mutating menubar / edit actions ([select_all],
    [delete_selection], ...) are NATIVE-INTERCEPTED: their actions.yaml
    [effects] are deliberate [log] / [if] stubs whose real behavior lives in
    native code, so the GENERIC dispatcher
    ([Panel_menu.dispatch_yaml_action]) would no-op them. [dispatch] routes
    those mutations through the SAME native ops the menu / keyboard handlers
    use, and falls through to the generic dispatcher for genuine panel /
    generic-effect actions. Mirrors the Python
    MainWindow._dispatch_action_by_name for cross-app equivalence. *)

(** Select all elements in [model] (the menubar Edit > Select All op).
    Selection-only (no journaled mutation). *)
val select_all : Model.model -> unit

(** Delete the current selection in [model] via the SHARED [Op_apply.op_apply]
    dispatcher, in one named transaction ([delete_orphan_confirm_ok]) — the
    SAME journaled one-undo-step delete the keyboard Delete path uses. No-op
    when the selection is empty. Window-free: the keyboard path's GUI
    orphan-confirm is intentionally not replicated here. *)
val delete_selection : Model.model -> unit

(** Route [name] native-first: [select_all] / [delete_selection] run their
    native document mutation on [model]; any other name falls through to
    [fallthrough] (default: [Panel_menu.dispatch_yaml_action]) with [params]
    forwarded verbatim. [fallthrough] is injectable so a unit test can spy on
    the fall-through (mirroring the Python spy of the panel dispatcher). *)
val dispatch :
  ?fallthrough:(params:(string * Yojson.Safe.t) list -> string -> Model.model -> unit) ->
  ?params:(string * Yojson.Safe.t) list ->
  string -> Model.model -> unit
