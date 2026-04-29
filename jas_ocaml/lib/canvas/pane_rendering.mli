(** Pane rendering helpers: pure functions that compute rendering data
    from PaneLayout state. No GTK code. *)

type pane_geometry = {
  id : int;
  kind : Pane.pane_kind;
  config : Pane.pane_config;
  x : float;
  y : float;
  width : float;
  height : float;
  z_index : int;
  visible : bool;
}

type shared_border = {
  snap_idx : int;
  bx : float;
  by : float;
  bw : float;
  bh : float;
  is_vertical : bool;
}

type snap_line = {
  lx : float;
  ly : float;
  lw : float;
  lh : float;
}

(** Effective on-screen geometry of every pane (after maximize). *)
val pane_geometries : Pane.pane_layout -> pane_geometry list

(** Shared borders between snapped panes that can be dragged to
    resize. Empty when the canvas is maximized. *)
val shared_borders : Pane.pane_layout -> shared_border list

(** Snap-preview overlay lines drawn during a pane drag. *)
val snap_lines : Pane.snap_constraint list -> Pane.pane_layout -> snap_line list
