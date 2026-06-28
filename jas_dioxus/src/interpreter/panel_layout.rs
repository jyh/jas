//! Shared canonical panel widget-layout pass (Path B).
//!
//! Rust port of `workspace_interpreter/panel_layout.py`.  A pure,
//! integer-arithmetic layout of a compiled panel node into widget rects,
//! byte-identical across all five apps.  The full contract is
//! PATH_B_DESIGN.md (Appendix A + Appendix B for foreach).
//!
//! All arithmetic is integer (no float anywhere), so the four native
//! implementations are byte-identical and the corpus
//! (`test_fixtures/algorithms/panel_layout.json`) needs no tolerance.  Text
//! `content` / `label` is first resolved through `eval_text` against the data
//! scope `ctx` (a bound `"{{sym.name}}"` is measured at its resolved value; a
//! literal passes through unchanged), then measured with the deterministic
//! stub `codepoint_count(text) * CHAR_WIDTH` (CHAR_WIDTH = 10).  Columns use
//! the Bootstrap-12 rule `cell_w = (2*inner_w*N + 12) / 24` (round-half-up,
//! exact).  `foreach` containers expand their `do` template once per item of
//! `eval(foreach.source, ctx)`; a column distributes `avail_h` leftover to
//! `flex`-weighted children (vertical flex).

use serde_json::{json, Map, Value};

use super::expr::{eval, eval_text};
use super::expr_types::Value as EVal;

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
///
/// `ctx` is the data scope used to evaluate `foreach` sources and text
/// bindings (defaults to empty/literals-only at call sites that pass `{}`).
/// `avail_h` drives vertical flex; 0 means content-height (no vertical flex).
pub fn layout_panel(panel_node: &Value, avail_w: i64, avail_h: i64, ctx: &Value) -> Value {
    let root = match panel_node.get("content") {
        Some(r) if r.is_object() => r,
        _ => return json!([]),
    };
    let (_w, _h, items) = measure(root, &[], avail_w, avail_h, ctx);
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

/// Resolved text width: `eval_text(node[key], ctx)` codepoint count * CHAR_WIDTH.
/// A non-string (or missing) value measures as 0; a literal (no `{{`) passes
/// through `eval_text` unchanged, so non-bound panels stay byte-identical.
fn text_w(n: &Value, key: &str, ctx: &Value) -> i64 {
    match n.get(key).and_then(|v| v.as_str()) {
        Some(raw) => eval_text(raw, ctx).chars().count() as i64 * CHAR_WIDTH,
        None => 0,
    }
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

/// Vertical/horizontal flex weight: `style.flex` (int), with an implicit
/// weight of 1 for a `spacer` that declares no explicit flex.
fn flex(n: &Value) -> i64 {
    let w = style_i(n, "flex").unwrap_or(0);
    if w == 0 && node_type(n) == "spacer" {
        1
    } else {
        w
    }
}

fn leaf_size(n: &Value, avail_w: i64, ctx: &Value) -> (i64, i64) {
    let t = node_type(n);
    let st = style(n);
    let h = resolve_dim(st.get("height").unwrap_or(&Value::Null), 0)
        .unwrap_or_else(|| kind_height(t));
    let mut w = if is_fill(t) {
        if avail_w > 0 {
            avail_w
        } else {
            kind_fallback_w(t)
        }
    } else {
        match t {
            "text" => text_w(n, "content", ctx),
            "button" => text_w(n, "label", ctx) + 16,
            "checkbox" | "toggle" => 16 + 4 + text_w(n, "label", ctx),
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
    (w, h)
}

/// Returns (w, h, items) with item coords RELATIVE to this node's origin.
fn measure(
    n: &Value,
    path: &[i64],
    avail_w: i64,
    avail_h: i64,
    ctx: &Value,
) -> (i64, i64, Vec<MItem>) {
    let st = style(n);
    let (pt, pr, pb, pl) = parse_padding(st.get("padding").unwrap_or(&Value::Null));
    let gap = style_i(n, "gap").unwrap_or(0);
    let inner_w = avail_w - pl - pr;
    let inner_h = if avail_h > 0 { avail_h - pt - pb } else { 0 };

    if is_container(n) {
        let has_foreach = st_foreach(n).is_some() && n.get("do").map_or(false, |v| !v.is_null());
        let (ch_items, content_h) = if has_foreach {
            foreach(n, path, inner_w, gap, ctx)
        } else {
            let children = visible_children(n);
            let lay = resolved_layout(n);
            if lay == "row" && children.iter().any(|&(_, c)| has_col(c)) {
                grid(&children, path, inner_w, gap, ctx)
            } else if lay == "row" {
                flow(&children, path, inner_w, gap, ctx)
            } else {
                column(&children, path, inner_w, gap, inner_h, ctx)
            }
        };
        let exp_h = resolve_dim(st.get("height").unwrap_or(&Value::Null), 0);
        let w = avail_w;
        let h = exp_h.unwrap_or(content_h + pt + pb);
        let mut items = vec![MItem { path: path.to_vec(), x: 0, y: 0, w, h }];
        for mut it in ch_items {
            it.x += pl;
            it.y += pt;
            items.push(it);
        }
        (w, h, items)
    } else {
        let (w, h) = leaf_size(n, avail_w, ctx);
        (w, h, vec![MItem { path: path.to_vec(), x: 0, y: 0, w, h }])
    }
}

/// The `foreach` spec object on a container, if present.
fn st_foreach(n: &Value) -> Option<&Value> {
    n.get("foreach").filter(|v| v.is_object())
}

fn column(
    children: &[(i64, &Value)],
    path: &[i64],
    inner_w: i64,
    gap: i64,
    avail_h: i64,
    ctx: &Value,
) -> (Vec<MItem>, i64) {
    // Measure each child at its natural height (avail_h = 0).
    let mut measured: Vec<(&Value, i64, Vec<MItem>)> = vec![];
    for &(i, c) in children {
        let mut cp = path.to_vec();
        cp.push(i);
        let (_cw, ch, cit) = measure(c, &cp, inner_w, 0, ctx);
        measured.push((c, ch, cit));
    }
    let n = measured.len();
    let natural: i64 =
        measured.iter().map(|m| m.1).sum::<i64>() + if n > 0 { gap * (n as i64 - 1) } else { 0 };
    let mut extra = vec![0i64; n];
    if avail_h > 0 {
        let leftover = avail_h - natural;
        if leftover > 0 {
            let weights: Vec<i64> = measured.iter().map(|m| flex(m.0)).collect();
            let sumw: i64 = weights.iter().sum();
            if sumw > 0 {
                let mut base: Vec<i64> =
                    (0..n).map(|k| leftover * weights[k] / sumw).collect();
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
        }
    }
    let mut items = vec![];
    let mut cy = 0;
    for (k, (_c, ch, mut cit)) in measured.into_iter().enumerate() {
        let hk = ch + extra[k];
        for it in cit.iter_mut() {
            it.y += cy;
        }
        if extra[k] != 0 && !cit.is_empty() {
            cit[0].h = hk;
        }
        items.append(&mut cit);
        cy += hk + gap;
    }
    (items, if n > 0 { cy - gap } else { 0 })
}

fn flow(
    children: &[(i64, &Value)],
    path: &[i64],
    inner_w: i64,
    gap: i64,
    ctx: &Value,
) -> (Vec<MItem>, i64) {
    let mut measured: Vec<(&Value, i64, i64, Vec<MItem>)> = vec![];
    for &(i, c) in children {
        let mut cp = path.to_vec();
        cp.push(i);
        let (cw, ch, cit) = measure(c, &cp, -1, 0, ctx);
        measured.push((c, cw, ch, cit));
    }
    let n = measured.len();
    let fixed: i64 =
        measured.iter().map(|m| m.1).sum::<i64>() + if n > 0 { gap * (n as i64 - 1) } else { 0 };
    let leftover = (inner_w - fixed).max(0);
    let weights: Vec<i64> = measured.iter().map(|m| flex(m.0)).collect();
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

fn grid(
    children: &[(i64, &Value)],
    path: &[i64],
    inner_w: i64,
    gap: i64,
    ctx: &Value,
) -> (Vec<MItem>, i64) {
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
            let (_cw, ch, cit) = measure(c, &cp, cell_w, 0, ctx);
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

/// Expand a foreach container's `do` template once per item of
/// `eval(foreach.source, ctx)`, laid out per the container's `layout`:
/// `column` (vertical stack, default), `row` (horizontal, single line), or
/// `wrap` (horizontal, wrapping at `inner_w`). Each item is bound as
/// `foreach.as` (plus `_index`) in a child scope.
///
/// Row/wrap items are measured at intrinsic width (avail = -1); `item_w` is the
/// subtree's actual extent (max of rect.x + rect.w over the item's produced
/// rects), and the item's own (root) rect width is corrected to that extent so
/// a container item carries its content width, not the unbounded sentinel.
fn foreach(
    n: &Value,
    path: &[i64],
    inner_w: i64,
    gap: i64,
    ctx: &Value,
) -> (Vec<MItem>, i64) {
    let spec = st_foreach(n).cloned().unwrap_or(Value::Null);
    let src = spec.get("source").and_then(|v| v.as_str()).unwrap_or("");
    let var = spec.get("as").and_then(|v| v.as_str()).unwrap_or("item");
    let template = n.get("do").cloned().unwrap_or(Value::Null);
    // Dispatch on the raw `layout` field (not resolved_layout): default column.
    let lay = n.get("layout").and_then(|v| v.as_str()).unwrap_or("column");

    let items: Vec<Value> = match eval(src, ctx) {
        EVal::List(v) => v,
        _ => vec![],
    };

    let base_obj: Map<String, Value> = ctx.as_object().cloned().unwrap_or_default();

    // Measure every expansion (column fills inner_w; row/wrap are intrinsic).
    let avail = if lay == "column" { inner_w } else { -1 };
    let mut measured: Vec<(i64, i64, Vec<MItem>)> = vec![]; // (item_w, item_h, items)
    for (i, item) in items.into_iter().enumerate() {
        let mut item_data: Map<String, Value> = match item {
            Value::Object(m) => m,
            other => {
                let mut m = Map::new();
                m.insert("_value".to_string(), other);
                m
            }
        };
        item_data.insert("_index".to_string(), json!(i));
        let mut child = base_obj.clone();
        child.insert(var.to_string(), Value::Object(item_data));
        let child_ctx = Value::Object(child);

        let mut cp = path.to_vec();
        cp.push(i as i64);
        let (mut w, h, mut cit) = measure(&template, &cp, avail, 0, &child_ctx);
        if lay != "column" {
            let iw = cit.iter().map(|it| it.x + it.w).max().unwrap_or(0);
            if !cit.is_empty() {
                cit[0].w = iw;
            }
            w = iw;
        }
        measured.push((w, h, cit));
    }

    let mut out: Vec<MItem> = vec![];
    if lay == "row" {
        let row_h = measured.iter().map(|m| m.1).max().unwrap_or(0);
        let mut cx = 0;
        for (w, h, mut cit) in measured {
            let dy = (row_h - h) / 2;
            for it in cit.iter_mut() {
                it.x += cx;
                it.y += dy;
            }
            out.append(&mut cit);
            cx += w + gap;
        }
        return (out, row_h);
    }
    if lay == "wrap" {
        let mut cx = 0;
        let mut line_y = 0;
        let mut line_h = 0;
        let empty = measured.is_empty();
        for (w, h, mut cit) in measured {
            if cx > 0 && cx + w > inner_w {
                line_y += line_h + gap;
                cx = 0;
                line_h = 0;
            }
            for it in cit.iter_mut() {
                it.x += cx;
                it.y += line_y;
            }
            out.append(&mut cit);
            cx += w + gap;
            line_h = line_h.max(h);
        }
        return (out, if empty { 0 } else { line_y + line_h });
    }
    // column
    let mut cy = 0;
    let empty = measured.is_empty();
    for (_w, h, mut cit) in measured {
        for it in cit.iter_mut() {
            it.y += cy;
        }
        out.append(&mut cit);
        cy += h + gap;
    }
    (out, if empty { 0 } else { cy - gap })
}
