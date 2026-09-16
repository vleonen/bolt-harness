# Ubuntu 24.04 (aarch64/amd64) container for building and benchmarking
# CPython (libpython) with the bolt-harness pipeline.
#
# The host llvm-project checkout (with llvm-bolt) is mounted read-only at
# /llvm; the harness is mounted at /harness and its state at /work.
#
# A wheelhouse for the pyperformance benchmark stack is baked into the image so
# apps/python/build.sh can install it offline into each CPython prefix.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        gcc \
        g++ \
        make \
        pkg-config \
        autoconf \
        bison \
        git \
        ca-certificates \
        curl \
        file \
        binutils \
        procps \
        psmisc \
        util-linux \
        patch \
        xz-utils \
        libssl-dev \
        zlib1g-dev \
        libbz2-dev \
        libreadline-dev \
        libsqlite3-dev \
        libffi-dev \
        liblzma-dev \
        libncurses-dev \
        libgdbm-dev \
        libgdbm-compat-dev \
        libnss3-dev \
        uuid-dev \
        libexpat1-dev \
        libcrypt-dev \
        python3 \
        python3-pip \
        python3-venv \
        python3-dev \
    && rm -rf /var/lib/apt/lists/*

# pyperformance + pyperf (+ psutil/packaging) as wheels, for offline installs.
# setuptools/wheel are included defensively so PEP 517 build isolation can be
# satisfied from the wheelhouse if a source distribution ever slips in.
RUN mkdir -p /wheelhouse \
    && python3 -m pip download --only-binary=:all: --dest /wheelhouse \
         pyperformance==1.14.0 wheel setuptools \
    && ls -l /wheelhouse

WORKDIR /work
CMD ["/bin/bash"]
