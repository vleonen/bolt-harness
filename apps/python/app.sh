#!/usr/bin/env bash
# CPython 3.13 adapter for the bolt-harness framework.
#
# Two configurations, mapped onto the pie/no-pie modes:
#   pie      shared libpython (--enable-shared). The BOLT target is
#            libpython3.13.so.1.0; the installed `python3` launcher loads the
#            selected variant via LD_LIBRARY_PATH.
#   no-pie   static non-PIE `python3` executable. The BOLT target is the
#            executable itself and is run directly.
#
# There is no persistent server: `app_server_start` just records the target
# (and stages the shared library under its SONAME), app_workload runs the
# pyperformance suite in fresh interpreter processes, and wait/stop are no-ops.
#
# Implements the application-specific hooks consumed by pipeline/*.sh:
#   app_variant_bin <mode> <which>   baseline / bolt / bolt-rewrite path
#   app_basedir <mode>               install prefix
#   app_server_bin <mode>            installed launcher
#   app_prepare_data <mode>          one-time marker + bytecode precompile
#   app_server_start <bin>           record the target (+ stage a .so)
#   app_server_wait/stop             no-ops
#   app_workload <outdir> <tag>      one pyperformance pass
#   app_parse_workload <rawfile>     normalized test<TAB>metric<TAB>value rows
#   app_verify_bin <mode> <variant> <path>   health check for a .so target
#
# Server-start globals set by the caller before app_server_start:
#   APP_BASEDIR  install prefix
#   APP_DATADIR  unused (kept for the generic pipeline)
#   APP_RUNDIR   directory for logs/staging
#   APP_PORT     unused TCP port (kept for the generic pipeline)
#   APP_TAG      tag for per-run file names

# ---------------------------------------------------------------------------
# Ports (unused, but the generic pipeline guards against a busy port)
# ---------------------------------------------------------------------------
: "${PROFILE_PORT:=39100}"
: "${BENCH_PORT:=39101}"

# ---------------------------------------------------------------------------
# Source / version
# ---------------------------------------------------------------------------
: "${PYTHON_VERSION:=v3.13.9}"
: "${PYTHON_SHORT_VER:=3.13}"
: "${APP_SRC:=$WORK/python}"

# ---------------------------------------------------------------------------
# Workload (pyperformance)
# ---------------------------------------------------------------------------
# Curated, dependency-free (pyperf-only) benchmarks that exercise the
# interpreter core; override with a comma-separated --benchmarks selection.
: "${PYTHON_BENCH_TESTS:=python_startup,nbody,spectral_norm,fannkuch,pyflate,deltablue,richards,json_dumps,json_loads,regex_v8,regex_compile,pickle,pickle_pure_python,unpickle_pure_python,go,hexiom,nqueens,scimark,float,telco}"
: "${PYTHON_BENCH_ARGS:=--fast}"
: "${PYTHON_DRIVER_PY:=}"           # empty = run the driver with the target interpreter
: "${PYPERFORMANCE_VERSION:=1.14.0}"
: "${WARMUP:=1}"
: "${REPS:=3}"
# pyperformance forks a worker per benchmark; BOLT's periodic dump thread
# deadlocks with that, so rely on BOLT's dump-at-exit (sleep-time 0, BOLT's
# default). profile.sh then only sleeps ~3s and merges the per-process files.
: "${PROFILE_SLEEP_TIME:=0}"
: "${PROFILE_TEST_TIME:=0}"

# ---------------------------------------------------------------------------
# BOLT flags
# ---------------------------------------------------------------------------
# CPython uses computed-goto dispatch in the eval loop and the regex matchers;
# LLVM BOLT < 20 misdetects the label-address tables, so exclude those
# functions from instrumentation (this mirrors CPython's own --enable-bolt
# support). PY_COMPUTED_GOTO=0 removes the tables entirely at build time if
# -instrument still crashes.
: "${PY_COMPUTED_GOTO:=1}"
PY_SKIP_FUNCS="_PyEval_EvalFrameDefault,sre_ucs1_match/1,sre_ucs2_match/1,sre_ucs4_match/1"
# pyperformance forks a worker per benchmark; append-pid keeps their profiles
# separate (profile.sh globs profile*.fdata* and merge-fdata merges them).
# PY_INSTR_SKIP_FUNCS=0 drops -skip-funcs from instrumentation so the profile
# also covers the computed-goto functions (eval loop, sre matchers); only
# meaningful on BOLT builds that recognize those label tables as jump tables.
: "${PY_INSTR_SKIP_FUNCS:=1}"
BOLT_INSTRUMENT_EXTRA_FLAGS="${BOLT_INSTRUMENT_EXTRA_FLAGS:-} -instrumentation-file-append-pid"
if [ "${PY_INSTR_SKIP_FUNCS}" = 1 ]; then
  BOLT_INSTRUMENT_EXTRA_FLAGS="$BOLT_INSTRUMENT_EXTRA_FLAGS -skip-funcs=$PY_SKIP_FUNCS"
fi
# Do NOT skip functions in the optimization pass on any arch: skipped
# functions are neither disassembled nor emitted, and `-rewrite` re-lays-out
# the whole binary and rejects -skip-funcs (skipped functions would leave
# callers branching into reused addresses, silently corrupting the output).
# The optimization pass no longer needs the skip either: BOLT now recognizes
# computed-goto label-address tables as jump tables on x86_64 (register-held
# table bases, notrack-prefixed indirect jumps, R_X86_64_RELATIVE table
# entries in PIE, unrelocated absolute entries in non-PIE), so `bolt` and the
# `-rewrite` variants run over every function on every arch.
# No -use-gnu-stack here: it is incompatible with the experimental -rewrite pass.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Installed SONAME of the shared libpython (recorded by build.sh).
_libpy_soname() {
  local f="$BINARIES/pie/.libpython-soname"
  if [ -r "$f" ]; then cat "$f"; else echo "libpython${PYTHON_SHORT_VER}.so.1.0"; fi
}

# True when <path> is the shared libpython target (as opposed to an executable).
_is_shared_bin() {
  case "$1" in
    *.so*) return 0 ;;
    *)     return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
app_name() { echo python; }

app_describe() {
  echo "workload: pyperformance tests=$PYTHON_BENCH_TESTS args=${PYTHON_BENCH_ARGS:-}"
  echo "target:   mode=$([ -n "${APP_LD_PATH:-}" ] && echo shared-libpython || echo executable) bin=${APP_PY:-n/a}"
  if [ -n "${APP_LD_PATH:-}" ]; then
    echo "ld_path:  $APP_LD_PATH"
  fi
  return 0
}

app_basedir() { # <mode>
  echo "$INSTALLS/$1"
}

app_server_bin() { # <mode>  installed launcher
  echo "$(app_basedir "$1")/bin/python3"
}

app_variant_bin() { # <mode> <baseline|bolt|bolt-rewrite|bolt-rewrite-nohuge>
  local mode="$1" which="$2" base
  case "$mode" in
    pie)    base="$BINARIES/pie/$(_libpy_soname)" ;;
    no-pie) base="$BINARIES/no-pie/python3" ;;
    *)      die "unknown mode '$mode' (valid: $VALID_MODES)" ;;
  esac
  case "$which" in
    baseline)            echo "$base" ;;
    bolt)                echo "$base.bolt" ;;
    bolt-rewrite)        echo "$base.bolt-rewrite" ;;
    bolt-rewrite-nohuge) echo "$base.bolt-rewrite-nohuge" ;;
    *) die "unknown variant '$which' (valid: $VALID_WHICH)" ;;
  esac
}

app_data_dir() { # <mode>
  echo "$STATE/data/$1"
}

app_prepare_data() { # <mode>
  local mode="$1" datadir marker base
  datadir="$(app_data_dir "$mode")"
  marker="$datadir/.bolt-harness-prepared"

  if [ "${RESET_DATA:-0}" = 1 ] && [ -d "$datadir" ]; then
    info "RESET_DATA=1: wiping $datadir"
    rm -rf "$datadir"
  fi
  if [ -f "$marker" ]; then
    info "data already prepared: $datadir"
    return 0
  fi

  mkdir -p "$datadir"
  base="$(app_basedir "$mode")"
  # Precompile the benchmark scripts with the baseline interpreter to reduce
  # first-run variance; bytecode is shared by every variant of this mode.
  if [ -x "$base/bin/python3" ]; then
    local sp="$base/lib/python${PYTHON_SHORT_VER}/site-packages/pyperformance"
    [ -d "$sp" ] && "$base/bin/python3" -m compileall -q "$sp" >/dev/null 2>&1 || true
  fi
  touch "$marker"
  info "dataset ready: $datadir"
}

app_server_start() { # <bin>
  local bin="$1" stage soname
  APP_PID=""
  APP_LD_PATH=""
  if _is_shared_bin "$bin"; then
    APP_PY="$APP_BASEDIR/bin/python3"
    stage="$APP_RUNDIR/stage-$APP_TAG"
    soname="$(_libpy_soname)"
    mkdir -p "$stage"
    ln -sf "$bin" "$stage/$soname"
    APP_LD_PATH="$stage:$APP_BASEDIR/lib"
    info "starting $APP_TAG: $(basename "$bin") loaded by $(basename "$APP_PY") (LD_LIBRARY_PATH=$APP_LD_PATH)"
  else
    APP_PY="$bin"
    info "starting $APP_TAG: $(basename "$bin")"
  fi
}

app_server_wait() { # <port> <timeout>
  return 0
}

app_server_stop() {
  APP_PID=""
  return 0
}

# One pyperformance pass. Writes <outdir>/<tag>.pyperformance.{json,txt}.
app_workload() { # <outdir> <tag>
  local outdir="$1" tag="$2" driver benchmarks_dir driver_py
  driver="$APP_DIR/bench/run_pyperformance.py"
  mkdir -p "$outdir"

  [ -n "${APP_PY:-}" ] || die "app_server_start was not called before app_workload"
  if [ -n "${APP_LD_PATH:-}" ]; then
    export LD_LIBRARY_PATH="$APP_LD_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
  [ -x "$APP_PY" ] || [ -L "$APP_PY" ] || die "target interpreter missing: $APP_PY"
  # The driver imports pyperf, which is installed in the target prefix.
  driver_py="${PYTHON_DRIVER_PY:-$APP_PY}"

  benchmarks_dir="$("$APP_PY" -c 'import os, pyperformance; print(os.path.join(os.path.dirname(pyperformance.__file__), "data-files", "benchmarks"))' 2>/dev/null || true)"
  [ -n "$benchmarks_dir" ] && [ -d "$benchmarks_dir" ] \
    || die "pyperformance benchmarks dir not found (is pyperformance installed in $APP_BASEDIR?)"

  info "pyperformance ($tag): tests=$PYTHON_BENCH_TESTS args=${PYTHON_BENCH_ARGS:-}"
  # shellcheck disable=SC2086  # PYTHON_BENCH_ARGS is intentionally word-split
  pinned "$SERVER_CPUS" "$driver_py" "$driver" \
    --python "$APP_PY" \
    --benchmarks-dir "$benchmarks_dir" \
    --benchmarks "$PYTHON_BENCH_TESTS" \
    --output "$outdir/$tag.pyperformance.json" \
    --tsv "$outdir/$tag.pyperformance.txt" \
    $PYTHON_BENCH_ARGS \
    > "$outdir/$tag.pyperformance.stdout" 2> "$outdir/$tag.pyperformance.stderr" \
    || { tail -30 "$outdir/$tag.pyperformance.stderr" >&2; die "pyperformance run failed ($tag)"; }
}

app_parse_workload() { # <rawfile>  -> test<TAB>metric<TAB>value
  local f="$1"
  [ -f "$f" ] || return 0
  cat "$f"
}

# Health check used by optimize.sh for targets that are not directly runnable.
# Imports pyperf/pyperformance as well as printing the version: a miscompiled
# -rewrite library can survive --version but crash on real imports. The hook
# owns its timeout (BOLT_VERIFY_TIMEOUT) as required by the contract.
app_verify_bin() { # <mode> <variant> <path>
  local mode="$1" variant="$2" path="$3" base soname tmp rc
  base="$(app_basedir "$mode")"
  : "$variant"
  local smoke='import sys, pyperf, pyperformance; print(sys.version)'
  if _is_shared_bin "$path"; then
    soname="$(_libpy_soname)"
    tmp="$(mktemp -d)"
    ln -sf "$path" "$tmp/$soname"
    timeout "${BOLT_VERIFY_TIMEOUT:-30}" env \
      LD_LIBRARY_PATH="$tmp:$base/lib" "$base/bin/python3" -c "$smoke"
    rc=$?
    rm -rf "$tmp"
    return "$rc"
  fi
  timeout "${BOLT_VERIFY_TIMEOUT:-30}" "$path" -c "$smoke"
}
