#!/usr/bin/env bash
# Compare the latest benchmark runs of baseline / bolt / bolt-rewrite.
#
# Usage: compare.sh <pie|no-pie>
#
# Uses the newest results/<mode>/<which>/<timestamp>/summary.tsv of each
# variant, prints mean metrics per workload plus the percentage delta over
# baseline and the geomean improvement. The set of metrics is discovered from
# the results, so apps that report different metrics (e.g. no QPS) still work;
# known metrics are printed first, the rest alphabetically.
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_ROOT/lib/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "usage: compare.sh <pie|no-pie>"
  exit 0
fi
[ $# -eq 1 ] || { echo "usage: compare.sh <pie|no-pie>" >&2; exit 1; }
MODE="$1"
mode_valid "$MODE" || die "unknown mode '$MODE' (valid: $VALID_MODES)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for w in $VALID_WHICH; do
  d="$RESULTS/$MODE/$w"
  if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
    latest="$(ls -1 "$d" | sort | tail -1)"
    echo "using $w run: $d/$latest" >&2
    awk -F'\t' -v which="$w" 'NR > 1 { sum[$2 SUBSEP $3] += $4; n[$2 SUBSEP $3]++ }
      END { for (k in sum) { split(k, a, SUBSEP); printf "%s\t%s\t%s\t%.4f\n", which, a[1], a[2], sum[k] / n[k] } }' \
      "$d/$latest/summary.tsv" >> "$TMP/means.tsv"
  else
    echo "using $w run: (none)" >&2
  fi
done

[ -f "$TMP/means.tsv" ] \
  || die "no benchmark results found for mode '$MODE' (run pipeline/bench.sh first)"

print_metric() { # <metric> <high|low>
  local metric="$1" better="$2"
  echo
  # Columns are driven by $VALID_WHICH (baseline first, then each variant with
  # a delta column), so adding an opt-in variant (e.g. NOHUGE=1) needs no
  # change here.
  awk -F'\t' -v metric="$metric" -v better="$better" -v variants="$VALID_WHICH" '
    BEGIN { nv = split(variants, V, " ") }
    $3 == metric { v[$1 SUBSEP $2] = $4; tests[$2] = 1 }
    END {
      for (i = 1; i <= nv; i++) { g[i] = 1; n[i] = 0 }
      line = sprintf("%-20s %14s", metric, V[1])
      for (i = 2; i <= nv; i++) line = line sprintf(" %14s %10s", V[i], "delta")
      print line
      for (t in tests) {
        base = ("baseline" SUBSEP t) in v ? v["baseline" SUBSEP t] : 0
        line = sprintf("%-20s %14s", t, (base > 0 ? sprintf("%.2f", base) : "n/a"))
        for (i = 2; i <= nv; i++) {
          key = V[i] SUBSEP t
          if (base > 0 && (key in v) && v[key] > 0) {
            line = line sprintf(" %14.2f %9.2f%%", v[key], 100 * (v[key] - base) / base)
            g[i] *= v[key] / base; n[i]++
          } else {
            line = line sprintf(" %14s %10s", "n/a", "n/a")
          }
        }
        print line
      }
      line = sprintf("%-20s %14s", "----", "----")
      for (i = 2; i <= nv; i++) line = line sprintf(" %14s %10s", "----", "----")
      print line
      line = sprintf("%-20s %14s", "GEOMEAN", "1.0000")
      for (i = 2; i <= nv; i++) {
        if (n[i] > 0) {
          gg = g[i] ^ (1.0 / n[i])
          line = line sprintf(" %14.4f %9.2f%%", gg, 100 * (gg - 1))
        } else {
          line = line sprintf(" %14s %10s", "n/a", "n/a")
        }
      }
      print line
      printf "(deltas are %s-better for this metric)\n", better
    }' "$TMP/means.tsv"
}

# Which direction is an improvement for a known metric (default: higher).
metric_better() {
  case "$1" in
    lat_avg_ms|latency_avg_ms|avg_latency_ms|lat_p95_ms) echo low ;;
    *) echo high ;;
  esac
}

PREFERRED_METRICS="TPS QPS lat_avg_ms"
present="$(awk -F'\t' '{print $3}' "$TMP/means.tsv" | sort -u)"
ordered=""
for m in $PREFERRED_METRICS; do
  printf '%s\n' "$present" | grep -qxF "$m" && ordered="$ordered $m"
done
while IFS= read -r m; do
  [ -n "$m" ] || continue
  case " $PREFERRED_METRICS " in *" $m "*) continue ;; esac
  ordered="$ordered $m"
done <<< "$present"

[ -n "$ordered" ] || die "no metrics found in $TMP/means.tsv"
for m in $ordered; do
  print_metric "$m" "$(metric_better "$m")"
done
