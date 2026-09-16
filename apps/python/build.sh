#!/usr/bin/env bash
# Build CPython 3.13 in a BOLT-friendly configuration.
#
# Usage: build.sh [pie|no-pie|all]...   (default: pie)
#
# Modes (each selects a different BOLT target):
#   pie      shared libpython (--enable-shared). BOLT optimizes
#            libpython3.13.so.1.0, loaded at runtime by the installed
#            `python3` launcher via LD_LIBRARY_PATH.
#   no-pie   static non-PIE `python3` executable (libpython linked in). BOLT
#            optimizes the executable.
#
# Each build is out-of-tree under $STATE/build/<mode> and installed under
# $STATE/installs/<mode>. The BOLT target is snapshotted under
# $BINARIES/<mode>/ together with build-info.txt, and the pyperformance
# benchmark stack is installed offline from $WHEELHOUSE into the prefix.
set -euo pipefail

APP="$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HARNESS_ROOT/lib/common.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
usage: build.sh [pie|no-pie|all]...   (default: pie)

Builds CPython out-of-tree, installs it under $STATE/installs/<mode>, installs
the pyperformance stack from $WHEELHOUSE, and snapshots the BOLT target under
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
# Compiler, version and BOLT-friendly flags
# ---------------------------------------------------------------------------
: "${CC:=gcc}"
: "${PYTHON_VERSION:=v3.13.9}"
: "${PYTHON_SHORT_VER:=3.13}"
: "${WHEELHOUSE:=/wheelhouse}"
: "${PYPERFORMANCE_VERSION:=1.14.0}"

build_cflags() { # <mode>
  local flags="-O2 -fno-omit-frame-pointer -fno-stack-protector" arch_flags
  arch_flags="$(harness_cflags_arch)"        # aarch64: -mbranch-protection=none
  [ -n "$arch_flags" ] && flags="$flags $arch_flags"
  # GCC 8+ enables -freorder-blocks-and-partition at -O2; BOLT is incompatible.
  case "$CC" in
    *gcc*) flags="$flags -fno-reorder-blocks-and-partition" ;;
  esac
  echo "$flags"
}

build_mode() { # <mode>
  local mode="$1" cflags src build prefix bin tgt soname reloc_prefix
  cflags="$(build_cflags "$mode")"
  src="${APP_SRC:-$WORK/$APP}"
  build="$STATE/build/$mode"
  prefix="$(app_basedir "$mode")"
  bin="$BINARIES/$mode"
  mkdir -p "$build" "$prefix" "$bin"

  [ -d "$src" ] || die "CPython source not found at $src (set APP_SRC or clone it)"
  [ -x "$src/configure" ] || die "$src/configure not found (is $src a CPython source tree?)"

  # computed gotos: BOLT cannot instrument the label-address dispatch table, so
  # CPython's own BOLT support skips _PyEval_EvalFrameDefault and the regex
  # matchers via -skip-funcs (see app.sh). PY_COMPUTED_GOTO=0 additionally
  # builds a plain switch-based eval loop, the fallback if -instrument crashes.
  local -a goto_opt=()
  if [ "${PY_COMPUTED_GOTO:-1}" = 1 ]; then
    goto_opt=(--with-computed-gotos)
  else
    goto_opt=(--with-computed-gotos=no)
    info "  computed gotos: disabled (switch-based eval loop)"
  fi

  # Shared (pie) must stay PIC. For no-pie, -fno-pie is applied through
  # CFLAGS_NODIST (build-only: configure's conftest links stay PIE) and -no-pie
  # only through LINKCC (executables: python/_bootstrap_python/_freeze_module).
  # -no-pie must NOT be in LDFLAGS: `gcc -shared -no-pie` builds an executable.
  local -a mode_env=(OPT="-O2 -Wall" LDFLAGS="-Wl,-q")
  local -a shared_opt=()
  if [ "$mode" = no-pie ]; then
    mode_env=(OPT="-O2 -Wall" LDFLAGS="-Wl,-q"
              LINKCC="$CC -fno-pie -no-pie" CFLAGS_NODIST="-fno-pie")
  else
    shared_opt=(--enable-shared)
  fi

  info "Configuring CPython [$mode]: CC=$CC"
  info "  CFLAGS:        $cflags"
  info "  mode env:      ${mode_env[*]}"
  # shellcheck disable=SC2086  # PYTHON_CONFIGURE_OPTS is intentionally word-split
  ( cd "$build" && env CFLAGS="$cflags" "${mode_env[@]}" \
      "$src/configure" \
        --prefix="$prefix" \
        --with-ensurepip=install \
        --disable-test-modules \
        "${goto_opt[@]}" \
        "${shared_opt[@]}" \
        ${PYTHON_CONFIGURE_OPTS:-} ) \
    > "$STATE/configure-$mode.log" 2>&1 \
    || { tail -30 "$STATE/configure-$mode.log" >&2; die "configure failed for [$mode]"; }

  info "Building CPython [$mode] (-j$BUILD_JOBS)"
  make -C "$build" -j "$BUILD_JOBS" \
    > "$STATE/build-$mode.log" 2>&1 \
    || { tail -50 "$STATE/build-$mode.log" >&2; die "CPython build failed for [$mode]"; }

  info "Installing CPython [$mode] -> $prefix"
  make -C "$build" install \
    > "$STATE/install-$mode.log" 2>&1 \
    || { tail -30 "$STATE/install-$mode.log" >&2; die "CPython install failed for [$mode]"; }

  info "Installing pyperformance==$PYPERFORMANCE_VERSION into $prefix (offline)"
  PIP_NO_INDEX=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1 \
  LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  PYTHONPATH= "$prefix/bin/python3" -m pip install \
      --no-index --find-links "$WHEELHOUSE" \
      "pyperformance==$PYPERFORMANCE_VERSION" \
      > "$STATE/pip-$mode.log" 2>&1 \
    || { tail -30 "$STATE/pip-$mode.log" >&2; die "pip install of pyperformance failed for [$mode]"; }

  # -------------------------------------------------------------------------
  # Snapshot the BOLT target
  # -------------------------------------------------------------------------
  case "$mode" in
    pie)
      local lib=""
      for cand in "$prefix"/lib/libpython*.so.1.0; do
        [ -f "$cand" ] && { lib="$cand"; break; }
      done
      [ -n "$lib" ] || die "shared libpython not found under $prefix/lib (was --enable-shared effective?)"
      soname="$(readelf -d "$lib" | awk -F'[][]' '/SONAME/{print $2; exit}')"
      [ -n "$soname" ] || soname="$(basename "$lib")"
      cp "$lib" "$bin/$soname"
      chmod +x "$bin/$soname"
      printf '%s\n' "$soname" > "$bin/.libpython-soname"
      tgt="$bin/$soname"
      ;;
    no-pie)
      [ -x "$prefix/bin/python3" ] || die "$prefix/bin/python3 not produced"
      cp "$prefix/bin/python3" "$bin/python3"
      chmod +x "$bin/python3"
      tgt="$bin/python3"
      ;;
  esac

  reloc_prefix="$(harness_reloc_prefix)"
  {
    echo "app:        $APP ($PYTHON_VERSION)"
    echo "mode:       $mode"
    echo "target:     $mode/$([ "$mode" = pie ] && echo shared-libpython || echo static-executable)"
    echo "arch:       $(uname -m)"
    echo "date:       $(date -Is)"
    echo "CC:         $CC ($($CC --version | head -1))"
    echo "CFLAGS:     $cflags"
    echo "OPT:        -O2 -Wall"
    echo "LDFLAGS:    -Wl,-q"
    [ "$mode" = no-pie ] && echo "CFLAGS_NODIST: -fno-pie"
    [ "$mode" = no-pie ] && echo "LINKCC:     $CC -fno-pie -no-pie"
    echo "computed gotos: $([ "${PY_COMPUTED_GOTO:-1}" = 1 ] && echo on || echo off)"
    echo "install:    $prefix"
    echo "BOLT target: $tgt"
    echo
    file "$tgt"
    echo "relocs:     $(readelf -rW "$tgt" | grep -c "$reloc_prefix" || true) entries"
    echo "rela.text:  $(readelf -SW "$tgt" | grep -c '\.rela\.text' || true) section(s)"
    echo "size:       $(du -h "$tgt" | cut -f1)"
    echo "size_stripped: $(stripped_size_bytes "$tgt") bytes"
    echo "sha256:     $(sha256sum "$tgt" | cut -d' ' -f1)"
    if [ "$mode" = pie ]; then
      echo "soname:     $soname"
      echo "NEEDED:"
      readelf -d "$tgt" | awk '/NEEDED/{print "  " $NF}'
      echo "version:    $(LD_LIBRARY_PATH="$prefix/lib" "$prefix/bin/python3" --version)"
    else
      echo "version:    $("$tgt" --version)"
      echo "interp:     $(readelf -lW "$tgt" | awk '/interpreter/{print $NF}' || true)"
    fi
  } > "$bin/build-info.txt"

  info "[$mode] BOLT target built -> $tgt"
  cat "$bin/build-info.txt"
}

ensure_dirs
for m in "${MODES[@]}"; do
  build_mode "$m"
done
