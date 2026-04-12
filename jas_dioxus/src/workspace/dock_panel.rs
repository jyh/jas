//! Dock panel rendering: anchored dock groups and floating docks.
//!
//! Extracted from `app.rs` to keep that file focused on top-level
//! application wiring.

use std::cell::RefCell;
use std::rc::Rc;

use dioxus::prelude::*;

use super::app_state::{Act, AppState};
use super::theme::*;
use super::workspace::{
    DockEdge, DockId, DragPayload, DropTarget, GroupAddr, PanelAddr, PanelGroup,
};
use crate::panels::panel_menu_state::{PanelMenuOpen, PanelMenuState, MenuBarState};

// ---------------------------------------------------------------------------
// DragState — shared drag signals, provided via context
// ---------------------------------------------------------------------------

/// Shared drag-and-drop signals used by dock panels and the main app shell.
#[derive(Clone, Copy)]
pub(crate) struct DragState {
    pub drag_source: Signal<Option<DragPayload>>,
    pub drop_target: Signal<Option<DropTarget>>,
    pub was_dropped: Signal<bool>,
    pub last_drag_pos: Signal<(f64, f64)>,
    pub title_drag: Signal<Option<(DockId, f64, f64)>>,
}

// ---------------------------------------------------------------------------
// build_dock_groups — reusable renderer for a list of PanelGroups
// ---------------------------------------------------------------------------

/// Build panel group nodes for a given dock.  Reused for anchored and
/// floating docks.
pub(crate) fn build_dock_groups(
    dock_id: DockId,
    groups: &[PanelGroup],
    act: &Rc<RefCell<dyn FnMut(Box<dyn FnOnce(&mut AppState)>)>>,
    mut drag_source: Signal<Option<DragPayload>>,
    mut drop_target_sig: Signal<Option<DropTarget>>,
    mut was_dropped: Signal<bool>,
    mut last_drag_pos: Signal<(f64, f64)>,
    focused: Option<PanelAddr>,
    mut panel_menu_open: Signal<Option<PanelMenuOpen>>,
    mut menu_bar_open: Signal<Option<String>>,
) -> Vec<Result<VNode, RenderError>> {
    let did = dock_id;
    let group_count = groups.len();
    let cur_drag = drag_source();
    let cur_drop = drop_target_sig();

    groups.iter().enumerate().map(|(gi, group)| {
        let act_tabs = act.clone();
        let act_chevron = act.clone();
        let act_collapse = act.clone();
        let act_drop = act.clone();
        let group_collapsed = group.collapsed;

        // Tab insertion indicator: which index has the drop caret?
        let tab_drop_idx: Option<usize> = if cur_drag.is_some() {
            match cur_drop {
                Some(DropTarget::TabBar { group: g, index }) if g == (GroupAddr { dock_id: did, group_idx: gi }) => Some(index),
                _ => None,
            }
        } else {
            None
        };
        let panel_count = group.panels.len();

        // Tab bar buttons — each tab is individually draggable
        let tab_nodes: Vec<Result<VNode, RenderError>> = group.panels.iter().enumerate().flat_map(|(pi, &kind)| {
            let act_dragend = act_tabs.clone();
            let act_click = act_tabs.clone();
            let label = crate::panels::panel_label(kind);
            let is_active = pi == group.active;
            let bg = if is_active { THEME_BG_TAB } else { THEME_BG_TAB_INACTIVE };
            let border_bottom = if is_active { format!("2px solid {THEME_BG_TAB}") } else { format!("2px solid {THEME_BORDER}") };
            let font_weight = if is_active { "bold" } else { "normal" };
            let is_focused = focused == Some(PanelAddr {
                group: GroupAddr { dock_id: did, group_idx: gi },
                panel_idx: pi,
            });
            let outline = "";

            // Insertion indicator before this tab
            let show_caret = tab_drop_idx == Some(pi);
            let mut nodes: Vec<Result<VNode, RenderError>> = Vec::new();
            if show_caret {
                nodes.push(rsx! {
                    div {
                        key: "tab-caret-{gi}-{pi}",
                        style: "width:3px; align-self:stretch; background:{THEME_ACCENT}; border-radius:1px; flex-shrink:0; transition:width 0.1s ease;",
                    }
                });
            }
            nodes.push(rsx! {
                div {
                    key: "dock-tab-{gi}-{pi}",
                    style: "padding:3px 8px; cursor:pointer; font-size:11px; color:{THEME_TEXT}; font-weight:{font_weight}; background:{bg}; border-bottom:{border_bottom}; user-select:none; {outline}",
                    draggable: "true",
                    ondragstart: move |evt: Event<DragData>| {
                        evt.stop_propagation();
                        drag_source.set(Some(DragPayload::Panel(PanelAddr {
                            group: GroupAddr { dock_id: did, group_idx: gi },
                            panel_idx: pi,
                        })));
                        was_dropped.set(false);
                    },
                    ondragend: move |_| {
                        if !was_dropped() {
                            let (x, y) = last_drag_pos();
                            let cur_tgt = drop_target_sig();
                            (act_dragend.borrow_mut())(Box::new(move |st: &mut AppState| {
                                let addr = PanelAddr {
                                    group: GroupAddr { dock_id: did, group_idx: gi },
                                    panel_idx: pi,
                                };
                                if let Some(DropTarget::Edge(edge)) = cur_tgt {
                                    if let Some(fid) = st.workspace_layout.detach_panel(addr, x, y) {
                                        st.workspace_layout.snap_to_edge(fid, edge);
                                    }
                                } else {
                                    st.workspace_layout.detach_panel(addr, x, y);
                                }
                            }));
                        }
                        drag_source.set(None);
                        drop_target_sig.set(None);
                        was_dropped.set(false);
                    },
                    ondragover: move |evt: Event<DragData>| {
                        evt.prevent_default();
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        last_drag_pos.set((coords.x, coords.y));
                        // Left half → insert before this tab; right half → insert after
                        let x = evt.data().element_coordinates().x;
                        let mid = 30.0; // approximate tab half-width
                        let idx = if x < mid { pi } else { pi + 1 };
                        drop_target_sig.set(Some(DropTarget::TabBar {
                            group: GroupAddr { dock_id: did, group_idx: gi },
                            index: idx,
                        }));
                    },
                    onclick: move |_| {
                        (act_click.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.workspace_layout.set_active_panel(PanelAddr {
                                group: GroupAddr { dock_id: did, group_idx: gi },
                                panel_idx: pi,
                            });
                        }));
                    },
                    "{label}"
                    // Close button
                    {
                        let act_close = act_click.clone();
                        rsx! {
                            span {
                                style: "margin-left:4px; color:{THEME_TEXT_BODY}; cursor:pointer; font-size:10px; line-height:1;",
                                onclick: move |evt: Event<MouseData>| {
                                    evt.stop_propagation();
                                    (act_close.borrow_mut())(Box::new(move |st: &mut AppState| {
                                        st.workspace_layout.close_panel(PanelAddr {
                                            group: GroupAddr { dock_id: did, group_idx: gi },
                                            panel_idx: pi,
                                        });
                                    }));
                                },
                                "\u{00d7}"
                            }
                        }
                    }
                }
            });
            // After-last caret (only on the final tab)
            if pi == panel_count - 1 && tab_drop_idx == Some(panel_count) {
                nodes.push(rsx! {
                    div {
                        key: "tab-caret-{gi}-end",
                        style: "width:3px; align-self:stretch; background:{THEME_ACCENT}; border-radius:1px; flex-shrink:0; transition:width 0.1s ease;",
                    }
                });
            }
            nodes
        }).collect();

        let chevron = if group_collapsed { "\u{00BB}" } else { "\u{00AB}" };
        let body_label = group.active_panel()
            .map(crate::panels::panel_label)
            .unwrap_or("");
        // Pre-compute active panel info for hamburger menu button
        let active_panel_info = group.active_panel().map(|kind| (kind, group.active));

        // Drop indicator logic
        let show_drop_before = cur_drag.is_some()
            && cur_drop == Some(DropTarget::GroupSlot { dock_id: did, group_idx: gi });
        let drop_indicator_style = if show_drop_before {
            "height:3px; background:{THEME_ACCENT}; border-radius:1px; margin:1px 4px; transition:height 0.1s ease;"
        } else {
            "height:0px; margin:0 4px; transition:height 0.1s ease;"
        };
        let show_drop_after = gi == group_count - 1
            && cur_drag.is_some()
            && cur_drop == Some(DropTarget::GroupSlot { dock_id: did, group_idx: group_count });
        let drop_after_style = if show_drop_after {
            "height:3px; background:{THEME_ACCENT}; border-radius:1px; margin:1px 4px; transition:height 0.1s ease;"
        } else {
            "height:0px; margin:0 4px; transition:height 0.1s ease;"
        };
        // Highlight tab bar when it's a TabBar drop target
        let tab_bar_drop = cur_drag.is_some()
            && matches!(cur_drop, Some(DropTarget::TabBar { group, .. }) if group == GroupAddr { dock_id: did, group_idx: gi });
        let tab_bar_border = if tab_bar_drop { format!("2px solid {THEME_ACCENT}") } else { format!("1px solid {THEME_BORDER}") };

        let is_dragged_group = matches!(cur_drag,
            Some(DragPayload::Group(addr)) if addr.dock_id == did && addr.group_idx == gi);
        let opacity = if is_dragged_group { "0.4" } else { "1.0" };

        rsx! {
            div {
                key: "dock-group-{did:?}-{gi}",
                style: "border-bottom:1px solid {THEME_BORDER}; opacity:{opacity};",
                ondragover: move |evt: Event<DragData>| {
                    evt.prevent_default();
                    let coords = evt.data().page_coordinates();
                    last_drag_pos.set((coords.x, coords.y));
                    let y = evt.data().element_coordinates().y;
                    let mid = 30.0;
                    if y < mid {
                        drop_target_sig.set(Some(DropTarget::GroupSlot { dock_id: did, group_idx: gi }));
                    } else {
                        drop_target_sig.set(Some(DropTarget::GroupSlot { dock_id: did, group_idx: gi + 1 }));
                    }
                },
                ondrop: move |evt: Event<DragData>| {
                    evt.prevent_default();
                    was_dropped.set(true);
                    let src = drag_source();
                    let tgt = drop_target_sig();
                    if let (Some(src), Some(tgt)) = (src, tgt) {
                        (act_drop.borrow_mut())(Box::new(move |st: &mut AppState| {
                            match (src, tgt) {
                                (DragPayload::Group(from), DropTarget::GroupSlot { dock_id: to_dock, group_idx: to_idx }) => {
                                    if from.dock_id == to_dock {
                                        st.workspace_layout.move_group_within_dock(to_dock, from.group_idx, to_idx);
                                    } else {
                                        st.workspace_layout.move_group_to_dock(from, to_dock, to_idx);
                                    }
                                }
                                (DragPayload::Panel(from), DropTarget::GroupSlot { dock_id: to_dock, group_idx: to_idx }) => {
                                    st.workspace_layout.insert_panel_as_new_group(from, to_dock, to_idx);
                                }
                                (DragPayload::Group(from), DropTarget::TabBar { group: to_group, .. }) => {
                                    st.workspace_layout.move_group_to_dock(from, to_group.dock_id, to_group.group_idx);
                                }
                                (DragPayload::Panel(from), DropTarget::TabBar { group: to_group, index: to_idx }) => {
                                    if from.group == to_group {
                                        // Same group: reorder
                                        st.workspace_layout.reorder_panel(to_group, from.panel_idx, to_idx);
                                    } else {
                                        st.workspace_layout.move_panel_to_group(from, to_group);
                                    }
                                }
                                _ => {}
                            }
                        }));
                    }
                    drag_source.set(None);
                    drop_target_sig.set(None);
                },

                div { style: "{drop_indicator_style}" }

                // Tab bar with grip handle
                {let panel_count = group.panels.len();
                rsx! { div {
                    style: "display:flex; background:{THEME_BG_DARK}; border-bottom:{tab_bar_border}; align-items:center; overflow-x:auto; overflow-y:hidden; min-height:24px;",
                    ondragover: move |evt: Event<DragData>| {
                        evt.prevent_default();
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        last_drag_pos.set((coords.x, coords.y));
                        drop_target_sig.set(Some(DropTarget::TabBar { group: GroupAddr { dock_id: did, group_idx: gi }, index: panel_count }));
                    },

                    // Grip handle for dragging the whole group
                    div {
                        style: "padding:2px 4px; cursor:grab; color:{THEME_TEXT_HINT}; font-size:10px; user-select:none;",
                        draggable: "true",
                        ondragstart: move |evt: Event<DragData>| {
                            evt.stop_propagation();
                            drag_source.set(Some(DragPayload::Group(GroupAddr {
                                dock_id: did,
                                group_idx: gi,
                            })));
                            was_dropped.set(false);
                        },
                        ondragend: move |_| {
                            if !was_dropped() {
                                let (x, y) = last_drag_pos();
                                let cur_tgt = drop_target_sig();
                                let act_detach = act_collapse.clone();
                                (act_detach.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    let addr = GroupAddr { dock_id: did, group_idx: gi };
                                    if let Some(DropTarget::Edge(edge)) = cur_tgt {
                                        // Detach then snap to edge
                                        if let Some(fid) = st.workspace_layout.detach_group(addr, x, y) {
                                            st.workspace_layout.snap_to_edge(fid, edge);
                                        }
                                    } else {
                                        st.workspace_layout.detach_group(addr, x, y);
                                    }
                                }));
                            }
                            drag_source.set(None);
                            drop_target_sig.set(None);
                            was_dropped.set(false);
                        },
                        "\u{2801}\u{2801}"
                    }

                    for tab in tab_nodes {
                        {tab}
                    }

                    div {
                        style: "margin-left:auto; padding:3px 6px; cursor:pointer; font-size:18px; color:{THEME_TEXT_BUTTON}; user-select:none; line-height:1;",
                        onclick: {
                            let act = act_chevron.clone();
                            move |_| {
                                (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    st.workspace_layout.toggle_group_collapsed(GroupAddr {
                                        dock_id: did,
                                        group_idx: gi,
                                    });
                                }));
                            }
                        },
                        "{chevron}"
                    }

                    // Hamburger menu button — hidden when collapsed
                    if !group_collapsed && active_panel_info.is_some() {
                        {
                            let (active_kind, active_idx) = active_panel_info.unwrap();
                            rsx! {
                                div {
                                    style: "padding:3px 6px; cursor:pointer; font-size:18px; color:{THEME_TEXT_BUTTON}; user-select:none; line-height:1;",
                                    onmousedown: move |evt: Event<MouseData>| {
                                        evt.stop_propagation();
                                        let coords = evt.data().page_coordinates();
                                        let addr = PanelAddr {
                                            group: GroupAddr { dock_id: did, group_idx: gi },
                                            panel_idx: active_idx,
                                        };
                                        panel_menu_open.set(Some(PanelMenuOpen {
                                            kind: active_kind,
                                            addr,
                                            x: coords.x,
                                            y: coords.y,
                                        }));
                                        menu_bar_open.set(None);
                                    },
                                    "\u{2261}" // ≡
                                }
                            }
                        }
                    }
                } } } // close tab bar div, rsx!, let

                if !group_collapsed {
                    div {
                        style: "padding:12px; min-height:60px; color:{THEME_TEXT_BODY}; font-size:12px;",
                        "{body_label}"
                    }
                }

                div { style: "{drop_after_style}" }
            }
        }
    }).collect()
}

// ---------------------------------------------------------------------------
// DockGroupsView — anchored dock content
// ---------------------------------------------------------------------------

/// Renders the panel groups for the anchored right dock.
///
/// When the dock is collapsed, shows icon buttons for each panel.
/// When expanded, renders full tabbed groups via [`build_dock_groups`].
#[component]
pub(crate) fn DockGroupsView() -> Element {
    let act = use_context::<Act>();
    let app = use_context::<Rc<RefCell<AppState>>>();
    let ds = use_context::<DragState>();
    let pms = use_context::<PanelMenuState>();
    let mbs = use_context::<MenuBarState>();
    // Subscribe to revision so we re-render when state changes.
    let revision = use_context::<Signal<u64>>();
    let _ = revision();

    let st = app.borrow();
    let layout = &st.workspace_layout;
    let focused_panel = layout.focused_panel();
    let right_dock = layout.anchored_dock(DockEdge::Right);

    let nodes: Vec<Result<VNode, RenderError>> = match right_dock {
        None => vec![],
        Some(dock) if dock.collapsed => {
            let act_dock = act.0.clone();
            let did = dock.id;
            dock.groups.iter().enumerate().flat_map(|(gi, group)| {
                let act_inner = act_dock.clone();
                group.panels.iter().enumerate().map(move |(pi, &kind)| {
                    let act = act_inner.clone();
                    let label = crate::panels::panel_label(kind);
                    let first_char: String = label.chars().take(1).collect();
                    rsx! {
                        div {
                            key: "dock-icon-{gi}-{pi}",
                            style: "width:28px; height:28px; margin:2px auto; background:{THEME_BG_TAB}; border-radius:3px; display:flex; align-items:center; justify-content:center; cursor:pointer; font-size:12px; font-weight:bold; color:{THEME_TEXT};",
                            title: "{label}",
                            onclick: move |_| {
                                (act.borrow_mut())(Box::new(move |st: &mut AppState| {
                                    st.workspace_layout.toggle_dock_collapsed(did);
                                    st.workspace_layout.set_active_panel(PanelAddr {
                                        group: GroupAddr { dock_id: did, group_idx: gi },
                                        panel_idx: pi,
                                    });
                                }));
                            },
                            "{first_char}"
                        }
                    }
                })
            }).collect()
        }
        Some(dock) => {
            build_dock_groups(
                dock.id,
                &dock.groups,
                &act.0,
                ds.drag_source,
                ds.drop_target,
                ds.was_dropped,
                ds.last_drag_pos,
                focused_panel,
                pms.open,
                mbs.open_menu,
            )
        }
    };

    // Release borrow before rendering
    drop(st);

    rsx! {
        for node in nodes {
            {node}
        }
    }
}

// ---------------------------------------------------------------------------
// FloatingDocksView — all floating dock overlays
// ---------------------------------------------------------------------------

/// Renders every floating dock as a position:fixed overlay.
#[component]
pub(crate) fn FloatingDocksView() -> Element {
    let act = use_context::<Act>();
    let app = use_context::<Rc<RefCell<AppState>>>();
    let ds = use_context::<DragState>();
    let pms = use_context::<PanelMenuState>();
    let mbs = use_context::<MenuBarState>();
    // Subscribe to revision so we re-render when state changes.
    let revision = use_context::<Signal<u64>>();
    let _ = revision();
    let mut title_drag = ds.title_drag;

    let st = app.borrow();
    let layout = &st.workspace_layout;
    let focused_panel = layout.focused_panel();

    let floating_nodes: Vec<Result<VNode, RenderError>> = layout.floating.iter().map(|fd| {
        let fid = fd.dock.id;
        let fx = fd.x;
        let fy = fd.y;
        let fw = fd.dock.width;
        let act_front = act.0.clone();
        let act_redock = act.0.clone();
        let fgroups = build_dock_groups(
            fid,
            &fd.dock.groups,
            &act.0,
            ds.drag_source,
            ds.drop_target,
            ds.was_dropped,
            ds.last_drag_pos,
            focused_panel,
            pms.open,
            mbs.open_menu,
        );
        let z = 900 + layout.z_order.iter().position(|&id| id == fid).unwrap_or(0);

        rsx! {
            div {
                key: "floating-{fid:?}",
                style: "position:fixed; left:{fx}px; top:{fy}px; width:{fw}px; background:{THEME_BG}; border:1px solid {THEME_BORDER}; box-shadow:4px 4px 12px rgba(0,0,0,0.4); border-radius:4px; z-index:{z}; display:flex; flex-direction:column; overflow:hidden;",
                onmousedown: move |evt: Event<MouseData>| {
                    evt.stop_propagation();
                    (act_front.borrow_mut())(Box::new(move |st: &mut AppState| {
                        st.workspace_layout.bring_to_front(fid);
                    }));
                },

                // Title bar: drag to reposition, double-click to redock
                div {
                    style: "height:20px; background:{THEME_BG_DARK}; cursor:grab; display:flex; align-items:center; padding:0 6px; font-size:10px; color:{THEME_TEXT_DIM}; user-select:none;",
                    onmousedown: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        let coords = evt.data().page_coordinates();
                        title_drag.set(Some((fid, coords.x - fx, coords.y - fy)));
                    },
                    ondoubleclick: move |evt: Event<MouseData>| {
                        evt.stop_propagation();
                        title_drag.set(None);
                        (act_redock.borrow_mut())(Box::new(move |st: &mut AppState| {
                            st.workspace_layout.redock(fid);
                        }));
                    },
                }

                for g in fgroups {
                    {g}
                }
            }
        }
    }).collect();

    // Release borrow before rendering
    drop(st);

    rsx! {
        for fdock in floating_nodes {
            {fdock}
        }
    }
}
