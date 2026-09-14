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
  awk -F'\t' -v metric="$metric" -v better="$better" '
    $3 == metric { v[$1 SUBSEP $2] = $4; tests[$2] = 1 }
    END {
      fmt = "%-20s %14s %14s %10s %14s %10s\n"
      printf fmt, metric, "baseline", "bolt", "delta", "rewrite", "delta"
      nb = nr = 0; gb = gr = 1
      for (t in tests) {
        has_b = (("baseline" SUBSEP t) in v) && v["baseline" SUBSEP t] > 0
        has_x = (("bolt" SUBSEP t) in v) && v["bolt" SUBSEP t] > 0
        has_y = (("bolt-rewrite" SUBSEP t) in v) && v["bolt-rewrite" SUBSEP t] > 0
        b = has_b ? sprintf("%.2f", v["baseline" SUBSEP t]) : "n/a"
        x = has_x ? sprintf("%.2f", v["bolt" SUBSEP t]) : "n/a"
        y = has_y ? sprintf("%.2f", v["bolt-rewrite" SUBSEP t]) : "n/a"
        dx = (has_b && has_x) ? sprintf("%+9.2f%%", 100 * (v["bolt" SUBSEP t] - v["baseline" SUBSEP t]) / v["baseline" SUBSEP t]) : "n/a"
        dy = (has_b && has_y) ? sprintf("%+9.2f%%", 100 * (v["bolt-rewrite" SUBSEP t] - v["baseline" SUBSEP t]) / v["baseline" SUBSEP t]) : "n/a"
        printf fmt, t, b, x, dx, y, dy
        if (has_b && has_x) { gb *= v["bolt" SUBSEP t] / v["baseline" SUBSEP t]; nb++ }
        if (has_b && has_y) { gr *= v["bolt-rewrite" SUBSEP t] / v["baseline" SUBSEP t]; nr++ }
      }
      printf fmt, "----", "----", "----", "----", "----", "----"
      if (nb) gb ^= (1.0 / nb)
      if (nr) gr ^= (1.0 / nr)
      gxs = nb ? sprintf("%.4f", gb) : "n/a"
      gxd = nb ? sprintf("%+9.2f%%", 100 * (gb - 1)) : "n/a"
      gys = nr ? sprintf("%.4f", gr) : "n/a"
      gyd = nr ? sprintf("%+9.2f%%", 100 * (gr - 1)) : "n/a"
      printf "%-20s %14s %14s %10s %14s %10s\n", "GEOMEAN", "1.0000", gxs, gxd, gys, gyd
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
