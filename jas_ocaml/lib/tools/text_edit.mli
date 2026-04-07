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
val select_all : t -> unit
val copy_selection : t -> string option

val undo : t -> unit
val redo : t -> unit

(** Apply the session's content to the document, returning the new document
    or [None] if the path no longer points to a matching element. *)
val apply_to_document : t -> Document.document -> Document.document option

(** Helpers to construct empty Text and Text_path elements. *)
val empty_text_elem : float -> float -> float -> float -> Element.element
val empty_text_path_elem : Element.path_command list -> Element.element
