(** Knuth-Liang TeX hyphenation. See the .ml file header. *)

(** Split a TeX hyphenation pattern into its letter sequence and
    per-position digit array. Returns [(letters, digits)] where
    [Array.length digits = String.length letters + 1]. *)
val split_pattern : string -> string * int array

(** Compute valid break positions in [word] per the given patterns.
    Returns a [bool array] of length [String.length word + 1].
    Suppresses breaks within the first [min_before] or last
    [min_after] characters of the word. *)
val hyphenate :
  string -> string list ->
  min_before:int -> min_after:int -> bool array

(** A small en-US pattern set for testing. Production callers should
    load the full TeX dictionary via a packaged resource (tracked
    separately). *)
val en_us_patterns_sample : string list
