(** Path-level operations: anchor insertion / deletion, eraser
    split, cubic/quad evaluation + projection.

    L2 primitives per NATIVE_BOUNDARY.md §5 — shared across
    vector-illustration apps. *)

open Element

(* ── Basic helpers ──────────────────────────────────────── *)

val lerp : float -> float -> float -> float

val eval_cubic :
  float -> float -> float -> float ->
  float -> float -> float -> float -> float ->
  float * float

val cmd_endpoint : path_command -> (float * float) option
val cmd_start_points : path_command list -> (float * float) list
val cmd_start_point : path_command list -> int -> float * float

(* ── Flattening ─────────────────────────────────────────── *)

(** Flatten commands to a polyline with a parallel cmd-index map. *)
val flatten_with_cmd_map :
  path_command list -> (float * float) list * int list

(* ── Projection ─────────────────────────────────────────── *)

val closest_on_line :
  float -> float -> float -> float -> float -> float -> float * float

val closest_on_cubic :
  float -> float -> float -> float ->
  float -> float -> float -> float ->
  float -> float -> float * float

val closest_segment_and_t :
  path_command list -> float -> float -> (int * float) option

(* ── Splitting ──────────────────────────────────────────── *)

val split_cubic :
  float -> float -> float -> float ->
  float -> float -> float -> float -> float ->
  (float * float * float * float * float * float) *
  (float * float * float * float * float * float)

val split_cubic_cmd_at :
  (float * float) -> float -> float -> float -> float ->
  float -> float -> float -> path_command * path_command

val split_quad_cmd_at :
  (float * float) -> float -> float -> float -> float -> float ->
  path_command * path_command

(* ── Anchor operations ──────────────────────────────────── *)

val delete_anchor_from_path :
  path_command list -> int -> path_command list option

type insert_anchor_result = {
  commands : path_command list;
  first_new_idx : int;
  anchor_x : float;
  anchor_y : float;
}

val insert_point_in_path :
  path_command list -> int -> float -> insert_anchor_result

(* ── Liang-Barsky ───────────────────────────────────────── *)

val liang_barsky_t_min :
  float -> float -> float -> float ->
  float -> float -> float -> float -> float

val liang_barsky_t_max :
  float -> float -> float -> float ->
  float -> float -> float -> float -> float

val line_segment_intersects_rect :
  float -> float -> float -> float ->
  float -> float -> float -> float -> bool

(* ── Eraser ─────────────────────────────────────────────── *)

type eraser_hit = {
  first_flat_idx : int;
  last_flat_idx : int;
  entry_t_seg : float;
  entry : float * float;
  exit_t_seg : float;
  exit_pt : float * float;
}

val find_eraser_hit :
  (float * float) list -> float -> float -> float -> float ->
  eraser_hit option

val flat_index_to_cmd_and_t :
  path_command list -> int -> float -> int * float

val entry_cmd : path_command -> (float * float) -> float -> path_command
val exit_cmd : path_command -> (float * float) -> float -> path_command

val split_path_at_eraser :
  path_command list -> eraser_hit -> bool -> path_command list list
