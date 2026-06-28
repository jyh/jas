//! Shared canonical panel widget-layout pass (Path B).
//!
//! Rust port of `jas/panels/panel_layout.py`.  A pure, integer-arithmetic
//! layout of a compiled panel node into widget rects, byte-identical across
//! all five apps.  The full contract is PATH_B_DESIGN.md Appendix A.
//!
//! All arithmetic is integer (no float anywhere), so the four native
//! implementations are byte-identical and the corpus
//! (`test_fixtures/algorithms/panel_layout.json`) needs no tolerance.  Text
//! widths use the deterministic stub measure `len(text) * CHAR_WIDTH`
//! (CHAR_WIDTH = 10) and columns use the Bootstrap-12 rule
//! `cell_w = (2*inner_w*N + 12) / 24` (round-half-up, exact).

use serde_json::{json, Value};

pub const CHAR_WIDTH: i64 = 10;

const CONTAINER_TYPES: [&str; 4] = ["container", "row", "col", "panel"];

struct MItem {
    path: Vec<i64>,
    x: i64,
    y: i64,
    w: i64,
    h: i64,
}

/// Lay out a compiled panel node (`{"type":"panel","content":<root>}`) into a
/// JSON array of `{"path":[..],"rect":{x,y,w,h}}`, pre-order, panel-relative.
pub fn layout_panel(panel_node: &Value, avail_w: i64) -> Value {
    let root = match panel_node.get("content") {
        Some(r) if r.is_object() => r,
        _ => return json!([]),
    };
    let (_w, _h, items) = measure(root, &[], avail_w);
    Value::Array(
        items
            .into_iter()
            .map(|it| json!({
                "path": it.path,
                "rect": {"x": it.x, "y": it.y, "w": it.w, "h": it.h},
            }))
            .collect(),
    )
}

// ── internals ─────────────────────────────────────────────────────────

fn node_type(n: &Value) -> &str {
    n.get("type").and_then(|v| v.as_str()).unwrap_or("")
}

fn style(n: &Value) -> &Value {
    n.get("style").unwrap_or(&Value::Null)
}

fn style_i(n: &Value, key: &str) -> Option<i64> {
    style(n)
        .get(key)
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
}

fn is_container(n: &Value) -> bool {
    CONTAINER_TYPES.contains(&node_type(n))
}

fn has_col(n: &Value) -> bool {
    n.get("col").map_or(false, |v| !v.is_null())
}

fn resolved_layout(n: &Value) -> &'static str {
    match n.get("layout").and_then(|v| v.as_str()) {
        Some("row") => "row",
        Some("column") => "column",
        _ => {
            if node_type(n) == "row" {
                "row"
            } else {
                "column"
            }
        }
    }
}

fn text_w(s: &str) -> i64 {
    s.chars().count() as i64 * CHAR_WIDTH
}

fn is_fill(kind: &str) -> bool {
    matches!(
        kind,
        "select" | "number_input" | "text_input" | "length_input" | "slider"
            | "placeholder" | "separator" | "combo_box" | "icon_select" | "spacer"
            // composite / data-driven widgets: placed as a fixed box (fill width)
            | "color_bar" | "fill_stroke_widget" | "gradient_slider" | "gradient_tile"
            | "dropdown" | "tree_view"
    )
}

fn kind_height(kind: &str) -> i64 {
    match kind {
        "text" => 20,
        "button" => 24,
        "checkbox" => 20,
        "icon_button" => 24,
        "icon" => 20,
        "select" => 20,
        "number_input" => 20,
        "text_input" => 20,
        "length_input" => 20,
        "slider" => 12,
        "placeholder" => 40,
        "separator" => 1,
        "combo_box" => 20,
        "icon_select" => 20,
        "spacer" => 0,
        "color_swatch" => 16,
        "toggle" => 20,
        // composite box heights (provisional)
        "color_bar" => 24,
        "fill_stroke_widget" => 44,
        "gradient_slider" => 24,
        "gradient_tile" => 24,
        "dropdown" => 20,
        "tree_view" => 200,
        _ => 20,
    }
}

fn kind_fallback_w(kind: &str) -> i64 {
    match kind {
        "select" => 80,
        "number_input" => 45,
        "text_input" => 80,
        "length_input" => 80,
        "slider" => 100,
        "placeholder" => 60,
        "combo_box" => 80,
        "icon_select" => 80,
        "fill_stroke_widget" => 50,
        "gradient_tile" => 32,
        "dropdown" => 80,
        _ => 0,
    }
}

/// Resolve a style dimension to integer px, or None to ignore. Numbers truncate
/// toward zero; `"N%"` is `(avail*N)/100` (ignored when avail <= 0); a bare numeric
/// string is that int; anything else (`"auto"`, junk) is ignored.
fn resolve_dim(v: &Value, avail: i64) -> Option<i64> {
    if v.is_null() {
        return None;
    }
    if let Some(n) = v.as_i64() {
        return Some(n);
    }
    if let Some(f) = v.as_f64() {
        return Some(f as i64);
    }
    if let Some(s) = v.as_str() {
        let s = s.trim();
        if let Some(num) = s.strip_suffix('%') {
            let num = num.trim();
            let p = num
                .parse::<i64>()
                .ok()
                .or_else(|| num.parse::<f64>().ok().map(|f| f as i64))?;
            return if avail > 0 { Some((avail * p) / 100) } else { None };
        }
        return s
            .parse::<i64>()
            .ok()
            .or_else(|| s.parse::<f64>().ok().map(|f| f as i64));
    }
    None
}

/// CSS 1/2/4-value shorthand -> (top, right, bottom, left), ints.
fn parse_padding(v: &Value) -> (i64, i64, i64, i64) {
    if v.is_null() {
        return (0, 0, 0, 0);
    }
    if let Some(n) = v.as_i64() {
        return (n, n, n, n);
    }
    if let Some(f) = v.as_f64() {
        let n = f as i64;
        return (n, n, n, n);
    }
    let parts: Vec<i64> = if let Some(s) = v.as_str() {
        s.split_whitespace().filter_map(|p| p.parse::<i64>().ok()).collect()
    } else if let Some(a) = v.as_array() {
        a.iter()
            .filter_map(|x| x.as_i64().or_else(|| x.as_f64().map(|f| f as i64)))
            .collect()
    } else {
        return (0, 0, 0, 0);
    };
    match parts.len() {
        1 => {
            let n = parts[0];
            (n, n, n, n)
        }
        2 => (parts[0], parts[1], parts[0], parts[1]),
        n if n >= 4 => (parts[0], parts[1], parts[2], parts[3]),
        _ => (0, 0, 0, 0),
    }
}

fn visible_children(n: &Value) -> Vec<(i64, &Value)> {
    let mut out = vec![];
    if let Some(ch) = n.get("children").and_then(|v| v.as_array()) {
        for (i, c) in ch.iter().enumerate() {
            if !c.is_object() {
                continue;
            }
            if c.get("visible").map_or(false, |v| v.as_bool() == Some(false)) {
                continue;
            }
            out.push((i as i64, c));
        }
    }
    out
}

fn col_span(n: &Value) -> i64 {
    // Mirror Python `int(c.get("col") or 1)`: 0 / null both become 1.
    let raw = n
        .get("col")
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
        .unwrap_or(0);
    if raw != 0 {
        raw
    } else {
        1
    }
}

fn leaf_size(n: &Value, avail_w: i64) -> (i64, i64, bool) {
    let t = node_type(n);
    let st = style(n);
    let h = resolve_dim(st.get("height").unwrap_or(&Value::Null), 0)
        .unwrap_or_else(|| kind_height(t));
    let fill = is_fill(t);
    let mut w = if fill {
        if avail_w > 0 {
            avail_w
        } else {
            kind_fallback_w(t)
        }
    } else {
        match t {
            "text" => text_w(n.get("content").and_then(|v| v.as_str()).unwrap_or("")),
            "button" => text_w(n.get("label").and_then(|v| v.as_str()).unwrap_or("")) + 16,
            "checkbox" | "toggle" => {
                16 + 4 + text_w(n.get("label").and_then(|v| v.as_str()).unwrap_or(""))
            }
            "color_swatch" => 16,
            "icon_button" => 24,
            "icon" => 20,
            _ => 0,
        }
    };
    if let Some(x) = resolve_dim(st.get("width").unwrap_or(&Value::Null), avail_w) {
        w = x;
    }
    if let Some(m) = resolve_dim(st.get("min_width").unwrap_or(&Value::Null), avail_w) {
        w = w.max(m);
    }
    (w, h, fill)
}

/// Returns (w, h, items) with item coords RELATIVE to this node's origin.
fn measure(n: &Value, path: &[i64], avail_w: i64) -> (i64, i64, Vec<MItem>) {
    let (pt, pr, pb, pl) = parse_padding(style(n).get("padding").unwrap_or(&Value::Null));
    let gap = style_i(n, "gap").unwrap_or(0);
    let inner_w = avail_w - pl - pr;

    if is_container(n) {
        let children = visible_children(n);
        let lay = resolved_layout(n);
        let (ch_items, content_h) = if lay == "row" && children.iter().any(|&(_, c)| has_col(c)) {
            grid(&children, path, inner_w, gap)
        } else if lay == "row" {
            flow(&children, path, inner_w, gap)
        } else {
            column(&children, path, inner_w, gap)
        };
        let w = avail_w;
        let h = content_h + pt + pb;
        let mut items = vec![MItem { path: path.to_vec(), x: 0, y: 0, w, h }];
        for mut it in ch_items {
            it.x += pl;
            it.y += pt;
            items.push(it);
        }
        (w, h, items)
    } else {
        let (w, h, _fill) = leaf_size(n, avail_w);
        (w, h, vec![MItem { path: path.to_vec(), x: 0, y: 0, w, h }])
    }
}

fn column(children: &[(i64, &Value)], path: &[i64], inner_w: i64, gap: i64) -> (Vec<MItem>, i64) {
    let mut items = vec![];
    let mut cy = 0;
    let mut n = 0;
    for &(i, c) in children {
        let mut cp = path.to_vec();
        cp.push(i);
        let (_cw, ch, mut cit) = measure(c, &cp, inner_w);
        for it in cit.iter_mut() {
            it.y += cy;
        }
        items.append(&mut cit);
        cy += ch + gap;
        n += 1;
    }
    (items, if n > 0 { cy - gap } else { 0 })
}

fn flow(children: &[(i64, &Value)], path: &[i64], inner_w: i64, gap: i64) -> (Vec<MItem>, i64) {
    let mut measured: Vec<(&Value, i64, i64, Vec<MItem>)> = vec![];
    for &(i, c) in children {
        let mut cp = path.to_vec();
        cp.push(i);
        let (cw, ch, cit) = measure(c, &cp, -1);
        measured.push((c, cw, ch, cit));
    }
    let n = measured.len();
    let fixed: i64 =
        measured.iter().map(|m| m.1).sum::<i64>() + if n > 0 { gap * (n as i64 - 1) } else { 0 };
    let leftover = (inner_w - fixed).max(0);
    let weights: Vec<i64> = measured
        .iter()
        .map(|m| {
            let wt = style_i(m.0, "flex").unwrap_or(0);
            if wt == 0 && node_type(m.0) == "spacer" {
                1
            } else {
                wt
            }
        })
        .collect();
    let sumw: i64 = weights.iter().sum();
    let mut extra = vec![0i64; n];
    if sumw > 0 && leftover > 0 {
        let mut base: Vec<i64> = (0..n).map(|k| leftover * weights[k] / sumw).collect();
        let mut rem = leftover - base.iter().sum::<i64>();
        for k in 0..n {
            if rem <= 0 {
                break;
            }
            if weights[k] > 0 {
                base[k] += 1;
                rem -= 1;
            }
        }
        extra = base;
    }
    let row_h = measured.iter().map(|m| m.2).max().unwrap_or(0);
    let mut items = vec![];
    let mut cx = 0;
    for (k, (_c, cw, ch, mut cit)) in measured.into_iter().enumerate() {
        let fw = cw + extra[k];
        let dy = (row_h - ch) / 2;
        for it in cit.iter_mut() {
            it.x += cx;
            it.y += dy;
        }
        if extra[k] != 0 && !cit.is_empty() {
            cit[0].w = fw;
        }
        items.append(&mut cit);
        cx += fw + gap;
    }
    (items, row_h)
}

fn grid(children: &[(i64, &Value)], path: &[i64], inner_w: i64, gap: i64) -> (Vec<MItem>, i64) {
    // Wrap into lines so each line's column span sums to <= 12.
    let mut lines: Vec<Vec<(i64, &Value, i64)>> = vec![];
    let mut cur: Vec<(i64, &Value, i64)> = vec![];
    let mut cur_span = 0i64;
    for &(i, c) in children {
        let span = col_span(c);
        if !cur.is_empty() && cur_span + span > 12 {
            lines.push(std::mem::take(&mut cur));
            cur_span = 0;
        }
        cur.push((i, c, span));
        cur_span += span;
    }
    if !cur.is_empty() {
        lines.push(cur);
    }

    let mut items = vec![];
    let mut line_y = 0;
    for line in &lines {
        let mut cx = 0;
        let mut line_h = 0;
        let mut cells: Vec<(Vec<MItem>, i64, i64)> = vec![];
        for &(i, c, span) in line {
            let cell_w = (2 * inner_w * span + 12) / 24; // round-half-up, exact
            let mut cp = path.to_vec();
            cp.push(i);
            let (_cw, ch, cit) = measure(c, &cp, cell_w);
            cells.push((cit, ch, cx));
            if ch > line_h {
                line_h = ch;
            }
            cx += cell_w + gap;
        }
        for (mut cit, ch, cell_x) in cells {
            let dy = (line_h - ch) / 2;
            for it in cit.iter_mut() {
                it.x += cell_x;
                it.y += line_y + dy;
            }
            items.append(&mut cit);
        }
        line_y += line_h + gap;
    }
    (items, if !lines.is_empty() { line_y - gap } else { 0 })
}
