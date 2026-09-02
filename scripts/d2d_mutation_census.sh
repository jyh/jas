#!/usr/bin/env bash
# ⭐ ROW EG(2) — THE DIRECT2D HALF OF THE "NO PIXEL CAN FAIL" CENSUS.
#
# jas ran the identical pass on `painter/canvas2d.rs` on 2026-09-01 and
# published the result on the bus: **24 mutants driven through the whole lane,
# 19 SURVIVED.** It offered the Direct2D half to this lane, unclaimed. This is
# that half, on the same 24 categories.
#
# ⛔ THREE PROPERTIES THIS HARNESS HAS, EACH BOUGHT WITH A MISTAKE OF MINE:
#
# 1. **It refuses a verdict when the mutation did not apply.** A `SITE NOT
#    UNIQUE` or a no-op edit prints `[NOT APPLIED]` and reports nothing. Without
#    this a naive harness reports a confident SURVIVED about UNMUTATED code --
#    it happened to me twice in one day.
#
# 2. **It reads a POSITIVE signal** (`test result: ok. N passed`), never the
#    absence of `failures:`. A compile error is not a surviving mutant; it is a
#    compile error, and it is reported as `BUILD-ERROR`, not as a verdict.
#    (2026-08-31, re-broken 2026-09-02.)
#
# 3. **It runs the WHOLE native suite, with no test filter.** On 2026-09-02 I
#    ran a census under a filter that did not match the arms written to kill two
#    of the mutants, and it duly reported SURVIVED about tests it never ran. A
#    filter is an assumption about which test kills a mutant, and the assumption
#    is exactly what a census is trying not to make.
#
# Usage:  bash scripts/d2d_mutation_census.sh [N]     # N = run only mutant N
set -u
cd "$(dirname "$0")/.." || exit 1

P=jas_dioxus/src/painter/direct2d/painter.rs
C=jas_dioxus/src/painter/direct2d/convert.rs
G=jas_dioxus/src/painter/direct2d/geometry.rs

ONLY="${1:-}"
n=0
killed=0
survived=0
declare -a SURVIVORS=()

verdict() {
  out=$(cd jas_dioxus && cargo test --no-default-features --features d2d,ffi 2>&1)
  if echo "$out" | grep -qE "^error(\[|: could not compile)"; then
    echo "BUILD-ERROR (not a verdict)"; return 2
  fi
  if echo "$out" | grep -qE "test result: FAILED"; then echo "KILLED"; return 0; fi
  local p
  p=$(echo "$out" | grep -oE "test result: ok\. [0-9]+ passed" | awk '{s+=$4} END {print s}')
  if [ "${p:-0}" -gt 0 ]; then echo "SURVIVED (${p} passed)"; return 1; fi
  echo "NO SIGNAL"; return 2
}

mut() { # $1 label  $2 file  $3 old  $4 new
  n=$((n+1))
  if [ -n "$ONLY" ] && [ "$ONLY" != "$n" ]; then return; fi
  cp "$2" /tmp/census_orig.rs
  python - "$2" "$3" "$4" <<'PY' 2>/tmp/census_err
import io,sys
p,o,new=sys.argv[1],sys.argv[2],sys.argv[3]
s=io.open(p,encoding='utf-8').read()
c=s.count(o)
assert c==1, "SITE NOT UNIQUE (%d matches)"%c
io.open(p,'w',encoding='utf-8',newline='\n').write(s.replace(o,new))
PY
  if cmp -s "$2" /tmp/census_orig.rs; then
    printf '%2d  %-34s [NOT APPLIED] %s\n' "$n" "$1" "$(head -1 /tmp/census_err | tail -c 60)"
    cp /tmp/census_orig.rs "$2"; return
  fi
  v=$(verdict); rc=$?
  printf '%2d  %-34s %s\n' "$n" "$1" "$v"
  case $rc in
    0) killed=$((killed+1));;
    1) survived=$((survived+1)); SURVIVORS+=("$n $1");;
  esac
  cp /tmp/census_orig.rs "$2"
}

echo "=== BASELINE (must be ok, or every verdict below is meaningless) ==="
verdict
echo
echo "=== 24 MUTANTS on the Direct2D backend ==="

# -- both gradient forms (jas: both survived on canvas2d) ---------------------
mut "G1 linear gradient ends swapped" "$P" \
  'startPoint: windows_numerics::Vector2 { X: g.x0 as f32, Y: g.y0 as f32 },
                    endPoint: windows_numerics::Vector2 { X: g.x1 as f32, Y: g.y1 as f32 },' \
  'startPoint: windows_numerics::Vector2 { X: g.x1 as f32, Y: g.y1 as f32 },
                    endPoint: windows_numerics::Vector2 { X: g.x0 as f32, Y: g.y0 as f32 },'
mut "G2 linear start X takes Y" "$P" \
  'startPoint: windows_numerics::Vector2 { X: g.x0 as f32, Y: g.y0 as f32 },' \
  'startPoint: windows_numerics::Vector2 { X: g.y0 as f32, Y: g.y0 as f32 },'
mut "G3 radial radius r1 -> r0" "$P" \
  'radiusX: g.r1 as f32,
                    radiusY: g.r1 as f32,' \
  'radiusX: g.r0 as f32,
                    radiusY: g.r0 as f32,'
mut "G4 radial origin offset zeroed" "$P" \
  'X: (g.x0 - g.x1) as f32, Y: (g.y0 - g.y1) as f32,' \
  'X: 0.0, Y: 0.0,'
mut "G5 gradient stop alpha ignored" "$P" \
  'color: D2D1_COLOR_F { r: r as f32, g: g as f32, b: b as f32, a: (a * alpha) as f32 },' \
  'color: D2D1_COLOR_F { r: r as f32, g: g as f32, b: b as f32, a: a as f32 },'
mut "G6 gradient gamma 2.2 -> 1.0" "$P" \
  'D2D1_GAMMA_2_2, D2D1_EXTEND_MODE_CLAMP' \
  'windows::Win32::Graphics::Direct2D::D2D1_GAMMA_1_0, D2D1_EXTEND_MODE_CLAMP'

# -- stroke width ------------------------------------------------------------
mut "S1 stroke style width -> 1.0" "$P" \
  'let dashes = convert::dash_multiples(&s.dash, emit_width);' \
  'let dashes = convert::dash_multiples(&s.dash, 1.0);'

# -- dash --------------------------------------------------------------------
mut "D1 dash not divided by width" "$C" \
  'dash.iter().map(|d| (d / divisor) as f32).collect()' \
  'dash.iter().map(|d| { let _ = divisor; *d as f32 }).collect()'
mut "D2 dash style always SOLID" "$C" \
  'dashStyle: if style.dash.is_empty() {
            D2D1_DASH_STYLE_SOLID
        } else {
            D2D1_DASH_STYLE_CUSTOM
        },' \
  'dashStyle: D2D1_DASH_STYLE_SOLID,'

# -- line cap ----------------------------------------------------------------
mut "C1 dashCap forced FLAT" "$C" \
  'dashCap: cap,' \
  'dashCap: D2D1_CAP_STYLE_FLAT,'
mut "C2 endCap forced FLAT" "$C" \
  'endCap: cap,' \
  'endCap: D2D1_CAP_STYLE_FLAT,'

# -- line join / miter -------------------------------------------------------
mut "J1 lineJoin forced MITER_OR_BEVEL" "$C" \
  'lineJoin: line_join(style.join),' \
  'lineJoin: D2D1_LINE_JOIN_MITER_OR_BEVEL,'
mut "J2 miter limit hardcoded 10" "$C" \
  'miterLimit: style.miter as f32,' \
  'miterLimit: 10.0,'

# -- winding rule (A3) -------------------------------------------------------
mut "W1 fill mode always NONZERO" "$G" \
  'sink.SetFillMode(convert::fill_mode(winding));' \
  'sink.SetFillMode(convert::fill_mode(crate::painter::FillRule::NonZero));'

# -- quadratic construction --------------------------------------------------
mut "Q1 first quad ctrl = endpoint" "$G" \
  '                    sink.AddQuadraticBezier(&D2D1_QUADRATIC_BEZIER_SEGMENT {
                        point1: v(x1, y1),' \
  '                    sink.AddQuadraticBezier(&D2D1_QUADRATIC_BEZIER_SEGMENT {
                        point1: v(x, y),'

# -- close path --------------------------------------------------------------
mut "P1 ClosePath ends figure OPEN" "$G" \
  'sink.EndFigure(D2D1_FIGURE_END_CLOSED);' \
  'sink.EndFigure(D2D1_FIGURE_END_OPEN);'

# -- open-group alpha product ------------------------------------------------
mut "A1 group alphas: product -> last" "$P" \
  'let p: f64 = self.group_alphas.iter().product::<f64>() * paint_alpha;' \
  'let p: f64 = self.group_alphas.last().copied().unwrap_or(1.0) * paint_alpha;'
mut "A2 paint_alpha dropped" "$P" \
  'let p: f64 = self.group_alphas.iter().product::<f64>() * paint_alpha;' \
  'let p: f64 = self.group_alphas.iter().product::<f64>();'

# -- group blend -------------------------------------------------------------
mut "B1 Multiply -> Screen" "$P" \
  'BlendMode::Multiply => D2D1_BLEND_MODE_MULTIPLY,' \
  'BlendMode::Multiply => D2D1_BLEND_MODE_SCREEN,'
mut "B2 Darken -> Lighten" "$P" \
  'BlendMode::Darken => D2D1_BLEND_MODE_DARKEN,' \
  'BlendMode::Darken => D2D1_BLEND_MODE_LIGHTEN,'
mut "B3 group blend never active" "$P" \
  'Some(b) if *b != BlendMode::Normal => Some(*b),' \
  'Some(b) if false && *b != BlendMode::Normal => Some(*b),'
mut "B4 ColorBurn -> ColorDodge" "$P" \
  'BlendMode::ColorBurn => D2D1_BLEND_MODE_COLOR_BURN,' \
  'BlendMode::ColorBurn => D2D1_BLEND_MODE_COLOR_DODGE,'

# -- translucent colour form -------------------------------------------------
mut "T1 colour alpha REPLACED not mult" "$P" \
  '            a: (a * alpha) as f32,' \
  '            a: alpha as f32,'
mut "T2 colour keeps own alpha only" "$P" \
  '            a: (a * alpha) as f32,' \
  '            a: a as f32,'
mut "T3 effective alpha unclamped" "$P" \
  'p.clamp(0.0, 1.0)' \
  'p'

echo
echo "=== CENSUS RESULT: $killed killed, $survived survived, of $n applied ==="
for s in "${SURVIVORS[@]:-}"; do [ -n "$s" ] && echo "  SURVIVED: $s"; done
