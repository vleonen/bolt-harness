#!/usr/bin/env bash
# Manage the CPython (libpython) bolt-harness container.
#
# Usage:
#   ./rebuild.sh          (re)build image, (re)create container, clone CPython
#                          if needed, print env check, drop into a shell
#   ./rebuild.sh exec ...  run a command inside the container (env pre-set)
#   ./rebuild.sh stop      stop and remove the container
#
# Overridable: LLVM_SRC (default ${HOME}/src/llvm-project),
#              LLVM_BUILD_DIR (default: auto-detected under LLVM_SRC),
#              PYTHON_VERSION (default v3.13.9),
#              HARNESS_ROOT (default: repo root two levels up).
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$APP_DIR/../.." && pwd)}"
IMAGE="bolt-harness-python:ubuntu24.04"
NAME="bolt-harness-python"
LLVM_SRC="${LLVM_SRC:-${HOME}/src/llvm-project}"
PYTHON_VERSION="${PYTHON_VERSION:-v3.13.9}"

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

# Locate the LLVM build tree (the one containing bin/llvm-bolt). LLVM_BUILD_DIR
# wins; otherwise prefer build/, then build23/, then any immediate subdir.
LLVM_BUILD_DIR="${LLVM_BUILD_DIR:-}"
if [ -z "$LLVM_BUILD_DIR" ]; then
  for d in build build23; do
    if [ -x "$LLVM_SRC/$d/bin/llvm-bolt" ]; then LLVM_BUILD_DIR="$d"; break; fi
  done
fi
if [ -z "$LLVM_BUILD_DIR" ]; then
  for p in "$LLVM_SRC"/*/bin/llvm-bolt; do
    [ -x "$p" ] || continue
    LLVM_BUILD_DIR="$(basename "$(dirname "$(dirname "$p")")")"
    break
  done
fi
[ -n "$LLVM_BUILD_DIR" ] || {
  echo "ERROR: no LLVM build with bin/llvm-bolt under $LLVM_SRC (set LLVM_BUILD_DIR)" >&2
  exit 1
}
[ -x "$LLVM_SRC/$LLVM_BUILD_DIR/bin/llvm-bolt" ] || {
  echo "ERROR: $LLVM_SRC/$LLVM_BUILD_DIR/bin/llvm-bolt not found (check LLVM_SRC/LLVM_BUILD_DIR)" >&2
  exit 1
}
# Path where LLVM_SRC is mounted read-only inside the container.
BOLT_BIN_DIR="/llvm/$LLVM_BUILD_DIR/bin"

BENCH_ENV=(APP=python
           HARNESS_WORK=/work
           BOLT_BIN_DIR="$BOLT_BIN_DIR"
           CC=gcc)

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

if [ ! -d "$HARNESS_ROOT/work/python/.git" ]; then
  msg "Cloning CPython $PYTHON_VERSION -> work/python"
  docker exec "$NAME" git clone --depth 1 --branch "$PYTHON_VERSION" \
    https://github.com/python/cpython /work/python
else
  msg "CPython source already present: work/python"
fi

msg "Environment inside $NAME:"
docker exec "$NAME" env "BOLT_BIN_DIR=$BOLT_BIN_DIR" bash -lc '
  echo "os:       $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "gcc:      $(gcc --version | head -1)"
  echo "python3:  $(python3 --version)"
  echo "cpython:  $(ls -d /work/python 2>/dev/null && (cd /work/python && git describe --tags 2>/dev/null || true))"
  echo "wheels:   $(ls /wheelhouse 2>/dev/null | tr "\n" " ")"
  "$BOLT_BIN_DIR"/llvm-bolt --version | head -3
'

msg ""
msg "Container '$NAME' is running. Enter it with:"
msg "  docker exec -it $NAME bash"
msg "Pipeline env: APP=python HARNESS_WORK=/work BOLT_BIN_DIR=$BOLT_BIN_DIR CC=gcc"
msg ""
msg "Run the full pipeline (pie = libpython.so, no-pie = static python3):"
msg "  $0 exec /harness/pipeline/run-all.sh pie no-pie"
msg ""

if [ "${1:-}" = "exec" ]; then
  shift
  exec docker exec -i "$NAME" env "${BENCH_ENV[@]}" \
    bash -c 'exec "$@"' _ "$@"
fi

exec docker exec -it "$NAME" env "${BENCH_ENV[@]}" \
  bash -c 'cd /harness; exec bash -i'
