#!/usr/bin/env bash
# Manage the PostgreSQL bolt-harness container.
#
# Usage:
#   ./rebuild.sh          (re)build image, (re)create container, clone
#                          PostgreSQL if needed, print env check, drop into shell
#   ./rebuild.sh exec ...  run a command inside the container (env pre-set)
#   ./rebuild.sh stop      stop and remove the container
#
# Overridable: LLVM_SRC (default ${HOME}/src/llvm-project),
#              POSTGRES_VERSION (default REL_17_11),
#              HARNESS_ROOT (default: repo root two levels up).
#
# The image runs as a non-root user (uid/gid = host) because PostgreSQL
# refuses to run as root.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$APP_DIR/../.." && pwd)}"
IMAGE="bolt-harness-postgresql:ubuntu24.04"
NAME="bolt-harness-postgresql"
LLVM_SRC="${LLVM_SRC:-${HOME}/src/llvm-project}"
POSTGRES_VERSION="${POSTGRES_VERSION:-REL_17_11}"
# Per-app state root. The container runs as a non-root uid, so it cannot share
# the root-owned work/ tree produced by other (root) app containers.
PG_WORK="$HARNESS_ROOT/work/postgresql"

BENCH_ENV=(APP=postgresql
           HARNESS_WORK=/work
           BOLT_BIN_DIR=/llvm/build/bin
           CC=gcc)

msg() { echo "==> $*"; }

stop_container() {
  if docker container inspect "$NAME" >/dev/null 2>&1; then
    msg "Removing existing container '$NAME'"
    docker rm -f "$NAME" >/dev/null
  fi
}

case "${1:-}" in
  stop)
    stop_container
    msg "done"
    exit 0
    ;;
  exec) ;;
  "") ;;
  *) echo "usage: $0 [exec <cmd...>|stop]" >&2; exit 1 ;;
esac

[ -d "$LLVM_SRC" ] || { echo "ERROR: LLVM_SRC not found: $LLVM_SRC" >&2; exit 1; }

msg "Building image $IMAGE (uid=$(id -u) gid=$(id -g))"
docker build --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
  -t "$IMAGE" "$APP_DIR"

stop_container

mkdir -p "$PG_WORK"
msg "Starting container $NAME"
docker run -d --name "$NAME" \
  -v "$LLVM_SRC":/llvm:ro \
  -v "$HARNESS_ROOT":/harness:ro \
  -v "$PG_WORK":/work \
  "$IMAGE" sleep infinity >/dev/null

if [ ! -d "$PG_WORK/postgresql/.git" ]; then
  msg "Cloning PostgreSQL $POSTGRES_VERSION -> work/postgresql/postgresql"
  docker exec "$NAME" git clone --depth 1 --branch "$POSTGRES_VERSION" \
    https://github.com/postgres/postgres /work/postgresql
else
  msg "PostgreSQL source already present: work/postgresql/postgresql"
fi

msg "Environment inside $NAME:"
docker exec "$NAME" bash -lc '
  echo "os:       $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "user:     $(id -un) (uid=$(id -u) gid=$(id -g))"
  echo "gcc:      $(gcc --version | head -1)"
  echo "perl:     $(perl --version | sed -n "2p" | tr -s " ")"
  echo "postgres: $(ls -d /work/postgresql 2>/dev/null && (cd /work/postgresql && git describe --tags 2>/dev/null || true))"
  /llvm/build/bin/llvm-bolt --version | head -3
'

msg ""
msg "Container '$NAME' is running. Enter it with:"
msg "  docker exec -it $NAME bash"
msg "Pipeline env: APP=postgresql HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build/bin CC=gcc"
msg ""
msg "Run the full pipeline:"
msg "  $0 exec /harness/pipeline/run-all.sh pie no-pie"
msg ""

if [ "${1:-}" = "exec" ]; then
  shift
  exec docker exec -i "$NAME" env "${BENCH_ENV[@]}" \
    bash -c 'exec "$@"' _ "$@"
fi

exec docker exec -it "$NAME" env "${BENCH_ENV[@]}" \
  bash -c 'cd /harness; exec bash -i'
