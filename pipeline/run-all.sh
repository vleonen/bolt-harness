#!/usr/bin/env bash
# End-to-end pipeline: build -> profile -> optimize -> benchmark -> compare.
#
# Usage: run-all.sh [pie|no-pie]...   (default: pie)
#
# Stages can be skipped via env guards:
#   SKIP_BUILD=1 SKIP_PROFILE=1 SKIP_OPTIMIZE=1 SKIP_BENCH=1 SKIP_COMPARE=1
#
# The optional exit-dump profiling variant (dump at application finalization,
# no -instrumentation-sleep-time) runs after the periodic profile when
# PROFILE_EXIT=1 (skip it alone with SKIP_PROFILE_EXIT=1).
#
# Select the application with APP=<name> (default: mariadb).
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_ROOT/lib/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

MODES=("$@")
[ ${#MODES[@]} -eq 0 ] && MODES=(pie)
for m in "${MODES[@]}"; do
  mode_valid "$m" || die "unknown mode '$m' (valid: $VALID_MODES)"
done

for MODE in "${MODES[@]}"; do
  echo
  info "==================== app: $APP   mode: $MODE ===================="

  [ "${SKIP_BUILD:-0}" = 1 ] || "$APP_DIR/build.sh" "$MODE"
  [ "${SKIP_PROFILE:-0}" = 1 ] || "$HARNESS_ROOT/pipeline/profile.sh" "$MODE"
  if [ "${PROFILE_EXIT:-0}" = 1 ] && [ "${SKIP_PROFILE_EXIT:-0}" != 1 ]; then
    "$HARNESS_ROOT/pipeline/profile-exit.sh" "$MODE"
  fi
  [ "${SKIP_OPTIMIZE:-0}" = 1 ] || "$HARNESS_ROOT/pipeline/optimize.sh" "$MODE"

  if [ "${SKIP_BENCH:-0}" != 1 ]; then
    for WHICH in $VALID_WHICH; do
      BIN="$(which_binary "$MODE" "$WHICH")"
      if [ -x "$BIN" ]; then
        "$HARNESS_ROOT/pipeline/bench.sh" "$MODE" "$WHICH"
      else
        info "skipping $MODE/$WHICH benchmark: $BIN missing"
      fi
    done
  fi

  [ "${SKIP_COMPARE:-0}" = 1 ] || "$HARNESS_ROOT/pipeline/compare.sh" "$MODE"
done

info "all done"
