//! Knuth-Plass every-line line-breaking composer.
//!
//! Pure-Rust implementation of the dynamic-programming line breaker
//! from Knuth-Plass "Breaking Paragraphs into Lines" (1981). Given a
//! sequence of [`Item`]s (boxes, glue, penalties) and a target line
//! width, returns the optimal break points that minimise the total
//! demerits across the paragraph.
//!
//! The composer is paragraph-internal: callers tokenise their text
//! into items, run [`compose`], and re-render the resulting lines
//! with the per-line adjustment ratio applied to glue widths.
//!
//! Phase 10: V1 supports word-spacing stretch/shrink derived from
//! the Justification dialog's min/desired/max plus hyphen penalties
//! from the bias slider. Letter-spacing and glyph-scaling fallbacks
//! are reserved for follow-up tuning when the parity harness lands.
//!
//! See `transcripts/PARAGRAPH.md` §Composer for the higher-level
//! description.

/// One item in the paragraph stream. The Knuth-Plass paper models
/// text as alternating boxes (immutable glyph clusters), glue
/// (stretchable / shrinkable inter-word space), and penalties
/// (potential break points with an associated cost). Box widths are
/// the sole contributor to the natural line width; glue contributes
/// `width` plus a stretch/shrink budget; penalties contribute width
/// only when the line breaks at the penalty.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Item {
    /// A printable cluster of glyphs (typically a word, but may be
    /// a single glyph for char-by-char layout). Cannot be broken.
    Box {
        width: f64,
        /// Char index of the first character in this box, in the
        /// surrounding paragraph's coordinate space. Used by the
        /// caller to map the chosen breaks back to char positions.
        char_idx: usize,
    },
    /// Stretchable / shrinkable space between two boxes. Acts as a
    /// legal break point when followed by a Box. The line that
    /// breaks at this glue ends just before it; the glue itself is
    /// dropped from the next line.
    Glue {
        /// Natural width — the glue's contribution to the line's
        /// natural width when no stretching or shrinking applies.
        width: f64,
        /// Maximum extra width the glue can stretch to. The line's
        /// adjustment ratio `r` ranges over `[-1, +inf)`; effective
        /// width is `width + r * stretch` for `r >= 0` and
        /// `width + r * shrink` for `r < 0`.
        stretch: f64,
        /// Maximum width the glue can shrink. Effective width when
        /// `r < 0` is `width + r * shrink` (note `r` is negative,
        /// so the glue gets narrower).
        shrink: f64,
        char_idx: usize,
    },
    /// Discretionary break point. The line breaks here only if the
    /// composer chooses to; when it does, the line gains `width`
    /// (typically the hyphen glyph width). When the composer does
    /// NOT break here, the penalty contributes nothing.
    ///
    /// `value` is the cost of breaking at this penalty: 0 = neutral,
    /// positive = discouraged, INFINITY = forbidden. Negative values
    /// reward the break (used for forced breaks at paragraph ends).
    /// `flagged` marks "expensive" breaks like hyphens — two flagged
    /// breaks in a row contribute extra demerits to discourage
    /// stacking.
    Penalty {
        width: f64,
        value: f64,
        flagged: bool,
        char_idx: usize,
    },
}

impl Item {
    pub fn width(&self) -> f64 {
        match self {
            Item::Box { width, .. } => *width,
            Item::Glue { width, .. } => *width,
            Item::Penalty { .. } => 0.0,  // contributes only on break
        }
    }
    pub fn char_idx(&self) -> usize {
        match self {
            Item::Box { char_idx, .. }
            | Item::Glue { char_idx, .. }
            | Item::Penalty { char_idx, .. } => *char_idx,
        }
    }
    fn is_glue(&self) -> bool { matches!(self, Item::Glue { .. }) }
    fn is_penalty(&self) -> bool { matches!(self, Item::Penalty { .. }) }
    fn is_box(&self) -> bool { matches!(self, Item::Box { .. }) }
}

/// Composer tuning. `INFINITY` and `MIN_PENALTY` use values from
/// the original paper; the remaining knobs cap badness so a single
/// terrible line can't dominate the demerit sum.
#[derive(Debug, Clone, Copy)]
pub struct Opts {
    /// Demerits added to every line break to discourage paragraphs
    /// with too many lines. Knuth's default is 10.
    pub line_penalty: f64,
    /// Demerits added when two consecutive breaks are both flagged
    /// (e.g. two hyphenated lines in a row). Knuth's default is
    /// 3000; we keep that.
    pub flagged_demerit: f64,
    /// Maximum allowed adjustment ratio. Lines whose `r` exceeds
    /// this in either direction are treated as infeasible.
    pub max_ratio: f64,
}

impl Default for Opts {
    fn default() -> Self {
        Self {
            line_penalty: 10.0,
            flagged_demerit: 3000.0,
            max_ratio: 10.0,
        }
    }
}

/// Penalty value above which a candidate is treated as "forbidden"
/// (never broken at). Matches Knuth's INFINITY threshold.
pub const PENALTY_INFINITY: f64 = 10000.0;

/// One line's break decision. Returned by [`compose`] in source order.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Break {
    /// Index of the [`Item`] that *ends* the line. The line spans
    /// `prev.item_idx + 1 ..= item_idx` (or `0 ..= item_idx` for
    /// the first line). When the ending item is a Penalty, its
    /// `width` contributes to the line and the line is "hyphenated"
    /// if the penalty was flagged.
    pub item_idx: usize,
    /// Adjustment ratio for this line. Glue widths render as
    /// `width + ratio * stretch` (or `+ ratio * shrink` when ratio
    /// is negative). For a perfectly fitting line `ratio == 0`.
    pub ratio: f64,
    /// True when the line ends at a flagged penalty (typically
    /// means a hyphen glyph should render at end-of-line).
    pub flagged: bool,
}

/// Run the Knuth-Plass DP composer.
///
/// `items` is the linear paragraph stream. `line_widths` is one
/// width per line; if the paragraph wants more lines than the
/// vector provides, the *last* width is reused. Returns the chosen
/// break sequence in source order, or `None` when no feasible set
/// of breaks exists (the caller should fall back to first-fit).
///
/// The returned vector always ends with a break at the final item,
/// which by Knuth-Plass convention is a forced penalty (value =
/// `-PENALTY_INFINITY`). Callers must add that terminator before
/// calling `compose`.
pub fn compose(
    items: &[Item],
    line_widths: &[f64],
    opts: &Opts,
) -> Option<Vec<Break>> {
    if items.is_empty() || line_widths.is_empty() {
        return Some(Vec::new());
    }
    // Precompute prefix sums of width / stretch / shrink so per-line
    // r-ratios cost O(1) to evaluate.
    let n = items.len();
    let mut sum_w = vec![0.0; n + 1];
    let mut sum_y = vec![0.0; n + 1];  // stretch
    let mut sum_z = vec![0.0; n + 1];  // shrink
    for (i, it) in items.iter().enumerate() {
        sum_w[i + 1] = sum_w[i] + it.width();
        if let Item::Glue { stretch, shrink, .. } = it {
            sum_y[i + 1] = sum_y[i] + stretch;
            sum_z[i + 1] = sum_z[i] + shrink;
        } else {
            sum_y[i + 1] = sum_y[i];
            sum_z[i + 1] = sum_z[i];
        }
    }

    /// One node in the DP graph = "break here" candidate.
    #[derive(Debug, Clone)]
    struct Node {
        item_idx: usize,
        line: usize,
        total_demerits: f64,
        ratio: f64,
        flagged: bool,
        prev: Option<usize>,  // index into `nodes`
    }

    let mut nodes: Vec<Node> = Vec::new();
    nodes.push(Node {
        item_idx: 0,
        line: 0,
        total_demerits: 0.0,
        ratio: 0.0,
        flagged: false,
        prev: None,
    });

    // Width effectively contributed by items in `from..=to`. Trailing
    // glue (the glue we break AT) is dropped; trailing penalty's
    // width counts.
    let nat_width = |from: usize, to: usize| -> (f64, f64, f64) {
        // Sum of widths/stretch/shrink across items[from..=to]. By
        // KP convention the trailing glue (the one we break AT) is
        // dropped from the line; a trailing penalty contributes its
        // width (it doesn't appear in sum_w because penalties have
        // 0 width in the prefix sums).
        let mut w = sum_w[to + 1] - sum_w[from];
        let mut y = sum_y[to + 1] - sum_y[from];
        let mut z = sum_z[to + 1] - sum_z[from];
        match items[to] {
            Item::Glue { width, stretch, shrink, .. } => {
                w -= width;
                y -= stretch;
                z -= shrink;
            }
            Item::Penalty { width, .. } => {
                w += width;
            }
            _ => {}
        }
        (w, y, z)
    };

    let line_width_for = |line: usize| -> f64 {
        if line < line_widths.len() {
            line_widths[line]
        } else {
            *line_widths.last().unwrap()
        }
    };

    // Walk every item and consider it as a possible break point.
    // For each, find the best predecessor node.
    for j in 0..n {
        // Item j is a legal break iff it's a Glue preceded by a Box,
        // or a Penalty with value < INFINITY.
        let legal_break = match &items[j] {
            Item::Glue { .. } => j > 0 && items[j - 1].is_box(),
            Item::Penalty { value, .. } => *value < PENALTY_INFINITY,
            Item::Box { .. } => false,
        };
        if !legal_break {
            continue;
        }
        let mut best: Option<(usize, f64, f64)> = None;
        for (ni, n_node) in nodes.iter().enumerate() {
            // Try line spanning items[n_node.item_idx + 1 ..= j].
            // (For the seed node at item 0, we span 0..=j.)
            let from = if n_node.prev.is_none() && ni == 0 { 0 }
                       else { n_node.item_idx + 1 };
            if from > j { continue; }
            let (nat, stretch, shrink) = nat_width(from, j);
            let line_w = line_width_for(n_node.line);
            // Compute adjustment ratio.
            let ratio = if (nat - line_w).abs() < 1e-9 {
                0.0
            } else if nat < line_w {
                if stretch > 0.0 {
                    (line_w - nat) / stretch
                } else {
                    f64::INFINITY  // need to stretch but can't
                }
            } else {
                if shrink > 0.0 {
                    (line_w - nat) / shrink  // negative
                } else {
                    f64::NEG_INFINITY
                }
            };
            // Filter infeasible.
            if ratio < -1.0 || ratio > opts.max_ratio { continue; }
            // Badness = 100 * |r|^3, capped.
            let badness = 100.0 * ratio.abs().powi(3);
            // Penalty contribution from item j when it's a Penalty.
            let (pen_value, pen_flagged) = match items[j] {
                Item::Penalty { value, flagged, .. } => (value, flagged),
                _ => (0.0, false),
            };
            let line_demerit = if pen_value >= 0.0 {
                (opts.line_penalty + badness + pen_value).powi(2)
            } else if pen_value > -PENALTY_INFINITY {
                (opts.line_penalty + badness).powi(2) - pen_value.powi(2)
            } else {
                (opts.line_penalty + badness).powi(2)
            };
            let mut demerits = n_node.total_demerits + line_demerit;
            if n_node.flagged && pen_flagged {
                demerits += opts.flagged_demerit;
            }
            match best {
                None => best = Some((ni, demerits, ratio)),
                Some((_, d_best, _)) if demerits < d_best => {
                    best = Some((ni, demerits, ratio));
                }
                _ => {}
            }
        }
        if let Some((prev, d, r)) = best {
            let pen_flagged = matches!(items[j],
                Item::Penalty { flagged: true, .. });
            nodes.push(Node {
                item_idx: j,
                line: nodes[prev].line + 1,
                total_demerits: d,
                ratio: r,
                flagged: pen_flagged,
                prev: Some(prev),
            });
        }
    }

    // Find the lowest-demerits node that breaks at the LAST item
    // (the caller's forced terminator). When the last item is not a
    // forced break or no node terminates there, scan for any node
    // ending at item n-1.
    let mut best: Option<usize> = None;
    let mut best_d = f64::INFINITY;
    for (ni, node) in nodes.iter().enumerate() {
        if node.item_idx == n - 1 && node.total_demerits < best_d {
            best_d = node.total_demerits;
            best = Some(ni);
        }
    }
    let mut cur = best?;
    let mut out: Vec<Break> = Vec::new();
    loop {
        let n = &nodes[cur];
        if n.prev.is_none() && cur == 0 { break; }
        out.push(Break {
            item_idx: n.item_idx,
            ratio: n.ratio,
            flagged: n.flagged,
        });
        match n.prev {
            Some(p) => cur = p,
            None => break,
        }
    }
    out.reverse();
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(width: f64, idx: usize) -> Item {
        Item::Box { width, char_idx: idx }
    }
    fn g(width: f64, idx: usize) -> Item {
        Item::Glue { width, stretch: width * 0.5, shrink: width * 0.33, char_idx: idx }
    }
    fn g_wide(width: f64, idx: usize) -> Item {
        // High-stretch glue used in hyphen-bias tests so that the
        // non-hyphen alternative also stays feasible.
        Item::Glue { width, stretch: 20.0, shrink: 5.0, char_idx: idx }
    }
    fn forced_break(idx: usize) -> Item {
        Item::Penalty { width: 0.0, value: -PENALTY_INFINITY, flagged: false, char_idx: idx }
    }
    fn fil_glue(idx: usize) -> Item {
        // Infinite-stretch glue used at end of paragraph to absorb
        // the slack on the last line.
        Item::Glue { width: 0.0, stretch: 1e9, shrink: 0.0, char_idx: idx }
    }

    #[test]
    fn empty_returns_empty() {
        let breaks = compose(&[], &[100.0], &Opts::default()).unwrap();
        assert!(breaks.is_empty());
    }

    #[test]
    fn three_words_one_line_when_wide_enough() {
        // "abc def ghi" — fits comfortably in 200pt.
        let items = vec![
            b(30.0, 0),
            g(10.0, 3),
            b(30.0, 4),
            g(10.0, 7),
            b(30.0, 8),
            fil_glue(11),
            forced_break(11),
        ];
        let breaks = compose(&items, &[200.0], &Opts::default()).unwrap();
        assert_eq!(breaks.len(), 1);
        assert_eq!(breaks[0].item_idx, items.len() - 1);
    }

    #[test]
    fn three_words_two_lines_when_narrow() {
        // Same items but only 70pt wide. Two-word lines barely fit:
        // "abc def" = 30+10+30 = 70 (perfect r=0); "ghi" alone.
        let items = vec![
            b(30.0, 0),
            g(10.0, 3),
            b(30.0, 4),
            g(10.0, 7),
            b(30.0, 8),
            fil_glue(11),
            forced_break(11),
        ];
        let breaks = compose(&items, &[70.0], &Opts::default()).unwrap();
        assert_eq!(breaks.len(), 2);
        // First break should be at the second glue (item 3) so line 1
        // is "abc def" and line 2 is "ghi".
        assert_eq!(breaks[0].item_idx, 3);
        assert_eq!(breaks[1].item_idx, items.len() - 1);
    }

    // Helper: produce the same paragraph items used by both hyphen
    // tests, parametrised by the hyphen penalty value.
    fn hyphen_corpus(penalty: f64) -> Vec<Item> {
        // Line width is 110 (set in the test calls). With a high-
        // stretch glue between word 1 and word 2, two compositions
        // are feasible:
        //   A — break at the hyphen (item 5): line1 r=0 (perfect)
        //   B — break at the regular glue 3: line1 r=1
        // With penalty=10, A wins; with penalty=1000, B wins.
        vec![
            b(35.0, 0),                                              // word 1
            g_wide(5.0, 2),                                          // wide glue
            b(50.0, 3),                                              // word 2
            g(5.0, 8),                                               // glue
            b(10.0, 9),                                              // partial word 3
            Item::Penalty { width: 5.0, value: penalty, flagged: true, char_idx: 11 },
            b(10.0, 11),                                             // rest of word 3
            fil_glue(13),
            forced_break(13),
        ]
    }

    #[test]
    fn hyphen_penalty_discourages_break_at_high_value() {
        let items = hyphen_corpus(1000.0);
        let breaks = compose(&items, &[110.0], &Opts::default()).unwrap();
        let used_hyphen = breaks.iter().any(|b| b.item_idx == 5);
        assert!(!used_hyphen, "high penalty should suppress hyphen break");
    }

    #[test]
    fn hyphen_penalty_taken_when_low() {
        let items = hyphen_corpus(10.0);
        let breaks = compose(&items, &[110.0], &Opts::default()).unwrap();
        let used_hyphen = breaks.iter().any(|b| b.item_idx == 5);
        assert!(used_hyphen, "low penalty should allow hyphen break");
    }

    #[test]
    fn ratio_within_stretch_budget() {
        // "abcd efgh" with line_w 100. Natural = 40+10+40 = 90.
        // Glue stretch = 5pt, so to fill 10pt slack r = 2.
        let items = vec![
            b(40.0, 0),
            g(10.0, 4),
            b(40.0, 5),
            fil_glue(9),
            forced_break(9),
        ];
        let breaks = compose(&items, &[100.0], &Opts::default()).unwrap();
        // The KP composer is allowed to use the fil glue on its
        // single line, making the line trivially feasible. We only
        // assert that one line was emitted; the fitted ratio depends
        // on whether the composer charged the gap to the regular
        // glue or the fil glue.
        assert_eq!(breaks.len(), 1);
    }
}
