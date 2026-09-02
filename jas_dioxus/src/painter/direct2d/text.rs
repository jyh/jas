//! `draw_text_run` on DirectWrite.
//!
//! # This file is where the project's largest open divergence lives
//!
//! S3 named host text metrics as the #1 cross-port risk and B1 confirmed it:
//! **no API can make DirectWrite agree with Chrome's `measureText`.** Different
//! shapers, different font resolution, and jas bundles no font file while
//! defaulting to the CSS generic `sans-serif`, which DirectWrite has no concept
//! of. The Captain has ruled the fix — **2a: one shared measurer in the core,
//! backends only draw** — with **2b (full `PlacedGlyphs`) as the endgame**.
//!
//! Until 2a lands, ADVANCES COME FROM DIRECTWRITE, and that is a divergence, not
//! a detail. It is confined to `advances_from_directwrite` below so 2a has one
//! function to delete.
//!
//! # Why `DrawGlyphRun` and not `DrawText`
//!
//! `TextRun::FastRun` carries a BASELINE origin `(x, y)`. `DrawText` takes a
//! layout RECT whose top edge is the ascent top, so using it would require
//! subtracting an ascent — a conversion that is easy to get subtly wrong and
//! silently shifts every line vertically. `DrawGlyphRun` takes the baseline
//! origin directly, so there is nothing to convert.
//!
//! It is also the shape 2b wants: a `PlacedGlyphs` run is the same call with
//! advances zeroed and per-glyph offsets supplied, which is the documented
//! DirectWrite idiom for absolute positioning.
//!
//! # The font-family policy is app-authored, and it should not be
//!
//! DirectWrite has no CSS generic families. `sans-serif` has to become a real
//! family name, and the browser resolved that from a PER-USER PREFERENCE — so
//! there is no fixed target to match, and any mapping here is a guess with a
//! default. Named loudly rather than buried: 2a's bundled font removes this
//! whole function.

use windows::core::{Result, PCWSTR};
use windows::Win32::Foundation::E_FAIL;
use windows::Win32::Graphics::Direct2D::Common::D2D1_COLOR_F;
use windows::Win32::Graphics::Direct2D::{
    ID2D1Brush, ID2D1RenderTarget, D2D1_DRAW_TEXT_OPTIONS_NONE,
};
use windows::Win32::Graphics::DirectWrite::{
    DWriteCreateFactory, IDWriteFactory, IDWriteFontFace, DWRITE_FACTORY_TYPE_SHARED,
    DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE, DWRITE_FONT_STYLE_ITALIC,
    DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STYLE_OBLIQUE, DWRITE_FONT_WEIGHT,
    DWRITE_FONT_WEIGHT_BOLD, DWRITE_FONT_WEIGHT_LIGHT, DWRITE_FONT_WEIGHT_NORMAL,
    DWRITE_GLYPH_RUN, DWRITE_MEASURING_MODE_NATURAL,
};
use windows_numerics::Vector2;

/// The three parts of a `TextRun::FastRun`'s `font` field.
///
/// ⛔ THAT FIELD IS A CSS FONT SHORTHAND MINUS THE SIZE, and this backend did
/// not know it. Measured 2026-09-01: the seam builds
/// `format!("{style} {weight} {family}")` and `Canvas2dPainter` consumes it as
/// `set_font("{size}px {font}")` — valid CSS, and it works. Direct2D passed the
/// WHOLE string to [`resolve_family`], which matches a bare family, so
/// `"normal normal sans-serif"` resolved to nothing and drew **0 pixels** where
/// `"sans-serif"` drew **615**. The seam and Canvas2D agreed; this backend was
/// the odd one out.
///
/// ⚖️ The contract is therefore the OTHER TWO, not a preference of mine: two
/// independent consumers already read the field one way.
#[derive(Debug, PartialEq)]
pub struct FontSpec<'a> {
    pub family: &'a str,
    pub weight: DWRITE_FONT_WEIGHT,
    pub style: DWRITE_FONT_STYLE,
}

/// Parse `"{style} {weight} {family}"`, honouring style and weight rather than
/// dropping them.
///
/// ⚠️ THE FAMILY IS THE TAIL, NOT THE LAST WORD. `"normal normal Times New
/// Roman"` has a three-word family; splitting on whitespace and taking the last
/// token would resolve `"Roman"` — a family that does not exist, which fails
/// closed here but would be an invisible typeface change on a system where it
/// did. So leading tokens are consumed ONLY while they are recognised keywords,
/// and everything from the first unrecognised token onward is the family.
///
/// An absent style/weight is `normal`, which is what CSS means by omitting them.
pub fn parse_font_spec(font: &str) -> FontSpec<'_> {
    let mut style = DWRITE_FONT_STYLE_NORMAL;
    let mut weight = DWRITE_FONT_WEIGHT_NORMAL;
    let mut rest = font.trim();
    loop {
        let (head, tail) = match rest.split_once(char::is_whitespace) {
            Some((h, t)) => (h, t.trim_start()),
            // The last token is always the family, never a keyword: a font
            // named only `"bold"` is a family called bold.
            None => break,
        };
        match head {
            "italic" => style = DWRITE_FONT_STYLE_ITALIC,
            "oblique" => style = DWRITE_FONT_STYLE_OBLIQUE,
            "bold" => weight = DWRITE_FONT_WEIGHT_BOLD,
            "bolder" => weight = DWRITE_FONT_WEIGHT_BOLD,
            "lighter" => weight = DWRITE_FONT_WEIGHT_LIGHT,
            "normal" => {}
            // A numeric CSS weight (100..900). DirectWrite's enum IS that
            // number, so no table is needed and none is invented.
            n if n.len() == 3 && n.chars().all(|c| c.is_ascii_digit()) => {
                if let Ok(v) = n.parse::<i32>() {
                    if (100..=900).contains(&v) {
                        weight = DWRITE_FONT_WEIGHT(v);
                    }
                }
            }
            // ⇒ NOT A KEYWORD, SO THE FAMILY STARTS HERE. Everything left,
            // spaces included.
            _ => break,
        }
        rest = tail;
    }
    FontSpec { family: resolve_family(rest), weight, style }
}

/// CSS generic → a real Windows family.
///
/// **This is a policy, not a mapping.** The browser picked `sans-serif` from a
/// per-user preference; there is no correct answer to reproduce. 2a's bundled
/// font deletes this.
pub fn resolve_family(css: &str) -> &str {
    match css {
        "sans-serif" => "Segoe UI",
        "serif" => "Times New Roman",
        "monospace" => "Consolas",
        other => other,
    }
}

/// UTF-16 **with a NUL terminator**. `PCWSTR` is a pointer to a NUL-terminated
/// wide string; handing it an unterminated buffer makes the callee read past the
/// end. That is undefined behaviour whose observable symptom here was
/// `FindFamilyName` reporting that "Segoe UI" does not exist -- a plausible,
/// entirely wrong answer rather than a crash.
fn utf16(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// The DirectWrite factory, created once per process.
fn factory() -> Result<IDWriteFactory> {
    unsafe { DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED) }
}

/// Resolve a family name to a font face via the system collection.
fn font_face(spec: &FontSpec) -> Result<IDWriteFontFace> {
    let family = spec.family;
    let f = factory()?;
    unsafe {
        // windows-rs 0.62 uses the out-param form here, not a return value.
        let mut coll_opt = None;
        f.GetSystemFontCollection(&mut coll_opt, false)?;
        let coll = coll_opt.ok_or_else(|| windows::core::Error::from_hresult(E_FAIL))?;
        let mut idx = 0u32;
        let mut exists = windows::core::BOOL(0);
        let name = utf16(family);
        coll.FindFamilyName(PCWSTR(name.as_ptr()), &mut idx, &mut exists)?;
        // A missing family is not an error to swallow: falling back silently is
        // how a document renders in the wrong typeface on one platform only.
        if !exists.as_bool() {
            return Err(windows::core::Error::from_hresult(E_FAIL));
        }
        let fam = coll.GetFontFamily(idx)?;
        // ⇒ THE PARSED WEIGHT AND STYLE, not three hardcoded NORMALs. Dropping
        // them is why `<text font-weight="bold">` rendered regular here while
        // rendering bold everywhere else -- a wrong picture, not a missing one.
        let font = fam.GetFirstMatchingFont(spec.weight, DWRITE_FONT_STRETCH_NORMAL, spec.style)?;
        font.CreateFontFace()
    }
}

/// **THE DIVERGENCE, in one function.** Advances come from DirectWrite's design
/// metrics, scaled by `size / unitsPerEm`, plus the contract's letter spacing.
///
/// Chrome shapes with HarfBuzz against a font it resolved; these numbers will
/// not match it, and no gate in this project can see the difference — the
/// conformance corpus injects a synthetic `char_width` measurer and pins the
/// layout algorithm GIVEN a measurer, never the measurer.
///
/// 2a replaces this whole function with the core's shared measurer.
fn advances_from_directwrite(
    face: &IDWriteFontFace, glyphs: &[u16], size: f64, letter_spacing: f64,
) -> Result<Vec<f32>> {
    unsafe {
        let mut metrics = vec![Default::default(); glyphs.len()];
        face.GetDesignGlyphMetrics(glyphs.as_ptr(), glyphs.len() as u32, metrics.as_mut_ptr(), false)?;
        let mut m = Default::default();
        face.GetMetrics(&mut m);
        let upem = m.designUnitsPerEm as f64;
        Ok(metrics.iter()
            .map(|g| ((g.advanceWidth as f64) * size / upem + letter_spacing) as f32)
            .collect())
    }
}

/// Draw one `FastRun` at its baseline origin. Returns false when the family
/// cannot be resolved, so the caller reports rather than draws nothing quietly.
pub fn draw_fast_run(
    rt: &ID2D1RenderTarget, brush: &ID2D1Brush,
    font: &str, size: f64, text: &str, letter_spacing: f64, x: f64, y: f64,
) -> bool {
    if text.is_empty() {
        return true;
    }
    let Ok(face) = font_face(&parse_font_spec(font)) else { return false };
    let units = utf16(text);
    let mut codepoints: Vec<u32> = text.chars().map(|c| c as u32).collect();
    let mut glyphs = vec![0u16; codepoints.len()];
    unsafe {
        // GetGlyphIndices IS the cmap lookup, so no Rust shaping crate is
        // needed for a FastRun -- B1's finding, and it is why 2b's shaper only
        // has to produce glyph ids, not do font resolution.
        if face.GetGlyphIndices(codepoints.as_mut_ptr(), codepoints.len() as u32, glyphs.as_mut_ptr()).is_err() {
            return false;
        }
    }
    let Ok(adv) = advances_from_directwrite(&face, &glyphs, size, letter_spacing) else {
        return false;
    };
    let run = DWRITE_GLYPH_RUN {
        fontFace: std::mem::ManuallyDrop::new(Some(face)),
        fontEmSize: size as f32,
        glyphCount: glyphs.len() as u32,
        glyphIndices: glyphs.as_ptr(),
        glyphAdvances: adv.as_ptr(),
        glyphOffsets: std::ptr::null(),
        isSideways: false.into(),
        bidiLevel: 0,
    };
    unsafe {
        rt.DrawGlyphRun(
            Vector2 { X: x as f32, Y: y as f32 },
            &run, brush, DWRITE_MEASURING_MODE_NATURAL,
        );
    }
    let _ = units;
    let _ = D2D1_COLOR_F::default();
    let _ = D2D1_DRAW_TEXT_OPTIONS_NONE;
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The generic-family policy is a POLICY. This test exists so that changing
    /// it is a deliberate act with a diff, not a silent retypesetting of every
    /// document.
    #[test]
    fn css_generics_resolve_to_named_windows_families() {
        assert_eq!(resolve_family("sans-serif"), "Segoe UI");
        assert_eq!(resolve_family("serif"), "Times New Roman");
        assert_eq!(resolve_family("monospace"), "Consolas");
        assert_eq!(resolve_family("Arial"), "Arial", "a real family passes through");
    }

    #[test]
    fn a_real_family_resolves_to_a_font_face() {
        match font_face(&parse_font_spec("Segoe UI")) {
            Ok(_) => {}
            Err(e) => panic!("Segoe UI should exist on Windows: {e:?}"),
        }
    }

    /// A missing family must FAIL rather than silently substituting. A silent
    /// fallback renders the document in the wrong typeface on one platform only.
    #[test]
    fn a_missing_family_is_an_error_not_a_substitution() {
        assert!(font_face(&parse_font_spec("NoSuchFamily-jas-b1")).is_err());
    }

    /// Advances must scale with size and respond to letter spacing. This does
    /// NOT assert agreement with Chrome -- nothing here can -- it asserts the
    /// arithmetic is the arithmetic.
    #[test]
    fn advances_scale_with_size_and_letter_spacing() {
        let face = font_face(&parse_font_spec("Segoe UI")).expect("face");
        let mut cps: Vec<u32> = "AV".chars().map(|c| c as u32).collect();
        let mut g = vec![0u16; cps.len()];
        unsafe { face.GetGlyphIndices(cps.as_mut_ptr(), cps.len() as u32, g.as_mut_ptr()).unwrap() };

        let a16 = advances_from_directwrite(&face, &g, 16.0, 0.0).unwrap();
        let a32 = advances_from_directwrite(&face, &g, 32.0, 0.0).unwrap();
        assert!(a16[0] > 0.0, "a glyph has a positive advance");
        assert!((a32[0] / a16[0] - 2.0).abs() < 1e-3, "advance scales linearly with em size");

        let spaced = advances_from_directwrite(&face, &g, 16.0, 3.0).unwrap();
        assert!((spaced[0] - a16[0] - 3.0).abs() < 1e-3, "letter spacing adds per glyph");
    }
}

#[cfg(test)]
mod shorthand_tests {
    use super::*;

    /// ⭐ THE 0-vs-615 TABLE, KEPT AS A FIXTURE.
    ///
    /// The measurement that opened row DA: the same call, one field changed.
    /// `"normal normal sans-serif"` is what the seam actually sends and it drew
    /// **zero** pixels; `"sans-serif"` drew **615**. Both must now resolve to the
    /// same family, which is the whole of the fix.
    #[test]
    fn the_shorthand_and_the_bare_family_resolve_alike() {
        let bare = parse_font_spec("sans-serif");
        let shorthand = parse_font_spec("normal normal sans-serif");
        assert_eq!(bare.family, "Segoe UI");
        assert_eq!(shorthand.family, bare.family,
                   "the seam sends the shorthand; it must reach the same family as \
                    the bare form, or text draws nothing at all");
        assert_eq!(shorthand.weight, bare.weight);
        assert_eq!(shorthand.style, bare.style);
    }

    /// ⛔ THE FAMILY IS THE TAIL, NOT THE LAST WORD. A multi-word family is the
    /// case a naive `split_whitespace().last()` gets wrong, and it gets it wrong
    /// SILENTLY on a system where the last word happens to name a real family.
    #[test]
    fn a_multi_word_family_survives_the_parse() {
        assert_eq!(parse_font_spec("normal normal Times New Roman").family, "Times New Roman");
        assert_eq!(parse_font_spec("italic bold Segoe UI").family, "Segoe UI");
        assert_eq!(parse_font_spec("serif").family, "Times New Roman", "generics still map");
    }

    /// Style and weight are HONOURED, not dropped. Dropping them rendered a bold
    /// document in regular here and bold everywhere else.
    #[test]
    fn style_and_weight_are_parsed_not_discarded() {
        let b = parse_font_spec("normal bold Arial");
        assert_eq!(b.weight, DWRITE_FONT_WEIGHT_BOLD);
        assert_eq!(b.style, DWRITE_FONT_STYLE_NORMAL);

        let i = parse_font_spec("italic normal Arial");
        assert_eq!(i.style, DWRITE_FONT_STYLE_ITALIC);
        assert_eq!(i.weight, DWRITE_FONT_WEIGHT_NORMAL);

        let both = parse_font_spec("oblique 700 Arial");
        assert_eq!(both.style, DWRITE_FONT_STYLE_OBLIQUE);
        assert_eq!(both.weight, DWRITE_FONT_WEIGHT(700),
                   "a numeric CSS weight IS DirectWrite's enum value; no table is invented");
    }

    /// ⛔ A FAMILY THAT LOOKS LIKE A KEYWORD IS STILL A FAMILY when it is the
    /// only token. Consuming it would leave an EMPTY family, which resolves to
    /// nothing and draws nothing — the failure this whole row is about, reached
    /// through the parser instead of through the caller.
    #[test]
    fn a_lone_keyword_is_a_family_not_a_modifier() {
        assert_eq!(parse_font_spec("bold").family, "bold");
        assert_eq!(parse_font_spec("bold").weight, DWRITE_FONT_WEIGHT_NORMAL);
        assert!(!parse_font_spec("normal normal sans-serif").family.is_empty());
    }
}

#[cfg(test)]
mod pixel_tests {
    use super::*;
    use crate::geometry::element::Color;
    use crate::painter::direct2d::device::HeadlessTarget;
    use crate::painter::direct2d::painter::Direct2DPainter;
    use crate::painter::{Brush, Painter, TextRun};

    const W: u32 = 220;
    const H: u32 = 60;

    fn render(font: &str, text: &str) -> Vec<u8> {
        let t = HeadlessTarget::new(W, H).expect("target");
        unsafe {
            t.target().BeginDraw();
            t.target().Clear(None);
            let mut p = Direct2DPainter::new(t.target());
            p.draw_text_run(
                &TextRun::FastRun {
                    font: font.into(), size: 32.0, text: text.into(),
                    letter_spacing: 0.0, x: 4.0, y: 44.0,
                },
                &Brush::Solid(Color::new(0.0, 0.0, 0.0, 1.0)),
                1.0,
            );
            let _ = t.target().EndDraw(None, None);
        }
        t.read_bgra().expect("readback")
    }

    fn ink(font: &str, text: &str) -> usize {
        render(font, text).chunks_exact(4).filter(|px| px[3] > 32).count()
    }

    /// The x of the right-most inked column: where the pen ended up.
    fn right_edge(font: &str, text: &str) -> u32 {
        let buf = render(font, text);
        (0..W)
            .filter(|x| (0..H).any(|y| buf[(((y * W + x) * 4) + 3) as usize] > 32))
            .max()
            .unwrap_or(0)
    }

    /// ⭐ THE ROW-DA MEASUREMENT, NOW AN ARM. The shorthand the seam sends must
    /// put ink on a surface. Before the parser it put down ZERO.
    #[test]
    fn the_seams_own_font_string_puts_ink_on_the_surface() {
        let n = ink("normal normal sans-serif", "Hello");
        assert!(n > 100,
                "the shorthand the seam actually sends inked {n} pixels -- 0 means the \
                 family did not resolve and text is silently absent");
    }

    /// ⛔ THE CONTROL IN THE OTHER DIRECTION. A family that genuinely does not
    /// exist must still ink NOTHING — otherwise the arm above would pass on a
    /// backend that fell back to a default font, which is the "wrong typeface on
    /// one platform only" failure `font_face` already refuses by name.
    #[test]
    fn an_unresolvable_family_still_inks_nothing() {
        assert_eq!(ink("No Such Family At All 12345", "Hello"), 0,
                   "a missing family must fail closed, never fall back silently");
    }

    /// WEIGHT REACHES THE GLYPHS. Bold is not merely parsed — it is a different
    /// face, and a different face inks a different number of pixels.
    #[test]
    fn bold_reaches_directwrite_and_changes_the_pixels() {
        let regular = ink("normal normal sans-serif", "Hello");
        let bold = ink("normal bold sans-serif", "Hello");
        assert!(regular > 100 && bold > 100, "both must draw: {regular} / {bold}");
        assert!(bold > regular,
                "bold must ink MORE than regular ({bold} vs {regular}) -- equal means the \
                 weight was parsed and then dropped before GetFirstMatchingFont");
    }

    /// STYLE REACHES THE GLYPHS too, by the same argument.
    #[test]
    fn italic_reaches_directwrite_and_changes_the_pixels() {
        let upright = ink("normal normal sans-serif", "Hello");
        let italic = ink("italic normal sans-serif", "Hello");
        assert!(upright > 100 && italic > 100, "both draw: {upright} / {italic}");
        assert_ne!(upright, italic,
                   "italic must differ from upright -- identical means the style was \
                    parsed and then dropped");
    }

    /// ⛔ RUNS OF SPACES MUST ADVANCE THE PEN — the `xml:space="preserve"` arm.
    ///
    /// Its own test because `text_xml_space_preserve.svg` is one of the four
    /// documents this row flips, and whitespace is exactly what a glyph pipeline
    /// drops without noticing: **spaces ink no pixels**, so the ink COUNT cannot
    /// see them. Only the position of what follows can, which is why this
    /// measures the right edge instead.
    #[test]
    fn preserved_runs_of_spaces_advance_the_pen() {
        let narrow = right_edge("normal normal sans-serif", "A B");
        let wide = right_edge("normal normal sans-serif", "A   B");
        assert!(narrow > 0 && wide > 0, "both must draw: {narrow} / {wide}");
        assert!(wide > narrow,
                "three preserved spaces must push the 'B' further right than one \
                 ({wide} vs {narrow}) -- equal means the run was collapsed");
    }
}
