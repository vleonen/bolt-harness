#!/usr/bin/env bash
# Build MongoDB 7.0 in a BOLT-friendly configuration (SCons).
#
# Usage: build.sh [pie|no-pie|all]...   (default: pie)
#
# Modes:
#   pie      position-independent executable (Ubuntu default), -Wl,-q
#   no-pie   fixed-address executable (-no-pie at link), -Wl,-q
#
# MongoDB 7.0's SCons build exposes CCFLAGS/CXXFLAGS/LINKFLAGS as command-line
# variables, so BOLT requirements are injected natively: relocations retained
# (-Wl,-q), stack protector off (--runtime-hardening=off + -fno-stack-protector)
# and, on aarch64, PAC/BTI off. The JavaScript engine (mozjs) is disabled
# (--js-engine=none): it is unused by the workload and its direct-threaded
# computed-goto interpreter is a known BOLT hazard.
#
# Each build is out-of-tree under $STATE/build/<mode> and installed under
# $STATE/installs/<mode>; the baseline server is copied to $BINARIES/<mode>/mongod
# together with a build-info.txt summary.
set -euo pipefail

APP="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_ROOT/lib/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
usage: build.sh [pie|no-pie|all]...   (default: pie)

Builds MongoDB (mongod) out-of-tree with SCons, installs it under
$STATE/installs/<mode>, and snapshots the baseline server under
$BINARIES/<mode>/ with a build-info.txt summary.
EOF
  exit 0
fi

MODES=("$@")
[ ${#MODES[@]} -eq 0 ] && MODES=(pie)
[ "${MODES[0]}" = all ] && MODES=(pie no-pie)

for m in "${MODES[@]}"; do
  mode_valid "$m" || die "unknown mode '$m' (valid: $VALID_MODES all)"
done

# ---------------------------------------------------------------------------
# Compiler and BOLT-friendly flags
# ---------------------------------------------------------------------------
: "${CC:=gcc}"
if [ -z "${CXX:-}" ]; then
  case "$CC" in
    *gcc*) CXX=g++ ;;
    *clang*) CXX=clang++ ;;
    *) CXX=g++ ;;
  esac
fi

build_cflags() { # <mode>
  local mode="$1" flags="-fno-omit-frame-pointer -fno-stack-protector" arch_flags
  arch_flags="$(harness_cflags_arch)"        # aarch64: -mbranch-protection=none
  [ -n "$arch_flags" ] && flags="$flags $arch_flags"
  # GCC 8+ enables -freorder-blocks-and-partition at -O2; BOLT is incompatible.
  case "$CC" in
    *gcc*) flags="$flags -fno-reorder-blocks-and-partition" ;;
  esac
  # NB: no -fno-pie. Both modes share one build tree (see build_mode), and the
  # PIE objects link fine into a -no-pie executable, so compile flags must be
  # identical or the second mode recompiles everything (~2 h).
  echo "$flags"
}

mongod_ldflags() { # <mode>
  # --emit-relocs (GNU ld -q) is accepted by bfd/gold/lld; MongoDB's default
  # linkers do not all understand the -q alias.
  case "$1" in
    pie)     echo "-Wl,--emit-relocs" ;;
    no-pie)  echo "-no-pie -Wl,--emit-relocs" ;;
  esac
}

build_mode() { # <mode>
  local mode="$1" cflags ldflags src build prefix bin server reloc_prefix py
  cflags="$(build_cflags "$mode")"
  ldflags="$(mongod_ldflags "$mode")"
  src="${APP_SRC:-$WORK/$APP}"
  # One shared SCons tree for every mode: compile flags are identical and only
  # LINKFLAGS differ, so building the second mode is just a relink instead of a
  # second ~2 h full compile. Objects are PIE-capable and link into -no-pie.
  # The directory keeps its historical "pie" name because the build dir is
  # embedded in every compile command line (-I$build/opt); renaming it would
  # invalidate all objects. Both modes share this one tree.
  build="$STATE/build/pie"
  prefix="$(app_basedir "$mode")"
  bin="$BINARIES/$mode"
  mkdir -p "$build" "$prefix" "$bin"

  [ -d "$src" ] || die "MongoDB source not found at $src (clone it or set APP_SRC)"
  [ -f "$src/SConstruct" ] || die "$src/SConstruct not found (MongoDB 7.0 SCons tree expected)"
  py="${MONGODB_PYTHON:-python3}"
  [ -x "$py" ] || py=python3
  "$py" -c 'import psutil' 2>/dev/null \
    || die "MongoDB Python build requirements missing; run apps/mongodb/rebuild.sh (expected interpreter: $py)"

  info "Building MongoDB [$mode] with SCons: CC=$CC CXX=$CXX"
  info "  CCFLAGS/CXXFLAGS: $cflags"
  info "  LINKFLAGS:        $ldflags"
  # shellcheck disable=SC2086  # MONGODB_SCONS_OPTS is intentionally word-split
  (
    cd "$src"
    "$py" buildscripts/scons.py install-mongod \
      CC="$CC" CXX="$CXX" \
      CCFLAGS="$cflags" CXXFLAGS="$cflags" LINKFLAGS="$ldflags" \
      --opt=on --dbg=off \
      --runtime-hardening=off \
      --js-engine=none \
      --linker="$MONGODB_LINKER" \
      --disable-warnings-as-errors \
      --allocator="$MONGODB_ALLOCATOR" \
      --separate-debug="$MONGODB_SEPARATE_DEBUG" \
      --build-dir="$build" \
      --jobs="$MONGO_JOBS" \
      DESTDIR="$prefix" \
      ${MONGODB_SCONS_OPTS:-}
  ) > "$STATE/build-$mode.log" 2>&1 \
    || { tail -50 "$STATE/build-$mode.log" >&2; die "MongoDB build failed for [$mode]"; }

  server="$prefix/bin/mongod"
  [ -x "$server" ] || die "$server not produced"
  cp "$server" "$bin/mongod"

  # MongoDB compiles with full DWARF, making the raw binary multi-GB. BOLT does
  # not need debug info: --strip-debug removes it while keeping the symbol table,
  # .eh_frame and the -Wl,--emit-relocs .rela.* sections. This is the single
  # biggest lever on BOLT runtime/memory for this app.
  if [ "${MONGODB_STRIP_DEBUG:-1}" = 1 ]; then
    info "[$mode] stripping DWARF from the BOLT input"
    objcopy --strip-debug "$bin/mongod"
  fi

  reloc_prefix="$(harness_reloc_prefix)"
  {
    echo "app:        $APP ($MONGODB_VERSION)"
    echo "mode:       $mode"
    echo "arch:       $(uname -m)"
    echo "date:       $(date -Is)"
    echo "CC:         $CC ($($CC --version | head -1))"
    echo "CXX:        $CXX ($($CXX --version | head -1))"
    echo "CCFLAGS:    $cflags"
    echo "LINKFLAGS:  $ldflags"
    echo "allocator:  $MONGODB_ALLOCATOR"
    echo "linker:     $MONGODB_LINKER"
    echo "js_engine:  none"
    echo "strip_debug: ${MONGODB_STRIP_DEBUG:-1}"
    echo "install:    $prefix"
    echo
    file "$bin/mongod"
    echo "relocs:     $(readelf -rW "$bin/mongod" | grep -c "$reloc_prefix" || true) entries"
    echo "rela.text:  $(readelf -SW "$bin/mongod" | grep -c '\.rela\.text' || true) section(s)"
    echo "size:       $(du -h "$bin/mongod" | cut -f1)"
    echo "size_stripped: $(stripped_size_bytes "$bin/mongod") bytes"
    echo "sha256:     $(sha256sum "$bin/mongod" | cut -d' ' -f1)"
    echo "version:    $("$bin/mongod" --version | head -1)"
  } > "$bin/build-info.txt"

  info "[$mode] built -> $bin/mongod"
  cat "$bin/build-info.txt"
}

ensure_dirs
for m in "${MODES[@]}"; do
  build_mode "$m"
done
