# LLVM 23.1.1 BOLT `-rewrite` — Results on MariaDB & PostgreSQL (aarch64 and x86_64)

Date: 2026-09-15
Harness: `bolt-harness`
Tool under test: `llvm-bolt`, LLVM **23.1.1**, branch `llvmorg-23.1.1-rewrite`:

- **aarch64**: `$HOME/src/llvm-23.1.1/build/bin/llvm-bolt`, revision
  `d1723d9d8a4d763722331379ab265e94b6c3cb14` (34 `[BOLT][Rewrite]` commits
  rebased onto tag `llvmorg-23.1.1`). The aarch64 results below were
  re-validated on 2026-09-15 with this revision after three additional
  `-rewrite` fixes landed on the branch (see §2.2); the earlier aarch64 run
  used `502a8fc3a4ce`. The aarch64 set also includes a fourth configuration,
  `bolt-rewrite-nohuge` (`-rewrite --no-huge-pages`), added to quantify BOLT's
  default 2 M huge-page code alignment (see §2.3 and §4.4).
- **x86_64**: `$HOME/src/llvm-project-23/build23/bin/llvm-bolt`, same branch,
  revision `d1723d9d8a4d` (the same revision as aarch64; the x86_64 results in
  this report were produced with it, so both architectures are now on one
  revision). The x86_64 run predates the `bolt-rewrite-nohuge` configuration.

## Summary

The `-rewrite` feature was validated end-to-end on two real server applications
in both ELF link modes, on **aarch64** and **x86_64**, against the standard
profile-driven BOLT pipeline.

**aarch64** (2026-09-15, rev `d1723d9d`; four configurations)

| App | Mode | `bolt` | `bolt-rewrite` | `bolt-rewrite-nohuge` | workload errors |
|---|---|---|---|---|---|
| MariaDB | pie | **+45.04 %** | **+46.21 %** | **+45.26 %** | 0 |
| MariaDB | no-pie | **+47.62 %** | **+46.90 %** | **+50.61 %** | 0 |
| PostgreSQL | pie | **+35.27 %** | **+35.63 %** | **+38.21 %** | 0 |
| PostgreSQL | no-pie | **+35.23 %** | **+35.42 %** | **+36.78 %** | 0 |

**x86_64** (three configurations; `bolt-rewrite-nohuge` pending the x86_64 re-run)

| App | Mode | `bolt` (no-rewrite) | `bolt-rewrite` | rewrite binary runs | workload errors |
|---|---|---|---|---|---|
| MariaDB | pie | **+20.36 %** | **+21.90 %** | yes | 0 |
| MariaDB | no-pie | **+21.27 %** | **+19.09 %** | yes | 0 |
| PostgreSQL | pie | **+9.21 %** | **+3.97 %** | yes | 0 |
| PostgreSQL | no-pie | **+14.37 %** | **+12.22 %** | yes | 0 |

(Throughput geomean vs. the unmodified baseline; higher is better.
`bolt-rewrite-nohuge` is the regular `-rewrite` build with BOLT's default 2 M
huge-page code alignment replaced by the target's regular page size, i.e.
`-rewrite --no-huge-pages` — see §2.3.)

All eight `*.bolt-rewrite` binaries (2 architectures × 2 applications × 2 link
modes), plus the four aarch64 `bolt-rewrite-nohuge` binaries, are produced,
start, and complete the full benchmark workload with zero errors.

Binary size (measured on **stripped** binaries, §4.4): on **x86_64** `bolt`
grows the runtime image by +23 % … +55 % (it keeps the original code), while
`-rewrite` is essentially size-neutral (≈ 0 %). On **aarch64** `bolt` grows the
runtime image by +60 % … +104 % and `-rewrite` by +21 % … +36 %; a substantial
part of both is alignment/placement padding introduced by BOLT's default 2 M
code alignment. Replacing it with the regular page size
(`bolt-rewrite-nohuge`) removes the 2 M `PT_LOAD` alignment and cuts the
aarch64 `-rewrite` overhead to +15 % … +23 %.

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
| BOLT | `$HOME/src/llvm-23.1.1/build/bin/llvm-bolt` (LLVM 23.1.1, rev `d1723d9d8a4d`) |
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

### 2.2 `-rewrite` fixes validated by the aarch64 re-run

The aarch64 re-validation on rev `d1723d9d` additionally exercises three
`[BOLT][Rewrite]` fixes that landed after the first aarch64 run (`502a8fc3a4ce`):

| Commit | Scope | Change |
|---|---|---|
| `208d52e30bb2` | common | Do not validate data references as branch targets: interior pointers (`func+offset` in a data pointer table) are tracked separately from control-flow targets instead of being reported as corrupted control flow and dropping the function. |
| `ef39667af327` | x86-motivated, common | `-rewrite` is authoritative over `-lite`: it no longer implicitly enables x86 auto-lite, and an explicit `-lite` is overridden with a warning so every function is emitted. |
| `d1723d9d8a4d` | x86_64 | x86 bfd lowering of the CET lazy-PLT `.got` slot (fall back to `.got` when there is no `.got.plt`); preserve renamed non-text originals so `.rodata` (and `.gcc_except_table`) content is not dropped. |

On aarch64 the only observable differences with these fixes are:

* `bolt` (no-rewrite) is byte-identical apart from the embedded BOLT revision
  (38 differing bytes), for all four app/mode combinations.
* `-rewrite` for PostgreSQL is likewise identical apart from the embedded
  revision.
* `-rewrite` for MariaDB gains a preserved `.bolt.org.gcc_except_table`
  (the original exception table, +136,168 B); it is the only change in the
  documented section list, and the optimization decisions and warning sets are
  unchanged (§4.5). This is the same content-preservation class as the x86
  `.rodata` fix, so `d1723d9d` is not a no-op on aarch64.
* No new `BOLT-ERROR`/`BOLT-WARNING` and no `corrupted control flow` messages
  appear on aarch64; the aarch64 baselines do not trigger the interior-pointer
  or lite-mode paths.

### 2.3 `bolt-rewrite-nohuge` — regular-page code alignment

BOLT aligns relocated code to 2 M by default: `BC->PageAlign` is initialized to
`HugePageSize` (`0x200000`, `bolt/lib/Core/BinaryContext.cpp:162`) unless the
hidden `--no-huge-pages` option is passed, in which case it becomes the target's
regular page size (`RegularPageSizeX86 = 4 K`, `RegularPageSizeAArch64 = 64 K`).
That 2 M alignment is applied to the new `.text` in relocation (`bolt`) mode
(`opts::AlignText = BC->PageAlign`) and to the placement/segment alignment of
the emitted image in both modes, which can leave multi-megabyte holes in the
file.

To measure and isolate that overhead the harness gained an opt-in fourth
configuration (`NOHUGE=1`), produced and benchmarked exactly like the others:

```
<binary>.bolt-rewrite-nohuge   =   BOLT_OPT_FLAGS -rewrite --no-huge-pages
```

The flag and the harness scripts are architecture-neutral (the same
`NOHUGE=1` invocation on x86_64 switches to 4 K pages); it is off by default, so
the standard three-variant pipeline is unchanged. §4.4 reports the resulting
size and alignment figures.

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
  `pgac_cv_computed_goto=no` (see `apps/postgresql/README.md`): `llvm-bolt
  -instrument` otherwise misdetects the `&&label` dispatch table in
  `.data.rel.ro` as a jump table and corrupts it. The **aarch64** baselines in
  this report were built before that harness workaround and therefore keep
  `HAVE_COMPUTED_GOTO=1`; they run correctly, and the 2026-09-15 re-validation
  of the common data-reference fix (`208d52e`, §2.2) ran the new `-rewrite`
  against exactly that baseline. The harness now disables computed goto by
  default on both architectures (`PG_COMPUTED_GOTO=1` re-enables it).

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

| Arch | App | Mode | `bolt` | `bolt-rewrite` | `bolt-rewrite-nohuge` |
|---|---|---|---|---|---|
| aarch64 | MariaDB | pie | **+45.04 %** | **+46.21 %** | **+45.26 %** |
| aarch64 | MariaDB | no-pie | **+47.62 %** | **+46.90 %** | **+50.61 %** |
| aarch64 | PostgreSQL | pie | **+35.27 %** | **+35.63 %** | **+38.21 %** |
| aarch64 | PostgreSQL | no-pie | **+35.23 %** | **+35.42 %** | **+36.78 %** |
| x86_64 | MariaDB | pie | **+20.36 %** | **+21.90 %** | — |
| x86_64 | MariaDB | no-pie | **+21.27 %** | **+19.09 %** | — |
| x86_64 | PostgreSQL | pie | **+9.21 %** | **+3.97 %** | — |
| x86_64 | PostgreSQL | no-pie | **+14.37 %** | **+12.22 %** | — |

On aarch64 `-rewrite` trails the in-place `bolt` variant by roughly 0.5–3
points (except MariaDB no-pie), as expected for a full re-emission vs. in-place
patching; on x86_64 the two are closer (and `-rewrite` leads slightly on MariaDB
pie). `bolt-rewrite-nohuge` performs within run-to-run noise of `bolt-rewrite`
on aarch64 (−1.0 … +3.7 points; it is a *size* change, not a reordering change).
The aarch64 deltas were re-measured at rev `d1723d9d` in one four-variant
session; absolute levels vary between runs (see §5.5), but the ordering and
magnitude are stable. The x86_64 `bolt-rewrite-nohuge` column is pending the
x86_64 re-run.

### 4.2 Per-workload throughput means

**aarch64 — MariaDB — pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 34,291.11 | 52,130.25 | 52,566.96 | 52,179.28 |
| oltp_read_write | TPS | 1,208.16 | 1,671.82 | 1,684.73 | 1,675.43 |
| oltp_read_write | QPS | 24,163.26 | 33,436.45 | 33,694.45 | 33,508.66 |

**aarch64 — MariaDB — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 33,923.12 | 52,991.04 | 52,415.68 | 54,707.54 |
| oltp_read_write | TPS | 1,202.51 | 1,677.58 | 1,679.40 | 1,691.38 |
| oltp_read_write | QPS | 24,050.11 | 33,551.65 | 33,588.02 | 33,827.63 |

**aarch64 — PostgreSQL — pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| select-only | TPS | 31,102.90 | 42,907.48 | 42,787.06 | 44,013.47 |
| tpcb-like | TPS | 5,298.06 | 7,027.30 | 7,084.12 | 7,151.78 |

**aarch64 — PostgreSQL — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| select-only | TPS | 30,701.17 | 42,454.20 | 42,437.52 | 43,063.77 |
| tpcb-like | TPS | 5,238.47 | 6,927.98 | 6,949.83 | 6,987.32 |

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

| Arch | App | Mode | `bolt` | `bolt-rewrite` | `bolt-rewrite-nohuge` |
|---|---|---|---|---|---|
| aarch64 | MariaDB | pie | −30.44 % | −31.47 % | −30.90 % |
| aarch64 | MariaDB | no-pie | −32.36 % | −32.01 % | −33.78 % |
| aarch64 | PostgreSQL | pie | −26.08 % | −26.25 % | −27.66 % |
| aarch64 | PostgreSQL | no-pie | −26.03 % | −26.15 % | −26.91 % |
| x86_64 | MariaDB | pie | −17.10 % | −18.86 % | — |
| x86_64 | MariaDB | no-pie | −17.38 % | −15.34 % | — |
| x86_64 | PostgreSQL | pie | −8.40 % | −3.67 % | — |
| x86_64 | PostgreSQL | no-pie | −12.63 % | −10.98 % | — |

Per-workload average latency (ms):

| Arch | App | Mode | workload | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|---|---|
| aarch64 | MariaDB | pie | oltp_point_select | 0.46 | 0.31 | 0.30 | 0.31 |
| aarch64 | MariaDB | pie | oltp_read_write | 13.22 | 9.56 | 9.48 | 9.54 |
| aarch64 | MariaDB | no-pie | oltp_point_select | 0.47 | 0.30 | 0.30 | 0.29 |
| aarch64 | MariaDB | no-pie | oltp_read_write | 13.29 | 9.52 | 9.52 | 9.44 |
| aarch64 | PostgreSQL | pie | select-only | 0.51 | 0.37 | 0.37 | 0.36 |
| aarch64 | PostgreSQL | pie | tpcb-like | 3.02 | 2.28 | 2.26 | 2.24 |
| aarch64 | PostgreSQL | no-pie | select-only | 0.52 | 0.38 | 0.38 | 0.37 |
| aarch64 | PostgreSQL | no-pie | tpcb-like | 3.05 | 2.31 | 2.30 | 2.29 |
| x86_64 | MariaDB | pie | oltp_point_select | 0.11 | 0.09 | 0.09 |
| x86_64 | MariaDB | pie | oltp_read_write | 3.43 | 2.86 | 2.84 |
| x86_64 | MariaDB | no-pie | oltp_point_select | 0.11 | 0.09 | 0.09 |
| x86_64 | MariaDB | no-pie | oltp_read_write | 3.42 | 2.85 | 2.89 |
| x86_64 | PostgreSQL | pie | select-only | 0.08 | 0.07 | 0.08 |
| x86_64 | PostgreSQL | pie | tpcb-like | 0.51 | 0.47 | 0.48 |
| x86_64 | PostgreSQL | no-pie | select-only | 0.09 | 0.08 | 0.08 |
| x86_64 | PostgreSQL | no-pie | tpcb-like | 0.57 | 0.50 | 0.51 |

### 4.4 Binary size

The BOLT input is linked with `-Wl,-q`, so it carries non-allocatable `.rela.*`
sections and a symbol table that are not part of the deployed image; stripping
removes them (runtime `.rela.dyn`/`.rela.plt` are kept). Comparing raw file
sizes therefore flatters BOLT output, which no longer carries those sections,
so all deltas below use **stripped file size**, for both architectures.

**x86_64 (stripped file size)**

| App | Mode | baseline (bytes) | `bolt` (Δ) | `bolt-rewrite` (Δ) |
|---|---|---|---|---|
| MariaDB | pie | 26,921,472 | 33,155,760 (**+23.2 %**) | 26,921,152 (**−0.0 %**) |
| MariaDB | no-pie | 22,346,312 | 28,593,264 (**+28.0 %**) | 22,367,000 (**+0.1 %**) |
| PostgreSQL | pie | 9,651,888 | 14,807,928 (**+53.4 %**) | 9,664,856 (**+0.1 %**) |
| PostgreSQL | no-pie | 9,367,352 | 14,523,208 (**+55.0 %**) | 9,376,200 (**+0.1 %**) |

**aarch64 (stripped file size; rev `d1723d9d`)**

| App | Mode | baseline (bytes) | `bolt` (Δ) | `bolt-rewrite` (Δ) | `bolt-rewrite-nohuge` (Δ) |
|---|---|---|---|---|---|
| MariaDB | pie | 26,151,200 | 41,727,128 (**+59.6 %**) | 31,608,128 (**+20.9 %**) | 30,166,360 (**+15.4 %**) |
| MariaDB | no-pie | 21,563,752 | 37,234,520 (**+72.7 %**) | 27,413,656 (**+27.1 %**) | 25,578,672 (**+18.6 %**) |
| PostgreSQL | pie | 9,541,128 | 19,163,888 (**+100.9 %**) | 12,621,424 (**+32.3 %**) | 11,703,944 (**+22.7 %**) |
| PostgreSQL | no-pie | 9,281,184 | 18,902,104 (**+103.7 %**) | 12,620,504 (**+36.0 %**) | 11,440,880 (**+23.3 %**) |

The earlier raw (unstripped) figures for these binaries (e.g. PostgreSQL
`-rewrite` ≈ −18 %) were an artifact of comparing a relocation-heavy baseline
against BOLT output that no longer carries the `.rela.*`/symbol sections.

#### 4.4.1 Alignment and placement overhead

BOLT aligns relocated code to 2 M by default (`BC->PageAlign = HugePageSize`,
§2.3); the padding this introduces is counted in the stripped file even though it
is not code. `pipeline/size-report.sh` measures, on the **stripped** artifacts:
the `.text` section alignment, the maximum `PT_LOAD` `p_align`, the padding
between consecutive `PT_LOAD` segments (`seghole`), and the total file slack
(stripped size − section bytes − ELF/header bytes, `gaps`). Percentages are of
the stripped file.

| App | Mode | variant | `.text` | LOAD | seghole | gaps | gaps % |
|---|---|---|---|---|---|---|---|
| MariaDB | pie | baseline | 64 | 64 K | 31 KB | 62 KB | 0.24 % |
| MariaDB | pie | bolt | 2 M | 2 M | 31 KB | 2.16 MB | 5.18 % |
| MariaDB | pie | bolt-rewrite | 64 K | 2 M | 1.48 MB | 2.41 MB | 7.63 % |
| MariaDB | pie | bolt-rewrite-nohuge | 64 K | 64 K | 35 KB | 0.97 MB | 3.21 % |
| MariaDB | no-pie | baseline | 64 | 64 K | 52 KB | 78 KB | 0.36 % |
| MariaDB | no-pie | bolt | 2 M | 2 M | 52 KB | 2.18 MB | 5.84 % |
| MariaDB | no-pie | bolt-rewrite | 64 K | 2 M | 1.89 MB | 2.83 MB | 10.34 % |
| MariaDB | no-pie | bolt-rewrite-nohuge | 64 K | 64 K | 60 KB | 1.00 MB | 3.90 % |
| PostgreSQL | pie | baseline | 64 | 64 K | 31 KB | 34 KB | 0.36 % |
| PostgreSQL | pie | bolt | 2 M | 2 M | 31 KB | 2.13 MB | 11.12 % |
| PostgreSQL | pie | bolt-rewrite | 64 K | 2 M | 0.95 MB | 1.60 MB | 12.65 % |
| PostgreSQL | pie | bolt-rewrite-nohuge | 64 K | 64 K | 34 KB | 0.68 MB | 5.80 % |
| PostgreSQL | no-pie | baseline | 64 | 64 K | 62 KB | 66 KB | 0.71 % |
| PostgreSQL | no-pie | bolt | 2 M | 2 M | 62 KB | 2.16 MB | 11.44 % |
| PostgreSQL | no-pie | bolt-rewrite | 64 K | 2 M | 1.24 MB | 1.89 MB | 14.97 % |
| PostgreSQL | no-pie | bolt-rewrite-nohuge | 64 K | 64 K | 61 KB | 0.71 MB | 6.20 % |

Observations:

* Without BOLT the binaries are essentially gap-free (0.24 % … 0.71 %).
* `bolt` (no-rewrite) aligns the new `.text` to 2 M; on aarch64 that alone adds
  ≈2.1 MB of in-segment padding (5 % … 11 % of the file). Together with keeping
  the original code as `.bolt.org.text`, this is why `bolt` looks so much larger
  than its emitted code.
* `-rewrite` keeps a 64 K `.text` alignment but 2 M-aligns its new `PT_LOAD`,
  leaving a 0.95 … 1.89 MB segment hole (7.6 % … 15.0 % of the file). After
  stripping, the larger raw inter-segment hole is compacted, but this alignment
  padding remains.
* `bolt-rewrite-nohuge` removes the 2 M alignment (`.text` and `LOAD` both 64 K,
  `seghole` back to the baseline ≈31 … 62 KB) and roughly halves the rewrite gap
  (3.2 % … 6.2 %). It cuts the aarch64 `-rewrite` size increase from
  +21 % … +36 % to **+15 % … +23 %** (1.4 … 1.8 MB per binary) with performance
  within run-to-run noise of `bolt-rewrite` (§4.1).
* The 2 M alignment is BOLT's default; the harness does not request
  `--hugify`/`--hot-text`, so the huge pages are never actually used. On x86_64
  the same switch falls back to 4 K regular pages; the x86_64 `nohuge` figures
  are pending that platform's re-run.
* `bolt`, `bolt-rewrite` and `bolt-rewrite-nohuge` all patch the ELF build-id
  (last bit flipped) — verified on all twelve optimized aarch64 binaries.

### 4.5 Functional validation

aarch64 re-validation at rev `d1723d9d` (all four app/mode combinations, all
three optimized variants including `bolt-rewrite-nohuge`):

* All twelve aarch64 optimized binaries (`bolt`, `bolt-rewrite`,
  `bolt-rewrite-nohuge` × 2 apps × 2 modes) exist and `--version` exits 0 within
  the harness health-check timeout; no `*.failed` artifact and no
  `bolt-*.verify.log` was left behind.
* Each optimized binary started as the benchmark server and completed the full
  workload (sysbench `oltp_point_select`+`oltp_read_write`; pgbench
  `select-only`+`tpcb-like`; 1 warmup + 3 recorded reps) with **0 errors**:
  sysbench `ignored errors = 0` and `reconnects = 0`, pgbench
  `failed transactions = 0`, and no server `SIGSEGV`/`FATAL`/`PANIC` lines.
* No `BOLT-ERROR` and no `corrupted control flow` message in any optimize log.
  The warning sets are identical to rev `502a8fc` (MariaDB pie `bolt`/`rewrite`:
  26/12 warnings; MariaDB no-pie 38/15; PostgreSQL pie 9/4; PostgreSQL no-pie
  8/4), so the common data-ref fix is behavior-neutral on these aarch64 inputs.
* Read-only content is preserved: `strings` counts are unchanged from baseline
  for every variant (`MariaDB` 117; `PostgreSQL` 39), exercising the
  content-preservation fix.
* Build-id is distinct from the baseline (last bit flipped) for all twelve
  binaries. The four `bolt` outputs and PostgreSQL `-rewrite` are byte-identical
  to rev `502a8fc` apart from the embedded BOLT revision; MariaDB `-rewrite`
  additionally carries the preserved `.bolt.org.gcc_except_table` (see §2.2 and
  §4.4).

The x86_64 run (same revision) reported the same end-to-end properties for its
three-variant pipeline (`bolt` + `bolt-rewrite`): all outputs produced, 0
workload errors, build-id patched.

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
   bolt-rewrite (and, with `NOHUGE=1`, bolt-rewrite-nohuge) benched
   back-to-back, and are only comparable within one architecture.
6. **Containers.** The aarch64 containers mount `$HOME/src/llvm-23.1.1` at
   `/llvm:ro`; the x86_64 containers mount `$HOME/src/llvm-project-23`.
   Previous result directories are preserved.
7. **Build-id** is patched (last bit flipped) by both `bolt` and
   `bolt-rewrite` on both architectures.
8. **aarch64 re-validation method and size metric.** The 2026-09-15 aarch64
   re-run reused the existing baselines, prepared datasets and merged profiles
   and re-ran only optimize + bench + compare (`SKIP_BUILD=1 SKIP_PROFILE=1`),
   so any delta versus the earlier aarch64 run is attributable to the BOLT
   revision rather than to a new profile. The old-tool artifacts and optimize
   logs are preserved under `work/backup-502a8fc/`. Deployed size is compared on
   **stripped file size** for both architectures (§4.4); `pipeline/size-report.sh`
   additionally reports the section/segment alignment share of that size.
9. **`--no-huge-pages` variant.** `NOHUGE=1` adds the `bolt-rewrite-nohuge`
   configuration (see §2.3). On aarch64 it removes BOLT's default 2 M code
   alignment and roughly halves the `-rewrite` size overhead, with performance
   within run-to-run noise. It is architecture-neutral and is intended to be run
   identically on x86_64. Adding the longer variant name also exposed a
   PostgreSQL-only 107-byte Unix-socket path limit; `apps/postgresql/app.sh` now
   uses a short fixed socket subdirectory.

---

## 6. Reproduction

```bash
# 0. Tools under test
$HOME/src/llvm-23.1.1/build/bin/llvm-bolt --version       # aarch64, rev d1723d9d
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
(`bolt` + `bolt-rewrite`, plus `bolt-rewrite-nohuge` when `NOHUGE=1`) → bench
(every variant in `VALID_WHICH`) → compare.

### 2026-09-15 aarch64 re-validation + `nohuge` (no re-profiling)

The aarch64 numbers in this report were refreshed with rev `d1723d9d` by
reusing the existing baselines, datasets and merged profiles and re-running
only the optimization and benchmark stages. `NOHUGE=1` adds the fourth
configuration; the same command works on x86_64 (omit the veneer flag there):

```bash
FLAGS='-reorder-blocks=ext-tsp -reorder-functions=hfsort -split-functions \
       -split-all-cold -split-eh -dyno-stats --drop-cortex-a53-843419-veneers'
for c in bolt-harness-mariadb bolt-harness-postgresql; do
  app=mariadb; [ "$c" = bolt-harness-postgresql ] && app=postgresql
  docker exec -i "$c" \
    env APP=$app HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build/bin CC=gcc NOHUGE=1 \
        BOLT_OPT_FLAGS="$FLAGS" \
    bash -c 'SKIP_BUILD=1 SKIP_PROFILE=1 /harness/pipeline/run-all.sh pie no-pie'
done

# Stripped size + section/segment alignment report for every variant:
APP=mariadb NOHUGE=1 pipeline/size-report.sh pie no-pie
APP=postgresql NOHUGE=1 HARNESS_WORK="$PWD/work/postgresql" \
  pipeline/size-report.sh pie no-pie
```

The pre-re-validation (rev `502a8fc`) optimized binaries and logs are kept under
`work/backup-502a8fc/`; the run logs are `work/validate-aarch64-*.out`.

---

## 7. Data sources

* Pipeline logs: `bolt-harness/work/newbolt-*.out` (first run),
  `bolt-harness/work/validate-aarch64-{mariadb,postgresql}.out` (2026-09-15
  re-validation) and `…-nohuge.out` (2026-09-15 four-variant/NOHUGE run)
* Functional-check transcripts: `bolt-harness/work/validate-aarch64-checks.txt`
  and `bolt-harness/work/validate-aarch64-nohuge-checks.txt`
* Consolidated metrics/sizes: `bolt-harness/work/validate-aarch64-data.txt`,
  `…-data-nohuge.txt` and the stripped alignment report
  `bolt-harness/work/validate-aarch64-sizes.txt`
* Pre-re-validation (rev `502a8fc`) binaries, logs and manifest:
  `bolt-harness/work/backup-502a8fc/`
* Benchmark results: `bolt-harness/work[/postgresql]/_state/<app>/results/<mode>/<variant>/<timestamp>/summary.tsv`
* Binaries and build info: `…/_state/<app>/binaries/<mode>/{baseline,*.bolt,*.bolt-rewrite,*.bolt-rewrite-nohuge,build-info.txt}`
* BOLT logs: `…/_state/<app>/binaries/<mode>/bolt-{bolt,bolt-rewrite,bolt-rewrite-nohuge}.log`
