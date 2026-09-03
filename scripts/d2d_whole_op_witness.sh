#!/usr/bin/env bash
# ⭐ THE DIRECT2D WHOLE-OP WITNESS PASS — the symmetric counterpart of row EJ.
#
# jas ran this on Canvas2D (row EJ, closed 09/02): **delete a Painter method's
# entire body and see whether any pixel reds.** It found 4 of 7 ops with NO
# WITNESS. EJ closed the Canvas2D table. Nobody has run it on Direct2D.
#
# ⛔ IT ASKS A DIFFERENT QUESTION FROM THE MUTATION CENSUS, AND A BLUNTER ONE.
# `scripts/d2d_mutation_census.sh` perturbs VALUES inside a method — the wrong
# radius, the wrong blend, a dropped alpha. This asks whether the method needs to
# execute AT ALL. An op with no witness is not merely weakly tested: nothing in
# the suite would notice if it stopped drawing.
#
# The harness properties are the census's, for the same reasons:
#   1. it refuses a verdict when the edit did not apply;
#   2. it reads a POSITIVE signal, never the absence of failures;
#   3. it runs the WHOLE native suite with no filter.
#
# Usage:  bash scripts/d2d_whole_op_witness.sh [op-name]
set -u
cd "$(dirname "$0")/.." || exit 1
P=jas_dioxus/src/painter/direct2d/painter.rs
ONLY="${1:-}"

OPS="fill_rect stroke_rect push_state pop_state push_group pop_group fill_path
     stroke_path fill_ellipse_arc stroke_ellipse_arc clip draw_text_run
     push_mask_layer pop_mask_layer push_isolated_layer pop_isolated_layer"

verdict() {
  out=$(cd jas_dioxus && cargo test --no-default-features --features d2d,ffi 2>&1)
  if echo "$out" | grep -qE "^error(\[|: could not compile)"; then echo "BUILD-ERROR"; return 2; fi
  if echo "$out" | grep -qE "test result: FAILED"; then echo "WITNESSED"; return 0; fi
  local p
  p=$(echo "$out" | grep -oE "test result: ok\. [0-9]+ passed" | awk '{s+=$4} END {print s}')
  if [ "${p:-0}" -gt 0 ]; then echo "NO WITNESS (${p} passed)"; return 1; fi
  echo "NO SIGNAL"; return 2
}

witnessed=0; blind=0; BLIND=()
for op in $OPS; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$op" ] && continue
  cp "$P" /tmp/witness_orig.rs
  # Gut the body: an early `return` as the first statement, inside the impl
  # block only. Arguments stay bound, so nothing goes unused-warning noisy.
  python - "$P" "$op" <<'PY' 2>/tmp/witness_err
import io,re,sys
p,op=sys.argv[1],sys.argv[2]
s=io.open(p,encoding='utf-8').read()
i=s.index('impl<')
i=s.index("impl<'a> Painter for Direct2DPainter")
m=re.search(r"\n    fn %s\(" % re.escape(op), s[i:])
assert m, "op not found in the impl block"
start=i+m.start()
brace=s.index('{', s.index('(', start))
# the first '{' after the signature's closing ')'
depth=0; j=s.index(')', start)
brace=s.index('{', j)
io.open(p,'w',encoding='utf-8',newline='\n').write(
    s[:brace+1] + "\n        return; // WHOLE-OP WITNESS PROBE\n" + s[brace+1:])
PY
  if cmp -s "$P" /tmp/witness_orig.rs; then
    printf '  %-22s [NOT APPLIED] %s\n' "$op" "$(head -1 /tmp/witness_err | tail -c 50)"
    cp /tmp/witness_orig.rs "$P"; continue
  fi
  v=$(verdict); rc=$?
  printf '  %-22s %s\n' "$op" "$v"
  case $rc in 0) witnessed=$((witnessed+1));; 1) blind=$((blind+1)); BLIND+=("$op");; esac
  cp /tmp/witness_orig.rs "$P"
done

echo
echo "=== WITNESS RESULT: $witnessed witnessed, $blind with NO witness ==="
for b in "${BLIND[@]:-}"; do [ -n "$b" ] && echo "  NO WITNESS: $b"; done
