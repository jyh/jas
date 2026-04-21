(** Artboards: print-page regions attached to the document root.

    See [transcripts/ARTBOARDS.md] for the full specification. In
    summary, every document has at least one artboard; [artboard]
    carries position, size, fill, display toggles, and a stable
    8-char base36 [id]. The 1-based [number] shown in the panel is
    derived from list position, not stored.

    Serialization format matches Python + Rust + Swift exactly
    (cross-app contract, ART-441). *)

(** The fill property is a sum type: [Transparent] or an opaque
    colour literal. Canonical string is "transparent" or "#rrggbb". *)
type fill =
  | Transparent
  | Color of string

let fill_as_canonical = function
  | Transparent -> "transparent"
  | Color hex -> hex

let fill_from_canonical = function
  | "transparent" -> Transparent
  | s -> Color s

type artboard = {
  id : string;
  name : string;
  x : float;
  y : float;
  width : float;
  height : float;
  fill : fill;
  show_center_mark : bool;
  show_cross_hairs : bool;
  show_video_safe_areas : bool;
  video_ruler_pixel_aspect_ratio : float;
}

(** Canonical default: Letter 612x792 at origin, transparent fill,
    all display toggles off. *)
let default_with_id id = {
  id;
  name = "Artboard 1";
  x = 0.0;
  y = 0.0;
  width = 612.0;
  height = 792.0;
  fill = Transparent;
  show_center_mark = false;
  show_cross_hairs = false;
  show_video_safe_areas = false;
  video_ruler_pixel_aspect_ratio = 1.0;
}

(** Document-global artboard toggles. Both default to on. *)
type options = {
  fade_region_outside_artboard : bool;
  update_while_dragging : bool;
}

let default_options = {
  fade_region_outside_artboard = true;
  update_while_dragging = true;
}

(* -------------------- id generation -------------------- *)

let id_alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
let id_length = 8

(** Platform-sourced 8-char base36 id. [rng] should return a
    non-negative integer per call; default uses [Random.int]. *)
let generate_id ?(rng = fun () -> Random.int 1_000_000_007) () =
  let buf = Bytes.create id_length in
  for i = 0 to id_length - 1 do
    let n = rng () in
    let idx = (n mod String.length id_alphabet + String.length id_alphabet) mod String.length id_alphabet in
    Bytes.set buf i id_alphabet.[idx]
  done;
  Bytes.to_string buf

(* -------------------- next-name rule -------------------- *)

let parse_default_name name =
  let prefix = "Artboard " in
  let plen = String.length prefix in
  if String.length name <= plen then None
  else if not (String.sub name 0 plen = prefix) then None
  else begin
    let rest = String.sub name plen (String.length name - plen) in
    if rest = "" then None
    else if String.exists (fun c -> not (c >= '0' && c <= '9')) rest then None
    else match int_of_string_opt rest with
      | Some n -> Some n
      | None -> None
  end

(** Pick the next unused "Artboard N" name. *)
let next_name artboards =
  let used = List.filter_map (fun a -> parse_default_name a.name) artboards in
  let used_set = List.sort_uniq compare used in
  let rec find n = if List.mem n used_set then find (n + 1) else n in
  Printf.sprintf "Artboard %d" (find 1)

(* -------------------- invariant -------------------- *)

(** Enforce the at-least-one-artboard invariant. Returns the
    (possibly seeded) list and [true] when a default was inserted. *)
let ensure_invariant ?(id_gen = fun () -> generate_id ()) artboards =
  match artboards with
  | [] -> ([default_with_id (id_gen ())], true)
  | _ -> (artboards, false)
