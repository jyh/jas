(** Planar graph extraction: turn a collection of polylines into a
    planar subdivision and enumerate the bounded faces. Port of
    jas_dioxus/src/algorithms/planar.rs. *)

type point = float * float

type polyline = point array

type vertex_id = int
type half_edge_id = int
type face_id = int

type vertex = {
  pos : point;
  outgoing : half_edge_id;
}

type half_edge = {
  origin : vertex_id;
  twin : half_edge_id;
  next : half_edge_id;
  prev : half_edge_id;
}

type face = {
  boundary : half_edge_id;
  holes : half_edge_id list;
  parent : face_id option;
  depth : int;
}

type t = {
  vertices : vertex array;
  half_edges : half_edge array;
  faces : face array;
}

(** Build a planar graph from a set of polylines. *)
val build : polyline list -> t

(** Number of bounded faces. *)
val face_count : t -> int

(** Absolute area of a face's outer boundary, ignoring its holes. *)
val face_outer_area : t -> face_id -> float

(** Net area of a face: outer boundary minus holes. *)
val face_net_area : t -> face_id -> float

(** Hit test: deepest face containing the given point, or [None]. A
    point in a hole returns the hole's face, not its parent. *)
val hit_test : t -> point -> face_id option

(** All top-level faces (depth 1). *)
val top_level_faces : t -> face_id list
