(** Menu enabled/checked evaluation (TESTING_STRATEGY.md chrome seam).

    OCaml port of [workspace_interpreter.menu_state]. Walks the compiled bundle
    [menubar] and evaluates each action item's [enabled_when] / [checked_when]
    predicate against [ctx], producing a pre-order JSON array of
    [{path, action, enabled, checked}] records: [enabled] defaults to true with
    no [enabled_when]; [checked] is null with no [checked_when]. Separators (a
    bare ["separator"] string) and submenu nodes are skipped, but a submenu's
    children are walked with an extended path. The only thing evaluated is each
    item's predicate, so this is a cross-app byte-gate over the menu's dynamic
    state. *)

(** [menu_state menubar ctx]: [menubar] is the bundle menubar array (a
    [`List] of menu objects), [ctx] the data scope (a Yojson object). Returns
    the [`List] of per-action-item records described above. *)
val menu_state : Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
