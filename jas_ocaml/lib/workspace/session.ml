(** Session persistence — save the open canvases on quit and reload
    them on launch so dev iteration doesn't have to redraw test
    content every restart.

    Session lives in ``~/.config/jas/session/``:
    - ``index.json``  — tab order, filenames, active-tab pointer.
    - ``tabN.jasbin`` — each tab's document, in JAS binary format
      (cross-port compatible with jas_dioxus / JasSwift / jas_flask;
      see ``geometry/binary.ml``).

    The session is rewritten in full on every save (no incremental
    updates) — the data volume is tiny and the codec is fast enough
    that this stays well under perceptible delay even with several
    tabs. Mirrors ``JasSwift/Sources/Canvas/Session.swift`` and
    ``jas_dioxus/src/workspace/session.rs``. *)

let session_dir () =
  let home = try Sys.getenv "HOME" with Not_found -> "." in
  Filename.concat home ".config/jas/session"

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let read_file_bin path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let data = really_input_string ic len in
  close_in ic;
  data

let write_file_bin path data =
  let oc = open_out_bin path in
  output_string oc data;
  close_out oc

let write_file_text path data =
  let oc = open_out path in
  output_string oc data;
  close_out oc

(** Wipe existing ``tabN.jasbin`` files so a closed-tab file doesn't
    reappear when the new session has fewer tabs. *)
let clear_tab_blobs dir =
  if Sys.file_exists dir then begin
    Array.iter (fun name ->
      if Filename.check_suffix name ".jasbin" then
        try Sys.remove (Filename.concat dir name) with _ -> ()
    ) (Sys.readdir dir)
  end

type tab_save = {
  filename : string;
  document : Document.document;
}

(** Persist the current open canvases to disk. Best-effort: any I/O
    error is swallowed (a failed session save shouldn't block app
    quit). When [tabs] is empty the session directory is cleared so
    the next launch starts fresh. *)
let save_session ~(tabs : tab_save list) ~(active_index : int option) : unit =
  try
    let dir = session_dir () in
    mkdir_p dir;
    clear_tab_blobs dir;
    let tab_entries = List.mapi (fun i (t : tab_save) ->
      let bin = Printf.sprintf "tab%d.jasbin" i in
      let path = Filename.concat dir bin in
      let data = Binary.document_to_binary ~compress:true t.document in
      write_file_bin path data;
      `Assoc [
        ("filename", `String t.filename);
        ("binFile", `String bin);
      ]
    ) tabs in
    let active_json = match active_index with
      | Some i -> `Int i
      | None -> `Null in
    let manifest = `Assoc [
      ("schemaVersion", `Int 1);
      ("tabs", `List tab_entries);
      ("activeIndex", active_json);
    ] in
    write_file_text
      (Filename.concat dir "index.json")
      (Yojson.Safe.to_string manifest)
  with _ -> ()

(** Reload the session saved by [save_session]. Returns
    ``Some (active_index, [(filename, document); ...])`` when a session
    is present and at least one tab decoded successfully; ``None``
    otherwise. Individual tab failures are skipped (logged to stderr)
    so a single corrupt blob doesn't lose the rest of the session. *)
let load_session () : (int option * (string * Document.document) list) option =
  let dir = session_dir () in
  let index_path = Filename.concat dir "index.json" in
  if not (Sys.file_exists index_path) then None
  else
    try
      let json = Yojson.Safe.from_file index_path in
      let open Yojson.Safe.Util in
      let version =
        match json |> member "schemaVersion" |> to_int_option with
        | Some v -> v | None -> 0 in
      if version <> 1 then begin
        Printf.eprintf "[session] unsupported schemaVersion %d\n%!" version;
        None
      end else
        let active_index = match json |> member "activeIndex" with
          | `Int i -> Some i
          | _ -> None in
        let tabs = match json |> member "tabs" with
          | `List xs -> xs | _ -> [] in
        let restored = List.filter_map (fun t ->
          let filename = t |> member "filename" |> to_string_option
                         |> Option.value ~default:"" in
          let bin_file = t |> member "binFile" |> to_string_option
                         |> Option.value ~default:"" in
          if filename = "" || bin_file = "" then None
          else
            let path = Filename.concat dir bin_file in
            if not (Sys.file_exists path) then begin
              Printf.eprintf "[session] missing tab blob %s\n%!" bin_file;
              None
            end else
              try
                let data = read_file_bin path in
                let doc = Binary.binary_to_document data in
                (* The binary format predates the artboards feature
                   so binary_to_document returns artboards = []. The
                   canvas relies on the at-least-one-artboard
                   invariant; without this fix the restored doc has
                   no artboard frame and centering early-returns,
                   leaving the canvas blank. Mirrors the same fix in
                   jas_dioxus / JasSwift load_session. *)
                let (repaired, _) =
                  Artboard.ensure_invariant doc.Document.artboards in
                let doc =
                  if List.length repaired <> List.length doc.Document.artboards
                  then { doc with Document.artboards = repaired }
                  else doc in
                Some (filename, doc)
              with e ->
                Printf.eprintf "[session] decode %s failed: %s\n%!"
                  bin_file (Printexc.to_string e);
                None
        ) tabs in
        if restored = [] then None
        else Some (active_index, restored)
    with e ->
      Printf.eprintf "[session] load failed: %s\n%!" (Printexc.to_string e);
      None
