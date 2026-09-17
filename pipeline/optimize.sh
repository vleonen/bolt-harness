#!/usr/bin/env bash
# Optimize the baseline with BOLT using the merged profile.
#
# Usage: optimize.sh <pie|no-pie>
#
# Produces, in binaries/<mode>/:
#   <server>.bolt          BOLT_OPT_FLAGS (README defaults)
#   <server>.bolt-rewrite  same flags + experimental -rewrite (optional; a
#                          failure is reported and the variant is skipped)
#   <server>.bolt-rewrite-nohuge
#                          as above + --no-huge-pages (only when NOHUGE=1)
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
  local out verify_log rc=0
  out="$(which_binary "$MODE" "$variant")"
  local log="$BINARIES/$MODE/bolt-$variant.log"
  verify_log="$BINARIES/$MODE/bolt-$variant.verify.log"
  # Clean any artifacts left by a previous failed run so they can't be
  # mistaken for a fresh result.
  rm -f "$out.failed" "$verify_log"
  info "BOLT [$MODE/$variant]: $BOLT_OPT_FLAGS $*"
  # shellcheck disable=SC2086  # BOLT_OPT_FLAGS is intentionally word-split
  if ! "$BOLT" "$BASE" -o "$out" -data="$DATA" $BOLT_OPT_FLAGS "$@" \
        > "$log" 2>&1; then
    tail -40 "$log" >&2
    if [ "$required" = 1 ]; then
      die "BOLT failed for [$MODE/$variant] (full log: $log)"
    fi
    info "WARNING: BOLT failed for [$MODE/$variant]; skipping variant (log: $log)"
    # Preserve a partial output for forensics instead of deleting it.
    [ -f "$out" ] && mv "$out" "$out.failed"
    return 1
  fi
  # Guard the health check: a miscompiled -rewrite binary can loop forever on
  # --version (seen on x86_64 no-pie). By default `<binary> --version` is run
  # under BOLT_VERIFY_TIMEOUT. An adapter may define
  #   app_verify_bin <mode> <variant> <path>
  # for targets that are not directly executable (e.g. a shared library); the
  # hook owns its own timeout. Either way stderr and the exit status are
  # captured so a failing variant leaves forensics.
  # rc is captured via `|| rc=$?` so a failing verification cannot trip the
  # caller's `set -e`: run_bolt runs under set -e when invoked as a plain
  # command (the required `bolt` variant), and dying here would skip the
  # diagnostic branches below entirely.
  if declare -F app_verify_bin >/dev/null 2>&1; then
    app_verify_bin "$MODE" "$variant" "$out" > /dev/null 2> "$verify_log" || rc=$?
  else
    timeout "${BOLT_VERIFY_TIMEOUT:-30}" "$out" --version \
      > /dev/null 2> "$verify_log" || rc=$?
  fi
  if [ $rc -ne 0 ]; then
    if [ "$required" = 1 ]; then
      tail -20 "$verify_log" >&2
      die "optimized binary $out does not run (--version exit $rc; log: $verify_log)"
    fi
    info "WARNING: optimized binary $out did not run (--version exit $rc); keeping as $out.failed"
    { echo "exit status: $rc (124 = timed out)"; } >> "$verify_log" 2>/dev/null || true
    mv "$out" "$out.failed"
    return 1
  fi
  # BOLT may write a non-executable output for a shared library, but the rest
  # of the pipeline tests variants with `[ -x ]`. Harmless for executables.
  chmod +x "$out" 2>/dev/null || true
  rm -f "$verify_log"
  info "[$MODE/$variant] -> $out ($(du -h "$out" | cut -f1) raw, $(stripped_size_bytes "$out") bytes stripped)"
  return 0
}

run_bolt bolt 1
run_bolt bolt-rewrite 0 -rewrite || true
# Optional fourth variant (NOHUGE=1): the same rewrite but with BOLT's default
# huge-page code alignment replaced by the regular page size, to isolate the
# alignment/placement share of the output size (arch-neutral).
if [ "$NOHUGE" = 1 ]; then
  run_bolt bolt-rewrite-nohuge 0 -rewrite --no-huge-pages || true
fi

echo
for v in bolt bolt-rewrite $([ "$NOHUGE" = 1 ] && echo bolt-rewrite-nohuge); do
  [ -f "$BINARIES/$MODE/bolt-$v.log" ] || continue
  info "tail of bolt-$v.log (dyno-stats):"
  tail -15 "$BINARIES/$MODE/bolt-$v.log" || true
done
