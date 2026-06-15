open Jas.Element
open Jas.Document

let roundtrip doc =
  let svg = Jas.Svg.document_to_svg doc in
  Jas.Svg.svg_to_document svg

let pt v = v *. 72.0 /. 96.0

let () =
  Alcotest.run "SVG" [
    "svg", [
      Alcotest.test_case "empty document produces valid SVG" `Quick (fun () ->
        let doc = make_document [|make_layer [||]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (String.length svg > 0);
        assert (try let _ = String.index svg '<' in true with Not_found -> false));

      Alcotest.test_case "line coordinates converted: 72pt -> 96px" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_line ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 36.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|x2="96"|}) svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|y2="48"|}) svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "rect with fill and stroke" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_rect ~fill:(Some (make_fill (make_color 1.0 0.0 0.0)))
            ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
            0.0 0.0 72.0 72.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|fill="rgb(255,0,0)"|}) svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|stroke="rgb(0,0,0)"|}) svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|width="96"|}) svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "circle" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_circle ~fill:(Some (make_fill (make_color 0.0 0.0 1.0))) 36.0 36.0 18.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|cx="48"|}) svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|r="24"|}) svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "polygon" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_polygon ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
            [(0.0, 0.0); (72.0, 0.0); (36.0, 72.0)]
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string "<polygon") svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string "0,0 96,0 48,96") svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "path with commands" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
            [MoveTo (0.0, 0.0); LineTo (72.0, 72.0); ClosePath]
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string "M0,0") svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string "L96,96") svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string "Z") svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "no fill => fill=\"none\"" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_rect ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 72.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|fill="none"|}) svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "opacity" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_rect ~opacity:0.5 0.0 0.0 72.0 72.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|opacity="0.5"|}) svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "full opacity omitted" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_rect ~opacity:1.0 0.0 0.0 72.0 72.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (not (try let _ : int = Str.search_forward (Str.regexp_string "opacity=") svg 0 in true
                     with Not_found -> false)));

      Alcotest.test_case "transform: translate(36,18) -> e=48, f=24" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_rect ~transform:(Some (make_translate 36.0 18.0)) 0.0 0.0 72.0 72.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|transform="matrix(1,0,0,1,48,24)"|}) svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "layer name" `Quick (fun () ->
        let doc = make_document [|make_layer ~name:"Background" [|
          make_rect 0.0 0.0 72.0 72.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|inkscape:label="Background"|}) svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "text" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_text ~fill:(Some (make_fill (make_color 0.0 0.0 0.0)))
            ~font_family:"Arial" ~font_size:12.0 10.0 20.0 "Hello"
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|font-family="Arial"|}) svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string ">Hello</text>") svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "flat text has no tspan wrapper" `Quick (fun () ->
        (* A Text with a single no-override tspan should round-trip as
           flat SVG — no <tspan> wrapper, no xml:space="preserve". *)
        let doc = make_document [|make_layer [|
          make_text 0.0 0.0 "Hello"
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (not (try let _ : int = Str.search_forward (Str.regexp_string "<tspan") svg 0 in true
                     with Not_found -> false));
        assert (not (try let _ : int = Str.search_forward (Str.regexp_string "xml:space") svg 0 in true
                     with Not_found -> false));
        assert (try let _ : int = Str.search_forward (Str.regexp_string ">Hello</text>") svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "multi-tspan text emits tspan children" `Quick (fun () ->
        (* Two tspans with distinct overrides round-trip as <tspan>
           children + xml:space="preserve" on the parent <text>. *)
        let base = make_text 0.0 0.0 "Hello world" in
        let overriden =
          match base with
          | Text r ->
            let tspans = [|
              { (Jas.Tspan.default_tspan ()) with content = "Hello " };
              { (Jas.Tspan.default_tspan ()) with
                id = 1; content = "world"; font_weight = Some "bold" };
            |] in
            Text { r with tspans }
          | _ -> assert false
        in
        let doc = make_document [|make_layer [| overriden |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string "xml:space=\"preserve\"") svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string "<tspan>Hello </tspan>") svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string "<tspan font-weight=\"bold\">world</tspan>") svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "tspan round-trip preserves overrides" `Quick (fun () ->
        (* Round-trip a two-tspan text through SVG and back: content,
           override attributes, and tspan count are preserved. *)
        let base = make_text 0.0 0.0 "AB" in
        let input =
          match base with
          | Text r ->
            let tspans = [|
              { (Jas.Tspan.default_tspan ()) with id = 0; content = "A" };
              { (Jas.Tspan.default_tspan ()) with
                id = 1; content = "B"; font_family = Some "Courier";
                font_weight = Some "bold";
                text_decoration = Some ["line-through"; "underline"] };
            |] in
            Text { r with tspans }
          | _ -> assert false
        in
        let doc = make_document [|make_layer [| input |]|] in
        let doc2 = roundtrip doc in
        match doc2.layers.(0) with
        | Layer { children; _ } ->
          (match children.(0) with
           | Text { tspans; _ } ->
             assert (Array.length tspans = 2);
             assert (tspans.(0).content = "A");
             assert (Jas.Tspan.has_no_overrides tspans.(0));
             assert (tspans.(1).content = "B");
             assert (tspans.(1).font_family = Some "Courier");
             assert (tspans.(1).font_weight = Some "bold");
             assert (tspans.(1).text_decoration =
                       Some ["line-through"; "underline"])
           | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "textPath tspan round-trip" `Quick (fun () ->
        let base = make_text_path [MoveTo (0.0, 0.0); LineTo (100.0, 0.0)] "foo bar" in
        let input =
          match base with
          | Text_path r ->
            let tspans = [|
              { (Jas.Tspan.default_tspan ()) with id = 0; content = "foo " };
              { (Jas.Tspan.default_tspan ()) with
                id = 1; content = "bar"; font_style = Some "italic" };
            |] in
            Text_path { r with tspans }
          | _ -> assert false
        in
        let doc = make_document [|make_layer [| input |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string "<tspan>foo </tspan>") svg 0 in true
                with Not_found -> false);
        let doc2 = roundtrip doc in
        (match doc2.layers.(0) with
         | Layer { children; _ } ->
           (match children.(0) with
            | Text_path { tspans; _ } ->
              assert (Array.length tspans = 2);
              assert (tspans.(1).font_style = Some "italic")
            | _ -> assert false)
         | _ -> assert false));

      Alcotest.test_case "text XML escaping" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_text 0.0 0.0 "<b>&</b>"
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string "&lt;b&gt;&amp;&lt;/b&gt;") svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "ellipse" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_ellipse ~fill:(Some (make_fill (make_color 0.0 1.0 0.0))) 36.0 36.0 18.0 9.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|cx="48"|}) svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|rx="24"|}) svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string {|ry="12"|}) svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "group export" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_group [|make_rect 0.0 0.0 72.0 72.0; make_circle 36.0 36.0 18.0|]
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward (Str.regexp_string "<g>") svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string "<rect") svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward (Str.regexp_string "<circle") svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "round-trip empty" `Quick (fun () ->
        let doc = make_document [|make_layer [||]|] in
        let doc2 = roundtrip doc in
        assert (Array.length doc2.Jas.Document.layers = 1));

      Alcotest.test_case "round-trip line" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_line ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 36.0
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Line { x2; y2; _ } ->
          assert (abs_float (x2 -. 72.0) < 0.1);
          assert (abs_float (y2 -. 36.0) < 0.1)
        | _ -> assert false);

      Alcotest.test_case "round-trip rect with fill" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_rect ~fill:(Some (make_fill (make_color 1.0 0.0 0.0)))
            ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
            10.0 20.0 72.0 36.0
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Rect { width; height; fill; _ } ->
          assert (abs_float (width -. 72.0) < 0.1);
          assert (abs_float (height -. 36.0) < 0.1);
          assert (fill <> None)
        | _ -> assert false);

      Alcotest.test_case "round-trip circle" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_circle ~fill:(Some (make_fill (make_color 0.0 0.0 1.0))) 36.0 36.0 18.0
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Circle { r; _ } -> assert (abs_float (r -. 18.0) < 0.1)
        | _ -> assert false);

      Alcotest.test_case "round-trip polygon" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_polygon ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
            [(0.0, 0.0); (72.0, 0.0); (36.0, 72.0)]
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Polygon { points; _ } ->
          assert (List.length points = 3);
          let (x, _) = List.nth points 1 in
          assert (abs_float (x -. 72.0) < 0.1)
        | _ -> assert false);

      Alcotest.test_case "round-trip path" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
            [MoveTo (0.0, 0.0); LineTo (72.0, 72.0); ClosePath]
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Path { d; _ } ->
          assert (List.length d = 3);
          (match List.nth d 1 with
           | LineTo (x, y) ->
             assert (abs_float (x -. 72.0) < 0.1);
             assert (abs_float (y -. 72.0) < 0.1)
           | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "round-trip text" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_text ~fill:(Some (make_fill (make_color 0.0 0.0 0.0)))
            ~font_family:"Arial" ~font_size:12.0 10.0 20.0 "Hello"
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Text { content; font_family; _ } ->
          assert (content = "Hello");
          assert (font_family = "Arial")
        | _ -> assert false);

      Alcotest.test_case "round-trip text y is preserved as top-of-box" `Quick (fun () ->
        (* Internally [text.y] is the top of the layout box. Round-tripping
           through SVG (where [y] is the baseline) must put us back at the
           same top-of-box position. *)
        let doc = make_document [|make_layer [|
          make_text ~fill:(Some (make_fill (make_color 0.0 0.0 0.0)))
            ~font_family:"Arial" ~font_size:16.0 10.0 20.0 "Hi"
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Text { x; y; _ } ->
          assert (abs_float (x -. 10.0) < 1e-3);
          assert (abs_float (y -. 20.0) < 1e-3)
        | _ -> assert false);

      Alcotest.test_case "round-trip opacity" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_rect ~opacity:0.5 0.0 0.0 72.0 72.0
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Rect { opacity; _ } -> assert (abs_float (opacity -. 0.5) < 0.1)
        | _ -> assert false);

      Alcotest.test_case "round-trip transform" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_rect ~transform:(Some (make_translate 36.0 18.0)) 0.0 0.0 72.0 72.0
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Rect { transform = Some t; _ } ->
          assert (abs_float (t.e -. 36.0) < 0.1);
          assert (abs_float (t.f -. 18.0) < 0.1)
        | _ -> assert false);

      Alcotest.test_case "round-trip layer name" `Quick (fun () ->
        let doc = make_document [|make_layer ~name:"Background" [|
          make_rect 0.0 0.0 72.0 72.0
        |]|] in
        let doc2 = roundtrip doc in
        match doc2.Jas.Document.layers.(0) with
        | Layer { name = Some n; _ } -> assert (n = "Background")
        | _ -> assert false);

      (* Stable-identity increment 2b: the additive element [id] must
         survive a full SVG round-trip, mirroring the layer-name test.
         Emitted only when set, so id-less elements stay byte-identical. *)
      Alcotest.test_case "round-trip element id" `Quick (fun () ->
        let rect = Jas.Element.with_id
            (make_rect 0.0 0.0 72.0 72.0) (Some "shape-42") in
        let doc = make_document [|make_layer [| rect |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int =
                  Str.search_forward (Str.regexp_string {|id="shape-42"|}) svg 0
                in true with Not_found -> false);
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Rect _ as e ->
          assert (Jas.Element.id_of e = Some "shape-42")
        | _ -> assert false);

      Alcotest.test_case "round-trip text-family id" `Quick (fun () ->
        (* Text/Text_path hand-inline their SVG attributes, so their id
           needs the same guard as the shapes — this is the element kind
           whose id the reference writer once dropped. *)
        let text = Jas.Element.with_id (make_text 10.0 20.0 "Hi")
            (Some "text-7") in
        let tp = Jas.Element.with_id
            (make_text_path [MoveTo (0.0, 0.0); LineTo (50.0, 0.0)] "Hi")
            (Some "textpath-7") in
        let doc = make_document [|make_layer [| text; tp |]|] in
        let doc2 = roundtrip doc in
        let kids = children_of doc2.Jas.Document.layers.(0) in
        (match kids.(0) with
         | Text _ as e -> assert (Jas.Element.id_of e = Some "text-7")
         | _ -> assert false);
        (match kids.(1) with
         | Text_path _ as e -> assert (Jas.Element.id_of e = Some "textpath-7")
         | _ -> assert false));

      Alcotest.test_case "round-trip layer id" `Quick (fun () ->
        let layer = Jas.Element.with_id
            (make_layer ~name:"Background" [| make_rect 0.0 0.0 72.0 72.0 |])
            (Some "layer-7") in
        let doc = { (Jas.Document.default_document ()) with
                    layers = [| layer |] } in
        let doc2 = roundtrip doc in
        match doc2.Jas.Document.layers.(0) with
        | Layer { name = Some n; _ } as e ->
          assert (n = "Background");
          assert (Jas.Element.id_of e = Some "layer-7")
        | _ -> assert false);

      Alcotest.test_case "id-less element emits no id attribute" `Quick (fun () ->
        (* CRITICAL byte-identity guard: an element with no id must not
           emit any [ id="..."] attribute, so existing fixtures and the
           cross-language comparison stay green. *)
        let doc = make_document [|make_layer [|
          make_rect 0.0 0.0 72.0 72.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (not (try let _ : int =
                       Str.search_forward (Str.regexp_string {| id="|}) svg 0
                     in true with Not_found -> false));
        (* And an id-less element parses back to id = None. *)
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Rect _ as e -> assert (Jas.Element.id_of e = None)
        | _ -> assert false);

      Alcotest.test_case "round-trip multiple layers" `Quick (fun () ->
        let doc = make_document [|
          make_layer ~name:"L1" [|
            make_line ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0))) 0.0 0.0 72.0 72.0
          |];
          make_layer ~name:"L2" [|
            make_circle 36.0 36.0 18.0
          |]
        |] in
        let doc2 = roundtrip doc in
        assert (Array.length doc2.Jas.Document.layers = 2);
        (match doc2.Jas.Document.layers.(0) with
         | Layer { name = Some n; _ } -> assert (n = "L1")
         | _ -> assert false);
        (match doc2.Jas.Document.layers.(1) with
         | Layer { name = Some n; _ } -> assert (n = "L2")
         | _ -> assert false));

      Alcotest.test_case "round-trip ellipse" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_ellipse ~fill:(Some (make_fill (make_color 0.0 1.0 0.0))) 36.0 36.0 18.0 9.0
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Ellipse { rx; ry; _ } ->
          assert (abs_float (rx -. 18.0) < 0.1);
          assert (abs_float (ry -. 9.0) < 0.1)
        | _ -> assert false);

      Alcotest.test_case "round-trip path with curves" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
            [MoveTo (0.0, 0.0); CurveTo (10.0, 20.0, 30.0, 40.0, 50.0, 60.0)]
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Path { d; _ } ->
          (match List.nth d 1 with
           | CurveTo (x1, y1, _, _, x, y) ->
             assert (abs_float (x1 -. 10.0) < 0.1);
             assert (abs_float (y1 -. 20.0) < 0.1);
             assert (abs_float (x -. 50.0) < 0.1);
             assert (abs_float (y -. 60.0) < 0.1)
           | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "round-trip group" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_group [|
            make_rect ~fill:(Some (make_fill (make_color 1.0 0.0 0.0))) 0.0 0.0 72.0 72.0;
            make_circle 36.0 36.0 18.0
          |]
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Group { children; _ } ->
          assert (Array.length children = 2);
          (match children.(0) with Rect _ -> () | _ -> assert false);
          (match children.(1) with Circle _ -> () | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "round-trip arc with large_arc=true, sweep=true" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
            [MoveTo (0.0, 0.0); ArcTo (36.0, 36.0, 0.0, true, true, 72.0, 0.0)]
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Path { d; _ } ->
          (match List.nth d 1 with
           | ArcTo (rx, _, _, la, sw, x, _) ->
             assert (abs_float (rx -. 36.0) < 0.1);
             assert (la = true);
             assert (sw = true);
             assert (abs_float (x -. 72.0) < 0.1)
           | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "round-trip arc with large_arc=false, sweep=false, rotated" `Quick (fun () ->
        let doc = make_document [|make_layer [|
          make_path ~stroke:(Some (make_stroke (make_color 0.0 0.0 0.0)))
            [MoveTo (0.0, 0.0); ArcTo (36.0, 18.0, 30.0, false, false, 72.0, 36.0)]
        |]|] in
        let doc2 = roundtrip doc in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Path { d; _ } ->
          (match List.nth d 1 with
           | ArcTo (_, ry, rot, la, sw, _, _) ->
             assert (abs_float (ry -. 18.0) < 0.1);
             assert (abs_float (rot -. 30.0) < 0.1);
             assert (la = false);
             assert (sw = false)
           | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "import relative path commands" `Quick (fun () ->
        let svg_rel = {|<svg xmlns="http://www.w3.org/2000/svg"><g><path d="m 10,20 l 30,0 l 0,40 z" stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>|} in
        let doc_rel = Jas.Svg.svg_to_document svg_rel in
        match (children_of doc_rel.Jas.Document.layers.(0)).(0) with
        | Path { d; _ } ->
          assert (List.length d = 4);
          (match List.nth d 0 with
           | MoveTo (x, y) ->
             assert (abs_float (x -. pt 10.0) < 0.1);
             assert (abs_float (y -. pt 20.0) < 0.1)
           | _ -> assert false);
          (match List.nth d 1 with
           | LineTo (x, y) ->
             assert (abs_float (x -. pt 40.0) < 0.1);
             assert (abs_float (y -. pt 20.0) < 0.1)
           | _ -> assert false);
          (match List.nth d 2 with
           | LineTo (x, y) ->
             assert (abs_float (x -. pt 40.0) < 0.1);
             assert (abs_float (y -. pt 60.0) < 0.1)
           | _ -> assert false);
          (match List.nth d 3 with ClosePath -> () | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "import relative cubic curve" `Quick (fun () ->
        let svg_c = {|<svg xmlns="http://www.w3.org/2000/svg"><g><path d="M 0,0 c 10,20 30,40 50,60" stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>|} in
        let doc_c = Jas.Svg.svg_to_document svg_c in
        match (children_of doc_c.Jas.Document.layers.(0)).(0) with
        | Path { d; _ } ->
          (match List.nth d 1 with
           | CurveTo (x1, y1, _, _, x, y) ->
             assert (abs_float (x1 -. pt 10.0) < 0.1);
             assert (abs_float (y1 -. pt 20.0) < 0.1);
             assert (abs_float (x -. pt 50.0) < 0.1);
             assert (abs_float (y -. pt 60.0) < 0.1)
           | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "import H/h/V/v commands" `Quick (fun () ->
        let svg_hv = {|<svg xmlns="http://www.w3.org/2000/svg"><g><path d="M 10,10 H 50 V 80 h -20 v -30" stroke="rgb(0,0,0)" stroke-width="1"/></g></svg>|} in
        let doc_hv = Jas.Svg.svg_to_document svg_hv in
        match (children_of doc_hv.Jas.Document.layers.(0)).(0) with
        | Path { d; _ } ->
          assert (List.length d = 5);
          (match List.nth d 1 with
           | LineTo (x, y) ->
             assert (abs_float (x -. pt 50.0) < 0.1);
             assert (abs_float (y -. pt 10.0) < 0.1)
           | _ -> assert false);
          (match List.nth d 2 with
           | LineTo (x, y) ->
             assert (abs_float (x -. pt 50.0) < 0.1);
             assert (abs_float (y -. pt 80.0) < 0.1)
           | _ -> assert false);
          (match List.nth d 3 with
           | LineTo (x, y) ->
             assert (abs_float (x -. pt 30.0) < 0.1);
             assert (abs_float (y -. pt 80.0) < 0.1)
           | _ -> assert false);
          (match List.nth d 4 with
           | LineTo (x, y) ->
             assert (abs_float (x -. pt 30.0) < 0.1);
             assert (abs_float (y -. pt 50.0) < 0.1)
           | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "import #RRGGBB hex color" `Quick (fun () ->
        let svg_hex6 = {|<svg xmlns="http://www.w3.org/2000/svg"><g><rect x="0" y="0" width="96" height="96" fill="#ff8000"/></g></svg>|} in
        let doc_hex6 = Jas.Svg.svg_to_document svg_hex6 in
        match (children_of doc_hex6.Jas.Document.layers.(0)).(0) with
        | Rect { fill = Some { fill_color; _ }; _ } ->
          let (r, g, b, _) = Jas.Element.color_to_rgba fill_color in
          assert (abs_float (r -. 1.0) < 0.01);
          assert (abs_float (g -. (128.0 /. 255.0)) < 0.01);
          assert (abs_float (b -. 0.0) < 0.01)
        | _ -> assert false);

      Alcotest.test_case "import #RGB shorthand hex color" `Quick (fun () ->
        let svg_hex3 = {|<svg xmlns="http://www.w3.org/2000/svg"><g><rect x="0" y="0" width="96" height="96" fill="#f00"/></g></svg>|} in
        let doc_hex3 = Jas.Svg.svg_to_document svg_hex3 in
        match (children_of doc_hex3.Jas.Document.layers.(0)).(0) with
        | Rect { fill = Some { fill_color; _ }; _ } ->
          let (r, g, b, _) = Jas.Element.color_to_rgba fill_color in
          assert (abs_float (r -. 1.0) < 0.01);
          assert (abs_float (g -. 0.0) < 0.01);
          assert (abs_float (b -. 0.0) < 0.01)
        | _ -> assert false);

      Alcotest.test_case "import hex color on stroke" `Quick (fun () ->
        let svg_hex_stroke = {|<svg xmlns="http://www.w3.org/2000/svg"><g><line x1="0" y1="0" x2="96" y2="96" stroke="#0000ff" stroke-width="2"/></g></svg>|} in
        let doc_hex_s = Jas.Svg.svg_to_document svg_hex_stroke in
        match (children_of doc_hex_s.Jas.Document.layers.(0)).(0) with
        | Line { stroke = Some { stroke_color; _ }; _ } ->
          let (_, _, b, _) = Jas.Element.color_to_rgba stroke_color in
          assert (abs_float (b -. 1.0) < 0.01)
        | _ -> assert false);

      Alcotest.test_case "import named color \"red\"" `Quick (fun () ->
        let svg_red = {|<svg xmlns="http://www.w3.org/2000/svg"><g><rect x="0" y="0" width="96" height="96" fill="red"/></g></svg>|} in
        let doc_red = Jas.Svg.svg_to_document svg_red in
        match (children_of doc_red.Jas.Document.layers.(0)).(0) with
        | Rect { fill = Some { fill_color; _ }; _ } ->
          let (r, g, _, _) = Jas.Element.color_to_rgba fill_color in
          assert (abs_float (r -. 1.0) < 0.01);
          assert (abs_float (g -. 0.0) < 0.01)
        | _ -> assert false);

      Alcotest.test_case "import named color \"steelblue\"" `Quick (fun () ->
        let svg_sb = {|<svg xmlns="http://www.w3.org/2000/svg"><g><rect x="0" y="0" width="96" height="96" fill="steelblue"/></g></svg>|} in
        let doc_sb = Jas.Svg.svg_to_document svg_sb in
        match (children_of doc_sb.Jas.Document.layers.(0)).(0) with
        | Rect { fill = Some { fill_color; _ }; _ } ->
          let (r, g, b, _) = Jas.Element.color_to_rgba fill_color in
          assert (abs_float (r -. 70.0 /. 255.0) < 0.01);
          assert (abs_float (g -. 130.0 /. 255.0) < 0.01);
          assert (abs_float (b -. 180.0 /. 255.0) < 0.01)
        | _ -> assert false);

      (* Tspan rotate roundtrip (multi-value handling) *)

      Alcotest.test_case "svg single-value tspan rotate roundtrip" `Quick (fun () ->
        let svg = {|<svg xmlns="http://www.w3.org/2000/svg"><g><text x="0" y="20" font-size="12"><tspan rotate="30">abc</tspan></text></g></svg>|} in
        let doc = Jas.Svg.svg_to_document svg in
        match (children_of doc.Jas.Document.layers.(0)).(0) with
        | Text { tspans; _ } ->
          assert (Array.length tspans = 1);
          assert (tspans.(0).content = "abc");
          assert (tspans.(0).rotate = Some 30.0)
        | _ -> assert false);

      Alcotest.test_case "svg multi-value rotate splits per glyph" `Quick (fun () ->
        let svg = {|<svg xmlns="http://www.w3.org/2000/svg"><g><text x="0" y="20" font-size="12"><tspan rotate="45 90 0">abc</tspan></text></g></svg>|} in
        let doc = Jas.Svg.svg_to_document svg in
        match (children_of doc.Jas.Document.layers.(0)).(0) with
        | Text { tspans; _ } ->
          assert (Array.length tspans = 3);
          assert (tspans.(0).content = "a");
          assert (tspans.(0).rotate = Some 45.0);
          assert (tspans.(1).content = "b");
          assert (tspans.(1).rotate = Some 90.0);
          assert (tspans.(2).content = "c");
          assert (tspans.(2).rotate = Some 0.0);
          assert (tspans.(0).id = 0);
          assert (tspans.(1).id = 1);
          assert (tspans.(2).id = 2)
        | _ -> assert false);

      Alcotest.test_case "svg multi-value rotate reuses last angle" `Quick (fun () ->
        let svg = {|<svg xmlns="http://www.w3.org/2000/svg"><g><text x="0" y="20" font-size="12"><tspan rotate="45 90">abcd</tspan></text></g></svg>|} in
        let doc = Jas.Svg.svg_to_document svg in
        match (children_of doc.Jas.Document.layers.(0)).(0) with
        | Text { tspans; _ } ->
          assert (Array.length tspans = 4);
          assert (tspans.(0).rotate = Some 45.0);
          assert (tspans.(1).rotate = Some 90.0);
          assert (tspans.(2).rotate = Some 90.0);
          assert (tspans.(3).rotate = Some 90.0)
        | _ -> assert false);

      Alcotest.test_case "svg per-glyph tspan rotate full roundtrip" `Quick (fun () ->
        let t = Jas.Text_edit.empty_text_elem 10.0 20.0 0.0 0.0 in
        let t = match t with
          | Text r ->
            Text { r with tspans = [|
              { (Jas.Tspan.default_tspan ()) with id = 0; content = "a"; rotate = Some 45.0 };
              { (Jas.Tspan.default_tspan ()) with id = 1; content = "b"; rotate = Some 90.0 };
              { (Jas.Tspan.default_tspan ()) with id = 2; content = "c"; rotate = Some 0.0 };
            |]}
          | _ -> assert false in
        let layer = Jas.Element.make_layer ~name:"L1" [| t |] in
        let doc = { (Jas.Document.default_document ()) with
                    layers = [| layer |] } in
        let svg = Jas.Svg.document_to_svg doc in
        let doc2 = Jas.Svg.svg_to_document svg in
        match (children_of doc2.Jas.Document.layers.(0)).(0) with
        | Text { tspans; _ } ->
          assert (Array.length tspans = 3);
          assert (tspans.(0).rotate = Some 45.0);
          assert (tspans.(1).rotate = Some 90.0);
          assert (tspans.(2).rotate = Some 0.0)
        | _ -> assert false);

      Alcotest.test_case "jas_role emitted on tspan in document SVG" `Quick (fun () ->
        (* Phase 1a: a wrapper Tspan with jas_role="paragraph" emits
           urn:jas:1:role="paragraph" on the <tspan> element. Full
           document round-trip through Xmlm is deferred to Phase 1b
           alongside the xmlns:jas namespace work. *)
        let base = make_text 0.0 0.0 "AB" in
        let input = match base with
          | Text r ->
            let tspans = [|
              { (Jas.Tspan.default_tspan ()) with
                id = 0; content = ""; jas_role = Some "paragraph" };
              { (Jas.Tspan.default_tspan ()) with
                id = 1; content = "hello" };
            |] in
            Text { r with tspans }
          | _ -> assert false
        in
        let doc = make_document [|make_layer [| input |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        assert (try let _ : int = Str.search_forward
            (Str.regexp_string {|urn:jas:1:role="paragraph"|}) svg 0 in true
                with Not_found -> false);
        assert (try let _ : int = Str.search_forward
            (Str.regexp_string ">hello</tspan>") svg 0 in true
                with Not_found -> false));

      Alcotest.test_case "Phase 1b1 paragraph attrs emit on tspan in document SVG" `Quick (fun () ->
        (* text-align / text-align-last / text-indent serialise as bare
           CSS-style attribute names; jas:space-before / jas:space-after
           use the urn:jas:1: prefix to keep XML namespace-friendly. *)
        let base = make_text 0.0 0.0 "X" in
        let input = match base with
          | Text r ->
            let tspans = [|
              { (Jas.Tspan.default_tspan ()) with
                id = 0; content = "";
                jas_role = Some "paragraph";
                text_align = Some "justify";
                text_align_last = Some "left";
                text_indent = Some (-12.0);
                jas_space_before = Some 6.0;
                jas_space_after = Some 3.0 };
              { (Jas.Tspan.default_tspan ()) with
                id = 1; content = "X" };
            |] in
            Text { r with tspans }
          | _ -> assert false
        in
        let doc = make_document [|make_layer [| input |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains pat =
          try let _ : int = Str.search_forward (Str.regexp_string pat) svg 0
              in true
          with Not_found -> false in
        assert (contains {|text-align="justify"|});
        assert (contains {|text-align-last="left"|});
        assert (contains {|text-indent="-12"|});
        assert (contains {|urn:jas:1:space-before="6"|});
        assert (contains {|urn:jas:1:space-after="3"|}));

      Alcotest.test_case "Phase 8 Justification attrs round-trip through document SVG" `Quick (fun () ->
        let base = make_text 0.0 0.0 "X" in
        let input = match base with
          | Text r ->
            let tspans = [|
              { (Jas.Tspan.default_tspan ()) with
                id = 0; content = "";
                jas_role = Some "paragraph";
                jas_word_spacing_min = Some 75.0;
                jas_word_spacing_desired = Some 95.0;
                jas_word_spacing_max = Some 150.0;
                jas_letter_spacing_min = Some (-5.0);
                jas_letter_spacing_desired = Some 0.0;
                jas_letter_spacing_max = Some 10.0;
                jas_glyph_scaling_min = Some 95.0;
                jas_glyph_scaling_desired = Some 100.0;
                jas_glyph_scaling_max = Some 105.0;
                jas_auto_leading = Some 140.0;
                jas_single_word_justify = Some "left" };
              { (Jas.Tspan.default_tspan ()) with id = 1; content = "X" };
            |] in
            Text { r with tspans }
          | _ -> assert false
        in
        let doc = make_document [|make_layer [| input |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains pat =
          try let _ : int = Str.search_forward (Str.regexp_string pat) svg 0
              in true
          with Not_found -> false in
        assert (contains {|urn:jas:1:word-spacing-min="75"|});
        assert (contains {|urn:jas:1:letter-spacing-desired="0"|});
        assert (contains {|urn:jas:1:glyph-scaling-max="105"|});
        assert (contains {|urn:jas:1:auto-leading="140"|});
        assert (contains {|urn:jas:1:single-word-justify="left"|}));

      Alcotest.test_case "Phase 9 Hyphenation attrs round-trip through document SVG" `Quick (fun () ->
        let base = make_text 0.0 0.0 "X" in
        let input = match base with
          | Text r ->
            let tspans = [|
              { (Jas.Tspan.default_tspan ()) with
                id = 0; content = "";
                jas_role = Some "paragraph";
                jas_hyphenate_min_word = Some 6.0;
                jas_hyphenate_min_before = Some 3.0;
                jas_hyphenate_min_after = Some 2.0;
                jas_hyphenate_limit = Some 2.0;
                jas_hyphenate_zone = Some 36.0;
                jas_hyphenate_bias = Some 0.5;
                jas_hyphenate_capitalized = Some true };
              { (Jas.Tspan.default_tspan ()) with id = 1; content = "X" };
            |] in
            Text { r with tspans }
          | _ -> assert false
        in
        let doc = make_document [|make_layer [| input |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains pat =
          try let _ : int = Str.search_forward (Str.regexp_string pat) svg 0
              in true
          with Not_found -> false in
        assert (contains {|urn:jas:1:hyphenate-min-word="6"|});
        assert (contains {|urn:jas:1:hyphenate-min-before="3"|});
        assert (contains {|urn:jas:1:hyphenate-min-after="2"|});
        assert (contains {|urn:jas:1:hyphenate-limit="2"|});
        assert (contains {|urn:jas:1:hyphenate-zone="36"|});
        assert (contains {|urn:jas:1:hyphenate-bias="0.5"|});
        assert (contains {|urn:jas:1:hyphenate-capitalized="true"|}));
    ];
    "dash_align_anchors", [
      Alcotest.test_case "roundtrips when true" `Quick (fun () ->
        let stroke = make_stroke ~dash_align_anchors:true
          (make_color 0.0 0.0 0.0) in
        let doc = make_document [|make_layer [|
          make_rect ~stroke:(Some stroke) 0.0 0.0 100.0 60.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains pat =
          try let _ : int = Str.search_forward (Str.regexp_string pat) svg 0
              in true
          with Not_found -> false in
        assert (contains {|data-jas-dash-align-anchors="true"|});
        let doc2 = roundtrip doc in
        let layers = doc2.layers in
        assert (Array.length layers > 0);
        match Array.get layers 0 with
        | Layer { children; _ } ->
          (match Array.get children 0 with
           | Rect r ->
             (match r.stroke with
              | Some s -> assert s.stroke_dash_align_anchors
              | None -> assert false)
           | _ -> assert false)
        | _ -> assert false);

      Alcotest.test_case "omitted when false" `Quick (fun () ->
        let stroke = make_stroke (make_color 0.0 0.0 0.0) in
        let doc = make_document [|make_layer [|
          make_rect ~stroke:(Some stroke) 0.0 0.0 100.0 60.0
        |]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let absent pat =
          try let _ = Str.search_forward (Str.regexp_string pat) svg 0 in false
          with Not_found -> true in
        assert (absent "data-jas-dash-align-anchors"));

      Alcotest.test_case "defaults false on import without attr" `Quick (fun () ->
        let svg = {|<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect x="0" y="0" width="100" height="60" stroke="black" stroke-width="1"/></svg>|} in
        let doc = Jas.Svg.svg_to_document svg in
        let layers = doc.layers in
        assert (Array.length layers > 0);
        match Array.get layers 0 with
        | Layer { children; _ } ->
          (match Array.get children 0 with
           | Rect r ->
             (match r.stroke with
              | Some s -> assert (not s.stroke_dash_align_anchors)
              | None -> assert false)
           | _ -> assert false)
        | _ -> assert false);
    ];

    (* DocumentSetup + PrintPreferences SVG persistence (PRINT.md §Phase 2) *)
    "phase2_metadata", [
      Alcotest.test_case "default doc emits no jas blocks" `Quick (fun () ->
        let doc = make_document [|make_layer [||]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains s sub =
          let len_s = String.length s and len_sub = String.length sub in
          let rec aux i =
            if i + len_sub > len_s then false
            else if String.sub s i len_sub = sub then true
            else aux (i + 1)
          in aux 0 in
        assert (not (contains svg "<jas:document-setup"));
        assert (not (contains svg "<jas:print-preferences"));
        assert (not (contains svg "<sodipodi:namedview")));

      Alcotest.test_case "non-default DocumentSetup round-trips" `Quick (fun () ->
        let s = { Jas.Document_setup.default with
                  bleed_top = 9.0;
                  bleed_right = 18.0; bleed_bottom = 36.0; bleed_left = 12.0;
                  bleed_uniform = false;
                  show_images_outline = true;
                  highlight_substituted_glyphs = true } in
        let doc = make_document ~document_setup:s [|make_layer [||]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains s sub =
          let len_s = String.length s and len_sub = String.length sub in
          let rec aux i =
            if i + len_sub > len_s then false
            else if String.sub s i len_sub = sub then true
            else aux (i + 1)
          in aux 0 in
        assert (contains svg "<jas:document-setup");
        assert (contains svg "xmlns:jas=");
        let parsed = Jas.Svg.svg_to_document svg in
        assert (parsed.document_setup = s));

      Alcotest.test_case "Advanced sub-record round-trips" `Quick (fun () ->
        let a = { Jas.Print_preferences.print_as_bitmap = true;
                  overprint_flattener_preset = Jas.Print_preferences.High_resolution } in
        let p = { Jas.Print_preferences.default with advanced = a } in
        let doc = make_document ~print_preferences:p [|make_layer [||]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains s sub =
          let len_s = String.length s and len_sub = String.length sub in
          let rec aux i =
            if i + len_sub > len_s then false
            else if String.sub s i len_sub = sub then true
            else aux (i + 1)
          in aux 0 in
        assert (contains svg "<jas:advanced");
        assert (contains svg "print-as-bitmap=\"true\"");
        assert (contains svg "overprint-flattener-preset=\"high_resolution\"");
        let parsed = Jas.Svg.svg_to_document svg in
        assert (parsed.print_preferences.advanced = a));

      Alcotest.test_case "DocumentSetup phase 6 fields round-trip" `Quick (fun () ->
        let s = { Jas.Document_setup.default with
                  grid_size = 36.0;
                  grid_color = "#0099ff";
                  paper_color = "#fff8e7";
                  simulate_colored_paper = true;
                  transparency_flattener_preset = Jas.Print_preferences.High_resolution;
                  discard_white_overprint = true } in
        let doc = make_document ~document_setup:s [|make_layer [||]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains s sub =
          let len_s = String.length s and len_sub = String.length sub in
          let rec aux i =
            if i + len_sub > len_s then false
            else if String.sub s i len_sub = sub then true
            else aux (i + 1)
          in aux 0 in
        assert (contains svg "grid-size=\"36\"");
        assert (contains svg "paper-color=\"#fff8e7\"");
        assert (contains svg "simulate-colored-paper=\"true\"");
        let parsed = Jas.Svg.svg_to_document svg in
        assert (parsed.document_setup = s));

      Alcotest.test_case "ColorManagement sub-record round-trips" `Quick (fun () ->
        let c = { Jas.Print_preferences.document_profile = "Adobe RGB (1998)";
                  color_handling = Jas.Print_preferences.Postscript_color_management;
                  printer_profile = "U.S. Web Coated (SWOP) v2";
                  rendering_intent = Jas.Print_preferences.Saturation;
                  preserve_rgb_numbers = true } in
        let p = { Jas.Print_preferences.default with color_management = c } in
        let doc = make_document ~print_preferences:p [|make_layer [||]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains s sub =
          let len_s = String.length s and len_sub = String.length sub in
          let rec aux i =
            if i + len_sub > len_s then false
            else if String.sub s i len_sub = sub then true
            else aux (i + 1)
          in aux 0 in
        assert (contains svg "<jas:color-management");
        assert (contains svg "color-handling=\"postscript_color_management\"");
        assert (contains svg "rendering-intent=\"saturation\"");
        assert (contains svg "Adobe RGB (1998)");
        let parsed = Jas.Svg.svg_to_document svg in
        assert (parsed.print_preferences.color_management = c));

      Alcotest.test_case "Graphics sub-record round-trips" `Quick (fun () ->
        let g = { Jas.Print_preferences.flatness = 0.4;
                  font_download = Jas.Print_preferences.Font_complete;
                  postscript_level = Jas.Print_preferences.Level_2;
                  data_format = Jas.Print_preferences.Ascii;
                  compatible_gradient_printing = true;
                  raster_effects_resolution = 600.0 } in
        let p = { Jas.Print_preferences.default with graphics = g } in
        let doc = make_document ~print_preferences:p [|make_layer [||]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains s sub =
          let len_s = String.length s and len_sub = String.length sub in
          let rec aux i =
            if i + len_sub > len_s then false
            else if String.sub s i len_sub = sub then true
            else aux (i + 1)
          in aux 0 in
        assert (contains svg "<jas:graphics");
        assert (contains svg "flatness=\"0.4\"");
        assert (contains svg "font-download=\"complete\"");
        let parsed = Jas.Svg.svg_to_document svg in
        assert (parsed.print_preferences.graphics = g));

      Alcotest.test_case "Output sub-record round-trips" `Quick (fun () ->
        let m = { Jas.Print_preferences.mode = Jas.Print_preferences.Separations;
                  emulsion = Jas.Print_preferences.Down_right;
                  image_polarity = Jas.Print_preferences.Negative;
                  printer_resolution = "150 lpi / 1200 dpi";
                  convert_spot_to_process = true;
                  overprint_black = true;
                  inks = [
                    { name = "Process Cyan"; print = false;
                      frequency = 100.0; angle = 105.0;
                      dot_shape = Jas.Print_preferences.Dot_ellipse };
                    { name = "PANTONE 185 C"; print = true;
                      frequency = 85.0; angle = 45.0;
                      dot_shape = Jas.Print_preferences.Dot_square };
                  ] } in
        let p = { Jas.Print_preferences.default with output = m } in
        let doc = make_document ~print_preferences:p [|make_layer [||]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains s sub =
          let len_s = String.length s and len_sub = String.length sub in
          let rec aux i =
            if i + len_sub > len_s then false
            else if String.sub s i len_sub = sub then true
            else aux (i + 1)
          in aux 0 in
        assert (contains svg "<jas:output");
        assert (contains svg "<jas:ink");
        assert (contains svg "PANTONE 185 C");
        let parsed = Jas.Svg.svg_to_document svg in
        assert (parsed.print_preferences.output = m));

      Alcotest.test_case "non-default PrintPreferences round-trips" `Quick (fun () ->
        let m = { Jas.Print_preferences.all_printer_marks = true;
                  trim_marks = true; registration_marks = true;
                  color_bars = true; page_information = true;
                  printer_mark_type = Jas.Print_preferences.Japanese;
                  trim_mark_weight = 0.5; mark_offset = 12.0;
                  use_document_bleed = false;
                  bleed_top = 4.0; bleed_right = 5.0;
                  bleed_bottom = 6.0; bleed_left = 7.0 } in
        let p = { Jas.Print_preferences.preset_name = "My Preset";
                  printer_name = Some "LaserJet 5000";
                  copies = 3; collate = true; reverse_order = true;
                  artboard_range_mode = Jas.Print_preferences.Range;
                  artboard_range = "1-3,5";
                  ignore_artboards = true; skip_blank_artboards = true;
                  media_size = Jas.Print_preferences.A4;
                  media_width = 595.0; media_height = 842.0;
                  orientation = Jas.Print_preferences.Landscape;
                  auto_rotate = false; transverse = true;
                  print_layers = Jas.Print_preferences.Visible;
                  placement_x = 12.5; placement_y = -3.25;
                  scaling_mode = Jas.Print_preferences.Custom_scale;
                  custom_scale = 75.0;
                  tile_overlap_h = 1.0; tile_overlap_v = 2.0;
                  tile_range = "1-2";
                  marks_and_bleed = m;
                  output = Jas.Print_preferences.default_output;
                  graphics = Jas.Print_preferences.default_graphics;
                  color_management = Jas.Print_preferences.default_color_management;
                  advanced = Jas.Print_preferences.default_advanced } in
        let doc = make_document ~print_preferences:p [|make_layer [||]|] in
        let svg = Jas.Svg.document_to_svg doc in
        let contains s sub =
          let len_s = String.length s and len_sub = String.length sub in
          let rec aux i =
            if i + len_sub > len_s then false
            else if String.sub s i len_sub = sub then true
            else aux (i + 1)
          in aux 0 in
        assert (contains svg "<jas:print-preferences");
        assert (contains svg "<jas:marks-and-bleed");
        let parsed = Jas.Svg.svg_to_document svg in
        assert (parsed.print_preferences = p));
    ];
  ]
