#[cfg(test)]
mod overlay_seam_test;

pub mod tool;
pub mod text_edit;
pub mod text_measure;
pub mod yaml_tool;
pub mod type_tool;
pub mod type_on_path_tool;

/// The APP-GLOBAL rich clipboard (tspan runs, not flat text), behind the same
/// shape `clipboard_write` below already uses for the flat one.
///
/// ⭐ ROW DU: `workspace::clipboard` is `#[cfg(feature = "web")]` because it
/// talks to the BROWSER clipboard through `web_sys`. Off the web there is no
/// rich clipboard yet, so a rich paste finds nothing and the caller falls
/// through to its flat-insert path -- the same behaviour the web build already
/// has on a first paste, not a silently different one.
#[cfg(feature = "web")]
fn rich_clipboard_read_matching(text: &str)
    -> Option<Vec<crate::geometry::tspan::Tspan>>
{
    crate::workspace::clipboard::rich_clipboard_read_matching(text)
}
#[cfg(not(feature = "web"))]
fn rich_clipboard_read_matching(_text: &str)
    -> Option<Vec<crate::geometry::tspan::Tspan>>
{
    None
}

#[cfg(feature = "web")]
fn rich_clipboard_write(text: String, payload: Vec<crate::geometry::tspan::Tspan>) {
    crate::workspace::clipboard::rich_clipboard_write(text, payload);
}
#[cfg(not(feature = "web"))]
fn rich_clipboard_write(_text: String, _payload: Vec<crate::geometry::tspan::Tspan>) {}
