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
    DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_WEIGHT_NORMAL,
    DWRITE_GLYPH_RUN, DWRITE_MEASURING_MODE_NATURAL,
};
use windows_numerics::Vector2;

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
fn font_face(family: &str) -> Result<IDWriteFontFace> {
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
        let font = fam.GetFirstMatchingFont(
            DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL,
        )?;
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
    let Ok(face) = font_face(resolve_family(font)) else { return false };
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
        match font_face("Segoe UI") {
            Ok(_) => {}
            Err(e) => panic!("Segoe UI should exist on Windows: {e:?}"),
        }
    }

    /// A missing family must FAIL rather than silently substituting. A silent
    /// fallback renders the document in the wrong typeface on one platform only.
    #[test]
    fn a_missing_family_is_an_error_not_a_substitution() {
        assert!(font_face("NoSuchFamily-jas-b1").is_err());
    }

    /// Advances must scale with size and respond to letter spacing. This does
    /// NOT assert agreement with Chrome -- nothing here can -- it asserts the
    /// arithmetic is the arithmetic.
    #[test]
    fn advances_scale_with_size_and_letter_spacing() {
        let face = font_face("Segoe UI").expect("face");
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
