(* See the .mli for the contract. *)

let _libs : Yojson.Safe.t ref = ref (`Assoc [])
let _listener : (Yojson.Safe.t -> unit) ref = ref (fun _ -> ())

let set (libs : Yojson.Safe.t) : unit =
  _libs := libs;
  !_listener libs

let get () : Yojson.Safe.t = !_libs

let on_change (cb : Yojson.Safe.t -> unit) : unit =
  _listener := cb
