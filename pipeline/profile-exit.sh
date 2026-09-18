#!/usr/bin/env bash
# Instrument the baseline with BOLT and collect a profile that is dumped at
# application finalization (process exit) only.
#
# Usage: profile-exit.sh <pie|no-pie>
#
# Complement of profile.sh: the binary is instrumented WITHOUT
# -instrumentation-sleep-time and WITHOUT -instrumentation-no-counters-clear,
# so BOLT's runtime performs no periodic dumps and writes the whole profile
# when the instrumented process exits (finalization dump). The script also
# verifies that the instrumented binary survives its workload and exits
# cleanly:
#   - the server must stay alive for the whole workload run,
#   - shutdown must terminate the process,
#   - no crash markers may appear in the server log,
#   - at least one .fdata must be produced by the exit dump.
#
# Outputs (kept separate from the periodic profile.sh artifacts):
#   profiles/<mode>/*.instr-exit            instrumented binary
#   profiles/<mode>/fdata-exit/profile*.fdata*   per-process exit dumps
#   profiles/<mode>/profile.exit.merged.fdata    merged profile
#
# Tunables:
#   PROFILE_EXIT_TEST_TIME (default 30)   workload seconds per pass
#   PROFILE_EXIT_WAIT       (default 60)  max seconds to wait for exit dumps
#   PROFILE_EXIT_APPEND_PID (default 1)   pass -instrumentation-file-append-pid
#                                         (forking servers, e.g. postgres
#                                         backends, would otherwise overwrite
#                                         the same .fdata on exit)
#   PROFILE_EXIT_VALIDATE_BOLT (default 0) additionally parse the merged
#                                         profile with llvm-bolt -data=...
#
# NOTE: this variant requires the application to terminate through regular
# ELF finalization (exit()/return from main), where BOLT's runtime DT_FINI
# hook writes the profile. Applications that exit via _exit()/quick_exit()
# (e.g. mongod) or die by SIGKILL bypass finalizers and can never produce
# an exit dump - profile them with profile.sh and
# -instrumentation-sleep-time (periodic dumps) instead.
set -euo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_ROOT/lib/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
[ $# -eq 1 ] || { echo "usage: profile-exit.sh <pie|no-pie>" >&2; exit 1; }
MODE="$1"
mode_valid "$MODE" || die "unknown mode '$MODE' (valid: $VALID_MODES)"

: "${PROFILE_EXIT_TEST_TIME:=30}"
: "${PROFILE_EXIT_WAIT:=60}"
: "${PROFILE_EXIT_APPEND_PID:=1}"
: "${PROFILE_EXIT_VALIDATE_BOLT:=0}"

ensure_dirs
BASE="$(which_binary "$MODE" baseline)"
[ -x "$BASE" ] || die "baseline missing: $BASE (run apps/$APP/build.sh $MODE first)"
[ -x "$BOLT" ] || die "llvm-bolt not found: $BOLT (set BOLT_BIN_DIR)"

PDIR="$PROFILES/$MODE"
IDIR="$PDIR/fdata-exit"
INSTR="$PDIR/$(basename "$BASE").instr-exit"
FDATA="$IDIR/profile.fdata"
MERGED="$PDIR/profile.exit.merged.fdata"
mkdir -p "$IDIR"

EXTRA_FLAGS="${BOLT_INSTRUMENT_EXTRA_FLAGS:-}"
if [ "$PROFILE_EXIT_APPEND_PID" = 1 ]; then
  EXTRA_FLAGS="$EXTRA_FLAGS -instrumentation-file-append-pid"
fi

info "Instrumenting $BASE with BOLT (dump at application finalization only:"
info "  no -instrumentation-sleep-time, no -instrumentation-no-counters-clear)"
# shellcheck disable=SC2086  # EXTRA_FLAGS is intentionally word-split
"$BOLT" "$BASE" -o "$INSTR" \
  -instrument \
  -instrumentation-file="$FDATA" \
  ${EXTRA_FLAGS} \
  > "$PDIR/instrument-exit.log" 2>&1 || {
    tail -30 "$PDIR/instrument-exit.log" >&2
    die "BOLT instrumentation failed (full log: $PDIR/instrument-exit.log)"
  }

rm -f "$IDIR"/profile*.fdata*

if port_in_use "$PROFILE_PORT"; then die "port $PROFILE_PORT already in use"; fi

info "Preparing dataset for $MODE"
export APP_BASEDIR="$(app_basedir "$MODE")"
export APP_DATADIR="$(app_data_dir "$MODE")"
export APP_RUNDIR="$PDIR"
export APP_PORT="$PROFILE_PORT"
export APP_TAG=profile-exit
app_prepare_data "$MODE"

# app_prepare_data may run its own server and rebind these globals; restore
# the profile-run values before starting the instrumented server.
export APP_BASEDIR="$(app_basedir "$MODE")"
export APP_DATADIR="$(app_data_dir "$MODE")"
export APP_RUNDIR="$PDIR"
export APP_PORT="$PROFILE_PORT"
export APP_TAG=profile-exit

SERVER_LOG="$APP_RUNDIR/server-$APP_TAG.log"
CRASH_RE='segfault|SIGSEGV|SIGABRT|signal 11|signal 6|core dumped|panic|fatal error|terminated by signal'

cleanup() {
  [ -n "${APP_PID:-}" ] && app_server_stop || true
}
trap cleanup EXIT

app_server_start "$INSTR"
if declare -F app_server_wait >/dev/null 2>&1; then
  app_server_wait "$APP_PORT" 180 || {
    tail -20 "$SERVER_LOG" >&2 || true
    die "instrumented server did not start (log: $SERVER_LOG)"
  }
fi

export APP_WORKLOAD_TIME="$PROFILE_EXIT_TEST_TIME"
if declare -F app_describe >/dev/null 2>&1; then
  app_describe
fi

# Liveness check: the instrumented server must stay alive for the whole
# workload. app_workload runs in the background while we poll APP_PID
# (apps without a persistent server, e.g. python, leave APP_PID empty and
# rely on the workload exit status instead).
info "Driving workload (${APP_WORKLOAD_TIME}s per workload unit); watching server liveness"
WL_FAILURE=0
app_workload "$PDIR/raw-exit" profile-exit &
WL_PID=$!
WL_START=$SECONDS
while kill -0 "$WL_PID" 2>/dev/null; do
  if [ -n "${APP_PID:-}" ] && ! kill -0 "$APP_PID" 2>/dev/null; then
    wait "$WL_PID" || WL_FAILURE=1
    tail -30 "$SERVER_LOG" >&2 || true
    die "instrumented server died during the workload after $((SECONDS - WL_START))s (log: $SERVER_LOG)"
  fi
  sleep 1
done
wait "$WL_PID" || WL_FAILURE=1
[ "$WL_FAILURE" = 0 ] || die "workload failed against the instrumented binary (see $PDIR/raw-exit)"
info "Workload finished in $((SECONDS - WL_START))s with the server still alive"

info "Shutting down gracefully (exit dump must fire)"
STOP_START=$SECONDS
app_server_stop
if [ -n "${APP_PID:-}" ]; then
  for _ in $(seq 1 300); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$APP_PID" 2>/dev/null; then
    die "instrumented server did not exit within $((SECONDS - STOP_START))s after shutdown"
  fi
  info "Instrumented server exited cleanly $((SECONDS - STOP_START))s after shutdown was requested"
fi

# Crash scan over the server log: a postmaster surviving a crashed backend
# (e.g. postgres) still logs "terminated by signal", which must fail the run.
if [ -f "$SERVER_LOG" ]; then
  if LC_ALL=C grep -nEi "$CRASH_RE" "$SERVER_LOG" >/dev/null 2>&1; then
    LC_ALL=C grep -nEi "$CRASH_RE" "$SERVER_LOG" | head -20 >&2 || true
    die "crash markers found in server log: $SERVER_LOG"
  fi
fi

# Wait for exit dumps to appear and stabilize (size unchanged between checks).
info "Waiting up to ${PROFILE_EXIT_WAIT}s for exit-dump .fdata files"
STABLE=0
WAITED=0
LAST_SIZE=-1
while [ "$WAITED" -lt "$PROFILE_EXIT_WAIT" ]; do
  CUR_SIZE=0
  if compgen -G "$IDIR"/profile*.fdata* >/dev/null; then
    CUR_SIZE=$(du -cb "$IDIR"/profile*.fdata* 2>/dev/null | tail -1 | cut -f1)
  fi
  if [ "$CUR_SIZE" -gt 0 ] && [ "$CUR_SIZE" = "$LAST_SIZE" ]; then
    STABLE=1
    break
  fi
  LAST_SIZE="$CUR_SIZE"
  sleep 2
  WAITED=$((WAITED + 2))
done
[ "$STABLE" = 1 ] || {
  ls -la "$IDIR" >&2 || true
  die "no stable .fdata exit dumps produced within ${PROFILE_EXIT_WAIT}s (dump at finalization did not fire or is incomplete)"
}

info "Exit dumps produced by $(ls "$IDIR"/profile*.fdata* | wc -l) process(es):"
ls -l "$IDIR"/profile*.fdata* >&2 || true

info "Merging exit-dump profiles"
"$MERGE_FDATA" "$IDIR"/profile*.fdata* > "$MERGED" || die "merge-fdata failed"
MERGED_SIZE=$(stat -c %s "$MERGED")
[ "$MERGED_SIZE" -gt 1024 ] || die "merged exit profile is suspiciously small (${MERGED_SIZE} bytes): $MERGED"

if [ "$PROFILE_EXIT_VALIDATE_BOLT" = 1 ]; then
  info "Validating merged exit profile with a BOLT parse"
  "$BOLT" "$BASE" -o /dev/null -data="$MERGED" \
    > "$PDIR/exit-profile-validate.log" 2>&1 || {
      tail -30 "$PDIR/exit-profile-validate.log" >&2
      die "llvm-bolt failed to parse the merged exit profile (log: $PDIR/exit-profile-validate.log)"
    }
fi

info "Exit-dump profile ready: $MERGED ($(du -h "$MERGED" | cut -f1))"
