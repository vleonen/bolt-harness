#!/usr/bin/env bash
# Manage the MongoDB bolt-harness container.
#
# Usage:
#   ./rebuild.sh          (re)build image, (re)create container, clone MongoDB,
#                          install the Python build requirements (in a venv on
#                          the bind-mounted work tree), build the YCSB runner,
#                          print env check, drop into a shell
#   ./rebuild.sh exec ...  run a command inside the container (env pre-set)
#   ./rebuild.sh stop      stop and remove the container
#
# Overridable: LLVM_SRC (default ${HOME}/src/llvm-23.1.1),
#              LLVM_BUILD_DIR (default: auto-detected under LLVM_SRC),
#              MONGODB_VERSION (default r7.0.43),
#              YCSB_REF (default master),
#              HARNESS_ROOT (default: repo root two levels up).
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$APP_DIR/../.." && pwd)}"
IMAGE="bolt-harness-mongodb:ubuntu24.04"
NAME="bolt-harness-mongodb"
LLVM_SRC="${LLVM_SRC:-${HOME}/src/llvm-23.1.1}"
MONGODB_VERSION="${MONGODB_VERSION:-r7.0.43}"
YCSB_REF="${YCSB_REF:-master}"
MONGO_WORK="$HARNESS_ROOT/work"
MONGO_VENV="/work/mongodb/venv"

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

BENCH_ENV=(APP=mongodb
           HARNESS_WORK=/work
           BOLT_BIN_DIR="$BOLT_BIN_DIR"
           CC=gcc-12
           CXX=g++-12
           MONGODB_PYTHON="$MONGO_VENV/bin/python3"
           YCSB_DIR=/work/ycsb)

msg "Building image $IMAGE"
docker build -t "$IMAGE" "$APP_DIR"

stop_container

mkdir -p "$MONGO_WORK"
msg "Starting container $NAME"
docker run -d --name "$NAME" \
  -v "$LLVM_SRC":/llvm:ro \
  -v "$HARNESS_ROOT":/harness:ro \
  -v "$MONGO_WORK":/work \
  "$IMAGE" sleep infinity >/dev/null

if [ ! -d "$MONGO_WORK/mongodb/.git" ]; then
  msg "Cloning MongoDB $MONGODB_VERSION -> work/mongodb"
  docker exec "$NAME" git clone --depth 1 --branch "$MONGODB_VERSION" \
    https://github.com/mongodb/mongo /work/mongodb
else
  msg "MongoDB source already present: work/mongodb"
fi

# The venv lives on the bind-mounted work tree so it survives container
# recreation; it must be created by the container's Python 3.10, not the host.
if [ ! -x "$MONGO_WORK/mongodb/venv/bin/python3" ]; then
  msg "Creating MongoDB Python 3.10 venv and installing build requirements"
  docker exec "$NAME" bash -lc "
    set -e
    python3.10 -m venv "$MONGO_VENV"
    "$MONGO_VENV/bin/pip" install -q --upgrade pip wheel
    # Cython<3 is required to build the pinned PyYAML==5.3.1 sdist on py3.10.
    "$MONGO_VENV/bin/pip" install -q 'Cython<3'
    "$MONGO_VENV/bin/pip" install -q -r /work/mongodb/etc/pip/compile-requirements.txt
  "
else
  msg "MongoDB Python venv already present: work/mongodb/venv"
fi

# Maven 3.8+ blocks HTTP-only repositories by default, but YCSB's mongodb
# binding depends on com.allanbank:mongodb-async-driver, which is only served
# over http://. Install a settings.xml that disables the built-in blocker.
docker exec "$NAME" mkdir -p /root/.m2
docker cp "$APP_DIR/maven-settings.xml" "$NAME:/root/.m2/settings.xml"

# Build a YCSB distribution (source checkouts otherwise invoke Maven on every
# run). YCSB master uses mongodb-driver-sync, which is compatible with 7.0.
if [ ! -f "$MONGO_WORK/ycsb/.bolt-harness-ready" ]; then
  msg "Building YCSB ($YCSB_REF) mongodb binding -> work/ycsb"
  docker exec "$NAME" bash -lc "
    set -e
    if [ ! -d /work/ycsb-src/.git ]; then
      git clone https://github.com/brianfrankcooper/YCSB /work/ycsb-src
    fi
    cd /work/ycsb-src
    git fetch --all -q --tags
    git checkout -q '$YCSB_REF'
    # install (not package) so the provided-scope core jar is in the local repo
    # for the dependency:copy-dependencies run below.
    mvn -q -B -pl site.ycsb:mongodb-binding -am -DskipTests install
    rm -rf /work/ycsb
    mkdir -p /work/ycsb/lib /work/ycsb/mongodb-binding/lib
    cp -r bin workloads LICENSE.txt /work/ycsb/
    [ -d conf ] && cp -r conf /work/ycsb/ || true
    cp core/target/core-*.jar /work/ycsb/lib/
    cp mongodb/target/mongodb-binding-*.jar /work/ycsb/mongodb-binding/lib/
    mvn -q -B -pl site.ycsb:core dependency:copy-dependencies \
        -DincludeScope=runtime -DoutputDirectory=/work/ycsb/lib
    mvn -q -B -pl site.ycsb:mongodb-binding dependency:copy-dependencies \
        -DincludeScope=runtime -DoutputDirectory=/work/ycsb/mongodb-binding/lib
    touch /work/ycsb/.bolt-harness-ready
    echo ' YCSB ready:' \$(ls /work/ycsb/bin/ycsb)
  "
else
  msg "YCSB runner already present: work/ycsb"
fi

msg "Environment inside $NAME:"
docker exec "$NAME" env "BOLT_BIN_DIR=$BOLT_BIN_DIR" bash -lc '
  echo "os:       $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "gcc:      $(gcc-12 --version | head -1)"
  echo "python:   $(/work/mongodb/venv/bin/python3 --version 2>/dev/null || python3 --version)"
  echo "java:     $(java -version 2>&1 | head -1)"
  echo "maven:    $(mvn -version 2>/dev/null | head -1)"
  echo "mongosh:  $(mongosh --version 2>/dev/null || echo missing)"
  echo "scons:    $(ls -d /work/mongodb/src/third_party/scons-* 2>/dev/null | head -1)"
  echo "ycsb:     $(ls -d /work/ycsb 2>/dev/null || echo missing)"
  echo "mongodb:  $(ls -d /work/mongodb 2>/dev/null && (cd /work/mongodb && git describe --tags 2>/dev/null || true))"
  "$BOLT_BIN_DIR"/llvm-bolt --version | head -3
'

msg ""
msg "Container '$NAME' is running. Enter it with:"
msg "  docker exec -it $NAME bash"
msg "Pipeline env: APP=mongodb HARNESS_WORK=/work BOLT_BIN_DIR=$BOLT_BIN_DIR CC=gcc-12 CXX=g++-12"
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
