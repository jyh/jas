(** The single LAYOUT-op dispatcher [layout_apply] (OP_LOG.md section 12,
    Fork 5, Increment 3d-2). The layout analogue of [Op_apply] for document ops.

    PROMOTED out of the cross-language test harness ([apply_workspace_op] in
    [test/cross_language_test.ml]) into this RUNTIME module so production layout
    mutations and the test harness share ONE dispatcher and ONE per-verb
    mutation body. The harness [apply_workspace_op] is now a thin shim over
    [layout_apply]; the production layout-mutation sites (menubar, dock panel,
    canvas pane handlers, per-panel hamburger menus) build a resolved op JSON
    via the [op_*] builders below and call [layout_apply] instead of calling
    the [Workspace_layout]/[Pane] method directly. The mutation is
    byte-identical to the pre-3d-2 direct call.

    LAYOUT STAYS NON-UNDOABLE (OP_LOG.md section 12, Option B): there is NO
    layout journal, NO layout undo, and NO checkpoint-vs-journal gate (that is
    Option C, deliberately NOT done). [layout_apply] is purely the shared
    parse -> apply envelope. The dirty signal is unchanged: the panel/dock verb
    mutators in [Workspace_layout] already call [bump] internally, and pane-verb
    sites wrap the dispatch in [Workspace_layout.panes_mut] (which bumps after
    [f pl]) so [needs_save] still flips at every routed site.

    HARDENED: production input must never panic. A missing/garbage [op] envelope
    string skips; a missing required [kind] string skips; numeric fields read
    with a default of 0 on missing/wrong type; an unknown verb skips. The
    harness fixtures (which always carry well-formed params) replay
    byte-identically. *)

open Workspace_layout

(** Parse a panel-kind op string to its {!Workspace_layout.panel_kind}. Complete
    over all 13 kinds; an unknown/garbage string falls back to [Layers]. *)
val parse_panel_kind_str : string -> panel_kind

(** Serialize a {!Workspace_layout.panel_kind} to its canonical lowercase op
    string (inverse of {!parse_panel_kind_str}). *)
val panel_kind_str : panel_kind -> string

(** Parse a pane-kind op string to its {!Pane.pane_kind}. Unknown falls back to
    [Canvas]. *)
val parse_pane_kind_str : string -> Pane.pane_kind

(** Serialize a {!Pane.pane_kind} to its canonical op string. *)
val pane_kind_str : Pane.pane_kind -> string

(* --- Op-JSON builders (production -> dispatcher). One place per verb shape. --- *)

val op_toggle_group_collapsed : group_addr -> Yojson.Safe.t
val op_set_active_panel : panel_addr -> Yojson.Safe.t
val op_close_panel : panel_addr -> Yojson.Safe.t
val op_show_panel : panel_kind -> Yojson.Safe.t
val op_reorder_panel : group_addr -> from:int -> to_:int -> Yojson.Safe.t
val op_move_panel_to_group : from:panel_addr -> to_:group_addr -> Yojson.Safe.t
val op_detach_group : group_addr -> x:float -> y:float -> Yojson.Safe.t
val op_redock : dock_id -> Yojson.Safe.t

val op_set_pane_position : Pane.pane_id -> x:float -> y:float -> Yojson.Safe.t
val op_tile_panes : ?override:(Pane.pane_id * float) -> unit -> Yojson.Safe.t
val op_toggle_canvas_maximized : unit -> Yojson.Safe.t
val op_resize_pane : Pane.pane_id -> width:float -> height:float -> Yojson.Safe.t
val op_hide_pane : Pane.pane_kind -> Yojson.Safe.t
val op_show_pane : Pane.pane_kind -> Yojson.Safe.t
val op_bring_pane_to_front : Pane.pane_id -> Yojson.Safe.t

(** Apply one primitive LAYOUT op to [layout]. The SINGLE per-verb mutation body
    shared by production and the cross-language harness. Hardened: a malformed
    op (missing/unknown verb, missing required [kind]) SKIPS without mutating or
    raising. *)
val layout_apply : workspace_layout -> Yojson.Safe.t -> unit
