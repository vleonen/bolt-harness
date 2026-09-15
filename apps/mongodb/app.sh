#!/usr/bin/env bash
# MongoDB 7.0 adapter for the bolt-harness framework.
#
# Implements the application-specific hooks consumed by pipeline/*.sh:
#   app_variant_bin <mode> <which>   baseline / bolt / bolt-rewrite path
#   app_basedir <mode>               installation prefix for runtime files
#   app_prepare_data <mode>          init WiredTiger dbpath + YCSB load (once)
#   app_server_start <bin>           launch `mongod` (globals below)
#   app_server_wait <port> <timeout> wait until mongosh `ping` succeeds
#   app_server_stop                  graceful shutdownServer of APP_PID
#   app_workload <outdir> <tag>      one YCSB pass over YCSB_WORKLOADS
#   app_parse_workload <rawfile>     normalized test<TAB>metric<TAB>value rows
#
# MongoDB runs as root, so the container shares the root work/ tree (like
# MariaDB) and uses work/_state/mongodb/.
#
# Server-start globals set by the caller before app_server_start:
#   APP_BASEDIR  install prefix
#   APP_DATADIR  WiredTiger --dbpath
#   APP_RUNDIR   directory for logs
#   APP_PORT     TCP port
#   APP_TAG      tag for per-process file names

# ---------------------------------------------------------------------------
# Ports / affinity
# ---------------------------------------------------------------------------
: "${PROFILE_PORT:=27018}"
: "${BENCH_PORT:=27019}"
# SERVER_CPUS / CLIENT_CPUS defaults are centralized in lib/common.sh
# (arch-aware and overridable from the environment).

# ---------------------------------------------------------------------------
# Source / build
# ---------------------------------------------------------------------------
: "${MONGODB_VERSION:=r7.0.43}"
: "${APP_SRC:=$WORK/mongodb}"
: "${MONGODB_ALLOCATOR:=system}"        # system | tcmalloc | auto
: "${MONGODB_LINKER:=gold}"             # bfd | gold | lld | auto
: "${MONGODB_SEPARATE_DEBUG:=off}"      # on shrinks the BOLT input (external .debug)
: "${MONGODB_STRIP_DEBUG:=1}"           # strip DWARF from the BOLT input (keeps symtab)
: "${MONGO_JOBS:=4}"                    # MongoDB TUs are memory-hungry

# ---------------------------------------------------------------------------
# Client tooling (prepared by apps/mongodb/rebuild.sh)
# ---------------------------------------------------------------------------
: "${MONGOSH_BIN:=mongosh}"
: "${MONGODB_PYTHON:=$WORK/mongodb/venv/bin/python3}"
: "${YCSB_DIR:=$WORK/ycsb}"            # constructed YCSB distribution
: "${YCSB_DATABASE:=mongodb}"          # YCSB binding (mongodb-driver-sync)
: "${YCSB_DBNAME:=ycsb}"

# ---------------------------------------------------------------------------
# Workload (YCSB)
# ---------------------------------------------------------------------------
: "${YCSB_WORKLOADS:=workloada,workloadc}"
: "${YCSB_RECORDCOUNT:=2000000}"
: "${YCSB_FIELDCOUNT:=10}"
: "${YCSB_THREADS:=16}"
: "${YCSB_TIME:=15}"                   # seconds per workload per rep
# YCSB stops at whichever of operationcount / maxexecutiontime is reached
# first; the harness is time-based, so operationcount is set effectively
# unlimited and maxexecutiontime (from APP_WORKLOAD_TIME) bounds each run.
: "${YCSB_OPERATIONCOUNT:=1000000000}"
: "${WARMUP:=1}"
: "${REPS:=3}"
: "${PROFILE_SLEEP_TIME:=10}"          # instrumentation profile dump interval (s)
: "${PROFILE_TEST_TIME:=0}"            # 0 = auto (PROFILE_SLEEP_TIME + 5)

# ---------------------------------------------------------------------------
# Server tuning (applied for both profiling and benchmarking)
# ---------------------------------------------------------------------------
: "${MONGODB_CACHE_GB:=4}"             # WiredTiger cache, sized to hold the dataset
: "${MONGODB_EXTRA_ARGS:=}"
: "${MONGO_START_TIMEOUT:=300}"        # instrumented mongod can start slowly

# mongod is large (148k functions, ~2.4M relocations). BOLT's default
# multithreaded pass peaks above the RAM of a typical 16 GB machine and gets
# OOM-killed while emitting the instrumented binary; --no-threads keeps it
# within memory. It is appended to any caller-supplied values so aarch64 can
# still add --drop-cortex-a53-843419-veneers.
if [ "${MONGODB_BOLT_NO_THREADS:-1}" = 1 ]; then
  case " ${BOLT_INSTRUMENT_EXTRA_FLAGS:-} " in
    *" --no-threads "*) ;;
    *) export BOLT_INSTRUMENT_EXTRA_FLAGS="${BOLT_INSTRUMENT_EXTRA_FLAGS:-} --no-threads" ;;
  esac
  case " ${BOLT_OPT_FLAGS:-} " in
    *" --no-threads "*) ;;
    *) export BOLT_OPT_FLAGS="${BOLT_OPT_FLAGS:-} --no-threads" ;;
  esac
fi

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------
app_name() { echo mongodb; }

app_describe() {
  echo "workload: ycsb binding=$YCSB_DATABASE db=$YCSB_DBNAME workloads=$YCSB_WORKLOADS time=${APP_WORKLOAD_TIME:-$YCSB_TIME}s threads=$YCSB_THREADS records=$YCSB_RECORDCOUNT fields=$YCSB_FIELDCOUNT"
  echo "tuning:   wiredTigerCacheSizeGB=$MONGODB_CACHE_GB allocator=$MONGODB_ALLOCATOR ${MONGODB_EXTRA_ARGS:-}"
}

app_basedir() { # <mode>
  echo "$INSTALLS/$1"
}

app_variant_bin() { # <mode> <baseline|bolt|bolt-rewrite|bolt-rewrite-nohuge>
  case "$2" in
    baseline)            echo "$BINARIES/$1/mongod" ;;
    bolt)                echo "$BINARIES/$1/mongod.bolt" ;;
    bolt-rewrite)        echo "$BINARIES/$1/mongod.bolt-rewrite" ;;
    bolt-rewrite-nohuge) echo "$BINARIES/$1/mongod.bolt-rewrite-nohuge" ;;
    *) die "unknown variant '$2' (valid: $VALID_WHICH)" ;;
  esac
}

app_server_bin() { # <mode>  baseline server (installed tree preferred)
  local base b
  base="$(app_basedir "$1")"
  for b in "$base/bin/mongod" "$BINARIES/$1/mongod"; do
    if [ -x "$b" ]; then echo "$b"; return 0; fi
  done
  echo "$BINARIES/$1/mongod"
}

app_data_dir() { # <mode>
  echo "$STATE/data/$1/db"
}

# YCSB connection URI for a running server.
_app_mongo_url() { # <port>
  echo "mongodb://127.0.0.1:$1/$YCSB_DBNAME?w=1"
}

# Run the YCSB runner pinned to the client CPUs.
_app_ycsb() {
  pinned "$CLIENT_CPUS" "$YCSB_DIR/bin/ycsb" "$@"
}

app_prepare_data() { # <mode>
  local mode="$1" datadir rootdir marker rundir
  datadir="$(app_data_dir "$mode")"
  rootdir="$(dirname "$datadir")"
  marker="$rootdir/.bolt-harness-prepared"

  if [ "${RESET_DATA:-0}" = 1 ] && [ -d "$rootdir" ]; then
    info "RESET_DATA=1: wiping $rootdir"
    rm -rf "$rootdir"
  fi
  if [ -f "$marker" ]; then
    info "data already prepared: $datadir"
    return 0
  fi

  [ -x "$YCSB_DIR/bin/ycsb" ] || die "YCSB runner not found at $YCSB_DIR (run apps/mongodb/rebuild.sh)"
  mkdir -p "$datadir" "$STATE/data"
  info "preparing MongoDB dataset: dbpath=$datadir"

  rundir="$STATE/data/run-$mode"
  mkdir -p "$rundir"
  APP_BASEDIR="$(app_basedir "$mode")" APP_DATADIR="$datadir" \
  APP_RUNDIR="$rundir" APP_PORT="$PROFILE_PORT" APP_TAG=prepare
  app_server_start "$(app_server_bin "$mode")"
  app_server_wait "$APP_PORT" "$MONGO_START_TIMEOUT" \
    || die "server did not start for data preparation (see $rundir)"

  info "loading YCSB dataset (records=$YCSB_RECORDCOUNT fields=$YCSB_FIELDCOUNT threads=$YCSB_THREADS)"
  _app_ycsb load "$YCSB_DATABASE" -s \
    -P "$YCSB_DIR/workloads/workloada" \
    -p recordcount="$YCSB_RECORDCOUNT" -p fieldcount="$YCSB_FIELDCOUNT" \
    -p mongodb.url="$(_app_mongo_url "$APP_PORT")" \
    -threads "$YCSB_THREADS" \
    > "$STATE/data-$mode-load.log" 2>&1 \
    || { tail -30 "$STATE/data-$mode-load.log" >&2; die "YCSB load failed"; }

  app_server_stop
  touch "$marker"
  info "dataset ready: $datadir"
}

app_server_start() { # <bin>
  local bin="$1" log
  log="$APP_RUNDIR/server-$APP_TAG.log"
  mkdir -p "$APP_DATADIR"
  info "starting $APP_TAG server: $(basename "$bin") port=$APP_PORT cpus=${SERVER_CPUS:-off}"
  # shellcheck disable=SC2086  # MONGODB_EXTRA_ARGS is intentionally word-split
  pinned_bg "$SERVER_CPUS" "$bin" \
    --dbpath "$APP_DATADIR" \
    --port "$APP_PORT" --bind_ip 127.0.0.1 \
    --wiredTigerCacheSizeGB "$MONGODB_CACHE_GB" \
    --logpath "$log" --logappend \
    --setParameter ttlMonitorEnabled=false \
    --setParameter diagnosticDataCollectionEnabled=false \
    $MONGODB_EXTRA_ARGS
  APP_PID="$PINNED_PID"
}

app_server_wait() { # <port> <timeout>
  local port="$1" timeout i
  timeout="${MONGO_START_TIMEOUT:-${2:-120}}"
  for ((i = 0; i < timeout; i++)); do
    if "$MONGOSH_BIN" --quiet --host 127.0.0.1 --port "$port" \
         --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -q '^1$'; then
      return 0
    fi
    kill -0 "${APP_PID:-1}" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}

app_server_stop() {
  local pid="${APP_PID:-}" _
  [ -n "$pid" ] || return 0
  "$MONGOSH_BIN" --quiet --host 127.0.0.1 --port "${APP_PORT:-$BENCH_PORT}" \
    --eval 'db.getSiblingDB("admin").shutdownServer()' >/dev/null 2>&1 \
    || kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  APP_PID=""
}

# One pass over YCSB_WORKLOADS. Writes <outdir>/<tag>.<workload>.txt per workload.
app_workload() { # <outdir> <tag>
  local outdir="$1" tag="$2" secs="${APP_WORKLOAD_TIME:-$YCSB_TIME}" w
  local -a workloads
  IFS=',' read -ra workloads <<< "$YCSB_WORKLOADS"
  mkdir -p "$outdir"
  for w in "${workloads[@]}"; do
    info "ycsb $w (${secs}s, threads=$YCSB_THREADS)"
    _app_ycsb run "$YCSB_DATABASE" -s \
      -P "$YCSB_DIR/workloads/$w" \
      -p recordcount="$YCSB_RECORDCOUNT" -p fieldcount="$YCSB_FIELDCOUNT" \
      -p operationcount="$YCSB_OPERATIONCOUNT" \
      -p mongodb.url="$(_app_mongo_url "$APP_PORT")" \
      -p maxexecutiontime="$secs" \
      -threads "$YCSB_THREADS" \
      > "$outdir/$tag.$w.txt" 2> "$outdir/$tag.$w.txt.err" \
      || { tail -20 "$outdir/$tag.$w.txt.err" >&2; die "ycsb $w failed"; }
  done
}

app_parse_workload() { # <rawfile>  -> test<TAB>metric<TAB>value
  local f="$1" test
  test="$(basename "$f")"
  test="${test#*.}"
  test="${test%.txt}"
  awk -F', ' -v t="$test" '
    $1 == "[OVERALL]" && $2 == "Throughput(ops/sec)" { print t "\tTPS\t" $3 }
    $2 == "Operations"         { op = substr($1, 2, length($1) - 2); ops[op] = $3 }
    $2 == "AverageLatency(us)" { op = substr($1, 2, length($1) - 2); lat[op] = $3 }
    END {
      tot = 0; wsum = 0
      for (op in ops)
        if ((ops[op] + 0) > 0 && (op in lat)) { tot += ops[op]; wsum += ops[op] * lat[op] }
      if (tot > 0) printf "%s\tlat_avg_ms\t%.4f\n", t, wsum / tot / 1000
      if ("READ" in lat)   printf "%s\tread_lat_ms\t%.4f\n",   t, lat["READ"] / 1000
      if ("UPDATE" in lat) printf "%s\tupdate_lat_ms\t%.4f\n", t, lat["UPDATE"] / 1000
    }
  ' "$f"
}
