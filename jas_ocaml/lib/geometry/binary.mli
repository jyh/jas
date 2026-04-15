(** Binary document serialization using MessagePack + deflate. *)

val document_to_binary : ?compress:bool -> Document.document -> string
val binary_to_document : string -> Document.document
