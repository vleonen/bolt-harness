#!/usr/bin/env bash
# Benchmark one binary variant.
#
# Usage: bench.sh <pie|no-pie> <baseline|bolt|bolt-rewrite>
#
# Starts the server (fresh per variant, tuned for stable results), runs WARMUP
# unrecorded + REPS recorded workload rounds, and stores raw output plus a
# parsed summary under results/<mode>/<which>/<timestamp>/.
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_ROOT/lib/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
usage: bench.sh <pie|no-pie> <baseline|bolt|bolt-rewrite>

Knobs (env): REPS WARMUP BENCH_PORT SERVER_CPUS CLIENT_CPUS
             plus application-specific workload knobs (see apps/<app>/README.md)
EOF
  exit 0
fi
[ $# -eq 2 ] || { echo "usage: bench.sh <mode> <baseline|bolt|bolt-rewrite>" >&2; exit 1; }
MODE="$1"
WHICH="$2"
BIN="$(which_binary "$MODE" "$WHICH")"   # validates both arguments
[ -x "$BIN" ] || die "binary missing: $BIN"

ensure_dirs
RUN="$RESULTS/$MODE/$WHICH/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN/raw"

if port_in_use "$BENCH_PORT"; then die "port $BENCH_PORT already in use"; fi

export APP_BASEDIR="$(app_basedir "$MODE")"
export APP_DATADIR="$(app_data_dir "$MODE")"
export APP_RUNDIR="$RUN"
export APP_PORT="$BENCH_PORT"
export APP_TAG="$WHICH"
# The app adapter supplies the default workload duration; BENCH_TIME (used by
# some apps) overrides it when set. An empty value makes the adapter fall back.
export APP_WORKLOAD_TIME="${BENCH_TIME:-}"

info "Preparing dataset for $MODE"
app_prepare_data "$MODE"

# app_prepare_data rebinds APP_RUNDIR/APP_TAG; restore this run's values.
export APP_RUNDIR="$RUN"
export APP_TAG="$WHICH"
export APP_PORT="$BENCH_PORT"

cleanup() {
  [ -n "${APP_PID:-}" ] && app_server_stop || true
}
trap cleanup EXIT

info "[$MODE/$WHICH] server=$(basename "$BIN") port=$BENCH_PORT server-cpus=${SERVER_CPUS:-off} client-cpus=${CLIENT_CPUS:-off}"
app_server_start "$BIN"
app_server_wait "$APP_PORT" 180 || {
  tail -20 "$RUN/server-$WHICH.log" >&2
  die "server did not start (log: $RUN/server-$WHICH.log)"
}
taskset -pc "$APP_PID" > "$RUN/server-affinity.txt" 2>&1 \
  || echo "affinity check failed for pid $APP_PID" > "$RUN/server-affinity.txt"

w=0
while [ "$w" -lt "$WARMUP" ]; do
  info "warmup $((w + 1))/$WARMUP"
  app_workload "$RUN/raw" "warmup-$w"
  w=$((w + 1))
done

printf 'rep\ttest\tmetric\tvalue\n' > "$RUN/summary.tsv"
r=1
while [ "$r" -le "$REPS" ]; do
  info "rep $r/$REPS"
  app_workload "$RUN/raw" "rep-$r"
  for f in "$RUN"/raw/rep-"$r".*.txt; do
    [ -f "$f" ] || continue
    [[ "$f" == *.err ]] && continue
    app_parse_workload "$f" \
      | awk -v rep="$r" -F'\t' '{ printf "%s\t%s\t%s\t%s\n", rep, $1, $2, $3 }' \
      >> "$RUN/summary.tsv"
  done
  r=$((r + 1))
done

info "stopping server"
app_server_stop

{
  echo "binary:  $BIN"
  echo "mode:    $MODE   which: $WHICH"
  echo "sha256:  $(sha256sum "$BIN" | cut -d' ' -f1)"
  echo "date:    $(date -Is)"
  echo "host:    $(uname -a)"
  echo "reps:    $REPS warmup=$WARMUP"
  if declare -F app_describe >/dev/null 2>&1; then
    app_describe
  fi
  echo "pinning: server=${SERVER_CPUS:-off} client=${CLIENT_CPUS:-off}"
  echo "affinity: $(sed 's/.*: //' "$RUN/server-affinity.txt" 2>/dev/null || echo n/a)"
} > "$RUN/env.txt"

info "results in $RUN"
echo
awk -F'\t' 'NR > 1 { sum[$2 SUBSEP $3] += $4; n[$2 SUBSEP $3]++ }
  END {
    for (k in sum) { split(k, a, SUBSEP); printf "%-20s %-12s %14.2f\n", a[1], a[2], sum[k] / n[k] }
  }' "$RUN/summary.tsv" | sort > "$RUN/means.tsv"
{ printf "%-20s %-12s %14s\n" "test" "metric" "mean"; cat "$RUN/means.tsv"; }
