(** App-global rich clipboard cache.

    GTK's OCaml bindings don't expose multi-format clipboard write
    (there's [set_text] / [set_image] but no [set_with_data]
    equivalent). Rather than extend the C bindings, we mirror the
    Rust approach: keep a module-level cache of [(flat_text, tspans)]
    so cross-element rich paste works within one process. Cross-app
    paste falls back to plain text.

    Paired with the serializers in {!Tspan.tspans_to_json_clipboard}
    / {!Tspan.tspans_to_svg_fragment}, ready for a later round that
    wires the native multi-format clipboard (via extended bindings
    or the selection API). *)

let _cache : (string * Element.tspan array) option ref = ref None

(** Publish a rich-copy payload: the flat text (mirrored to the OS
    clipboard by the caller) plus the source tspan list. Survives
    across edit sessions within one app process. *)
let write (flat : string) (tspans : Element.tspan array) : unit =
  _cache := Some (flat, tspans)

(** Retrieve the cached tspan list if its flat text matches [flat],
    else [None]. Callers consult this on paste after reading the
    OS clipboard's plain text. *)
let read_matching (flat : string) : Element.tspan array option =
  match !_cache with
  | Some (f, t) when f = flat -> Some t
  | _ -> None

let _clear_for_test () = _cache := None
