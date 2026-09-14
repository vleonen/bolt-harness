#!/usr/bin/env bash
# Optimize the baseline with BOLT using the merged profile.
#
# Usage: optimize.sh <pie|no-pie>
#
# Produces, in binaries/<mode>/:
#   <server>.bolt          BOLT_OPT_FLAGS (README defaults)
#   <server>.bolt-rewrite  same flags + experimental -rewrite (optional; a
#                          failure is reported and the variant is skipped)
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_ROOT/lib/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "usage: optimize.sh <pie|no-pie>"
  exit 0
fi
[ $# -eq 1 ] || { echo "usage: optimize.sh <pie|no-pie>" >&2; exit 1; }
MODE="$1"
mode_valid "$MODE" || die "unknown mode '$MODE' (valid: $VALID_MODES)"

BASE="$(which_binary "$MODE" baseline)"
DATA="$PROFILES/$MODE/profile.merged.fdata"
[ -x "$BASE" ] || die "baseline missing: $BASE (run apps/$APP/build.sh $MODE first)"
[ -f "$DATA" ] || die "profile missing: $DATA (run pipeline/profile.sh $MODE first)"
[ -x "$BOLT" ] || die "llvm-bolt not found: $BOLT (set BOLT_BIN_DIR)"

# run_bolt <variant> <required:0|1> <extra-flags...>
# -rewrite is experimental: when required=0 a BOLT failure or a non-running
# output is reported as a warning and the variant is skipped, so the rest of
# the pipeline (baseline + bolt) still runs. A missing rewrite binary is then
# skipped by run-all.sh and shows up as "n/a" in compare.sh.
run_bolt() {
  local variant="$1" required="$2"; shift 2
  local out
  out="$(which_binary "$MODE" "$variant")"
  local log="$BINARIES/$MODE/bolt-$variant.log"
  info "BOLT [$MODE/$variant]: $BOLT_OPT_FLAGS $*"
  # shellcheck disable=SC2086  # BOLT_OPT_FLAGS is intentionally word-split
  if ! "$BOLT" "$BASE" -o "$out" -data="$DATA" $BOLT_OPT_FLAGS "$@" \
        > "$log" 2>&1; then
    tail -40 "$log" >&2
    if [ "$required" = 1 ]; then
      die "BOLT failed for [$MODE/$variant] (full log: $log)"
    fi
    info "WARNING: BOLT failed for [$MODE/$variant]; skipping variant (log: $log)"
    rm -f "$out"
    return 1
  fi
  # Guard the health check: a miscompiled -rewrite binary can loop forever on
  # --version (seen on x86_64 no-pie). BOLT_VERIFY_TIMEOUT bounds it.
  if ! timeout "${BOLT_VERIFY_TIMEOUT:-30}" "$out" --version >/dev/null 2>&1; then
    if [ "$required" = 1 ]; then
      die "optimized binary $out does not run (--version failed or timed out)"
    fi
    info "WARNING: optimized binary $out did not run (--version failed or timed out); skipping variant"
    rm -f "$out"
    return 1
  fi
  info "[$MODE/$variant] -> $out ($(du -h "$out" | cut -f1))"
  return 0
}

run_bolt bolt 1
run_bolt bolt-rewrite 0 -rewrite || true

echo
for v in bolt bolt-rewrite; do
  [ -f "$BINARIES/$MODE/bolt-$v.log" ] || continue
  info "tail of bolt-$v.log (dyno-stats):"
  tail -15 "$BINARIES/$MODE/bolt-$v.log" || true
done
