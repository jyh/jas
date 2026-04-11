//! Color picker dialog component.

use dioxus::prelude::*;
use wasm_bindgen::JsCast;
use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

use super::app_state::{Act, AppState};
use super::theme::*;
use crate::document::controller::Controller;
use crate::geometry::element::{Fill, Stroke};

/// Sample a pixel color from the canvas at page coordinates.
pub(crate) fn sample_pixel_at(page_x: f64, page_y: f64) -> Option<(u8, u8, u8)> {
    let window = web_sys::window()?;
    let document = window.document()?;
    let canvas_el = document.get_element_by_id("jas-canvas")
        .or_else(|| document.query_selector("canvas").ok().flatten())?;
    let canvas: HtmlCanvasElement = canvas_el.unchecked_into();
    let rect = canvas.get_bounding_client_rect();
    let cx = page_x - rect.left();
    let cy = page_y - rect.top();
    if cx < 0.0 || cy < 0.0 || cx > rect.width() || cy > rect.height() {
        return None;
    }
    let ctx: CanvasRenderingContext2d = canvas.get_context("2d").ok()??.unchecked_into();
    let scale_x = canvas.width() as f64 / rect.width();
    let scale_y = canvas.height() as f64 / rect.height();
    let px = (cx * scale_x).round();
    let py = (cy * scale_y).round();
    let data = ctx.get_image_data(px, py, 1.0, 1.0).ok()?.data();
    if data.len() >= 4 {
        Some((data[0], data[1], data[2]))
    } else {
        None
    }
}

#[component]
pub(crate) fn ColorPickerDialogView(
    color_picker_state: Signal<Option<super::color_picker::ColorPickerState>>,
) -> Element {
    let act = use_context::<Act>();

    if color_picker_state().is_none() {
        return rsx! {};
    }

    let cp = color_picker_state().unwrap();
    let (cr, cg, cb) = cp.rgb_u8();
    let swatch_css = format!("rgb({cr},{cg},{cb})");
    let hex_val = cp.hex_str();
    let (h_val, s_val, b_val) = cp.hsb_vals();
    let (cmyk_c, cmyk_m, cmyk_y, cmyk_k) = cp.cmyk_vals();
    // Field display: use override if mid-edit, computed otherwise
    let dv_h = cp.field_display("H", &format!("{h_val:.0}"));
    let dv_s = cp.field_display("S", &format!("{s_val:.0}"));
    let dv_b = cp.field_display("B", &format!("{b_val:.0}"));
    let dv_r = cp.field_display("R", &format!("{cr}"));
    let dv_g = cp.field_display("G", &format!("{cg}"));
    let dv_bl = cp.field_display("Bl", &format!("{cb}"));
    let dv_c = cp.field_display("C", &format!("{cmyk_c:.0}"));
    let dv_m = cp.field_display("M", &format!("{cmyk_m:.0}"));
    let dv_y = cp.field_display("Y", &format!("{cmyk_y:.0}"));
    let dv_k = cp.field_display("K", &format!("{cmyk_k:.0}"));
    let dv_hex = cp.field_display("hex", &hex_val);
    // Gradient cursor position (in pixels within 180x180)
    let (gx_norm, gy_norm) = cp.gradient_pos();
    let gx_px = gx_norm * 180.0;
    let gy_px = gy_norm * 180.0;
    // Colorbar slider position (in pixels within 180px height)
    let cb_pos = cp.colorbar_pos() * 180.0;
    // Circle color: use white or black depending on luminance for contrast
    let luminance = 0.299 * (cr as f64) + 0.587 * (cg as f64) + 0.114 * (cb as f64);
    let circle_color = if luminance > 128.0 { "#000" } else { "#fff" };
    let act_ok = act.clone();

    let eyedropper_active = cp.eyedropper_active;
    let backdrop_cursor = if eyedropper_active {
        // Custom SVG cursor: eyedropper with hotspot at tip (bottom-left)
        r##"url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24' viewBox='0 0 24 24'%3E%3Cpath d='M20.354 3.646a3.121 3.121 0 0 0-4.414 0l-2.5 2.5-1.06-1.06a.75.75 0 0 0-1.06 1.06l.53.53L3.6 14.93a2 2 0 0 0-.543 1.02L2 21.5a.75.75 0 0 0 .9.9l5.55-1.06a2 2 0 0 0 1.02-.543l8.25-8.25.53.53a.75.75 0 0 0 1.06-1.06l-1.06-1.06 2.5-2.5a3.121 3.121 0 0 0 0-4.414zM7.93 19.72a.5.5 0 0 1-.255.136L3.7 20.7l.844-3.975a.5.5 0 0 1 .136-.255L13 8.172l2.828 2.828z' fill='%23fff' stroke='%23000' stroke-width='.5'/%3E%3C/svg%3E") 1 23, crosshair"##
    } else { "default" };

    rsx! {
        // Eyedropper overlay — full screen, above everything, captures all clicks
        if eyedropper_active {
            div {
                style: "position:fixed; left:0; top:0; width:100vw; height:100vh; z-index:3000; cursor:{backdrop_cursor}; background:rgba(0,0,0,0.01);",
                onmousemove: move |evt: Event<MouseData>| {
                    let coords = evt.data().page_coordinates();
                    let mut cp = color_picker_state().unwrap();
                    if let Some((sr, sg, sb)) = sample_pixel_at(coords.x, coords.y) {
                        cp.set_rgb(sr, sg, sb);
                    }
                    color_picker_state.set(Some(cp));
                },
                onclick: move |evt: Event<MouseData>| {
                    evt.stop_propagation();
                    let mut cp = color_picker_state().unwrap();
                    let coords = evt.data().page_coordinates();
                    if let Some((sr, sg, sb)) = sample_pixel_at(coords.x, coords.y) {
                        cp.set_rgb(sr, sg, sb);
                    }
                    cp.eyedropper_active = false;
                    color_picker_state.set(Some(cp));
                },
            }
        }
        // Dialog backdrop
        div {
            style: "position:fixed; inset:0; background:rgba(0,0,0,0.15); z-index:2000; display:flex; align-items:center; justify-content:center;",
            onmousedown: move |evt: Event<MouseData>| {
                evt.stop_propagation();
                color_picker_state.set(None);
            },

            div {
                style: "background:{THEME_BG}; border:1px solid {THEME_BORDER}; border-radius:8px; padding:16px; box-shadow:0 8px 32px rgba(0,0,0,0.25); min-width:480px;",
                onmousedown: move |evt: Event<MouseData>| {
                    evt.stop_propagation();
                },
                onkeydown: move |evt: Event<KeyboardData>| {
                    evt.stop_propagation();
                },

                // Title + eyedropper
                div {
                    style: "font-size:13px; color:{THEME_TEXT}; margin-bottom:12px; display:flex; align-items:center; gap:8px;",
                    "Select Color:"
                    // Eyedropper button
                    {
                        let eyedropper_bg = if cp.eyedropper_active { THEME_BG_TOOLBAR_BTN } else { "transparent" };
                        rsx! {
                            div {
                                style: "cursor:pointer; padding:2px 4px; border-radius:3px; background:{eyedropper_bg}; user-select:none; display:flex; align-items:center;",
                                title: "Sample a color from the screen",
                                onmousedown: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    let mut cp = color_picker_state().unwrap();
                                    cp.eyedropper_active = !cp.eyedropper_active;
                                    color_picker_state.set(Some(cp));
                                },
                                dangerous_inner_html: EYEDROPPER_SVG,
                            }
                        }
                    }
                }

                // Main layout: gradient + colorbar + fields
                div {
                    style: "display:flex; gap:12px;",

                    // Left column: gradient + colorbar + Only Web Colors
                    div {
                        style: "display:flex; flex-direction:column; gap:6px; flex-shrink:0;",
                        // Gradient + colorbar row
                        div {
                            style: "display:flex; gap:4px;",
                            // Color gradient
                            div {
                                style: "width:180px; height:180px; background:linear-gradient(to bottom, transparent, #000), linear-gradient(to right, #fff, {swatch_css}); border:1px solid {THEME_BORDER}; cursor:crosshair; position:relative;",
                                onmousedown: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    let coords = evt.data().element_coordinates();
                                    let x = (coords.x / 180.0).clamp(0.0, 1.0);
                                    let y = (coords.y / 180.0).clamp(0.0, 1.0);
                                    let mut cp = color_picker_state().unwrap();
                                    cp.set_from_gradient(x, y);
                                    color_picker_state.set(Some(cp));
                                },
                                onmousemove: move |evt: Event<MouseData>| {
                                    if evt.data().held_buttons().contains(dioxus::html::input_data::MouseButton::Primary) {
                                        let coords = evt.data().element_coordinates();
                                        let x = (coords.x / 180.0).clamp(0.0, 1.0);
                                        let y = (coords.y / 180.0).clamp(0.0, 1.0);
                                        let mut cp = color_picker_state().unwrap();
                                        cp.set_from_gradient(x, y);
                                        color_picker_state.set(Some(cp));
                                    }
                                },
                                // Current color indicator circle
                                div {
                                    style: "position:absolute; left:{gx_px - 5.0}px; top:{gy_px - 5.0}px; width:10px; height:10px; border-radius:50%; border:1.5px solid {circle_color}; pointer-events:none; box-sizing:border-box;",
                                }
                            }
                            // Colorbar with drag area
                            // Wider container captures mouse moves during drag
                            div {
                                style: "width:32px; height:180px; position:relative; cursor:pointer; flex-shrink:0;",
                                onmousedown: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    let coords = evt.data().element_coordinates();
                                    let t = (coords.y / 180.0).clamp(0.0, 1.0);
                                    let mut cp = color_picker_state().unwrap();
                                    cp.set_from_colorbar(t);
                                    color_picker_state.set(Some(cp));
                                },
                                onmousemove: move |evt: Event<MouseData>| {
                                    if evt.data().held_buttons().contains(dioxus::html::input_data::MouseButton::Primary) {
                                        let coords = evt.data().element_coordinates();
                                        let t = (coords.y / 180.0).clamp(0.0, 1.0);
                                        let mut cp = color_picker_state().unwrap();
                                        cp.set_from_colorbar(t);
                                        color_picker_state.set(Some(cp));
                                    }
                                },
                                // Visible colorbar strip (centered)
                                div {
                                    style: "position:absolute; left:6px; top:0; width:20px; height:180px; background:linear-gradient(to bottom, #f00, #ff0, #0f0, #0ff, #00f, #f0f, #f00); border:1px solid {THEME_BORDER}; pointer-events:none; box-sizing:border-box;",
                                }
                                // Slider: left triangle
                                div {
                                    style: "position:absolute; left:0; top:{cb_pos - 4.0}px; width:0; height:0; border-top:4px solid transparent; border-bottom:4px solid transparent; border-left:5px solid #fff; pointer-events:none;",
                                }
                                // Slider: right triangle
                                div {
                                    style: "position:absolute; right:0; top:{cb_pos - 4.0}px; width:0; height:0; border-top:4px solid transparent; border-bottom:4px solid transparent; border-right:5px solid #fff; pointer-events:none;",
                                }
                            }
                        }
                        // Only Web Colors checkbox (below gradient)
                        div { style: "display:flex; align-items:center; gap:4px; font-size:12px; color:{THEME_TEXT};",
                            input {
                                r#type: "checkbox",
                                checked: cp.web_only,
                                onchange: move |_| {
                                    let mut cp = color_picker_state().unwrap();
                                    cp.web_only = !cp.web_only;
                                    if cp.web_only {
                                        let (r, g, b) = cp.rgb_u8();
                                        cp.set_rgb(r, g, b);
                                    }
                                    color_picker_state.set(Some(cp));
                                },
                            }
                            "Only Web Colors"
                        }
                    }

                    // Fields area
                    div {
                        style: "display:flex; flex-direction:column; gap:4px; font-size:12px; color:{THEME_TEXT};",

                        // HSB row with swatch to the right
                        div { style: "display:flex; gap:12px; align-items:flex-start;",
                            // HSB fields
                            div { style: "display:flex; flex-direction:column; gap:4px;",
                                div { style: "display:flex; align-items:center; gap:4px;",
                                    input { r#type: "radio", name: "cp-radio", checked: cp.radio == super::color_picker::RadioChannel::H,
                                        onchange: move |_| { let mut cp = color_picker_state().unwrap(); cp.radio = super::color_picker::RadioChannel::H; color_picker_state.set(Some(cp)); },
                                    }
                                    "H:"
                                    input { r#type: "text", value: "{dv_h}",
                                        style: "width:45px; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; padding:2px 4px; font-size:11px;",
                                        onfocus: move |_| { if let Some(el) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.active_element()) { if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() { input.select(); } } },
                                        oninput: move |evt: Event<FormData>| { let mut cp = color_picker_state().unwrap(); let v = evt.value(); if let Ok(n) = v.parse::<f64>() { cp.clear_input_override(); let (_, s, b) = cp.hsb_vals(); cp.set_hsb(n, s, b); } else { cp.set_input_override("H", v); } color_picker_state.set(Some(cp)); },
                                    }
                                    "\u{00B0}"
                                }
                                div { style: "display:flex; align-items:center; gap:4px;",
                                    input { r#type: "radio", name: "cp-radio", checked: cp.radio == super::color_picker::RadioChannel::S,
                                        onchange: move |_| { let mut cp = color_picker_state().unwrap(); cp.radio = super::color_picker::RadioChannel::S; color_picker_state.set(Some(cp)); },
                                    }
                                    "S:"
                                    input { r#type: "text", value: "{dv_s}",
                                        style: "width:45px; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; padding:2px 4px; font-size:11px;",
                                        onfocus: move |_| { if let Some(el) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.active_element()) { if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() { input.select(); } } },
                                        oninput: move |evt: Event<FormData>| { let mut cp = color_picker_state().unwrap(); let v = evt.value(); if let Ok(n) = v.parse::<f64>() { cp.clear_input_override(); let (h, _, b) = cp.hsb_vals(); cp.set_hsb(h, n, b); } else { cp.set_input_override("S", v); } color_picker_state.set(Some(cp)); },
                                    }
                                    "%"
                                }
                                div { style: "display:flex; align-items:center; gap:4px;",
                                    input { r#type: "radio", name: "cp-radio", checked: cp.radio == super::color_picker::RadioChannel::B,
                                        onchange: move |_| { let mut cp = color_picker_state().unwrap(); cp.radio = super::color_picker::RadioChannel::B; color_picker_state.set(Some(cp)); },
                                    }
                                    "B:"
                                    input { r#type: "text", value: "{dv_b}",
                                        style: "width:45px; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; padding:2px 4px; font-size:11px;",
                                        onfocus: move |_| { if let Some(el) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.active_element()) { if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() { input.select(); } } },
                                        oninput: move |evt: Event<FormData>| { let mut cp = color_picker_state().unwrap(); let v = evt.value(); if let Ok(n) = v.parse::<f64>() { cp.clear_input_override(); let (h, s, _) = cp.hsb_vals(); cp.set_hsb(h, s, n); } else { cp.set_input_override("B", v); } color_picker_state.set(Some(cp)); },
                                    }
                                    "%"
                                }
                            }
                            // Color swatch preview
                            div { style: "width:50px; height:50px; background:{swatch_css}; border:1px solid {THEME_BORDER};" }
                        }

                        // RGB + CMYK side by side
                        div { style: "display:flex; gap:16px; align-items:flex-start;",
                            // RGB column
                            div { style: "display:flex; flex-direction:column; gap:4px;",
                                div { style: "display:flex; align-items:center; gap:4px;",
                                    input { r#type: "radio", name: "cp-radio", checked: cp.radio == super::color_picker::RadioChannel::R,
                                        onchange: move |_| { let mut cp = color_picker_state().unwrap(); cp.radio = super::color_picker::RadioChannel::R; color_picker_state.set(Some(cp)); },
                                    }
                                    "R:"
                                    input { r#type: "text", value: "{dv_r}",
                                        style: "width:45px; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; padding:2px 4px; font-size:11px;",
                                        onfocus: move |_| { if let Some(el) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.active_element()) { if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() { input.select(); } } },
                                        oninput: move |evt: Event<FormData>| { let mut cp = color_picker_state().unwrap(); let v = evt.value(); if let Ok(n) = v.parse::<u8>() { cp.clear_input_override(); let (_, g, b) = cp.rgb_u8(); cp.set_rgb(n, g, b); } else { cp.set_input_override("R", v); } color_picker_state.set(Some(cp)); },
                                    }
                                }
                                div { style: "display:flex; align-items:center; gap:4px;",
                                    input { r#type: "radio", name: "cp-radio", checked: cp.radio == super::color_picker::RadioChannel::G,
                                        onchange: move |_| { let mut cp = color_picker_state().unwrap(); cp.radio = super::color_picker::RadioChannel::G; color_picker_state.set(Some(cp)); },
                                    }
                                    "G:"
                                    input { r#type: "text", value: "{dv_g}",
                                        style: "width:45px; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; padding:2px 4px; font-size:11px;",
                                        onfocus: move |_| { if let Some(el) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.active_element()) { if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() { input.select(); } } },
                                        oninput: move |evt: Event<FormData>| { let mut cp = color_picker_state().unwrap(); let v = evt.value(); if let Ok(n) = v.parse::<u8>() { cp.clear_input_override(); let (r, _, b) = cp.rgb_u8(); cp.set_rgb(r, n, b); } else { cp.set_input_override("G", v); } color_picker_state.set(Some(cp)); },
                                    }
                                }
                                div { style: "display:flex; align-items:center; gap:4px;",
                                    input { r#type: "radio", name: "cp-radio", checked: cp.radio == super::color_picker::RadioChannel::Blue,
                                        onchange: move |_| { let mut cp = color_picker_state().unwrap(); cp.radio = super::color_picker::RadioChannel::Blue; color_picker_state.set(Some(cp)); },
                                    }
                                    "B:"
                                    input { r#type: "text", value: "{dv_bl}",
                                        style: "width:45px; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; padding:2px 4px; font-size:11px;",
                                        onfocus: move |_| { if let Some(el) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.active_element()) { if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() { input.select(); } } },
                                        oninput: move |evt: Event<FormData>| { let mut cp = color_picker_state().unwrap(); let v = evt.value(); if let Ok(n) = v.parse::<u8>() { cp.clear_input_override(); let (r, g, _) = cp.rgb_u8(); cp.set_rgb(r, g, n); } else { cp.set_input_override("Bl", v); } color_picker_state.set(Some(cp)); },
                                    }
                                }
                            }
                            // CMYK column
                            div { style: "display:flex; flex-direction:column; gap:4px;",
                                div { style: "display:flex; align-items:center; gap:2px;",
                                    "C:"
                                    input { r#type: "text", value: "{dv_c}",
                                        style: "width:40px; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; padding:2px 4px; font-size:11px;",
                                        onfocus: move |_| { if let Some(el) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.active_element()) { if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() { input.select(); } } },
                                        oninput: move |evt: Event<FormData>| { let mut cp = color_picker_state().unwrap(); let v = evt.value(); if let Ok(n) = v.parse::<f64>() { cp.clear_input_override(); let (_, m, y, k) = cp.cmyk_vals(); cp.set_cmyk(n, m, y, k); } else { cp.set_input_override("C", v); } color_picker_state.set(Some(cp)); },
                                    }
                                    "%"
                                }
                                div { style: "display:flex; align-items:center; gap:2px;",
                                    "M:"
                                    input { r#type: "text", value: "{dv_m}",
                                        style: "width:40px; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; padding:2px 4px; font-size:11px;",
                                        onfocus: move |_| { if let Some(el) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.active_element()) { if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() { input.select(); } } },
                                        oninput: move |evt: Event<FormData>| { let mut cp = color_picker_state().unwrap(); let v = evt.value(); if let Ok(n) = v.parse::<f64>() { cp.clear_input_override(); let (c, _, y, k) = cp.cmyk_vals(); cp.set_cmyk(c, n, y, k); } else { cp.set_input_override("M", v); } color_picker_state.set(Some(cp)); },
                                    }
                                    "%"
                                }
                                div { style: "display:flex; align-items:center; gap:2px;",
                                    "Y:"
                                    input { r#type: "text", value: "{dv_y}",
                                        style: "width:40px; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; padding:2px 4px; font-size:11px;",
                                        onfocus: move |_| { if let Some(el) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.active_element()) { if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() { input.select(); } } },
                                        oninput: move |evt: Event<FormData>| { let mut cp = color_picker_state().unwrap(); let v = evt.value(); if let Ok(n) = v.parse::<f64>() { cp.clear_input_override(); let (c, m, _, k) = cp.cmyk_vals(); cp.set_cmyk(c, m, n, k); } else { cp.set_input_override("Y", v); } color_picker_state.set(Some(cp)); },
                                    }
                                    "%"
                                }
                                div { style: "display:flex; align-items:center; gap:2px;",
                                    "K:"
                                    input { r#type: "text", value: "{dv_k}",
                                        style: "width:40px; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; padding:2px 4px; font-size:11px;",
                                        onfocus: move |_| { if let Some(el) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.active_element()) { if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() { input.select(); } } },
                                        oninput: move |evt: Event<FormData>| { let mut cp = color_picker_state().unwrap(); let v = evt.value(); if let Ok(n) = v.parse::<f64>() { cp.clear_input_override(); let (c, m, y, _) = cp.cmyk_vals(); cp.set_cmyk(c, m, y, n); } else { cp.set_input_override("K", v); } color_picker_state.set(Some(cp)); },
                                    }
                                    "%"
                                }
                            }
                        }

                        // Hex field
                        div { style: "display:flex; align-items:center; gap:4px; margin-top:4px;",
                            "#"
                            input { r#type: "text", value: "{dv_hex}", maxlength: "6",
                                style: "width:60px; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT}; border:1px solid {THEME_BORDER}; padding:2px 4px; font-size:11px; font-family:monospace;",
                                onfocus: move |_| { if let Some(el) = web_sys::window().and_then(|w| w.document()).and_then(|d| d.active_element()) { if let Ok(input) = el.dyn_into::<web_sys::HtmlInputElement>() { input.select(); } } },
                                oninput: move |evt: Event<FormData>| { let mut cp = color_picker_state().unwrap(); let v = evt.value(); cp.set_hex(&v); if cp.hex_str() != v { cp.set_input_override("hex", v); } else { cp.clear_input_override(); } color_picker_state.set(Some(cp)); },
                            }
                        }
                    }

                    // Right column: buttons
                    div {
                        style: "display:flex; flex-direction:column; gap:6px; margin-left:8px;",

                        // OK button
                        div {
                            style: "padding:6px 20px; cursor:pointer; font-size:13px; border:1px solid {THEME_BORDER}; border-radius:4px; user-select:none; color:{THEME_TEXT}; text-align:center; background:{THEME_BG_ACTIVE};",
                            onmousedown: move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                let cp = color_picker_state().unwrap();
                                let chosen_color = cp.color();
                                let for_fill = cp.for_fill;
                                color_picker_state.set(None);
                                (act_ok.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    if let Some(tab) = st.tab_mut() {
                                        if for_fill {
                                            tab.model.default_fill = Some(Fill::new(chosen_color));
                                            let fill = tab.model.default_fill;
                                            if !tab.model.document().selection.is_empty() {
                                                tab.model.snapshot();
                                                Controller::set_selection_fill(&mut tab.model, fill);
                                            }
                                        } else {
                                            let new_stroke = match tab.model.default_stroke {
                                                Some(mut s) => { s.color = chosen_color; Some(s) }
                                                None => Some(Stroke::new(chosen_color, 1.0)),
                                            };
                                            tab.model.default_stroke = new_stroke;
                                            if !tab.model.document().selection.is_empty() {
                                                tab.model.snapshot();
                                                Controller::set_selection_stroke(&mut tab.model, new_stroke);
                                            }
                                        }
                                    }
                                }));
                            },
                            "OK"
                        }

                        // Cancel button
                        div {
                            style: "padding:6px 20px; cursor:pointer; font-size:13px; border:1px solid {THEME_BORDER}; border-radius:4px; user-select:none; color:{THEME_TEXT}; text-align:center;",
                            onmousedown: move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                color_picker_state.set(None);
                            },
                            "Cancel"
                        }

                        // Color Swatches button (disabled)
                        div {
                            style: "padding:6px 12px; font-size:12px; border:1px solid {THEME_BORDER}; border-radius:4px; user-select:none; color:{THEME_TEXT_DIM}; text-align:center; opacity:0.5; cursor:default;",
                            "Color Swatches"
                        }
                    }
                }
            }
        }
    }
}
