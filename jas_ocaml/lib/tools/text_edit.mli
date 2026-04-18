(** In-place text editing session shared by Type_tool and Type_on_path_tool. *)

type edit_target = Edit_text | Edit_text_path

type t

val create :
  path:int list -> target:edit_target -> content:string -> insertion:int -> t

val path : t -> int list
val target : t -> edit_target
val content : t -> string
val insertion : t -> int
val anchor : t -> int
val set_drag_active : t -> bool -> unit
val drag_active : t -> bool
val blink_epoch_ms : t -> float
val set_blink_epoch_ms : t -> float -> unit

val has_selection : t -> bool
val selection_range : t -> int * int

val insert : t -> string -> unit
val backspace : t -> unit
val delete_forward : t -> unit
val set_insertion : t -> int -> extend:bool -> unit

(** Move the caret with an explicit affinity. Use when crossing a
    tspan boundary — arrow-right lands with [Right], arrow-left with
    [Left]. The char-indexed overload [set_insertion] keeps defaulting
    to [Left] per TSPAN.md. *)
val set_insertion_with_affinity :
  t -> int -> affinity:Tspan.affinity -> extend:bool -> unit

val caret_affinity : t -> Tspan.affinity

(** Prime the next-typed-character state. Non-[None] fields of
    [overrides] are merged into the existing pending template; the
    anchor position is captured on the first call (later calls layer
    on more attributes without moving the anchor). *)
val set_pending_override : t -> Element.tspan -> unit

val clear_pending_override : t -> unit
val has_pending_override : t -> bool
val pending_override : t -> Element.tspan option
val pending_char_start : t -> int option

(** Wrap [t] as a [Model.edit_session_ref] so callers in layers
    above [tools] (notably the Character-panel pipeline in
    [Effects]) can reach the session without a direct dependency on
    [Text_edit]. *)
val as_session_ref : t -> Model.edit_session_ref

(** Resolve the caret's [(tspan_idx, offset)] using [caret_affinity].
    Used by the next-typed-character path. *)
val insertion_tspan_pos : t -> Element.tspan array -> int * int

(** Resolve the selection anchor's [(tspan_idx, offset)]. Anchors do
    not have an independent affinity; they track the caret's. *)
val anchor_tspan_pos : t -> Element.tspan array -> int * int

val select_all : t -> unit
val copy_selection : t -> string option

(** Capture the selection's flat text and tspan structure (from
    [element_tspans]) into the session clipboard. Returns the flat
    text for the system clipboard, or [None] if there is no
    selection. Mirrors Rust's [copy_selection_with_tspans]. *)
val copy_selection_with_tspans :
  t -> Element.tspan array -> string option

(** When the session clipboard's flat text matches [text], splice
    the captured tspans into [element_tspans] at the caret and
    return the resulting tspan array. Otherwise [None] — caller
    falls back to [insert]. *)
val try_paste_tspans :
  t -> Element.tspan array -> string -> Element.tspan array option

(** Atomic content / caret update after an external tspan-aware
    paste rewrote the underlying element. *)
val set_content :
  t -> string -> insertion:int -> anchor:int -> unit

val undo : t -> unit
val redo : t -> unit

(** Apply the session's content to the document, returning the new document
    or [None] if the path no longer points to a matching element. *)
val apply_to_document : t -> Document.document -> Document.document option

(** Helpers to construct empty Text and Text_path elements. *)
val empty_text_elem : float -> float -> float -> float -> Element.element
val empty_text_path_elem : Element.path_command list -> Element.element
