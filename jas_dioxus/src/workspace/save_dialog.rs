//! Save-as workspace dialog component.

use dioxus::prelude::*;

use super::app_state::{Act, AppHandle, AppState};
use super::theme::*;

/// Save As dialog state.
#[derive(Clone, Debug)]
pub(crate) enum SaveAsDialog {
    /// User is typing a name.
    Editing(String),
    /// Confirm overwrite of an existing layout.
    ConfirmOverwrite(String),
    /// Reject the reserved "Workspace" name.
    RejectWorkspace,
}

#[component]
pub(crate) fn SaveAsDialogView(
    save_as_dialog: Signal<Option<SaveAsDialog>>,
) -> Element {
    let act = use_context::<Act>();
    let app = use_context::<AppHandle>();

    let Some(dialog_state) = save_as_dialog() else {
        return rsx! {};
    };

    let saved_layouts = app.borrow().app_config.saved_layouts.clone();

    match dialog_state {
        SaveAsDialog::Editing(ref current_name) => {
            let current_name = current_name.clone();
            let submit_name = {
                let act = act.clone();
                let saved_layouts = saved_layouts.clone();
                move |name: String| {
                    let trimmed = name.trim().to_string();
                    if trimmed.is_empty() {
                        return;
                    }
                    if trimmed.eq_ignore_ascii_case(super::workspace::WORKSPACE_LAYOUT_NAME) {
                        save_as_dialog.set(Some(SaveAsDialog::RejectWorkspace));
                    } else if saved_layouts.iter().any(|n| n == &trimmed) {
                        save_as_dialog.set(Some(SaveAsDialog::ConfirmOverwrite(trimmed)));
                    } else {
                        (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.save_layout_as(&trimmed);
                        }));
                        save_as_dialog.set(None);
                    }
                }
            };
            let mut submit_enter = submit_name.clone();
            let mut submit_ok = submit_name.clone();
            rsx! {
                div {
                    style: "position:fixed; inset:0; background:rgba(0,0,0,0.3); z-index:2000; display:flex; align-items:center; justify-content:center;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        save_as_dialog.set(None);
                    },

                    div {
                        style: "background:{THEME_BG}; border:1px solid {THEME_BORDER}; border-radius:8px; padding:20px; box-shadow:0 8px 32px rgba(0,0,0,0.25); min-width:300px;",
                        onmousedown: move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                        },

                        div {
                            style: "display:flex; align-items:center; gap:8px; margin-bottom:12px;",
                            span {
                                style: "display:inline-block; width:36px; height:16px; flex-shrink:0;",
                                dangerous_inner_html: BRAND_LOGO_SVG,
                            }
                            span {
                                style: "font-size:14px; font-weight:bold; color:{THEME_TEXT};",
                                "Save Workspace As"
                            }
                        }

                        input {
                            r#type: "text",
                            placeholder: "Workspace name",
                            value: "{current_name}",
                            autofocus: true,
                            style: "width:100%; padding:6px 8px; font-size:13px; border:1px solid {THEME_BORDER}; border-radius:4px; box-sizing:border-box; background:{THEME_BG_ACTIVE}; color:{THEME_TEXT};",
                            oninput: move |evt: Event<FormData>| {
                                save_as_dialog.set(Some(SaveAsDialog::Editing(evt.value().to_string())));
                            },
                            onkeydown: move |evt: Event<KeyboardData>| {
                                if evt.data().key() == Key::Enter {
                                    if let Some(SaveAsDialog::Editing(ref name)) = save_as_dialog() {
                                        submit_enter(name.clone());
                                    }
                                } else if evt.data().key() == Key::Escape {
                                    save_as_dialog.set(None);
                                }
                            },
                        }

                        div {
                            style: "display:flex; justify-content:flex-end; gap:8px; margin-top:12px;",

                            div {
                                style: "padding:6px 16px; cursor:pointer; font-size:13px; border:1px solid {THEME_BORDER}; border-radius:4px; user-select:none; color:{THEME_TEXT};",
                                onmousedown: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    save_as_dialog.set(None);
                                },
                                "Cancel"
                            }

                            {
                                rsx! {
                                    div {
                                        style: "padding:6px 16px; cursor:pointer; font-size:13px; background:{THEME_ACCENT}; color:#fff; border-radius:4px; user-select:none;",
                                        onmousedown: move |evt: Event<MouseData>| {
                                            evt.stop_propagation();
                                            if let Some(SaveAsDialog::Editing(ref name)) = save_as_dialog() {
                                                submit_ok(name.clone());
                                            }
                                        },
                                        "Save"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        SaveAsDialog::ConfirmOverwrite(ref name) => {
            let name = name.clone();
            let confirm_name = name.clone();
            let message = format!("Layout \u{201C}{name}\u{201D} already exists. Overwrite?");
            rsx! {
                div {
                    style: "position:fixed; inset:0; background:rgba(0,0,0,0.3); z-index:2000; display:flex; align-items:center; justify-content:center;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                    },

                    div {
                        style: "background:{THEME_BG}; border:1px solid {THEME_BORDER}; border-radius:8px; padding:20px; box-shadow:0 8px 32px rgba(0,0,0,0.25); min-width:300px;",
                        onmousedown: move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                        },

                        div {
                            style: "font-size:13px; margin-bottom:16px; color:{THEME_TEXT};",
                            "{message}"
                        }

                        div {
                            style: "display:flex; justify-content:flex-end; gap:8px;",

                            div {
                                style: "padding:6px 16px; cursor:pointer; font-size:13px; border:1px solid {THEME_BORDER}; border-radius:4px; user-select:none; color:{THEME_TEXT};",
                                onmousedown: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    save_as_dialog.set(Some(SaveAsDialog::Editing(name.clone())));
                                },
                                "Cancel"
                            }

                            {
                                let act = act.clone();
                                rsx! {
                                    div {
                                        style: "padding:6px 16px; cursor:pointer; font-size:13px; background:{THEME_ACCENT}; color:#fff; border-radius:4px; user-select:none;",
                                        onmousedown: move |evt: Event<MouseData>| {
                                            evt.stop_propagation();
                                            let n = confirm_name.clone();
                                            (act.0.borrow_mut())(Box::new(move |st: &mut AppState| {
                                                st.save_layout_as(&n);
                                            }));
                                            save_as_dialog.set(None);
                                        },
                                        "Overwrite"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        SaveAsDialog::RejectWorkspace => {
            rsx! {
                div {
                    style: "position:fixed; inset:0; background:rgba(0,0,0,0.3); z-index:2000; display:flex; align-items:center; justify-content:center;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                    },

                    div {
                        style: "background:{THEME_BG}; border:1px solid {THEME_BORDER}; border-radius:8px; padding:20px; box-shadow:0 8px 32px rgba(0,0,0,0.25); min-width:300px;",
                        onmousedown: move |evt: Event<MouseData>| {
                            evt.stop_propagation();
                        },

                        div {
                            style: "font-size:13px; margin-bottom:16px; color:{THEME_TEXT};",
                            "\u{201C}Workspace\u{201D} is a system workspace that is saved automatically."
                        }

                        div {
                            style: "display:flex; justify-content:flex-end;",

                            div {
                                style: "padding:6px 16px; cursor:pointer; font-size:13px; background:{THEME_ACCENT}; color:#fff; border-radius:4px; user-select:none;",
                                onmousedown: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    save_as_dialog.set(Some(SaveAsDialog::Editing(String::new())));
                                },
                                "OK"
                            }
                        }
                    }
                }
            }
        }
    }
}
