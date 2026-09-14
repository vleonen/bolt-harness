# Ubuntu 24.04 (aarch64) container for building and benchmarking PostgreSQL
# with the bolt-harness pipeline.
#
# PostgreSQL refuses to run as root, so the image runs as a non-root
# `postgres` user whose uid/gid match the host (passed as build args). This
# also makes bind-mounted work/ artifacts host-owned.
#
# The host llvm-project checkout (with llvm-bolt) is mounted read-only at
# /llvm; the harness is mounted at /harness and its state at /work.
FROM ubuntu:24.04

ARG UID=1001
ARG GID=1001

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc \
        bison \
        flex \
        perl \
        pkg-config \
        git \
        ca-certificates \
        rsync \
        file \
        util-linux \
        psmisc \
        procps \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g "$GID" postgres \
    && useradd -m -u "$UID" -g "$GID" -s /bin/bash postgres

USER postgres
WORKDIR /work
CMD ["/bin/bash"]
