//! Fill/Stroke indicator widget component.

use dioxus::prelude::*;

use super::app_state::{Act, AppHandle, AppState};
use super::theme::*;
use crate::document::controller::{FillSummary, StrokeSummary};
use crate::geometry::element::{Color, Fill, Stroke};

#[component]
pub(crate) fn FillStrokeWidgetView(
    fill_summary: FillSummary,
    stroke_summary: StrokeSummary,
    default_fill: Option<Fill>,
    default_stroke: Option<Stroke>,
    fill_on_top: bool,
    color_picker_state: Signal<Option<super::color_picker::ColorPickerState>>,
) -> Element {
    let act = use_context::<Act>();
    let app = use_context::<AppHandle>();

    // Determine what to display for fill and stroke
    let fill_display = match &fill_summary {
        FillSummary::NoSelection => match default_fill {
            Some(f) => FsDisplay::Color(f.color),
            None => FsDisplay::None,
        },
        FillSummary::Uniform(Some(f)) => FsDisplay::Color(f.color),
        FillSummary::Uniform(None) => FsDisplay::None,
        FillSummary::Mixed => FsDisplay::Mixed,
    };
    let stroke_display = match &stroke_summary {
        StrokeSummary::NoSelection => match default_stroke {
            Some(s) => FsDisplay::Color(s.color),
            None => FsDisplay::None,
        },
        StrokeSummary::Uniform(Some(s)) => FsDisplay::Color(s.color),
        StrokeSummary::Uniform(None) => FsDisplay::None,
        StrokeSummary::Mixed => FsDisplay::Mixed,
    };

    let fill_css = fs_display_bg(&fill_display);
    let stroke_css = fs_display_bg(&stroke_display);
    let fill_label = fs_display_label(&fill_display);
    let stroke_label = fs_display_label(&stroke_display);
    // Active attribute determines mode button highlight
    let active_is_none = if fill_on_top {
        matches!(fill_display, FsDisplay::None)
    } else {
        matches!(stroke_display, FsDisplay::None)
    };
    let color_btn_bg = if !active_is_none { THEME_BG_TOOLBAR_BTN } else { "transparent" };
    let none_btn_bg = if active_is_none { THEME_BG_TOOLBAR_BTN } else { "transparent" };

    let act_swap = act.clone();
    let act_default = act.clone();
    let act_none = act.clone();
    let act_fill_click = act.clone();
    let act_stroke_click = act.clone();

    rsx! {
        div {
            style: "padding:8px 4px 4px; border-top:1px solid {THEME_BORDER}; flex-shrink:0;",
            // Overlapping squares container
            div {
                style: "position:relative; width:54px; height:54px; margin:0 auto;",
                // Swap arrow (top-right)
                div {
                    style: "position:absolute; top:0; right:0; cursor:pointer; font-size:11px; color:{THEME_TEXT}; z-index:3; user-select:none; line-height:1;",
                    title: "Swap Fill and Stroke (Shift+X)",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        (act_swap.0.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.swap_fill_stroke();
                        }));
                    },
                    "\u{21C4}" // ⇄
                }
                // Default button (bottom-left)
                div {
                    style: "position:absolute; bottom:0; left:0; width:14px; height:14px; cursor:pointer; z-index:3; user-select:none;",
                    title: "Default Fill and Stroke (D)",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        (act_default.0.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.reset_fill_stroke_defaults();
                        }));
                    },
                    // Mini fill/stroke icon
                    div {
                        style: "position:absolute; top:0; left:0; width:9px; height:9px; background:#000; border:1px solid #888;",
                    }
                    div {
                        style: "position:absolute; bottom:0; right:0; width:9px; height:9px; background:#fff; border:1px solid #888;",
                    }
                }
                // Back square (behind)
                if fill_on_top {
                    // Stroke is behind
                    div {
                        style: "position:absolute; right:2px; bottom:2px; width:28px; height:28px; border:6px solid {stroke_css}; background:transparent; cursor:pointer; z-index:1; box-sizing:border-box;",
                        title: "Stroke",
                        onmousedown: move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            (act_stroke_click.0.borrow_mut())(Box::new(|st: &mut AppState| {
                                st.fill_on_top = false;
                            }));
                        },
                        if stroke_label.is_some() {
                            div {
                                style: "width:100%; height:100%; display:flex; align-items:center; justify-content:center; font-size:14px; font-weight:bold; color:{THEME_TEXT};",
                                "{stroke_label.unwrap()}"
                            }
                        }
                    }
                } else {
                    // Fill is behind
                    div {
                        style: "position:absolute; left:2px; top:2px; width:28px; height:28px; background:{fill_css}; border:1px solid #888; cursor:pointer; z-index:1; box-sizing:border-box;",
                        title: "Fill",
                        onmousedown: move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                            (act_fill_click.0.borrow_mut())(Box::new(|st: &mut AppState| {
                                st.fill_on_top = true;
                            }));
                        },
                        if fill_label.is_some() {
                            div {
                                style: "width:100%; height:100%; display:flex; align-items:center; justify-content:center; font-size:14px; font-weight:bold; color:{THEME_TEXT};",
                                "{fill_label.unwrap()}"
                            }
                        }
                    }
                }
                // Front square (on top)
                if fill_on_top {
                    // Fill is on top
                    div {
                        style: "position:absolute; left:2px; top:2px; width:28px; height:28px; background:{fill_css}; border:1px solid #888; cursor:pointer; z-index:2; box-sizing:border-box;",
                        title: "Fill (active)",
                        ondoubleclick: {
                            let app_dbl = app.clone();
                            move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                let st = app_dbl.borrow();
                                let initial_color = st.tab()
                                    .and_then(|t| t.model.default_fill.map(|f| f.color))
                                    .unwrap_or(Color::BLACK);
                                color_picker_state.set(Some(
                                    super::color_picker::ColorPickerState::new(initial_color, true)
                                ));
                            }
                        },
                        if fill_label.is_some() {
                            div {
                                style: "width:100%; height:100%; display:flex; align-items:center; justify-content:center; font-size:14px; font-weight:bold; color:{THEME_TEXT};",
                                "{fill_label.unwrap()}"
                            }
                        }
                    }
                } else {
                    // Stroke is on top
                    div {
                        style: "position:absolute; right:2px; bottom:2px; width:28px; height:28px; border:6px solid {stroke_css}; background:transparent; cursor:pointer; z-index:2; box-sizing:border-box;",
                        title: "Stroke (active)",
                        ondoubleclick: {
                            let app_dbl = app.clone();
                            move |evt: Event<MouseData>| {
                                evt.stop_propagation();
                                let st = app_dbl.borrow();
                                let initial_color = st.tab()
                                    .and_then(|t| t.model.default_stroke.map(|s| s.color))
                                    .unwrap_or(Color::BLACK);
                                color_picker_state.set(Some(
                                    super::color_picker::ColorPickerState::new(initial_color, false)
                                ));
                            }
                        },
                        if stroke_label.is_some() {
                            div {
                                style: "width:100%; height:100%; display:flex; align-items:center; justify-content:center; font-size:14px; font-weight:bold; color:{THEME_TEXT};",
                                "{stroke_label.unwrap()}"
                            }
                        }
                    }
                }
            }
            // Mode buttons: Color | Gradient | None
            div {
                style: "display:flex; gap:2px; margin-top:6px; justify-content:center;",
                // Color button
                div {
                    style: "width:18px; height:18px; background:{color_btn_bg}; border:1px solid {THEME_BORDER}; cursor:pointer; border-radius:2px;",
                    title: "Color",
                    // Solid color icon
                    div {
                        style: "margin:3px; width:12px; height:12px; background:linear-gradient(135deg, #f00, #ff0, #0f0, #0ff, #00f, #f0f);",
                    }
                }
                // Gradient button (disabled)
                div {
                    style: "width:18px; height:18px; background:transparent; border:1px solid {THEME_BORDER}; cursor:default; border-radius:2px; opacity:0.4;",
                    title: "Gradient (not implemented)",
                    div {
                        style: "margin:3px; width:12px; height:12px; background:linear-gradient(to right, #000, #fff);",
                    }
                }
                // None button
                div {
                    style: "width:18px; height:18px; background:{none_btn_bg}; border:1px solid {THEME_BORDER}; cursor:pointer; border-radius:2px;",
                    title: "None",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        (act_none.0.borrow_mut())(Box::new(|st: &mut AppState| {
                            st.set_active_to_none();
                        }));
                    },
                    // Red diagonal "none" icon
                    div {
                        style: "margin:3px; width:12px; height:12px; background:white; position:relative; overflow:hidden;",
                        div {
                            style: "position:absolute; top:50%; left:-2px; width:16px; height:2px; background:red; transform:rotate(-45deg); transform-origin:center;",
                        }
                    }
                }
            }
        }
    }
}
