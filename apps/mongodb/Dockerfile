# Ubuntu 24.04 (aarch64/amd64) container for building and benchmarking
# MongoDB 7.0 with the bolt-harness pipeline.
#
# 24.04 (glibc 2.39) is required so the host-built llvm-bolt mounted at /llvm
# runs inside the container; 22.04's glibc 2.35 is too old for it.
#
# MongoDB 7.0's SCons build wants the old Python pins in
# etc/pip/compile-requirements.txt (psutil<=5.8, PyYAML==5.3.1, ...) and GCC
# >= 11.3, which do not work on Noble's Python 3.12 / GCC 13. We therefore
# install Python 3.10 from the deadsnakes PPA and build with GCC 12.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Python 3.10 (deadsnakes) for the MongoDB SCons build environment.
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
        gnupg \
        ca-certificates \
        curl \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && rm -rf /var/lib/apt/lists/*

# MongoDB build dependencies (its third-party C/C++ sources are vendored in the
# repo; SCons itself lives in src/third_party/scons-4.9.1). JDK 17 + Maven build
# the YCSB mongodb binding; python-is-python3 is needed by YCSB's bin/ycsb
# shebang (#!/usr/bin/env python).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc-12 \
        g++-12 \
        python3.10 \
        python3.10-venv \
        python3.10-dev \
        python3-pip \
        python-is-python3 \
        git \
        ca-certificates \
        curl \
        wget \
        rsync \
        file \
        util-linux \
        psmisc \
        procps \
        pkg-config \
        libssl-dev \
        libcurl4-openssl-dev \
        liblzma-dev \
        zlib1g-dev \
        libzstd-dev \
        libsnappy-dev \
        openjdk-17-jdk \
        maven \
    && rm -rf /var/lib/apt/lists/*

# mongosh, used to ping and gracefully shut down the server. The openssl3
# tarball matches Ubuntu 24.04.
ARG MONGOSH_VERSION=2.11.1
RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
         amd64) m=x64 ;; \
         arm64) m=arm64 ;; \
         *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
       esac \
    && curl -fsSL "https://downloads.mongodb.com/compass/mongosh-${MONGOSH_VERSION}-linux-${m}-openssl3.tgz" \
         -o /tmp/mongosh.tgz \
    && tar -xzf /tmp/mongosh.tgz -C /opt \
    && mv /opt/mongosh-*-linux-* /opt/mongosh \
    && ln -s /opt/mongosh/bin/mongosh /usr/local/bin/mongosh \
    && rm -f /tmp/mongosh.tgz

WORKDIR /work
CMD ["/bin/bash"]
