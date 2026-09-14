#!/usr/bin/env bash
# MariaDB 11.4 LTS adapter for the bolt-harness framework.
#
# Implements the application-specific hooks consumed by pipeline/*.sh:
#   app_variant_bin <mode> <which>   baseline / bolt / bolt-rewrite path
#   app_basedir <mode>               `cmake --install` prefix for runtime files
#   app_prepare_data <mode>          init datadir + sysbench dataset (once)
#   app_server_start <bin>           launch a server (globals below)
#   app_server_wait <port> <timeout> wait until the server answers ping
#   app_server_stop                  graceful shutdown of APP_PID
#   app_workload <outdir> <tag>      one sysbench pass over SYSBENCH_TESTS
#   app_parse_workload <rawfile>     normalized test<TAB>metric<TAB>value rows
#
# Server-start globals set by the caller before app_server_start:
#   APP_BASEDIR  install prefix
#   APP_DATADIR  data directory
#   APP_RUNDIR   directory for socket/pid/log files
#   APP_PORT     TCP port
#   APP_TAG      tag for per-process file names

# ---------------------------------------------------------------------------
# Ports / affinity
# ---------------------------------------------------------------------------
: "${PROFILE_PORT:=3307}"
: "${BENCH_PORT:=3308}"
: "${SERVER_CPUS:=0-3}"   # InnoDB is multi-threaded; give it the fast cores
: "${CLIENT_CPUS:=8-11}"

# ---------------------------------------------------------------------------
# Source / build
# ---------------------------------------------------------------------------
: "${MARIADB_VERSION:=mariadb-11.4.13}"
: "${APP_SRC:=$WORK/mariadb}"
: "${MARIADB_BUILD_TYPE:=Release}"

# ---------------------------------------------------------------------------
# Workload (sysbench OLTP)
# ---------------------------------------------------------------------------
: "${SYSBENCH_TABLES:=10}"
: "${SYSBENCH_TABLE_SIZE:=100000}"
: "${SYSBENCH_TESTS:=oltp_point_select,oltp_read_write}"
: "${SYSBENCH_THREADS:=16}"
: "${BENCH_TIME:=15}"            # seconds per test per rep
: "${WARMUP:=1}"
: "${REPS:=3}"
: "${PROFILE_SLEEP_TIME:=10}"    # instrumentation profile dump interval (s)
: "${PROFILE_TEST_TIME:=0}"      # 0 = auto (PROFILE_SLEEP_TIME + 5)

# ---------------------------------------------------------------------------
# Server tuning (applied for both profiling and benchmarking so the profile
# matches the workload)
# ---------------------------------------------------------------------------
: "${INNODB_BUFFER_POOL_SIZE:=4G}"
: "${MYSQLD_EXTRA_ARGS:=--skip-log-bin --innodb-flush-log-at-trx-commit=2 --innodb-doublewrite=0 --performance-schema=OFF --skip-name-resolve}"

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
app_name() { echo mariadb; }

app_describe() {
  echo "workload: sysbench tests=$SYSBENCH_TESTS time=${APP_WORKLOAD_TIME:-$BENCH_TIME}s threads=$SYSBENCH_THREADS tables=$SYSBENCH_TABLES table_size=$SYSBENCH_TABLE_SIZE"
  echo "tuning:   innodb_buffer_pool=$INNODB_BUFFER_POOL_SIZE ${MYSQLD_EXTRA_ARGS:-}"
}

app_basedir() { # <mode>
  echo "$INSTALLS/$1"
}

app_variant_bin() { # <mode> <baseline|bolt|bolt-rewrite>
  case "$2" in
    baseline)     echo "$BINARIES/$1/mariadbd" ;;
    bolt)         echo "$BINARIES/$1/mariadbd.bolt" ;;
    bolt-rewrite) echo "$BINARIES/$1/mariadbd.bolt-rewrite" ;;
    *) die "unknown variant '$2' (valid: $VALID_WHICH)" ;;
  esac
}

app_server_bin() { # <mode>  baseline server (installed tree preferred)
  local base b
  base="$(app_basedir "$1")"
  for b in "$base/sbin/mariadbd" "$base/bin/mariadbd"; do
    if [ -x "$b" ]; then echo "$b"; return 0; fi
  done
  echo "$BINARIES/$1/mariadbd"
}

app_install_db() { # <mode>
  local base
  base="$(app_basedir "$1")"
  if [ -x "$base/scripts/mariadb-install-db" ]; then
    echo "$base/scripts/mariadb-install-db"
  else
    echo "$base/bin/mariadb-install-db"
  fi
}
app_admin()      { echo "$(app_basedir "$1")/bin/mariadb-admin"; }
app_client()     { echo "$(app_basedir "$1")/bin/mariadb"; }

app_data_dir() { # <mode>
  echo "$STATE/data/$1"
}

# sysbench connection arguments for a running server.
_app_sysbench_conn() { # <port>
  echo "--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$1 --mysql-user=root --mysql-db=sbtest"
}

app_prepare_data() { # <mode>
  local mode="$1" datadir base marker bin rundir
  datadir="$(app_data_dir "$mode")"
  marker="$datadir/.bolt-harness-prepared"

  if [ -f "$marker" ]; then
    info "data already prepared: $datadir"
    return 0
  fi
  if [ "${RESET_DATA:-0}" = 1 ] && [ -d "$datadir" ]; then
    info "RESET_DATA=1: wiping $datadir"
    rm -rf "$datadir"
  fi

  base="$(app_basedir "$mode")"
  mkdir -p "$datadir" "$STATE/data"
  info "initializing MariaDB data directory: $datadir"
  "$(app_install_db "$mode")" --no-defaults \
      --basedir="$base" --datadir="$datadir" \
      --auth-root-authentication-method=normal --skip-test-db \
      > "$STATE/data-$mode-install.log" 2>&1 \
    || { tail -30 "$STATE/data-$mode-install.log" >&2; die "mariadb-install-db failed"; }

  rundir="$STATE/data/run-$mode"
  mkdir -p "$rundir"
  bin="$(app_server_bin "$mode")"
  APP_BASEDIR="$base" APP_DATADIR="$datadir" APP_RUNDIR="$rundir" \
  APP_PORT="$PROFILE_PORT" APP_TAG=prepare
  app_server_start "$bin"
  app_server_wait "$APP_PORT" 120 \
    || die "server did not start for data preparation (see $rundir)"

  info "creating database sbtest"
  "$(app_client "$mode")" --no-defaults --protocol=tcp -h127.0.0.1 -P "$APP_PORT" -u root \
    -e "CREATE DATABASE IF NOT EXISTS sbtest" \
    || die "failed to create sbtest database"

  info "preparing sysbench dataset (tables=$SYSBENCH_TABLES table-size=$SYSBENCH_TABLE_SIZE)"
  # shellcheck disable=SC2046
  pinned "$CLIENT_CPUS" sysbench $(_app_sysbench_conn "$APP_PORT") \
    --tables="$SYSBENCH_TABLES" --table-size="$SYSBENCH_TABLE_SIZE" \
    oltp_read_write prepare > "$STATE/data-$mode-prepare.log" 2>&1 \
    || { tail -30 "$STATE/data-$mode-prepare.log" >&2; die "sysbench prepare failed"; }

  app_server_stop
  touch "$marker"
  info "dataset ready: $datadir"
}

app_server_start() { # <bin>
  local bin="$1" log sock pidf
  log="$APP_RUNDIR/server-$APP_TAG.log"
  sock="$APP_RUNDIR/mysql-$APP_TAG.sock"
  pidf="$APP_RUNDIR/mariadb-$APP_TAG.pid"
  info "starting $APP_TAG server: $(basename "$bin") port=$APP_PORT cpus=${SERVER_CPUS:-off}"
  # shellcheck disable=SC2086  # MYSQLD_EXTRA_ARGS is intentionally word-split
  pinned_bg "$SERVER_CPUS" "$bin" --no-defaults \
    --basedir="$APP_BASEDIR" --datadir="$APP_DATADIR" \
    --port="$APP_PORT" --bind-address=127.0.0.1 --socket="$sock" \
    --pid-file="$pidf" --user=root \
    --log-error="$log" \
    --innodb-buffer-pool-size="$INNODB_BUFFER_POOL_SIZE" \
    $MYSQLD_EXTRA_ARGS
  APP_PID="$PINNED_PID"
}

app_server_wait() { # <port> <timeout>
  local port="$1" timeout="${2:-120}" i
  for ((i = 0; i < timeout * 10; i++)); do
    if [ -n "${APP_BASEDIR:-}" ] && \
       "$APP_BASEDIR/bin/mariadb-admin" --no-defaults --protocol=tcp \
         -h127.0.0.1 -P "$port" -u root ping >/dev/null 2>&1; then
      return 0
    fi
    kill -0 "${APP_PID:-1}" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

app_server_stop() {
  local pid="${APP_PID:-}"
  [ -n "$pid" ] || return 0
  if [ -n "${APP_BASEDIR:-}" ]; then
    "$APP_BASEDIR/bin/mariadb-admin" --no-defaults --protocol=tcp \
      -h127.0.0.1 -P "$APP_PORT" -u root shutdown 2>/dev/null \
      || kill "$pid" 2>/dev/null || true
  else
    kill "$pid" 2>/dev/null || true
  fi
  local _ 
  for _ in $(seq 1 200); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  APP_PID=""
}

# One pass over SYSBENCH_TESTS. Writes <outdir>/<tag>.<test>.txt for each test.
app_workload() { # <outdir> <tag>
  local outdir="$1" tag="$2" secs="${APP_WORKLOAD_TIME:-$BENCH_TIME}" t
  local -a tests
  IFS=',' read -ra tests <<< "$SYSBENCH_TESTS"
  mkdir -p "$outdir"
  for t in "${tests[@]}"; do
    info "sysbench $t (${secs}s, threads=$SYSBENCH_THREADS)"
    # shellcheck disable=SC2046
    pinned "$CLIENT_CPUS" sysbench $(_app_sysbench_conn "$APP_PORT") \
      --tables="$SYSBENCH_TABLES" --table-size="$SYSBENCH_TABLE_SIZE" \
      --threads="$SYSBENCH_THREADS" --time="$secs" --events=0 --report-interval=0 \
      "$t" run > "$outdir/$tag.$t.txt" 2> "$outdir/$tag.$t.txt.err" \
      || { tail -20 "$outdir/$tag.$t.txt.err" >&2; die "sysbench $t failed"; }
  done
}

app_parse_workload() { # <rawfile>  -> test<TAB>metric<TAB>value
  local f="$1" test
  test="$(basename "$f")"
  test="${test#*.}"
  test="${test%.txt}"
  awk -v t="$test" '
    /transactions:/ { s = $0; sub(/.*\(/, "", s); sub(/ per sec.*/, "", s); gsub(/ /, "", s); print t "\tTPS\t" s }
    /queries:/      { s = $0; sub(/.*\(/, "", s); sub(/ per sec.*/, "", s); gsub(/ /, "", s); print t "\tQPS\t" s }
    /^ *avg:/       { s = $0; sub(/.*avg:/, "", s); gsub(/ /, "", s); print t "\tlat_avg_ms\t" s; exit }
  ' "$f"
}
