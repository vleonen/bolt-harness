#!/usr/bin/env bash
# Build MariaDB 11.4 LTS in a BOLT-friendly configuration.
#
# Usage: build.sh [pie|no-pie|all]...   (default: pie)
#
# Modes:
#   pie      position-independent executable (Ubuntu default), -Wl,-q
#   no-pie   fixed-address executable (-no-pie at link), -Wl,-q
#
# Each build is out-of-tree under $STATE/build/<mode> and installed under
# $STATE/installs/<mode>; the baseline server is copied to
# $BINARIES/<mode>/mariadbd together with build-info.txt.
#
# Executable-only link flags are injected through WITH_MYSQLD_LDFLAGS so the
# plugin .so objects (which must stay PIC) are not affected by -no-pie.
set -euo pipefail

APP="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_ROOT/lib/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
usage: build.sh [pie|no-pie|all]...   (default: pie)

Builds MariaDB (mariadbd + client tools) out-of-tree, installs it under
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
  local flags="-O2 -fno-omit-frame-pointer -fno-stack-protector -mbranch-protection=none"
  # GCC 8+ enables -freorder-blocks-and-partition at -O2; BOLT is incompatible.
  case "$CC" in
    *gcc*) flags="$flags -fno-reorder-blocks-and-partition" ;;
  esac
  echo "$flags"
}

mariadbd_ldflags() { # <mode>
  case "$1" in
    pie)     echo "-Wl,-q" ;;
    no-pie)  echo "-no-pie -Wl,-q" ;;
  esac
}

build_mode() { # <mode>
  local mode="$1" cflags ldflags src build prefix bin server cand
  cflags="$(build_cflags "$mode")"
  ldflags="$(mariadbd_ldflags "$mode")"
  src="${APP_SRC:-$WORK/$APP}"
  build="$STATE/build/$mode"
  prefix="$(app_basedir "$mode")"
  bin="$BINARIES/$mode"
  mkdir -p "$build" "$prefix" "$bin"

  [ -d "$src" ] || die "MariaDB source not found at $src (set APP_SRC or clone it)"

  info "Configuring MariaDB [$mode]: CC=$CC CXX=$CXX"
  info "  C/CXX flags: $cflags"
  info "  mariadbd link flags: $ldflags"
  cmake -S "$src" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE="$MARIADB_BUILD_TYPE" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$cflags" \
    -DCMAKE_CXX_FLAGS="$cflags" \
    -DSECURITY_HARDENED=OFF \
    -DWITH_UNIT_TESTS=OFF \
    -DWITH_MARIABACKUP=OFF \
    -DWITH_SYSTEMD=no \
    -DWITH_WSREP=OFF \
    -DWITH_MYSQLD_LDFLAGS="$ldflags" \
    ${MARIADB_CMAKE_OPTS:-} \
    > "$STATE/configure-$mode.log" 2>&1 \
    || { tail -30 "$STATE/configure-$mode.log" >&2; die "cmake configure failed for [$mode]"; }

  info "Building MariaDB [$mode] (-j$BUILD_JOBS)"
  ninja -C "$build" -j "$BUILD_JOBS" \
    > "$STATE/build-$mode.log" 2>&1 \
    || { tail -50 "$STATE/build-$mode.log" >&2; die "MariaDB build failed for [$mode]"; }

  info "Installing MariaDB [$mode] -> $prefix"
  cmake --install "$build" \
    > "$STATE/install-$mode.log" 2>&1 \
    || { tail -30 "$STATE/install-$mode.log" >&2; die "MariaDB install failed for [$mode]"; }

  local server="" cand
  for cand in "$prefix/sbin/mariadbd" "$prefix/bin/mariadbd"; do
    [ -x "$cand" ] && { server="$cand"; break; }
  done
  [ -n "$server" ] || die "mariadbd not found under $prefix/{sbin,bin} after install"
  cp "$server" "$bin/mariadbd"

  {
    echo "app:        $APP ($MARIADB_VERSION)"
    echo "mode:       $mode"
    echo "date:       $(date -Is)"
    echo "CC:         $CC ($($CC --version | head -1))"
    echo "CXX:        $CXX ($($CXX --version | head -1))"
    echo "CFLAGS:     $cflags"
    echo "MYSQLD_LDFLAGS: $ldflags"
    echo "install:    $prefix"
    echo
    file "$bin/mariadbd"
    echo "relocs:     $(readelf -rW "$bin/mariadbd" | grep -c 'R_AARCH64' || true) entries"
    echo "rela.text:  $(readelf -SW "$bin/mariadbd" | grep -c '\.rela\.text' || true) section(s)"
    echo "size:       $(du -h "$bin/mariadbd" | cut -f1)"
    echo "sha256:     $(sha256sum "$bin/mariadbd" | cut -d' ' -f1)"
    echo "version:    $("$bin/mariadbd" --version)"
  } > "$bin/build-info.txt"

  info "[$mode] built -> $bin/mariadbd"
  cat "$bin/build-info.txt"
}

ensure_dirs
for m in "${MODES[@]}"; do
  build_mode "$m"
done
