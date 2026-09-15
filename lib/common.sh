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

# Optional fourth variant: a second -rewrite build with BOLT's default huge-page
# code alignment replaced by the target's regular page size (--no-huge-pages).
# BOLT aligns relocated code to 2M by default (BC->PageAlign = HugePageSize),
# which can leave multi-megabyte file holes; --no-huge-pages aligns to the
# regular page (4K on x86_64, 64K on aarch64). Opt in with NOHUGE=1; the
# harness scripts and the flag itself are architecture-neutral.
: "${NOHUGE:=0}"
NOHUGE_WHICH="bolt-rewrite-nohuge"
[ "$NOHUGE" = 1 ] && VALID_WHICH="$VALID_WHICH $NOHUGE_WHICH"

# Default optimization flags from bolt/README.md.
: "${BOLT_OPT_FLAGS:=-reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions -split-all-cold -split-eh -dyno-stats}"

# ---------------------------------------------------------------------------
# Application adapter
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$APP_DIR/app.sh"

# ---------------------------------------------------------------------------
# Architecture and generic defaults (overridable by the app adapter or env)
# ---------------------------------------------------------------------------
# Normalize the machine architecture so pipeline/app code stays arch-neutral.
# aarch64 and x86_64 are the supported targets; anything else is passed through.
case "$(uname -m)" in
  aarch64|arm64) HARNESS_ARCH=aarch64 ;;
  x86_64|amd64)  HARNESS_ARCH=x86_64 ;;
  *)             HARNESS_ARCH="$(uname -m)" ;;
esac

: "${BUILD_JOBS:=$(nproc)}"

# BOLT-friendly compiler flags that are only valid/needed on some arches.
# x86_64 needs nothing extra: GCC's default CET/IBT is left enabled.
harness_cflags_arch() {
  case "$HARNESS_ARCH" in
    aarch64) echo "-mbranch-protection=none" ;;   # keep PAC/BTI out
  esac
}

# ELF relocation-family prefix used to count relocations in build-info.txt.
harness_reloc_prefix() {
  case "$HARNESS_ARCH" in
    aarch64) echo "R_AARCH64" ;;
    x86_64)  echo "R_X86_64" ;;
    *)       echo "R_" ;;
  esac
}

# Expand a Linux CPU list ("0-3,8" or "0-7") into a comma-separated id list.
_harness_expand_cpus() { # <spec>
  local spec="$1" part lo hi i out="" sep=""
  local -a parts
  spec="${spec//[[:space:]]/}"
  IFS=',' read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    case "$part" in
      *-*) lo="${part%-*}"; hi="${part#*-}" ;;
      *)   lo="$part"; hi="$part" ;;
    esac
    for ((i = lo; i <= hi; i++)); do
      out="${out}${sep}${i}"; sep=","
    done
  done
  echo "$out"
}

# Print "server client" CPU lists to pin both sides, or nothing if unknown.
# Prefers the cgroup cpuset, then the online CPUs.
_harness_detect_cpus() {
  local spec="" list srv cli half n f
  local -a cpus
  for f in /sys/fs/cgroup/cpuset.cpus.effective \
           /sys/fs/cgroup/cpuset.cpus \
           /sys/devices/system/cpu/online; do
    [ -r "$f" ] || continue
    spec="$(cat "$f")"
    [ -n "$spec" ] && break
  done
  [ -n "$spec" ] || return 0
  list="$(_harness_expand_cpus "$spec")"
  [ -n "$list" ] || return 0
  IFS=',' read -ra cpus <<< "$list"
  n="${#cpus[@]}"
  [ "$n" -ge 2 ] || return 0
  half=$(( n / 2 ))
  srv="$(IFS=','; echo "${cpus[*]:0:half}")"
  cli="$(IFS=','; echo "${cpus[*]:half}")"
  echo "$srv $cli"
}

# Empty CPU list disables pinning. The aarch64 reference host keeps the
# historical 0-3/8-11 split; other hosts split the available CPUs in half.
if [ "$HARNESS_ARCH" = aarch64 ]; then
  : "${SERVER_CPUS:=0-3}"
  : "${CLIENT_CPUS:=8-11}"
else
  _harness_cpus="$(_harness_detect_cpus)"
  if [ -n "$_harness_cpus" ]; then
    : "${SERVER_CPUS:=${_harness_cpus%% *}}"
    : "${CLIENT_CPUS:=${_harness_cpus#* }}"
  else
    : "${SERVER_CPUS:=}"
    : "${CLIENT_CPUS:=}"
  fi
  unset _harness_cpus
fi

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

# Print the size in bytes of <path> after removing all non-runtime sections
# (symbol table, debug info, and the non-allocatable .rela.* sections kept by
# -Wl,-q). This is the fair basis for comparing BOLT output size against the
# baseline, whose raw size is inflated by those BOLT-input-only sections.
# Falls back to the raw file size if stripping is unavailable or fails.
stripped_size_bytes() { # <path>
  local f="$1" tmp raw
  raw="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  tmp="$(mktemp)"
  if strip -o "$tmp" "$f" >/dev/null 2>&1; then
    stat -c%s "$tmp"
  else
    echo "$raw"
  fi
  rm -f "$tmp"
}
