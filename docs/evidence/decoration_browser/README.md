# Where a decoration draws beside a shift or a turn

The evidence for TSPAN.md "Decoration beside a shift or a turn". `decoration.svg`
has four rows (Arial 32):

1. the element's underline over a tspan with `baseline-shift="12"`
2. a tspan's own underline, the same shift
3. the element's underline over a tspan with `rotate="30"`
4. the element's underline over a tspan with `dy="-12"`

Two browser engines rendered it on 2026-10-19: `blink.png` (headless Chrome 155) and
`webkit.png` (macOS Quick Look). They agree on every row. The decoration is drawn in
its glyph's frame: it rises with a shifted run whoever declares it, and each turned
glyph's piece turns with that glyph.

The arms that pin the law: `a_decoration_follows_its_glyphs_shift_and_turn`
(`jas_dioxus/src/algorithms/text_runs.rs`), `a_decoration_is_stroked_in_its_glyphs_frame`
(the Windows walk, `jas_dioxus/src/painter/element_render/tests.rs`), and
`JasSwift/Tests/Canvas/StyledDecorationRenderTests.swift`.
