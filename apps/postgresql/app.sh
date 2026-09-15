#!/usr/bin/env bash
# PostgreSQL 17 adapter for the bolt-harness framework.
#
# Implements the application-specific hooks consumed by pipeline/*.sh:
#   app_variant_bin <mode> <which>   baseline / bolt / bolt-rewrite path
#   app_basedir <mode>               installation prefix for runtime files
#   app_pgbin <mode> <tool>          installed PostgreSQL tool path
#   app_prepare_data <mode>          initdb + pgbench -i dataset (once)
#   app_server_start <bin>           launch `postgres` (globals below)
#   app_server_wait <port> <timeout> wait until pg_isready succeeds
#   app_server_stop                  graceful `pg_ctl -m fast` of APP_PID
#   app_workload <outdir> <tag>      one pgbench pass over PGBENCH_SCRIPTS
#   app_parse_workload <rawfile>     normalized test<TAB>metric<TAB>value rows
#
# PostgreSQL refuses to run as root, so the container runs as a non-root
# `postgres` user (see Dockerfile). No runuser wrapping is needed.
#
# Server-start globals set by the caller before app_server_start:
#   APP_BASEDIR  install prefix
#   APP_DATADIR  PGDATA
#   APP_RUNDIR   directory for logs, socket dir and pid file
#   APP_PORT     TCP port
#   APP_TAG      tag for per-process file names

# ---------------------------------------------------------------------------
# Ports / affinity
# ---------------------------------------------------------------------------
: "${PROFILE_PORT:=55432}"
: "${BENCH_PORT:=55433}"
# SERVER_CPUS / CLIENT_CPUS defaults are centralized in lib/common.sh
# (arch-aware and overridable from the environment).

# ---------------------------------------------------------------------------
# Source / build
# ---------------------------------------------------------------------------
: "${POSTGRES_VERSION:=REL_17_11}"
: "${APP_SRC:=$WORK/postgresql}"

# ---------------------------------------------------------------------------
# Workload (pgbench, bundled with the server)
# ---------------------------------------------------------------------------
: "${PGBENCH_SCRIPTS:=select-only,tpcb-like}"
: "${PGBENCH_SCALE:=100}"
: "${PGBENCH_CLIENTS:=16}"
: "${PGBENCH_JOBS:=4}"
: "${PGBENCH_TIME:=15}"
: "${PGBENCH_MODE:=prepared}"
: "${WARMUP:=1}"
: "${REPS:=3}"
: "${PROFILE_SLEEP_TIME:=10}"    # instrumentation profile dump interval (s)
: "${PROFILE_TEST_TIME:=0}"      # 0 = auto (PROFILE_SLEEP_TIME + 5)

# ---------------------------------------------------------------------------
# Server tuning (applied for both profiling and benchmarking)
# ---------------------------------------------------------------------------
: "${SHARED_BUFFERS:=4GB}"
: "${POSTGRES_EXTRA_ARGS:=}"

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
app_name() { echo postgresql; }

app_describe() {
  echo "workload: pgbench scripts=$PGBENCH_SCRIPTS time=${APP_WORKLOAD_TIME:-$PGBENCH_TIME}s clients=$PGBENCH_CLIENTS jobs=$PGBENCH_JOBS mode=$PGBENCH_MODE scale=$PGBENCH_SCALE"
  echo "tuning:   shared_buffers=$SHARED_BUFFERS ${POSTGRES_EXTRA_ARGS:-}"
}

app_basedir() { # <mode>
  echo "$INSTALLS/$1"
}

app_variant_bin() { # <mode> <baseline|bolt|bolt-rewrite|bolt-rewrite-nohuge>
  case "$2" in
    baseline)            echo "$BINARIES/$1/postgres" ;;
    bolt)                echo "$BINARIES/$1/postgres.bolt" ;;
    bolt-rewrite)        echo "$BINARIES/$1/postgres.bolt-rewrite" ;;
    bolt-rewrite-nohuge) echo "$BINARIES/$1/postgres.bolt-rewrite-nohuge" ;;
    *) die "unknown variant '$2' (valid: $VALID_WHICH)" ;;
  esac
}

app_server_bin() { # <mode>  baseline server (installed tree preferred)
  local base b
  base="$(app_basedir "$1")"
  for b in "$base/bin/postgres" "$BINARIES/$1/postgres"; do
    if [ -x "$b" ]; then echo "$b"; return 0; fi
  done
  echo "$BINARIES/$1/postgres"
}

app_pgbin() { # <mode> <tool>
  echo "$(app_basedir "$1")/bin/$2"
}

app_data_dir() { # <mode>
  echo "$STATE/data/$1/pgdata"
}

app_prepare_data() { # <mode>
  local mode="$1" datadir basedir marker rundir
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

  basedir="$(app_basedir "$mode")"
  mkdir -p "$datadir" "$STATE/data"
  info "initializing PostgreSQL data directory: $datadir"
  "$(app_pgbin "$mode" initdb)" -D "$datadir" -U postgres -A trust \
      --no-sync -E UTF-8 --locale=C \
      > "$STATE/data-$mode-initdb.log" 2>&1 \
    || { tail -30 "$STATE/data-$mode-initdb.log" >&2; die "initdb failed"; }

  rundir="$STATE/data/run-$mode"
  mkdir -p "$rundir"
  APP_BASEDIR="$basedir" APP_DATADIR="$datadir" APP_RUNDIR="$rundir" \
  APP_PORT="$PROFILE_PORT" APP_TAG=prepare
  app_server_start "$(app_server_bin "$mode")"
  app_server_wait "$APP_PORT" 120 \
    || die "server did not start for data preparation (see $rundir)"

  info "creating database pgbench"
  "$(app_pgbin "$mode" createdb)" -h 127.0.0.1 -p "$APP_PORT" -U postgres pgbench \
    || die "failed to create pgbench database"

  info "initializing pgbench dataset (scale=$PGBENCH_SCALE)"
  "$(app_pgbin "$mode" pgbench)" -i -s "$PGBENCH_SCALE" \
    -h 127.0.0.1 -p "$APP_PORT" -U postgres --no-vacuum pgbench \
    > "$STATE/data-$mode-pgbench.log" 2>&1 \
    || { tail -30 "$STATE/data-$mode-pgbench.log" >&2; die "pgbench -i failed"; }

  app_server_stop
  touch "$marker"
  info "dataset ready: $datadir"
}

app_server_start() { # <bin>
  local bin="$1" log sockdir
  local -a launcher=()
  log="$APP_RUNDIR/server-$APP_TAG.log"
  # Keep the Unix-socket dir short and fixed: PostgreSQL rejects socket paths
  # longer than 107 bytes, and APP_RUNDIR already embeds the (possibly long)
  # variant name and timestamp.
  sockdir="$APP_RUNDIR/s"
  mkdir -p "$sockdir"
  [ -n "${SERVER_CPUS:-}" ] && launcher=(taskset -c "$SERVER_CPUS")
  info "starting $APP_TAG server: $(basename "$bin") port=$APP_PORT cpus=${SERVER_CPUS:-off}"
  # shellcheck disable=SC2086  # POSTGRES_EXTRA_ARGS is intentionally word-split
  ( exec "${launcher[@]}" "$bin" \
      -D "$APP_DATADIR" -p "$APP_PORT" -k "$sockdir" -h 127.0.0.1 \
      -c shared_buffers="$SHARED_BUFFERS" \
      -c max_connections="$((PGBENCH_CLIENTS + 20))" \
      -c fsync=off -c synchronous_commit=off -c full_page_writes=off \
      -c autovacuum=off \
      $POSTGRES_EXTRA_ARGS > "$log" 2>&1 ) &
  APP_PID=$!
}

app_server_wait() { # <port> <timeout>
  local port="$1" timeout="${2:-120}" i
  for ((i = 0; i < timeout * 10; i++)); do
    if "$APP_BASEDIR/bin/pg_isready" -h 127.0.0.1 -p "$port" -U postgres -q; then
      return 0
    fi
    kill -0 "${APP_PID:-1}" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

app_server_stop() {
  local pid="${APP_PID:-}" ctl _
  [ -n "$pid" ] || return 0
  ctl="$APP_BASEDIR/bin/pg_ctl"
  if [ -x "$ctl" ]; then
    "$ctl" -D "$APP_DATADIR" -m fast -w -t 60 stop >/dev/null 2>&1 \
      || kill "$pid" 2>/dev/null || true
  else
    kill "$pid" 2>/dev/null || true
  fi
  for _ in $(seq 1 200); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  APP_PID=""
}

# One pass over PGBENCH_SCRIPTS. Writes <outdir>/<tag>.<script>.txt per script.
app_workload() { # <outdir> <tag>
  local outdir="$1" tag="$2" secs="${APP_WORKLOAD_TIME:-$PGBENCH_TIME}" script
  local -a scripts
  IFS=',' read -ra scripts <<< "$PGBENCH_SCRIPTS"
  mkdir -p "$outdir"
  for script in "${scripts[@]}"; do
    info "pgbench $script (${secs}s, clients=$PGBENCH_CLIENTS jobs=$PGBENCH_JOBS mode=$PGBENCH_MODE)"
    pinned "$CLIENT_CPUS" "$APP_BASEDIR/bin/pgbench" \
      -h 127.0.0.1 -p "$APP_PORT" -U postgres --dbname=pgbench \
      -c "$PGBENCH_CLIENTS" -j "$PGBENCH_JOBS" -T "$secs" -M "$PGBENCH_MODE" \
      -n -b "$script" > "$outdir/$tag.$script.txt" 2> "$outdir/$tag.$script.txt.err" \
      || { tail -20 "$outdir/$tag.$script.txt.err" >&2; die "pgbench $script failed"; }
  done
}

app_parse_workload() { # <rawfile>  -> test<TAB>metric<TAB>value
  local f="$1" test
  test="$(basename "$f")"
  test="${test#*.}"
  test="${test%.txt}"
  awk -v t="$test" '
    /tps = / && !seen_tps {
      s = $0; sub(/.*tps = /, "", s); sub(/ .*/, "", s); print t "\tTPS\t" s; seen_tps = 1
    }
    /latency average = / {
      s = $0; sub(/.*latency average = /, "", s); sub(/ .*/, "", s); print t "\tlat_avg_ms\t" s
    }
  ' "$f"
}
