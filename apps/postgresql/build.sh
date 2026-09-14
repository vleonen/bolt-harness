#!/usr/bin/env bash
# Build PostgreSQL 17 in a BOLT-friendly configuration.
#
# Usage: build.sh [pie|no-pie|all]...   (default: pie)
#
# Modes:
#   pie      position-independent executable (Ubuntu default), -Wl,-q
#   no-pie   fixed-address executable (-no-pie at link), -Wl,-q
#
# BOLT-friendly link flags are passed through LDFLAGS_EX, which PostgreSQL
# applies to executables only; shared modules use LDFLAGS_SL and stay PIC.
#
# Each build is an out-of-tree (VPATH) build under $STATE/build/<mode> and
# installed under $STATE/installs/<mode>; the baseline server is copied to
# $BINARIES/<mode>/postgres together with build-info.txt.
set -euo pipefail

APP="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_ROOT/lib/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
usage: build.sh [pie|no-pie|all]...   (default: pie)

Builds PostgreSQL (postgres + client tools) out-of-tree, installs it under
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

build_cflags() { # <mode>
  local flags="-O2 -fno-omit-frame-pointer -fno-stack-protector -mbranch-protection=none"
  # GCC 8+ enables -freorder-blocks-and-partition at -O2; BOLT is incompatible.
  case "$CC" in
    *gcc*) flags="$flags -fno-reorder-blocks-and-partition" ;;
  esac
  echo "$flags"
}

ex_ldflags() { # <mode>
  case "$1" in
    pie)     echo "-Wl,-q" ;;
    no-pie)  echo "-no-pie -Wl,-q" ;;
  esac
}

build_mode() { # <mode>
  local mode="$1" cflags ldflags src build prefix bin server
  cflags="$(build_cflags "$mode")"
  ldflags="$(ex_ldflags "$mode")"
  src="${APP_SRC:-$WORK/$APP}"
  build="$STATE/build/$mode"
  prefix="$(app_basedir "$mode")"
  bin="$BINARIES/$mode"
  mkdir -p "$build" "$prefix" "$bin"

  [ -d "$src" ] || die "PostgreSQL source not found at $src (set APP_SRC or clone it)"
  [ -x "$src/configure" ] || die "$src/configure not found (is $src a PostgreSQL source tree?)"

  info "Configuring PostgreSQL [$mode]: CC=$CC"
  info "  CFLAGS:        $cflags"
  info "  LDFLAGS_EX:    $ldflags"
  # shellcheck disable=SC2086  # POSTGRES_CONFIGURE_OPTS is intentionally word-split
  ( cd "$build" && CC="$CC" CFLAGS="$cflags" LDFLAGS_EX="$ldflags" \
      "$src/configure" \
        --prefix="$prefix" \
        --without-icu \
        --without-readline \
        --without-zlib \
        --without-llvm \
        ${POSTGRES_CONFIGURE_OPTS:-} ) \
    > "$STATE/configure-$mode.log" 2>&1 \
    || { tail -30 "$STATE/configure-$mode.log" >&2; die "configure failed for [$mode]"; }

  info "Building PostgreSQL [$mode] (-j$BUILD_JOBS)"
  make -C "$build" -j "$BUILD_JOBS" \
    > "$STATE/build-$mode.log" 2>&1 \
    || { tail -50 "$STATE/build-$mode.log" >&2; die "PostgreSQL build failed for [$mode]"; }

  info "Installing PostgreSQL [$mode] -> $prefix"
  make -C "$build" install \
    > "$STATE/install-$mode.log" 2>&1 \
    || { tail -30 "$STATE/install-$mode.log" >&2; die "PostgreSQL install failed for [$mode]"; }

  server="$prefix/bin/postgres"
  [ -x "$server" ] || die "$server not produced"
  cp "$server" "$bin/postgres"

  {
    echo "app:        $APP ($POSTGRES_VERSION)"
    echo "mode:       $mode"
    echo "date:       $(date -Is)"
    echo "CC:         $CC ($($CC --version | head -1))"
    echo "CFLAGS:     $cflags"
    echo "LDFLAGS_EX: $ldflags"
    echo "install:    $prefix"
    echo
    file "$bin/postgres"
    echo "relocs:     $(readelf -rW "$bin/postgres" | grep -c 'R_AARCH64' || true) entries"
    echo "rela.text:  $(readelf -SW "$bin/postgres" | grep -c '\.rela\.text' || true) section(s)"
    echo "size:       $(du -h "$bin/postgres" | cut -f1)"
    echo "sha256:     $(sha256sum "$bin/postgres" | cut -d' ' -f1)"
    echo "version:    $("$bin/postgres" --version)"
  } > "$bin/build-info.txt"

  info "[$mode] built -> $bin/postgres"
  cat "$bin/build-info.txt"
}

ensure_dirs
for m in "${MODES[@]}"; do
  build_mode "$m"
done
