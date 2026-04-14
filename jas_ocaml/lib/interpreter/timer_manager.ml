(** Timer manager for start_timer/cancel_timer effects.

    Manages named delayed timers for the YAML interpreter. Uses
    GMain.Timeout for GTK3 event loop integration. *)

let timers : (string, GMain.Timeout.id) Hashtbl.t = Hashtbl.create 16

(** Cancel a pending timer by ID. *)
let cancel_timer (id : string) : unit =
  match Hashtbl.find_opt timers id with
  | Some timer_id ->
    GMain.Timeout.remove timer_id;
    Hashtbl.remove timers id
  | None -> ()

(** Start a named timer that fires after delay_ms.
    If a timer with the same id already exists, it is cancelled first. *)
let start_timer (id : string) (delay_ms : int) (callback : unit -> unit) : unit =
  cancel_timer id;
  let timer_id = GMain.Timeout.add ~ms:delay_ms ~callback:(fun () ->
    Hashtbl.remove timers id;
    callback ();
    false  (* don't repeat *)
  ) in
  Hashtbl.replace timers id timer_id
