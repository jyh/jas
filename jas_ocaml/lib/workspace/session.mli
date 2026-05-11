(** Session persistence — save the open canvases on quit and reload
    them on launch. See ``session.ml`` header for the on-disk layout. *)

type tab_save = {
  filename : string;
  document : Document.document;
}

(** Persist the current tabs to ``~/.config/jas/session/``. Best-effort:
    swallows I/O errors so a failed save can't block app quit. *)
val save_session : tabs:tab_save list -> active_index:int option -> unit

(** Reload the session. Returns ``Some (active_index, [(filename, doc); ...])``
    when at least one tab decodes successfully. *)
val load_session : unit -> (int option * (string * Document.document) list) option
