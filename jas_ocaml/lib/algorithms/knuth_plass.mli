(** Knuth-Plass every-line composer. See the .ml file header. *)

type item =
  | Box of { width : float; char_idx : int }
  | Glue of { width : float; stretch : float; shrink : float; char_idx : int }
  | Penalty of { width : float; value : float; flagged : bool; char_idx : int }

val item_width : item -> float
val item_char_idx : item -> int

type opts = {
  line_penalty : float;
  flagged_demerit : float;
  max_ratio : float;
}

val default_opts : opts
val penalty_infinity : float

type brk = { item_idx : int; ratio : float; flagged : bool }

(** Run the DP composer. Returns [None] when no feasible composition
    exists (caller falls back to greedy first-fit). The caller must
    terminate [items] with a forced penalty (value = -.penalty_infinity). *)
val compose : ?opts:opts -> item array -> float array -> brk list option
