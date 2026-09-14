# LLVM 23.1.1 BOLT `-rewrite` — Results on MariaDB & PostgreSQL (aarch64)

Date: 2026-09-14
Harness: `bolt-harness`
Tool under test: `llvm-bolt`, LLVM **23.1.1**, branch `llvmorg-23.1.1-rewrite`,
revision `502a8fc3a4ce45478ba6d59c987b667a003b8bd9`
(31 `[BOLT][Rewrite]` commits rebased onto tag `llvmorg-23.1.1`).

## Summary

The ported `-rewrite` feature was validated end-to-end on two real server
applications in both ELF link modes, against the standard profile-driven BOLT
pipeline:

| App | Mode | `bolt` (no-rewrite) | `bolt-rewrite` | rewrite binary runs | workload errors |
|---|---|---|---|---|---|
| MariaDB | pie | **+49.14 %** | **+46.49 %** | yes | 0 |
| MariaDB | no-pie | **+48.01 %** | **+46.53 %** | yes | 0 |
| PostgreSQL | pie | **+36.53 %** | **+34.15 %** | yes | 0 |
| PostgreSQL | no-pie | **+37.23 %** | **+34.69 %** | yes | 0 |

(Throughput geomean vs. the unmodified baseline; higher is better.)

All four `*.bolt-rewrite` binaries are produced, start, and complete the full
benchmark workload with zero errors.

Binary size: `bolt` grows the executable by +25 % … +38 %, while `-rewrite`
shrinks it by up to −18.5 % (PostgreSQL) / ≈ −1 % (MariaDB).

---

## 1. Test environment

| Item | Value |
|---|---|
| Host | CIX P1 CD8160 |
| CPU | ARM Cortex-A520 / Cortex-A720 (MP, 12 CPUs visible) |
| Kernel | 6.6.89-cix |
| Userspace | Ubuntu 24.04.4 LTS (containers), GCC 13.3.0 |
| Harness | `bolt-harness` — Docker containers, `llvm-bolt` run from the host checkout bind-mounted read-only |
| BOLT | `$HOME/src/llvm-23.1.1/build/bin/llvm-bolt` (LLVM 23.1.1, rev `502a8fc3a4ce`) |
| Workload generators | sysbench (MariaDB, in-container), pgbench (PostgreSQL, in-container) |

> Note: the host is **not** Cortex-A53, so dropping the linker's Cortex-A53
> erratum 843419 veneers (see §5.1) is safe here.

---

## 2. BOLT configuration

Optimization flags (identical for both variants; the rewrite variant adds
`-rewrite`):

```
-reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions
-split-all-cold -split-eh -dyno-stats
```

Runtime-library flags passed by the harness:
`--runtime-instrumentation-lib=…/libbolt_rt_instr.a`
`--runtime-hugify-lib=…/libbolt_rt_hugify.a`.

Profiling (instrumentation) flags:

```
-instrument
-instrumentation-file=<dir>/profile.fdata
-instrumentation-sleep-time=10
-instrumentation-no-counters-clear
```

### 2.1 AArch64 veneer requirement (LLVM 23.x)

Both `-instrument` and `-rewrite` refuse to process these binaries unless the
new flag is supplied:

```
--drop-cortex-a53-843419-veneers
```

Error emitted otherwise:

```
BOLT-ERROR: binary contains Cortex-A53 erratum 843419 workaround veneers;
pass --drop-cortex-a53-843419-veneers only if the BOLTed binary will not run
on Cortex-A53, or relink without --fix-cortex-a53-843419
```

The plain (no-rewrite) `bolt` pass is **not** affected. The harness was given a
small, backwards-compatible knob for this:

```
pipeline/profile.sh:  ${BOLT_INSTRUMENT_EXTRA_FLAGS:-}
```

and the flag was passed in `BOLT_OPT_FLAGS` for the optimization stages.

---

## 3. Target applications and build requirements

Both applications are built **BOLT-friendly**: no pointer authentication / BTI,
no stack protector, linker relocations preserved (`-Wl,-q`), and no GCC
hot/cold block partitioning.

### 3.1 Common compiler flags

```
-O2 -fno-omit-frame-pointer -fno-stack-protector
-mbranch-protection=none -fno-reorder-blocks-and-partition
```

* `-mbranch-protection=none` — keep PAC/BTI out; BOLT cannot rewrite
  pointer-auth code.
* `-fno-stack-protector` — remove SSP instrumentation.
* `-Wl,-q` (a.k.a. `--emit-relocs`) — keep static relocations so BOLT can
  recover control flow and rewrite.
* `-fno-reorder-blocks-and-partition` — BOLT is incompatible with GCC's
  hot/cold partitioning at `-O2`.

### 3.2 MariaDB 11.4 LTS (`mariadb-11.4.13`, github.com/MariaDB/server)

Out-of-tree CMake + Ninja build; `mariadbd` is the optimized binary.

```bash
cmake -S mariadb -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DSECURITY_HARDENED=OFF \
  -DWITH_UNIT_TESTS=OFF \
  -DWITH_MARIABACKUP=OFF \
  -DWITH_SYSTEMD=off \
  -DWITH_WSREP=OFF \
  -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CFLAGS" \
  -DWITH_MYSQLD_LDFLAGS="-Wl,-q"            # pie
# -DWITH_MYSQLD_LDFLAGS="-no-pie -Wl,-q"     # no-pie
```

* Link flags are injected through `WITH_MYSQLD_LDFLAGS` (executable only) so
  plugin `.so` objects stay PIC.
* Container build dependencies: `build-essential gcc g++ cmake ninja-build
  bison flex pkg-config git libssl-dev libncurses-dev libaio-dev libnuma-dev
  libpcre2-dev libreadline-dev libedit-dev zlib1g-dev libxml2-dev liblz4-dev
  liblzma-dev libsnappy-dev libzstd-dev libcurl4-openssl-dev libboost-dev
  libjudy-dev libjemalloc-dev liburing-dev sysbench`.

Baseline binary characteristics:

| Mode | ELF | relocations | `.rela.text` |
|---|---|---|---|
| pie | `ELF 64-bit LSB pie executable` | 727,902 | 1 section |
| no-pie | `ELF 64-bit LSB executable` | 535,582 | 1 section |

Workload: **sysbench OLTP** — `oltp_point_select` + `oltp_read_write`,
10 tables × 100,000 rows, 16 client threads, 15 s per test per rep,
1 warmup + 3 recorded reps.

### 3.3 PostgreSQL 17 (`REL_17_11`, github.com/postgres/postgres)

Out-of-tree (VPATH) Autoconf build; `postgres` is the optimized binary.

```bash
./configure \
  --without-icu --without-readline --without-zlib --without-llvm \
  CFLAGS="$CFLAGS" \
  LDFLAGS_EX="-Wl,-q"          # pie
# LDFLAGS_EX="-no-pie -Wl,-q"  # no-pie
```

* JIT is disabled (`--without-llvm`) so the served code is comparable.
* BOLT link flags go through `LDFLAGS_EX` (executables only); shared modules
  built via `LDFLAGS_SL` stay PIC.

Baseline binary characteristics:

| Mode | ELF | relocations | `.rela.text` |
|---|---|---|---|
| pie | `ELF 64-bit LSB pie executable` | 298,039 | 1 section |
| no-pie | `ELF 64-bit LSB executable` | 285,892 | 1 section |

Workload: **pgbench** — `select-only` + `tpcb-like`, scale 100 (~10 M account
rows), 16 clients / 4 jobs, prepared protocol, 15 s per script per rep,
1 warmup + 3 recorded reps.

---

## 4. Results

### 4.1 Performance — throughput geomean vs. baseline

Geomean of per-workload ratios (baseline = 1.0000); higher is better.

| App | Mode | `bolt` | `bolt-rewrite` |
|---|---|---|---|
| MariaDB | pie | **+49.14 %** | **+46.49 %** |
| MariaDB | no-pie | **+48.01 %** | **+46.53 %** |
| PostgreSQL | pie | **+36.53 %** | **+34.15 %** |
| PostgreSQL | no-pie | **+37.23 %** | **+34.69 %** |

`-rewrite` trails the in-place `bolt` variant by roughly 1.5–2.5 points, as
expected for a full re-emission vs. in-place patching.

### 4.2 Per-workload throughput means

**MariaDB — pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 33,928.36 | 53,972.04 | 52,465.77 |
| oltp_read_write | TPS | 1,197.08 | 1,673.74 | 1,661.23 |
| oltp_read_write | QPS | 23,941.63 | 33,474.83 | 33,224.64 |

**MariaDB — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 34,284.50 | 53,975.54 | 53,291.51 |
| oltp_read_write | TPS | 1,196.22 | 1,664.50 | 1,652.28 |
| oltp_read_write | QPS | 23,924.38 | 33,289.92 | 33,045.68 |

**PostgreSQL — pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| select-only | TPS | 31,435.70 | 43,885.68 | 42,998.25 |
| tpcb-like | TPS | 5,333.47 | 7,121.83 | 7,016.85 |

**PostgreSQL — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| select-only | TPS | 30,827.23 | 43,188.87 | 42,540.53 |
| tpcb-like | TPS | 5,247.47 | 7,053.31 | 6,898.05 |

### 4.3 Latency (geomean vs. baseline, lower is better)

| App | Mode | `bolt` | `bolt-rewrite` |
|---|---|---|---|
| MariaDB | pie | −32.80 % | −31.79 % |
| MariaDB | no-pie | −32.79 % | −31.78 % |
| PostgreSQL | pie | −26.75 % | −25.47 % |
| PostgreSQL | no-pie | −27.10 % | −25.74 % |

Per-workload average latency (ms):

| App | Mode | workload | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|---|
| MariaDB | pie | oltp_point_select | 0.47 | 0.30 | 0.30 |
| MariaDB | pie | oltp_read_write | 13.34 | 9.54 | 9.62 |
| MariaDB | no-pie | oltp_point_select | 0.47 | 0.29 | 0.30 |
| MariaDB | no-pie | oltp_read_write | 13.35 | 9.60 | 9.67 |
| PostgreSQL | pie | select-only | 0.51 | 0.36 | 0.37 |
| PostgreSQL | pie | tpcb-like | 3.00 | 2.25 | 2.28 |
| PostgreSQL | no-pie | select-only | 0.52 | 0.37 | 0.38 |
| PostgreSQL | no-pie | tpcb-like | 3.05 | 2.27 | 2.32 |

### 4.4 Binary size

| App | Mode | baseline (bytes) | `bolt` (Δ) | `bolt-rewrite` (Δ) |
|---|---|---|---|---|
| MariaDB | pie | 42,493,688 | 56,259,264 (**+32.4 %**) | 42,100,800 (**−0.9 %**) |
| MariaDB | no-pie | 37,906,536 | 52,150,832 (**+37.6 %**) | 37,517,728 (**−1.0 %**) |
| PostgreSQL | pie | 17,356,328 | 21,640,704 (**+24.7 %**) | 14,151,520 (**−18.5 %**) |
| PostgreSQL | no-pie | 17,096,392 | 21,638,080 (**+26.6 %**) | 14,149,152 (**−17.2 %**) |

Observations:

* `bolt` (no-rewrite) grows the file because the optimized code is laid out
  alongside the BOLT metadata/segments with the original layout constraints;
  the growth is largest on MariaDB (+32…+38 %).
* `-rewrite` **repacks the whole binary**, so it removes the redundant original
  layout and tends to be near the baseline (MariaDB, ≈ −1 %) or substantially
  smaller (PostgreSQL, ≈ −18 %).
* Both `bolt` and `bolt-rewrite` patch the ELF build-id (last bit flipped) —
  verified on all four binaries.

### 4.5 Functional validation

* All four `*.bolt-rewrite` binaries exist and `--version` succeeds.
* Each rewrite binary was started as the benchmark server and completed the
  complete workload (sysbench / pgbench) with **0 errors and 0 mismatches**;
  results were captured and compared normally.
* No `BOLT-ERROR` in any of the four pipeline logs.
* Build-id is distinct from the baseline (last bit flipped) for both variants.

---

## 5. Issues, caveats and notes

1. **Cortex-A53 erratum 843419 veneers (LLVM 23.x).** `-instrument` and
   `-rewrite` abort on these AArch64 baselines unless
   `--drop-cortex-a53-843419-veneers` is passed. The host is A520/A720, so
   dropping the veneers is safe; on Cortex-A53 hardware the binary must be
   relinked with `-Wl,--no-fix-cortex-a53-843419` instead. Plain `bolt` is
   unaffected.
2. **Transient `merge-fdata` flush race.** During the PostgreSQL *pie* profile
   step, `merge-fdata` once aborted with
   `MemoryBuffer.cpp: … "Buffer is not null terminated!"` because the
   instrumentation `.fdata` was still being flushed at merge time. The finished
   file merged cleanly with `merge-fdata`; the pipeline
   was continued with the successfully merged profile. Not seen in the other
   three combinations.
3. **Benign optimization warnings.** MariaDB pie logged
   `BOLT-WARNING: failed to patch entries in <function>. The function will not
   be optimized` for a couple of functions; harmless for correctness/perf.
4. **Harness change.** `pipeline/profile.sh` now honors
   `BOLT_INSTRUMENT_EXTRA_FLAGS` (empty by default, i.e. behavior is unchanged
   when unset); it was set to the veneer flag for these runs. `BOLT_OPT_FLAGS`
   was extended with the same flag for the optimization stages.
5. **Baseline variance.** Baseline absolute numbers vary between runs;
   percentage deltas are computed within a single run with baseline / bolt /
   bolt-rewrite benched back-to-back.
6. **Containers were repointed** to the new build: `bolt-harness-mariadb` and
   `bolt-harness-postgresql` now mount
   `$HOME/src/llvm-23.1.1` at `/llvm:ro`. Previous result
   directories are preserved.
7. **Build-id** is patched (last bit flipped) by both `bolt` and `bolt-rewrite`.

---

## 6. Reproduction

```bash
# 0. Tool under test
$HOME/src/llvm-23.1.1/build/bin/llvm-bolt --version   # 23.1.1, rev 502a8fc

# 1. Point each harness container at the new build
cd $HOME/src/bolt-harness/apps/mariadb
LLVM_SRC=$HOME/src/llvm-23.1.1 ./rebuild.sh
cd ../postgresql
LLVM_SRC=$HOME/src/llvm-23.1.1 ./rebuild.sh

# 2. Run the full pipeline for each app/mode (example: MariaDB pie)
BOLT_FLAGS='-reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions
            -split-all-cold -split-eh -dyno-stats --drop-cortex-a53-843419-veneers'
docker exec -i bolt-harness-mariadb \
  env APP=mariadb HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build/bin CC=gcc \
      BOLT_OPT_FLAGS="$BOLT_FLAGS" \
      BOLT_INSTRUMENT_EXTRA_FLAGS='--drop-cortex-a53-843419-veneers' \
  bash -c 'SKIP_BUILD=1 /harness/pipeline/run-all.sh pie'
# repeat with `no-pie`; for PostgreSQL use container bolt-harness-postgresql and APP=postgresql
```

`SKIP_BUILD=1` reuses the previously built baseline/install trees. Each run
performs: profile (instrument + workload + `merge-fdata`) → optimize
(`bolt` + `bolt-rewrite`) → bench (baseline/bolt/bolt-rewrite) → compare.

Raw logs: `bolt-harness/work/newbolt-{mariadb,postgresql}-{pie,no-pie}.out`.

---

## 7. Data sources

* Pipeline logs: `bolt-harness/work/newbolt-*.out`
* Benchmark results: `bolt-harness/work[/postgresql]/_state/<app>/results/<mode>/<variant>/<timestamp>/summary.tsv`
* Binaries and build info: `…/_state/<app>/binaries/<mode>/{baseline,*.bolt,*.bolt-rewrite,build-info.txt}`
* BOLT logs: `…/_state/<app>/binaries/<mode>/bolt-{bolt,bolt-rewrite}.log`
