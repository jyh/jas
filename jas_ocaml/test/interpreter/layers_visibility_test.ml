(* Layers-panel eye-button visibility cycle. The tree-row eye button cycles
   an element's visibility Preview -> Outline -> Invisible -> Preview
   (Element.cycle_visibility, shared by the eye handler). Cross-app
   equivalent: Rust cycle_element_visibility, Swift cycleVisibility,
   Python _cycle_visibility. *)

let vis = Alcotest.testable
  (fun ppf v -> Format.fprintf ppf "%s" (match v with
     | Jas.Element.Preview -> "preview"
     | Jas.Element.Outline -> "outline"
     | Jas.Element.Invisible -> "invisible"))
  (=)

let test_cycle_order () =
  let open Jas.Element in
  Alcotest.check vis "preview->outline" Outline (cycle_visibility Preview);
  Alcotest.check vis "outline->invisible" Invisible (cycle_visibility Outline);
  Alcotest.check vis "invisible->preview" Preview (cycle_visibility Invisible)

let test_full_loop () =
  let open Jas.Element in
  (* Three cycles return to the start. *)
  let v = cycle_visibility (cycle_visibility (cycle_visibility Preview)) in
  Alcotest.check vis "3x cycle back to preview" Preview v

let test_applies_to_element () =
  (* Cycling an element's visibility via set_visibility + cycle_visibility. *)
  let open Jas.Element in
  let e = make_rect 0.0 0.0 10.0 10.0 in
  Alcotest.check vis "starts preview" Preview (get_visibility e);
  let e1 = set_visibility (cycle_visibility (get_visibility e)) e in
  Alcotest.check vis "after 1 cycle outline" Outline (get_visibility e1);
  let e2 = set_visibility (cycle_visibility (get_visibility e1)) e1 in
  Alcotest.check vis "after 2 cycles invisible" Invisible (get_visibility e2)

let () =
  Alcotest.run "LayersVisibility"
    [
      ( "cycle",
        [
          Alcotest.test_case "order" `Quick test_cycle_order;
          Alcotest.test_case "full loop" `Quick test_full_loop;
          Alcotest.test_case "applies to element" `Quick test_applies_to_element;
        ] );
    ]
