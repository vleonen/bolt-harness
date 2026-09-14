#!/usr/bin/env bash
# Shared configuration and helpers for the bolt-harness framework.
#
# bolt-harness measures llvm-bolt optimizations on real applications. Every
# application lives in apps/<app>/ and provides:
#   build.sh   application-specific build (produces the baseline binary)
#   app.sh     adapter hooks used by the generic pipeline stages
#   Dockerfile container image with the build/benchmark dependencies
#   rebuild.sh container lifecycle helper
#
# The pipeline stages in pipeline/ are application-agnostic:
#   profile.sh   llvm-bolt -instrument + application workload + merge-fdata
#   optimize.sh  baseline + profile -> baseline.bolt and baseline.bolt-rewrite
#   bench.sh     run the application workload against each variant
#   compare.sh   baseline vs bolt vs bolt-rewrite
#   run-all.sh   build.sh then profile -> optimize -> bench -> compare
#
# Directory layout created by the pipeline:
#   $WORK/_state/<app>/binaries/<mode>/   baseline + BOLT-optimized binaries
#   $WORK/_state/<app>/installs/<mode>/   `cmake --install` tree (runtime files)
#   $WORK/_state/<app>/data/<mode>/       prepared benchmark dataset
#   $WORK/_state/<app>/profiles/<mode>/   instrumented binary + merged .fdata
#   $WORK/_state/<app>/results/<mode>/<which>/<timestamp>/   benchmark runs
#
# Every tunable below can be overridden from the environment, e.g.:
#   SERVER_CPUS= CLIENT_CPUS= ./pipeline/bench.sh pie bolt

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${APP:=mariadb}"
APP_DIR="$HARNESS_ROOT/apps/$APP"
[ -d "$APP_DIR" ] || { echo "ERROR: unknown app '$APP' (no $APP_DIR)" >&2; exit 1; }

: "${HARNESS_WORK:=$HARNESS_ROOT/work}"
WORK="$HARNESS_WORK"
STATE="$WORK/_state/$APP"
BINARIES="$STATE/binaries"
INSTALLS="$STATE/installs"
PROFILES="$STATE/profiles"
RESULTS="$STATE/results"

: "${BOLT_BIN_DIR:=${HOME}/src/llvm-project/build/bin}"
BOLT="$BOLT_BIN_DIR/llvm-bolt"
MERGE_FDATA="$BOLT_BIN_DIR/merge-fdata"

VALID_MODES="pie no-pie"
VALID_WHICH="baseline bolt bolt-rewrite"

# Default optimization flags from bolt/README.md.
: "${BOLT_OPT_FLAGS:=-reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions -split-all-cold -split-eh -dyno-stats}"

# ---------------------------------------------------------------------------
# Application adapter
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$APP_DIR/app.sh"

# ---------------------------------------------------------------------------
# Generic defaults (overridable by the app adapter or the environment)
# ---------------------------------------------------------------------------
: "${BUILD_JOBS:=$(nproc)}"
# Empty CPU list disables pinning. Defaults are a reasonable starting point
# for a big.LITTLE aarch64 host; each app overrides as appropriate.
: "${SERVER_CPUS:=0-3}"
: "${CLIENT_CPUS:=8-11}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

mode_valid() { # <mode>
  case " $VALID_MODES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_dirs() {
  mkdir -p "$BINARIES" "$INSTALLS" "$PROFILES" "$RESULTS"
}

# Return the path of a binary variant. Delegates to the app adapter.
which_binary() { # <mode> <baseline|bolt|bolt-rewrite>
  app_variant_bin "$@"
}

# Run a command pinned to a CPU list (empty list = no pinning).
pinned() { # <cpu-list> <cmd...>
  local cpus="$1"; shift
  if [ -n "$cpus" ]; then taskset -c "$cpus" "$@"; else "$@"; fi
}

# Background-safe launcher. `pinned ... &` must NOT be used for a function:
# a backgrounded function runs in a subshell wrapper and $! would be the
# wrapper's pid, not the command's. pinned_bg execs taskset in the subshell
# so PINNED_PID is the real pid.
pinned_bg() { # <cpu-list> <cmd...>  -> sets PINNED_PID
  local cpus="$1"; shift
  if [ -n "$cpus" ]; then
    ( exec taskset -c "$cpus" "$@" ) &
  else
    "$@" &
  fi
  PINNED_PID=$!
}

port_in_use() { # <port>
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# Make an executable path absolute.
abspath() {
  local p="$1"
  case "$p" in
    /*) echo "$p" ;;
    *) echo "$PWD/$p" ;;
  esac
}
