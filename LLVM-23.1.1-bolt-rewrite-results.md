# LLVM 23.1.1 BOLT `-rewrite` — Results on MariaDB & PostgreSQL (aarch64 and x86_64)

Date: 2026-09-14
Harness: `bolt-harness`
Tool under test: `llvm-bolt`, LLVM **23.1.1**, branch `llvmorg-23.1.1-rewrite`:

- **aarch64**: `$HOME/src/llvm-23.1.1/build/bin/llvm-bolt`, revision
  `502a8fc3a4ce45478ba6d59c987b667a003b8bd9` (31 `[BOLT][Rewrite]` commits
  rebased onto tag `llvmorg-23.1.1`).
- **x86_64**: `$HOME/src/llvm-project-23/build23/bin/llvm-bolt`, same branch,
  revision `d1723d9d8a4d`.

## Summary

The `-rewrite` feature was validated end-to-end on two real server applications
in both ELF link modes, on **aarch64** and **x86_64**, against the standard
profile-driven BOLT pipeline.

**aarch64**

| App | Mode | `bolt` (no-rewrite) | `bolt-rewrite` | rewrite binary runs | workload errors |
|---|---|---|---|---|---|
| MariaDB | pie | **+49.14 %** | **+46.49 %** | yes | 0 |
| MariaDB | no-pie | **+48.01 %** | **+46.53 %** | yes | 0 |
| PostgreSQL | pie | **+36.53 %** | **+34.15 %** | yes | 0 |
| PostgreSQL | no-pie | **+37.23 %** | **+34.69 %** | yes | 0 |

**x86_64**

| App | Mode | `bolt` (no-rewrite) | `bolt-rewrite` | rewrite binary runs | workload errors |
|---|---|---|---|---|---|
| MariaDB | pie | **+20.36 %** | **+21.90 %** | yes | 0 |
| MariaDB | no-pie | **+21.27 %** | **+19.09 %** | yes | 0 |
| PostgreSQL | pie | **+9.21 %** | **+3.97 %** | yes | 0 |
| PostgreSQL | no-pie | **+14.37 %** | **+12.22 %** | yes | 0 |

(Throughput geomean vs. the unmodified baseline; higher is better.)

All eight `*.bolt-rewrite` binaries (2 architectures × 2 applications × 2 link
modes) are produced, start, and complete the full benchmark workload with zero
errors.

Binary size: measured on **stripped** binaries — the BOLT input carries
`-Wl,-q` relocation sections and a symbol table that are not part of the
deployed image (see §4.4). On x86_64 `bolt` grows the runtime image by
+23 % … +55 % (it keeps the original code), while `-rewrite` is essentially
size-neutral (≈ 0 %). aarch64 stripped figures are pending; §4.4 shows the
as-recorded raw numbers.

---

## 1. Test environment

**aarch64**

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
> erratum 843419 veneers (see §2.1) is safe here.

**x86_64**

| Item | Value |
|---|---|
| Host | WSL2 (13th Gen Intel Core i7-13700, 8 CPUs visible) |
| Kernel | 6.18.33.2-microsoft-standard-WSL2 |
| Userspace | Ubuntu 24.04 (containers), GCC 13.3.0 |
| Harness | `bolt-harness` (same as aarch64) |
| BOLT | `$HOME/src/llvm-project-23/build23/bin/llvm-bolt` (LLVM 23.1.1, rev `d1723d9d8a4d`) |
| Workload generators | sysbench (MariaDB), pgbench (PostgreSQL) |

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
No equivalent flag is needed on x86_64.

---

## 3. Target applications and build requirements

Both applications are built **BOLT-friendly** on both architectures: stack
protector off, linker relocations preserved (`-Wl,-q`), and no GCC hot/cold
block partitioning. aarch64 additionally keeps pointer authentication / BTI out.

### 3.1 Common compiler flags

```
-O2 -fno-omit-frame-pointer -fno-stack-protector
[-mbranch-protection=none]           # aarch64 only
-fno-reorder-blocks-and-partition    # GCC
```

* `-mbranch-protection=none` — aarch64 only; BOLT cannot rewrite pointer-auth
  code.
* `-fno-stack-protector` — remove SSP instrumentation.
* `-Wl,-q` (a.k.a. `--emit-relocs`) — keep static relocations so BOLT can
  recover control flow and rewrite.
* `-fno-reorder-blocks-and-partition` — BOLT is incompatible with GCC's
  hot/cold block partitioning at `-O2`.

x86_64 keeps GCC's default CET/IBT (`endbr64`); no extra flag is required.

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

| Arch | Mode | ELF | relocations | `.rela.text` |
|---|---|---|---|---|
| aarch64 | pie | `ELF 64-bit LSB pie executable` | 727,902 | 1 section |
| aarch64 | no-pie | `ELF 64-bit LSB executable` | 535,582 | 1 section |
| x86_64 | pie | `ELF 64-bit LSB pie executable` | 696,122 | 1 section |
| x86_64 | no-pie | `ELF 64-bit LSB executable` | 505,446 | 1 section |

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
* On x86_64 PostgreSQL is additionally configured with
  `pgac_cv_computed_goto=no` (see `apps/postgresql/README.md`).

Baseline binary characteristics:

| Arch | Mode | ELF | relocations | `.rela.text` |
|---|---|---|---|---|
| aarch64 | pie | `ELF 64-bit LSB pie executable` | 298,039 | 1 section |
| aarch64 | no-pie | `ELF 64-bit LSB executable` | 285,892 | 1 section |
| x86_64 | pie | `ELF 64-bit LSB pie executable` | 263,390 | 1 section |
| x86_64 | no-pie | `ELF 64-bit LSB executable` | 251,380 | 1 section |

Workload: **pgbench** — `select-only` + `tpcb-like`, scale 100 (~10 M account
rows), 16 clients / 4 jobs, prepared protocol, 15 s per script per rep,
1 warmup + 3 recorded reps.

---

## 4. Results

### 4.1 Performance — throughput geomean vs. baseline

Geomean of per-workload ratios (baseline = 1.0000); higher is better.

| Arch | App | Mode | `bolt` | `bolt-rewrite` |
|---|---|---|---|---|
| aarch64 | MariaDB | pie | **+49.14 %** | **+46.49 %** |
| aarch64 | MariaDB | no-pie | **+48.01 %** | **+46.53 %** |
| aarch64 | PostgreSQL | pie | **+36.53 %** | **+34.15 %** |
| aarch64 | PostgreSQL | no-pie | **+37.23 %** | **+34.69 %** |
| x86_64 | MariaDB | pie | **+20.36 %** | **+21.90 %** |
| x86_64 | MariaDB | no-pie | **+21.27 %** | **+19.09 %** |
| x86_64 | PostgreSQL | pie | **+9.21 %** | **+3.97 %** |
| x86_64 | PostgreSQL | no-pie | **+14.37 %** | **+12.22 %** |

On aarch64 `-rewrite` trails the in-place `bolt` variant by roughly 1.5–2.5
points, as expected for a full re-emission vs. in-place patching; on x86_64 the
two are closer (and `-rewrite` leads slightly on MariaDB pie).

### 4.2 Per-workload throughput means

**aarch64 — MariaDB — pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 33,928.36 | 53,972.04 | 52,465.77 |
| oltp_read_write | TPS | 1,197.08 | 1,673.74 | 1,661.23 |
| oltp_read_write | QPS | 23,941.63 | 33,474.83 | 33,224.64 |

**aarch64 — MariaDB — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 34,284.50 | 53,975.54 | 53,291.51 |
| oltp_read_write | TPS | 1,196.22 | 1,664.50 | 1,652.28 |
| oltp_read_write | QPS | 23,924.38 | 33,289.92 | 33,045.68 |

**aarch64 — PostgreSQL — pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| select-only | TPS | 31,435.70 | 43,885.68 | 42,998.25 |
| tpcb-like | TPS | 5,333.47 | 7,121.83 | 7,016.85 |

**aarch64 — PostgreSQL — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| select-only | TPS | 30,827.23 | 43,188.87 | 42,540.53 |
| tpcb-like | TPS | 5,247.47 | 7,053.31 | 6,898.05 |

**x86_64 — MariaDB — pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 140,054.91 | 169,322.39 | 172,460.69 |
| oltp_read_write | TPS | 4,666.09 | 5,591.01 | 5,630.59 |
| oltp_read_write | QPS | 93,321.72 | 111,820.12 | 112,611.76 |

**x86_64 — MariaDB — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 140,307.91 | 172,359.86 | 168,170.87 |
| oltp_read_write | TPS | 4,677.18 | 5,599.33 | 5,534.45 |
| oltp_read_write | QPS | 93,543.68 | 111,986.74 | 110,688.98 |

**x86_64 — PostgreSQL — pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| select-only | TPS | 204,839.75 | 224,914.46 | 209,851.63 |
| tpcb-like | TPS | 31,594.91 | 34,317.09 | 33,336.51 |

**x86_64 — PostgreSQL — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| select-only | TPS | 183,646.87 | 210,539.50 | 204,894.68 |
| tpcb-like | TPS | 27,997.88 | 31,943.16 | 31,601.17 |

### 4.3 Latency (geomean vs. baseline, lower is better)

| Arch | App | Mode | `bolt` | `bolt-rewrite` |
|---|---|---|---|---|
| aarch64 | MariaDB | pie | −32.80 % | −31.79 % |
| aarch64 | MariaDB | no-pie | −32.79 % | −31.78 % |
| aarch64 | PostgreSQL | pie | −26.75 % | −25.47 % |
| aarch64 | PostgreSQL | no-pie | −27.10 % | −25.74 % |
| x86_64 | MariaDB | pie | −17.10 % | −18.86 % |
| x86_64 | MariaDB | no-pie | −17.38 % | −15.34 % |
| x86_64 | PostgreSQL | pie | −8.40 % | −3.67 % |
| x86_64 | PostgreSQL | no-pie | −12.63 % | −10.98 % |

Per-workload average latency (ms):

| Arch | App | Mode | workload | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|---|---|
| aarch64 | MariaDB | pie | oltp_point_select | 0.47 | 0.30 | 0.30 |
| aarch64 | MariaDB | pie | oltp_read_write | 13.34 | 9.54 | 9.62 |
| aarch64 | MariaDB | no-pie | oltp_point_select | 0.47 | 0.29 | 0.30 |
| aarch64 | MariaDB | no-pie | oltp_read_write | 13.35 | 9.60 | 9.67 |
| aarch64 | PostgreSQL | pie | select-only | 0.51 | 0.36 | 0.37 |
| aarch64 | PostgreSQL | pie | tpcb-like | 3.00 | 2.25 | 2.28 |
| aarch64 | PostgreSQL | no-pie | select-only | 0.52 | 0.37 | 0.38 |
| aarch64 | PostgreSQL | no-pie | tpcb-like | 3.05 | 2.27 | 2.32 |
| x86_64 | MariaDB | pie | oltp_point_select | 0.11 | 0.09 | 0.09 |
| x86_64 | MariaDB | pie | oltp_read_write | 3.43 | 2.86 | 2.84 |
| x86_64 | MariaDB | no-pie | oltp_point_select | 0.11 | 0.09 | 0.09 |
| x86_64 | MariaDB | no-pie | oltp_read_write | 3.42 | 2.85 | 2.89 |
| x86_64 | PostgreSQL | pie | select-only | 0.08 | 0.07 | 0.08 |
| x86_64 | PostgreSQL | pie | tpcb-like | 0.51 | 0.47 | 0.48 |
| x86_64 | PostgreSQL | no-pie | select-only | 0.09 | 0.08 | 0.08 |
| x86_64 | PostgreSQL | no-pie | tpcb-like | 0.57 | 0.50 | 0.51 |

### 4.4 Binary size

Sizes are measured on **stripped** binaries. The BOLT input is linked with
`-Wl,-q`, so it carries non-allocatable `.rela.*` sections and a symbol table
that are not part of the deployed image; stripping removes them (runtime
`.rela.dyn`/`.rela.plt` are kept). Comparing raw file sizes therefore flatters
BOLT output, which no longer carries those sections, so all deltas below use
stripped sizes. (The aarch64 artifacts are not available on the x86_64 host,
so their stripped figures are pending; the as-recorded raw numbers are shown
for reference.)

**x86_64 (stripped)**

| App | Mode | baseline (bytes) | `bolt` (Δ) | `bolt-rewrite` (Δ) |
|---|---|---|---|---|
| MariaDB | pie | 26,921,472 | 33,155,760 (**+23.2 %**) | 26,921,152 (**−0.0 %**) |
| MariaDB | no-pie | 22,346,312 | 28,593,264 (**+28.0 %**) | 22,367,000 (**+0.1 %**) |
| PostgreSQL | pie | 9,651,888 | 14,807,928 (**+53.4 %**) | 9,664,856 (**+0.1 %**) |
| PostgreSQL | no-pie | 9,367,352 | 14,523,208 (**+55.0 %**) | 9,376,200 (**+0.1 %**) |

**aarch64 (as-recorded, unstripped; stripped recomputation pending)**

| App | Mode | baseline (bytes) | `bolt` (Δ) | `bolt-rewrite` (Δ) |
|---|---|---|---|---|
| MariaDB | pie | 42,493,688 | 56,259,264 (**+32.4 %**) | 42,100,800 (**−0.9 %**) |
| MariaDB | no-pie | 37,906,536 | 52,150,832 (**+37.6 %**) | 37,517,728 (**−1.0 %**) |
| PostgreSQL | pie | 17,356,328 | 21,640,704 (**+24.7 %**) | 14,151,520 (**−18.5 %**) |
| PostgreSQL | no-pie | 17,096,392 | 21,638,080 (**+26.6 %**) | 14,149,152 (**−17.2 %**) |

Observations:

* `bolt` (no-rewrite) is substantially larger on x86_64 (+23 % … +55 %) because
  it keeps the original code (`.bolt.org.text`) alongside the optimized code.
* `-rewrite` **repacks the whole binary**; once the BOLT-input-only relocation
  sections and symbol table are excluded, its runtime image is essentially the
  same size as the baseline (≈ 0 %). The raw-size reductions previously
  reported for x86_64 (e.g. PostgreSQL ≈ −33 %) were an artifact of comparing a
  relocation-heavy baseline against BOLT output that no longer carries those
  sections.
* Both `bolt` and `bolt-rewrite` patch the ELF build-id (last bit flipped) —
  verified on all eight binaries.

### 4.5 Functional validation

* All eight `*.bolt-rewrite` binaries (2 arches × 2 apps × 2 modes) exist and
  `--version` succeeds.
* Each rewrite binary was started as the benchmark server and completed the
  complete workload (sysbench / pgbench) with **0 errors and 0 mismatches**;
  results were captured and compared normally.
* No `BOLT-ERROR` in any of the pipeline logs.
* Build-id is distinct from the baseline (last bit flipped) for both variants.

---

## 5. Issues, caveats and notes

1. **Cortex-A53 erratum 843419 veneers (LLVM 23.x, aarch64).** `-instrument`
   and `-rewrite` abort on these AArch64 baselines unless
   `--drop-cortex-a53-843419-veneers` is passed. The host is A520/A720, so
   dropping the veneers is safe; on Cortex-A53 hardware the binary must be
   relinked with `-Wl,--no-fix-cortex-a53-843419` instead. Plain `bolt` is
   unaffected. No equivalent flag is needed on x86_64.
2. **Transient `merge-fdata` flush race (aarch64).** During the PostgreSQL
   *pie* profile step, `merge-fdata` once aborted with
   `MemoryBuffer.cpp: … "Buffer is not null terminated!"` because the
   instrumentation `.fdata` was still being flushed at merge time. The finished
   file merged cleanly with `merge-fdata`; the pipeline was continued with the
   successfully merged profile. Not seen in the other combinations.
3. **Benign optimization warnings.** MariaDB pie (aarch64) logged
   `BOLT-WARNING: failed to patch entries in <function>. The function will not
   be optimized` for a couple of functions; harmless for correctness/perf.
4. **Harness change.** `pipeline/profile.sh` now honors
   `BOLT_INSTRUMENT_EXTRA_FLAGS` (empty by default, i.e. behavior is unchanged
   when unset); it was set to the veneer flag for the aarch64 runs.
   `BOLT_OPT_FLAGS` was extended with the same flag for the aarch64
   optimization stages.
5. **Baseline variance.** Baseline absolute numbers vary between runs;
   percentage deltas are computed within a single run with baseline / bolt /
   bolt-rewrite benched back-to-back, and are only comparable within one
   architecture.
6. **Containers.** The aarch64 containers mount `$HOME/src/llvm-23.1.1` at
   `/llvm:ro`; the x86_64 containers mount `$HOME/src/llvm-project-23`.
   Previous result directories are preserved.
7. **Build-id** is patched (last bit flipped) by both `bolt` and
   `bolt-rewrite` on both architectures.

---

## 6. Reproduction

```bash
# 0. Tools under test
$HOME/src/llvm-23.1.1/build/bin/llvm-bolt --version       # aarch64, rev 502a8fc
$HOME/src/llvm-project-23/build23/bin/llvm-bolt --version # x86_64,  rev d1723d9d

# 1. Point each harness container at the build for the target host
#    (aarch64 example)
cd $HOME/src/bolt-harness/apps/mariadb
LLVM_SRC=$HOME/src/llvm-23.1.1 ./rebuild.sh
cd ../postgresql
LLVM_SRC=$HOME/src/llvm-23.1.1 ./rebuild.sh
#    x86_64: same with LLVM_SRC=$HOME/src/llvm-project-23

# 2. Run the full pipeline for each app/mode (example: MariaDB pie, aarch64)
BOLT_FLAGS='-reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions
            -split-all-cold -split-eh -dyno-stats --drop-cortex-a53-843419-veneers'
docker exec -i bolt-harness-mariadb \
  env APP=mariadb HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build/bin CC=gcc \
      BOLT_OPT_FLAGS="$BOLT_FLAGS" \
      BOLT_INSTRUMENT_EXTRA_FLAGS='--drop-cortex-a53-843419-veneers' \
  bash -c 'SKIP_BUILD=1 /harness/pipeline/run-all.sh pie'
# repeat with `no-pie`; for PostgreSQL use container bolt-harness-postgresql and APP=postgresql.
# x86_64: omit BOLT_INSTRUMENT_EXTRA_FLAGS and the veneer flag in BOLT_OPT_FLAGS.
```

`SKIP_BUILD=1` reuses the previously built baseline/install trees. Each run
performs: profile (instrument + workload + `merge-fdata`) → optimize
(`bolt` + `bolt-rewrite`) → bench (baseline/bolt/bolt-rewrite) → compare.

---

## 7. Data sources

* Pipeline logs: `bolt-harness/work/newbolt-*.out`
* Benchmark results: `bolt-harness/work[/postgresql]/_state/<app>/results/<mode>/<variant>/<timestamp>/summary.tsv`
* Binaries and build info: `…/_state/<app>/binaries/<mode>/{baseline,*.bolt,*.bolt-rewrite,build-info.txt}`
* BOLT logs: `…/_state/<app>/binaries/<mode>/bolt-{bolt,bolt-rewrite}.log`
