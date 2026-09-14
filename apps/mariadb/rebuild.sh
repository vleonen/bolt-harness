#!/usr/bin/env bash
# Manage the MariaDB bolt-harness container.
#
# Usage:
#   ./rebuild.sh          (re)build image, (re)create container, clone MariaDB
#                          if needed, print env check, drop into a shell
#   ./rebuild.sh exec ...  run a command inside the container (env pre-set)
#   ./rebuild.sh stop      stop and remove the container
#
# Overridable: LLVM_SRC (default ${HOME}/src/llvm-project),
#              MARIADB_VERSION (default mariadb-11.4.13),
#              HARNESS_ROOT (default: repo root two levels up).
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$APP_DIR/../.." && pwd)}"
IMAGE="bolt-harness-mariadb:ubuntu24.04"
NAME="bolt-harness-mariadb"
LLVM_SRC="${LLVM_SRC:-${HOME}/src/llvm-project}"
MARIADB_VERSION="${MARIADB_VERSION:-mariadb-11.4.13}"

BENCH_ENV=(APP=mariadb
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

msg "Building image $IMAGE"
docker build -t "$IMAGE" "$APP_DIR"

stop_container

mkdir -p "$HARNESS_ROOT/work"
msg "Starting container $NAME"
docker run -d --name "$NAME" \
  -v "$LLVM_SRC":/llvm:ro \
  -v "$HARNESS_ROOT":/harness:ro \
  -v "$HARNESS_ROOT/work":/work \
  "$IMAGE" sleep infinity >/dev/null

if [ ! -d "$HARNESS_ROOT/work/mariadb/.git" ]; then
  msg "Cloning MariaDB $MARIADB_VERSION -> work/mariadb"
  docker exec "$NAME" git clone --depth 1 --branch "$MARIADB_VERSION" \
    https://github.com/MariaDB/server /work/mariadb
else
  msg "MariaDB source already present: work/mariadb"
fi

msg "Environment inside $NAME:"
docker exec "$NAME" bash -lc '
  echo "os:       $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "gcc:      $(gcc --version | head -1)"
  echo "cmake:    $(cmake --version | head -1)"
  echo "sysbench: $(sysbench --version)"
  echo "mariadb:  $(ls -d /work/mariadb 2>/dev/null && (cd /work/mariadb && git describe --tags 2>/dev/null || true))"
  /llvm/build/bin/llvm-bolt --version | head -3
'

msg ""
msg "Container '$NAME' is running. Enter it with:"
msg "  docker exec -it $NAME bash"
msg "Pipeline env: APP=mariadb HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build/bin CC=gcc"
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
