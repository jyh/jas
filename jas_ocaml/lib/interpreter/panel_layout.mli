(* Shared canonical panel widget-layout pass (Path B).

   Lay out a compiled panel node ({"type":"panel","content":<root>}) into a
   pre-order, panel-relative JSON array of {"path":[..],"rect":{x,y,w,h}}.
   Pure integer arithmetic; byte-identical across all five apps. The full
   contract is PATH_B_DESIGN.md Appendix A (+ Appendix B for foreach).

   [layout_panel panel_node avail_w avail_h ctx]: [avail_h] drives vertical
   flex (0 = none); [ctx] is the data scope (a Yojson object) used to evaluate
   foreach sources and text bindings (empty object = literals only). *)

val layout_panel :
  Yojson.Safe.t -> int -> int -> Yojson.Safe.t -> Yojson.Safe.t
