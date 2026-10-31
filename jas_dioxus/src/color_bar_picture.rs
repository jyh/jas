//! The Color panel's colour bar as a picture: a `data:image/bmp;base64,…` URI.
//!
//! NOT web-gated. The web view draws it as an `<img>`, and the panel plan
//! sends it to a native shell as the `color_bar` leaf's `display.picture`
//! (STATUS-flask §249), so both builds need it. Moved here from
//! `workspace::color_panel_view`, which is behind `feature = "web"`.
//!
//! Each pixel is [`color_bar_rgb`] at that pixel, normalized: the picture and
//! the pick are one function, so a click lands on the colour drawn under it.

use crate::interpreter::color_util::color_bar_rgb;

/// The picture's width in pixels. A shell scales it to the leaf's rect.
const WIDTH: usize = 120;
/// The picture's height in pixels.
const HEIGHT: usize = 32;

/// The colour bar as a BMP data URI. Cached: the gradient never changes.
pub fn data_uri() -> String {
    use std::sync::OnceLock;
    static CACHE: OnceLock<String> = OnceLock::new();
    CACHE.get_or_init(build).clone()
}

fn build() -> String {
    bmp_data_uri(WIDTH, HEIGHT, color_bar_rgb)
}

/// A `width` × `height` 24-bit BMP as a data URI, each pixel `pixel(u, v)` at
/// its top-left corner normalized (`u = x / width`, `v = y / height`, from the
/// top-left). Shared with [`crate::color_picker_picture`]. `width * 3` must be
/// a multiple of 4, since rows carry no padding.
pub(crate) fn bmp_data_uri(width: usize, height: usize, pixel: impl Fn(f64, f64) -> (u8, u8, u8)) -> String {
    debug_assert_eq!(width * 3 % 4, 0, "BMP rows here carry no padding");
    // BMP: 54-byte header + W*H*3 pixel data
    let pixel_data_size = width * 3 * height;
    let file_size = 54 + pixel_data_size;

    let mut bmp = Vec::with_capacity(file_size);
    // BMP file header (14 bytes)
    bmp.extend_from_slice(b"BM");
    bmp.extend_from_slice(&(file_size as u32).to_le_bytes());
    bmp.extend_from_slice(&[0u8; 4]); // reserved
    bmp.extend_from_slice(&54u32.to_le_bytes()); // pixel data offset
    // DIB header (40 bytes - BITMAPINFOHEADER)
    bmp.extend_from_slice(&40u32.to_le_bytes());
    bmp.extend_from_slice(&(width as i32).to_le_bytes());
    bmp.extend_from_slice(&(height as i32).to_le_bytes());
    bmp.extend_from_slice(&1u16.to_le_bytes()); // color planes
    bmp.extend_from_slice(&24u16.to_le_bytes()); // bits per pixel
    bmp.extend_from_slice(&[0u8; 24]); // compression, sizes, resolution, colors

    // BMP rows are bottom-to-top, so row 0 in the file is the bottom of the image.
    for bmp_row in 0..height {
        let y = (height - 1 - bmp_row) as f64;
        for x in 0..width {
            let (r, g, b) = pixel(x as f64 / width as f64, y / height as f64);
            // BMP pixel order is BGR
            bmp.extend_from_slice(&[b, g, r]);
        }
    }

    format!("data:image/bmp;base64,{}", base64(&bmp))
}

/// Minimal base64 encoder (no external dependency).
fn base64(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((triple >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((triple >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[((triple >> 6) & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(TABLE[(triple & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An independent decoder, so the arm below does not read the picture
    /// back through the encoder it is checking.
    fn decode(s: &str) -> Vec<u8> {
        let val = |c: u8| -> u32 {
            match c {
                b'A'..=b'Z' => (c - b'A') as u32,
                b'a'..=b'z' => (c - b'a' + 26) as u32,
                b'0'..=b'9' => (c - b'0' + 52) as u32,
                b'+' => 62,
                b'/' => 63,
                _ => panic!("not base64: {c}"),
            }
        };
        let mut out = vec![];
        for q in s.as_bytes().chunks(4) {
            let pad = q.iter().filter(|&&c| c == b'=').count();
            let n = q.iter().take(4 - pad).enumerate()
                .fold(0u32, |acc, (i, &c)| acc | (val(c) << (18 - 6 * i)));
            out.extend_from_slice(&[(n >> 16) as u8, (n >> 8) as u8, n as u8][..3 - pad]);
        }
        out
    }

    /// THE PICTURE IS THE PICK. Every pixel, decoded from the URI, is
    /// `color_bar_rgb` at that pixel, with the top of the image at v = 0
    /// (BMP stores rows bottom-up) and the channels in RGB order (BMP stores
    /// BGR). A picture flipped, or with red and blue swapped, would draw one
    /// colour over a point that picks another.
    #[test]
    fn every_pixel_of_the_picture_is_the_picks_colour_at_that_pixel() {
        let uri = data_uri();
        let b64 = uri.strip_prefix("data:image/bmp;base64,").expect("a BMP data URI");
        let bmp = decode(b64);
        assert_eq!(&bmp[0..2], b"BM");
        assert_eq!(bmp.len(), 54 + WIDTH * HEIGHT * 3, "the header's size and the pixels");
        assert_eq!(u32::from_le_bytes(bmp[2..6].try_into().unwrap()) as usize, bmp.len());
        assert_eq!(i32::from_le_bytes(bmp[18..22].try_into().unwrap()), WIDTH as i32);
        assert_eq!(i32::from_le_bytes(bmp[22..26].try_into().unwrap()), HEIGHT as i32);
        let mut distinct = std::collections::BTreeSet::new();
        for y in 0..HEIGHT {
            for x in 0..WIDTH {
                let at = 54 + ((HEIGHT - 1 - y) * WIDTH + x) * 3;
                let (b, g, r) = (bmp[at], bmp[at + 1], bmp[at + 2]);
                let want = color_bar_rgb(x as f64 / WIDTH as f64, y as f64 / HEIGHT as f64);
                assert_eq!((r, g, b), want, "pixel ({x}, {y})");
                distinct.insert(want);
            }
        }
        // The control: a uniform picture would pass the flip and the channel
        // order trivially, so the bar must actually vary in both directions.
        assert!(distinct.len() > 1000, "only {} distinct colours", distinct.len());
        assert_ne!(color_bar_rgb(0.0, 0.5), color_bar_rgb(0.0, 0.0), "v varies");
    }

    /// The cache hands back the same picture every call.
    #[test]
    fn the_cached_picture_is_the_built_one() {
        assert_eq!(data_uri(), build());
    }
}
