#!/usr/bin/env bash
# Instrument the baseline with BOLT and collect a profile under load.
#
# Usage: profile.sh <pie|no-pie>
#
# Produces profiles/<mode>/profile.merged.fdata (via merge-fdata) using the
# application's own workload (app_workload) driven through app.sh.
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_ROOT/lib/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "usage: profile.sh <pie|no-pie>"
  exit 0
fi
[ $# -eq 1 ] || { echo "usage: profile.sh <pie|no-pie>" >&2; exit 1; }
MODE="$1"
mode_valid "$MODE" || die "unknown mode '$MODE' (valid: $VALID_MODES)"

ensure_dirs
BASE="$(which_binary "$MODE" baseline)"
[ -x "$BASE" ] || die "baseline missing: $BASE (run apps/$APP/build.sh $MODE first)"
[ -x "$BOLT" ] || die "llvm-bolt not found: $BOLT (set BOLT_BIN_DIR)"

PDIR="$PROFILES/$MODE"
IDIR="$PDIR/fdata"
INSTR="$PDIR/$(basename "$BASE").instr"
FDATA="$IDIR/profile.fdata"
MERGED="$PDIR/profile.merged.fdata"
mkdir -p "$IDIR"

info "Instrumenting $BASE with BOLT (dump interval: ${PROFILE_SLEEP_TIME}s, counters not cleared)"
# BOLT_INSTRUMENT_EXTRA_FLAGS lets callers pass toolchain-specific flags that
# are only valid for the installed llvm-bolt. aarch64/LLVM 23+ only:
# --drop-cortex-a53-843419-veneers (required when the baseline was linked with
# the C-A53 erratum 843419 workaround; do not pass it on x86_64).
# shellcheck disable=SC2086  # BOLT_INSTRUMENT_EXTRA_FLAGS is intentionally word-split
"$BOLT" "$BASE" -o "$INSTR" \
  -instrument \
  -instrumentation-file="$FDATA" \
  -instrumentation-sleep-time="$PROFILE_SLEEP_TIME" \
  -instrumentation-no-counters-clear \
  ${BOLT_INSTRUMENT_EXTRA_FLAGS:-} \
  > "$PDIR/instrument.log" 2>&1 || {
    tail -30 "$PDIR/instrument.log" >&2
    die "BOLT instrumentation failed (full log: $PDIR/instrument.log)"
  }

rm -f "$IDIR"/profile*.fdata*

if port_in_use "$PROFILE_PORT"; then die "port $PROFILE_PORT already in use"; fi

info "Preparing dataset for $MODE"
export APP_BASEDIR="$(app_basedir "$MODE")"
export APP_DATADIR="$(app_data_dir "$MODE")"
export APP_RUNDIR="$PDIR"
export APP_PORT="$PROFILE_PORT"
export APP_TAG=profile
app_prepare_data "$MODE"

# app_prepare_data runs its own server and rebinds these globals; restore the
# profile-run values before starting the instrumented server.
export APP_BASEDIR="$(app_basedir "$MODE")"
export APP_DATADIR="$(app_data_dir "$MODE")"
export APP_RUNDIR="$PDIR"
export APP_PORT="$PROFILE_PORT"
export APP_TAG=profile

cleanup() {
  [ -n "${APP_PID:-}" ] && app_server_stop || true
}
trap cleanup EXIT

app_server_start "$INSTR"
app_server_wait "$APP_PORT" 180 || {
  tail -20 "$PDIR/server-profile.log" >&2
  die "instrumented server did not start (log: $PDIR/server-profile.log)"
}

# Per-test duration must outlast the dump interval so at least one periodic
# dump fires while the workload is still executing.
if [ "${PROFILE_TEST_TIME:-0}" -gt 0 ]; then
  APP_WORKLOAD_TIME="$PROFILE_TEST_TIME"
else
  APP_WORKLOAD_TIME=$((PROFILE_SLEEP_TIME + 5))
fi
export APP_WORKLOAD_TIME

if declare -F app_describe >/dev/null 2>&1; then
  app_describe
fi
info "Driving profile workload (${APP_WORKLOAD_TIME}s per workload unit)"
WORKLOAD_START=$SECONDS
app_workload "$PDIR/raw" profile
WORKLOAD_ELAPSED=$((SECONDS - WORKLOAD_START))
info "Profile workload finished in ${WORKLOAD_ELAPSED}s (dump interval: ${PROFILE_SLEEP_TIME}s)"

if ((PROFILE_SLEEP_TIME > 0 && WORKLOAD_ELAPSED <= PROFILE_SLEEP_TIME)); then
  die "profile workload ran ${WORKLOAD_ELAPSED}s, not longer than -instrumentation-sleep-time=${PROFILE_SLEEP_TIME}s; raise PROFILE_TEST_TIME or lower PROFILE_SLEEP_TIME"
fi

info "Waiting $((PROFILE_SLEEP_TIME + 3))s for the final periodic profile dump"
sleep $((PROFILE_SLEEP_TIME + 3))

info "Shutting down gracefully (flushes .fdata profile)"
app_server_stop

ls "$IDIR"/profile*.fdata* >/dev/null 2>&1 \
  || die "no .fdata files were produced in $IDIR"

info "Merging $(ls "$IDIR"/profile*.fdata* | wc -l) profile file(s)"
"$MERGE_FDATA" "$IDIR"/profile*.fdata* > "$MERGED" || die "merge-fdata failed"

info "Profile ready: $MERGED ($(du -h "$MERGED" | cut -f1))"
