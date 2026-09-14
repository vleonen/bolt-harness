# Ubuntu 24.04 (aarch64/amd64) container for building and benchmarking
# MariaDB with the bolt-harness pipeline.
#
# The host llvm-project checkout (with llvm-bolt) is mounted read-only at
# /llvm; the harness is mounted at /harness and its state at /work.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc \
        g++ \
        cmake \
        ninja-build \
        bison \
        flex \
        pkg-config \
        git \
        ca-certificates \
        rsync \
        file \
        util-linux \
        psmisc \
        procps \
        libssl-dev \
        libncurses-dev \
        libaio-dev \
        libnuma-dev \
        libpcre2-dev \
        libreadline-dev \
        libedit-dev \
        zlib1g-dev \
        libxml2-dev \
        liblz4-dev \
        liblzma-dev \
        libsnappy-dev \
        libzstd-dev \
        libcurl4-openssl-dev \
        libboost-dev \
        libjudy-dev \
        libjemalloc-dev \
        liburing-dev \
        sysbench \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
CMD ["/bin/bash"]
