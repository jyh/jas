//! The engine's dock layout, seeded from the SPEC (`default_layouts.yaml`) and
//! read back for a shell (floating panels on Windows, node FP-2).
//!
//! A shell that draws docks from the engine needs two things this module
//! answers: a `WorkspaceLayout` seeded from the named layout the bundle
//! declares, and that layout as plain data a shell can draw without holding
//! any dock law of its own.
//!
//! **The seed reads the YAML through [`crate::panel_plan::dock_layout`]**, the
//! one strict reader the Windows dock already draws from, so the two cannot
//! disagree about a group: an `active` outside its group, an empty group or a
//! panel the bundle lacks is refused there and so here. It is NOT
//! `WorkspaceLayout::named()`, whose hard-coded Default dock differs from the
//! YAML's; seeding from `named()` would move the Windows dock under the shell.

use serde_json::{json, Value};

use crate::workspace::layout_apply::{panel_kind_str, parse_panel_kind};
use crate::workspace::workspace::{Dock, DockEdge, PanelGroup, PanelKind, WorkspaceLayout};

const CONTENT_SUFFIX: &str = "_panel_content";

/// A panel's kind from its bundle content id (`color_panel_content`), or
/// `None` for an id that names no `PanelKind`. Strict: `parse_panel_kind`
/// falls back to `Layers` for anything it does not know, so the answer is
/// checked by the inverse rather than trusted.
fn kind_of_content_id(id: &str) -> Option<PanelKind> {
    let short = id.strip_suffix(CONTENT_SUFFIX)?;
    let kind = parse_panel_kind(short);
    (panel_kind_str(kind) == short).then_some(kind)
}

fn content_id(kind: PanelKind) -> String {
    format!("{}{CONTENT_SUFFIX}", panel_kind_str(kind))
}

/// The layout named `name` in the bundle's `default_layouts`, as the engine
/// holds it: one Right-anchored dock with the YAML's groups and active tabs,
/// collapsed as the layout's `state.dock_collapsed` says. `None`, never a
/// repaired layout, when `dock_layout` refuses the dock, a docked panel names
/// no `PanelKind`, `dock_collapsed` is present and not a boolean, or the layout
/// declares a non-empty `floating` (the spec gives a floating entry no schema,
/// so a seed would be a guess).
pub fn from_default_layout(data: &Value, name: &str) -> Option<WorkspaceLayout> {
    let decl = data.get("default_layouts")?.get(name)?;
    match decl.get("floating") {
        None => {}
        Some(Value::Array(f)) if f.is_empty() => {}
        Some(_) => return None,
    }
    let collapsed = match decl.get("state").and_then(|s| s.get("dock_collapsed")) {
        None => false,
        Some(v) => v.as_bool()?,
    };
    let dock = crate::panel_plan::dock_layout(data, name)?;
    let mut groups = vec![];
    for g in dock.get("groups")?.as_array()? {
        let mut panels = vec![];
        for id in g.get("panels")?.as_array()? {
            panels.push(kind_of_content_id(id.as_str()?)?);
        }
        let mut group = PanelGroup::new(panels);
        group.active = g.get("active")?.as_u64()? as usize;
        groups.push(group);
    }
    let mut layout = WorkspaceLayout::named(name);
    let (_, d) = layout.anchored.first_mut()?;
    *d = Dock::from_parts(d.id, groups, collapsed, d.auto_hide, d.width, d.min_width);
    Some(layout)
}

fn edge_str(e: DockEdge) -> &'static str {
    match e {
        DockEdge::Left => "left",
        DockEdge::Right => "right",
        DockEdge::Bottom => "bottom",
    }
}

fn dock_json(d: &Dock) -> Value {
    let groups: Vec<Value> = d.groups.iter().map(|g| json!({
        "panels": g.panels.iter().map(|k| content_id(*k)).collect::<Vec<_>>(),
        "active": g.active,
        "collapsed": g.collapsed,
    })).collect();
    json!({"id": d.id.0, "collapsed": d.collapsed, "width": d.width, "groups": groups})
}

/// The layout as a shell draws it: anchored docks with their edge, floating
/// docks with their position, every panel by its CONTENT id (what
/// `jas_panel_plan` takes), each floating dock's stacking index `z` (draw in
/// ascending `z`), and `z_order` back to front. A shell reads this and
/// sends `layout_apply` verbs; it holds no dock state of its own.
pub fn shell_state(layout: &WorkspaceLayout) -> Value {
    let anchored: Vec<Value> = layout.anchored.iter().map(|(e, d)| {
        let mut v = dock_json(d);
        v["edge"] = json!(edge_str(*e));
        v
    }).collect();
    let floating: Vec<Value> = layout.floating.iter().map(|f| {
        let mut v = dock_json(&f.dock);
        v["x"] = json!(f.x);
        v["y"] = json!(f.y);
        // The engine's own stacking law (`z_index_for`: 0 = back, and a dock
        // missing from `z_order` reads 0), so a shell sorts and holds no law.
        v["z"] = json!(layout.z_index_for(f.dock.id));
        v
    }).collect();
    json!({
        "name": layout.name,
        "anchored": anchored,
        "floating": floating,
        "z_order": layout.z_order.iter().map(|id| id.0).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace::layout_apply::layout_apply;

    fn bundle(layout: Value) -> Value {
        json!({
            "panels": {"color_panel_content": {}, "align_panel_content": {}, "zzz_panel_content": {}},
            "default_layouts": {"L": layout}
        })
    }

    fn dock(groups: Value) -> Value {
        json!({"dock": {"dock_main": {"groups": groups}}})
    }

    /// The seed's groups are the groups the Windows dock draws today, for every
    /// layout the real bundle declares, so moving the shell onto the engine's
    /// layout (FP-3) changes nothing it draws.
    #[test]
    fn every_bundle_layout_seeds_the_groups_the_dock_reader_answers() {
        let ws = crate::interpreter::workspace::Workspace::load().expect("the compiled workspace");
        let names: Vec<String> = ws.data()["default_layouts"].as_object().unwrap().keys().cloned().collect();
        assert!(names.len() >= 3, "only {names:?}");
        for name in &names {
            let seeded = from_default_layout(ws.data(), name).unwrap_or_else(|| panic!("{name} refused"));
            let want = crate::panel_plan::dock_layout(ws.data(), name).unwrap();
            let got = &shell_state(&seeded)["anchored"][0];
            assert_eq!(got["edge"], "right", "{name}");
            for (i, g) in want["groups"].as_array().unwrap().iter().enumerate() {
                assert_eq!(got["groups"][i]["panels"], g["panels"], "{name} group {i}");
                assert_eq!(got["groups"][i]["active"], g["active"], "{name} group {i}");
            }
            assert_eq!(got["groups"].as_array().unwrap().len(), want["groups"].as_array().unwrap().len(), "{name}");
            assert_eq!(shell_state(&seeded)["floating"], json!([]), "{name}");
        }
    }

    /// The seed is NOT `named()`: the bundle's Default has `brushes` in its first
    /// group and `named()` does not. If they ever agree this arm says so, and
    /// the seeding question can be revisited.
    #[test]
    fn the_seed_is_the_yaml_not_the_hard_coded_default() {
        let ws = crate::interpreter::workspace::Workspace::load().unwrap();
        let seeded = from_default_layout(ws.data(), "Default").unwrap();
        let named = WorkspaceLayout::named("Default");
        assert_ne!(seeded.anchored[0].1.groups[0].panels, named.anchored[0].1.groups[0].panels);
        assert!(seeded.anchored[0].1.groups[0].panels.contains(&PanelKind::Brushes));
    }

    #[test]
    fn active_and_dock_collapsed_are_read_from_the_layout() {
        let mut l = dock(json!([{"panels": ["color", "align"], "active": 1}]));
        l["state"] = json!({"dock_collapsed": true});
        let s = shell_state(&from_default_layout(&bundle(l), "L").unwrap());
        assert_eq!(s["anchored"][0]["groups"][0]["active"], 1);
        assert_eq!(s["anchored"][0]["collapsed"], true);
        let open = shell_state(&from_default_layout(&bundle(dock(json!([{"panels": ["color"], "active": 0}]))), "L").unwrap());
        assert_eq!(open["anchored"][0]["collapsed"], false);
    }

    /// Each refusal is driven against a control that the same bundle, with the
    /// one defect removed, DOES seed, so a refusal for another reason cannot
    /// pass the arm.
    #[test]
    fn a_defective_layout_is_refused_never_repaired() {
        let ok = dock(json!([{"panels": ["color"], "active": 0}]));
        assert!(from_default_layout(&bundle(ok.clone()), "L").is_some(), "the control seeds");
        assert!(from_default_layout(&bundle(ok.clone()), "Nope").is_none(), "an unknown layout");
        let no_kind = dock(json!([{"panels": ["zzz"], "active": 0}]));
        assert!(from_default_layout(&bundle(no_kind), "L").is_none(), "a panel with no PanelKind");
        let bad_active = dock(json!([{"panels": ["color"], "active": 3}]));
        assert!(from_default_layout(&bundle(bad_active), "L").is_none(), "dock_layout's refusal is inherited");
        let mut floating = ok.clone();
        floating["floating"] = json!([{"x": 0}]);
        assert!(from_default_layout(&bundle(floating), "L").is_none(), "a floating entry has no schema");
        let mut empty_floating = ok.clone();
        empty_floating["floating"] = json!([]);
        assert!(from_default_layout(&bundle(empty_floating), "L").is_some(), "an empty floating list seeds");
        let mut bad_state = ok;
        bad_state["state"] = json!({"dock_collapsed": "yes"});
        assert!(from_default_layout(&bundle(bad_state), "L").is_none(), "dock_collapsed not a boolean");
    }

    #[test]
    fn a_content_id_maps_to_its_kind_only_when_the_kind_round_trips() {
        assert_eq!(kind_of_content_id("brushes_panel_content"), Some(PanelKind::Brushes));
        assert_eq!(kind_of_content_id("magic_wand_panel_content"), Some(PanelKind::MagicWand));
        assert_eq!(kind_of_content_id("layers_panel_content"), Some(PanelKind::Layers));
        // `parse_panel_kind` answers Layers for these; the round trip refuses.
        assert_eq!(kind_of_content_id("zzz_panel_content"), None);
        assert_eq!(kind_of_content_id("color"), None);
    }

    #[test]
    fn a_floating_dock_reads_back_with_its_position_ids_and_z_order() {
        let mut l = from_default_layout(&bundle(dock(json!([
            {"panels": ["color"], "active": 0}, {"panels": ["align"], "active": 0}]))), "L").unwrap();
        layout_apply(&mut l, &json!({"op": "detach_group", "dock_id": 0, "group_idx": 1, "x": 12.0, "y": 34.0}));
        let s = shell_state(&l);
        assert_eq!(s["anchored"][0]["groups"].as_array().unwrap().len(), 1);
        let f = &s["floating"][0];
        assert_eq!((f["x"].as_f64(), f["y"].as_f64()), (Some(12.0), Some(34.0)));
        assert_eq!(f["groups"][0]["panels"], json!(["align_panel_content"]));
        assert_eq!(s["z_order"], json!([f["id"].clone()]));
        assert_ne!(f["id"], s["anchored"][0]["id"]);
    }

    /// Each floating dock carries its stacking index from the engine's own
    /// `z_index_for`, so a shell sorts by it and holds no stacking law. Driven
    /// both ways: the dock brought to the front reads the higher `z`, and the
    /// other one does after it is brought forward in turn.
    #[test]
    fn a_floating_dock_carries_the_engines_stacking_index() {
        let mut l = from_default_layout(&bundle(dock(json!([
            {"panels": ["color"], "active": 0}, {"panels": ["align"], "active": 0},
            {"panels": ["zzz"], "active": 0}]))), "L");
        assert!(l.is_none(), "control: zzz names no kind");
        l = from_default_layout(&bundle(dock(json!([
            {"panels": ["color"], "active": 0}, {"panels": ["align"], "active": 0}]))), "L");
        let mut l = l.unwrap();
        let op = |g: usize| json!({"op": "detach_group", "dock_id": 0, "group_idx": g, "x": 1.0, "y": 2.0});
        layout_apply(&mut l, &op(1));
        layout_apply(&mut l, &op(0));
        let z = |l: &WorkspaceLayout| shell_state(l)["floating"].as_array().unwrap().iter()
            .map(|f| (f["id"].as_u64().unwrap(), f["z"].as_u64().unwrap())).collect::<Vec<_>>();
        let first = z(&l);
        assert_eq!(first.len(), 2);
        assert!(first[1].1 > first[0].1, "the later detach is in front: {first:?}");
        layout_apply(&mut l, &json!({"op": "bring_to_front", "dock_id": first[0].0}));
        let after = z(&l);
        assert!(after[0].1 > after[1].1, "brought forward: {after:?}");
    }
}
