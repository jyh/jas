(* Shared canonical panel widget-layout pass (Path B).

   Lay out a compiled panel node ({"type":"panel","content":<root>}) into a
   pre-order, panel-relative JSON array of {"path":[..],"rect":{x,y,w,h}}.
   Pure integer arithmetic; byte-identical across all five apps. The full
   contract is PATH_B_DESIGN.md Appendix A. *)

val layout_panel : Yojson.Safe.t -> int -> Yojson.Safe.t
