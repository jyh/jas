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

(* Render-side projection of the same layout pass.
   [render_plan panel_node avail_w avail_h ctx] returns the JSON object
   {"height": <int panel content height>, "leaves": [{"rect","node","ctx"}, ..]},
   one leaf per renderable widget. [rect] is {x,y,w,h}; [node] is the compiled
   node to render; [ctx] is the (child) data scope to render it with, so a
   foreach-expanded leaf carries its per-row scope. Layout-only nodes
   (container / row / col / grid / panel / disclosure) are omitted. The
   byte-gated [layout_panel] consumes rects only; the render swap consumes this. *)
val render_plan :
  Yojson.Safe.t -> int -> int -> Yojson.Safe.t -> Yojson.Safe.t
