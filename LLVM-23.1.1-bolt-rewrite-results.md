# LLVM 23.1.1 BOLT `-rewrite` — Results on MariaDB, PostgreSQL, MongoDB and CPython (aarch64 & x86_64)

Date: 2026-09-15 (aarch64 MongoDB added 2026-09-16; CPython aarch64 re-verified 2026-09-17)
Harness: `bolt-harness`
Tool under test: `llvm-bolt`, LLVM **23.1.1**, branch `llvmorg-23.1.1-rewrite`:

- **aarch64**: `$HOME/src/llvm-23.1.1/build/bin/llvm-bolt`, revision
  `d1723d9d8a4d763722331379ab265e94b6c3cb14` (34 `[BOLT][Rewrite]` commits
  rebased onto tag `llvmorg-23.1.1`). The aarch64 results below were
  re-validated on 2026-09-15 with this revision after three additional
  `-rewrite` fixes landed on the branch (see §2.2); the earlier aarch64 run
  used `502a8fc3a4ce`. The aarch64 set also includes a fourth configuration,
  `bolt-rewrite-nohuge` (`-rewrite --no-huge-pages`), added to quantify BOLT's
  default 2 M huge-page code alignment (see §2.3 and §4.4). The CPython aarch64
  results were re-verified on 2026-09-17 with revision `d0a877fc33a1` (36
  `[BOLT][Rewrite]` commits), which adds *Reject `-rewrite` with `-skip-funcs`*
  and *Fix AArch64 TLSDESC descriptor retargeting* (see §3.5); all other
  aarch64 results remain at `d1723d9d`.
- **x86_64**: `$HOME/src/llvm-project-23/build23/bin/llvm-bolt`, same branch,
  revision `d1723d9d8a4d` (the same revision as aarch64; both architectures are
  now on one revision). The x86_64 results below also include the fourth
  configuration, `bolt-rewrite-nohuge`.
- **MongoDB**: MongoDB 7.0 (`r7.0.43`, built from source with SCons) was added
  to the harness and measured with YCSB on x86_64 (2026-09-15, standard three
  configurations) and, on 2026-09-16, on aarch64 (both link modes, four
  configurations including `bolt-rewrite-nohuge`) with the same BOLT revision
  (see §3.4).
- **CPython**: CPython 3.13.9 (`v3.13.9`) is measured with the **pyperformance**
  suite (`ops_per_sec`). It was validated with LLVM 23.1.1 on x86_64 (both
  modes; `bolt` +10.2 % pie / +10.5 % no-pie) and on aarch64 (2026-09-17, both
  modes, four configurations; `bolt` +19.72 % pie / +21.34 % no-pie,
  `-rewrite` +21.14 % / +19.77 %, `-rewrite-nohuge` +18.32 % / +19.93 %). The
  two modes BOLT different targets: `pie` optimizes shared
  `libpython3.13.so.1.0`, `no-pie` the static `python3` executable. The aarch64
  `-rewrite` outputs were the motivation for the two fixes in `d0a877fc33a1`
  and now run (see §3.5).

## Summary

The `-rewrite` feature was validated end-to-end on three real server
applications plus the CPython interpreter, in both ELF link modes, on
**aarch64** and **x86_64**, against the standard profile-driven BOLT pipeline.

**aarch64** (rev `d1723d9d`, CPython at `d0a877f`; four configurations; MongoDB added 2026-09-16)

| App | Mode | `bolt` | `bolt-rewrite` | `bolt-rewrite-nohuge` | workload errors |
|---|---|---|---|---|---|
| MariaDB | pie | **+45.04 %** | **+46.21 %** | **+45.26 %** | 0 |
| MariaDB | no-pie | **+47.62 %** | **+46.90 %** | **+50.61 %** | 0 |
| PostgreSQL | pie | **+35.27 %** | **+35.63 %** | **+38.21 %** | 0 |
| PostgreSQL | no-pie | **+35.23 %** | **+35.42 %** | **+36.78 %** | 0 |
| MongoDB | pie | **+34.30 %** | **+43.68 %** | **+42.71 %** | 0 |
| MongoDB | no-pie | **+40.97 %** | **+40.51 %** | **+40.55 %** | 0 |
| CPython | pie | **+19.72 %** | **+21.14 %** | **+18.32 %** | 0 |
| CPython | no-pie | **+21.34 %** | **+19.77 %** | **+19.93 %** | 0 |

**x86_64** (2026-09-15, rev `d1723d9d`; four configurations)

| App | Mode | `bolt` | `bolt-rewrite` | `bolt-rewrite-nohuge` | workload errors |
|---|---|---|---|---|---|
| MariaDB | pie | **+10.27 %** | **+16.39 %** | **+22.40 %** | 0 |
| MariaDB | no-pie | **+20.69 %** | **+21.46 %** | **+21.44 %** | 0 |
| PostgreSQL | pie | **+7.66 %** | **+1.79 %** | **+2.46 %** | 0 |
| PostgreSQL | no-pie | **+16.36 %** | **+18.31 %** | **+15.59 %** | 0 |
| MongoDB | pie | **+24.35 %** | **+20.05 %** | — | 0 |
| MongoDB | no-pie | **+28.89 %** | **+32.73 %** | — | 0 |
| CPython | pie | **+10.2 %** | — | — | 0 |
| CPython | no-pie | **+10.5 %** | — | — | 0 |

(Throughput geomean vs. the unmodified baseline; higher is better. MongoDB was
measured on x86_64 on 2026-09-15 with the standard three configurations, and on
aarch64 (both link modes) on 2026-09-16 with the fourth `bolt-rewrite-nohuge`
configuration. `bolt-rewrite-nohuge` is the regular `-rewrite` build with
BOLT's default 2 M huge-page code alignment replaced by the target's regular
page size, i.e. `-rewrite --no-huge-pages` — see §2.3. CPython is measured with
pyperformance, so its figure is the `ops_per_sec` geomean; it was run on x86_64
on 2026-09-15 (three configurations) and on aarch64 on 2026-09-16 (four
configurations; `no-pie` uses `PY_COMPUTED_GOTO=0`, see §3.5). The aarch64
CPython results use rev `d0a877f`, whose two fixes make `-rewrite` usable; the
x86_64 CPython `-rewrite` cells were not re-verified with that revision, hence
the `—`.)

All optimized `-rewrite` binaries (plain and `bolt-rewrite-nohuge`) in the
configurations above are produced, start, and complete the full benchmark
workload with zero errors. (With rev `d1723d9d`, CPython's `-rewrite` outputs
crashed on import; the rev `d0a877f` fixes resolve that on aarch64 — see §3.5,
§4.5.)

Binary size (measured on **stripped** binaries, §4.4): on **x86_64** `bolt`
grows the runtime image by +16.5 % … +55 % (it keeps the original code), while
`-rewrite` is near size-neutral (≤ 2.3 %); because x86_64 `-rewrite` is
already regular-page aligned, `bolt-rewrite-nohuge` matches `-rewrite`
(≤ 16 B). On **aarch64** `bolt` grows the runtime image by +60 % … +104 % and
`-rewrite` by +3.7 % … +36 %; a substantial part of both is alignment/placement
padding introduced by BOLT's default 2 M code alignment. Replacing it with the
regular page size (`bolt-rewrite-nohuge`) removes the aarch64 `-rewrite`
overhead (down to +3.4 % … +23 %). MongoDB `bolt` adds +16.5 % / +17.2 %
(x86_64 pie/no-pie) / +66.7 % / +69.2 % (aarch64 pie/no-pie) and `-rewrite`
+2.1 % / +2.3 % / +3.7 % / +4.0 %. On aarch64 CPython `bolt` adds +107.1 %
(pie) / +116.3 % (no-pie); `-rewrite` +37.8 % / +42.5 %, reduced by
`--no-huge-pages` to +22.0 % / +8.7 % (the interpreter is small, so BOLT's
retained original code dominates the deployed size; see §4.4).

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
| Workload generators | sysbench (MariaDB), pgbench (PostgreSQL), YCSB (MongoDB) |
| MongoDB build | Ubuntu 24.04 container, GCC 12.4, deadsnakes Python 3.10, MongoDB 7.0 `r7.0.43` (SCons) |

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
size and alignment figures. (On x86_64 the default `-rewrite` is already
regular-page aligned, so the flag changes nothing there; see §4.4.1.)

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

### 3.4 MongoDB 7.0 (`r7.0.43`, github.com/mongodb/mongo)

MongoDB 7.0 is the last release built with **SCons** (8.0 is Bazel-only), which
exposes `CCFLAGS`/`CXXFLAGS`/`LINKFLAGS` so the BOLT flags can be injected
natively. It is built in an Ubuntu 24.04 container — the host-built `llvm-bolt`
needs glibc ≥ 2.36, so the other apps' base is required — with GCC 12 and a
deadsnakes Python 3.10 venv for MongoDB's pinned SCons requirements. `mongod`
is the optimized binary (WiredTiger, `--js-engine=none`, `--allocator=system`);
both link modes share one SCons tree and differ only in `LINKFLAGS`. The
aarch64 measurements (2026-09-16, LLVM 23.1.1) use the same recipe with
`-mbranch-protection=none` and, on this host, `--drop-cortex-a53-843419-veneers`
for the BOLT instrumentation/optimization passes.

```bash
CCFLAGS/CXXFLAGS='-fno-omit-frame-pointer -fno-stack-protector [-mbranch-protection=none]'
LINKFLAGS='-Wl,--emit-relocs'          # pie; no-pie adds -no-pie
python3 buildscripts/scons.py install-mongod \
  --opt=on --dbg=off --runtime-hardening=off --js-engine=none \
  --allocator=system --linker=gold --disable-warnings-as-errors
objcopy --strip-debug mongod           # 8.5 GB raw -> ~220 MB BOLT input
```

`--js-engine=none` drops the bundled mozjs engine (unused by the workload, and
its direct-threaded computed-goto interpreter is a BOLT hazard);
`objcopy --strip-debug` removes full DWARF while keeping the symbol table,
`.eh_frame` and the `--emit-relocs` `.rela.*` sections.

Baseline binary characteristics:

| Arch | Mode | ELF | relocations | `mongod` raw | stripped |
|---|---|---|---|---|---|
| x86_64 | pie | `ELF 64-bit LSB pie executable` | 2,431,098 | 221 MB | 129,725,304 B |
| x86_64 | no-pie | `ELF 64-bit LSB executable` | 2,258,954 | 217 MB | 125,596,536 B |
| aarch64 | pie | `ELF 64-bit LSB pie executable` | 2,702,276 | 219 MB | 120,792,312 B |
| aarch64 | no-pie | `ELF 64-bit LSB executable` | 2,523,766 | 215 MB | 116,466,936 B |

Workload: **YCSB** (`mongodb` binding, `mongodb-driver-sync`) — `workloada`
(50/50 read/update) + `workloadc` (read-only), 2,000,000 records × 10 fields,
16 threads, 15 s per workload, 1 warmup + 3 recorded reps, WiredTiger cache
4 GB.

### 3.5 CPython 3.13.9 (`v3.13.9`, github.com/python/cpython)

The harness builds CPython 3.13.9 out-of-tree with `-O2` and BOLT-friendly
flags; each mode optimizes a different artifact, so `compare.sh` compares
within a mode:

| Mode | CPython build | BOLT target |
|---|---|---|
| `pie` | `--enable-shared` | `libpython3.13.so.1.0` (loaded by the installed `python3` launcher via a staged SONAME on `LD_LIBRARY_PATH`) |
| `no-pie` | static libpython in the executable, `-fno-pie -no-pie` | the `python3` executable |

```bash
CFLAGS:  -O2 -fno-omit-frame-pointer -fno-stack-protector \
         [-mbranch-protection=none] -fno-reorder-blocks-and-partition
LDFLAGS: -Wl,-q
pie:     --enable-shared
no-pie:  CFLAGS_NODIST=-fno-pie  LINKCC='gcc -fno-pie -no-pie'
common:  --with-ensurepip=install --disable-test-modules --with-computed-gotos[=no]
```

The workload is **pyperformance** 1.14.0 run through
`apps/python/bench/run_pyperformance.py` (each benchmark's `run_benchmark.py`
under the prefix-installed `pyperf`, so no per-benchmark venvs). It reports
`ops_per_sec` medians for 24 benchmarks; 1 warmup + 3 recorded reps.

BOLT specifics: `-instrumentation-file-append-pid` (pyperformance forks a
worker per benchmark) and `-skip-funcs=_PyEval_EvalFrameDefault,`
`sre_ucs1_match/1,sre_ucs2_match/1,sre_ucs4_match/1` on the **instrumentation**
pass to exclude the computed-goto dispatch functions; `PROFILE_SLEEP_TIME=0` so
BOLT dumps the profile at process exit (its periodic dump thread deadlocks with
pyperformance's forking). `-skip-funcs` must **not** be passed to the
optimization pass: `-rewrite` re-lays-out the whole binary and rejects it
(`d7136fcb56ab`), because skipped functions are neither disassembled nor emitted,
leaving callers branching into reused addresses and silently corrupting the
output. `app.sh` defines `app_verify_bin`, which stages a `pie` `.so` and runs
`import sys, pyperf, pyperformance` as the health check, so a miscompiled
`-rewrite` output that survives `--version` but crashes on real imports is
caught and parked as `.failed`.

**aarch64 non-PIE needs `PY_COMPUTED_GOTO=0`.** With the default computed-goto
eval loop, the BOLT-instrumented static `no-pie` executable aborts
(`free(): invalid pointer`) inside `subprocess`/fork when pyperformance spawns
its worker, so the workload cannot run; the switch-based eval loop
(`PY_COMPUTED_GOTO=0`) avoids it, and the aarch64 `no-pie` results below
therefore use the switch eval loop. The `pie` target (shared libpython) profiles
fine with computed gotos on.

**Re-verification with the two `-rewrite` fixes (2026-09-17).** Earlier aarch64
runs (rev `d1723d9d`, `-skip-funcs` still passed to the optimization pass)
produced `-rewrite` outputs that crashed on import — `pie` during
`Py_InitializeFromConfig` (AArch64 TLS descriptor retargeting) and both modes
from the skipped-function corruption. Revision `d0a877fc33a1` rejects
`-rewrite` with `-skip-funcs` and fixes AArch64 TLSDESC descriptor retargeting;
re-running with `-skip-funcs` removed from the optimization pass (instrumentation
still skips), the `bolt`, `-rewrite` and `-rewrite-nohuge` binaries for both
modes are produced, pass `app_verify_bin`, and complete the full pyperformance
suite with zero errors (§4.5).

Baseline binary characteristics (aarch64):

| Arch | Mode | BOLT target | ELF | relocations | raw | stripped |
|---|---|---|---|---|---|---|
| aarch64 | pie | `libpython3.13.so.1.0` | `ELF 64-bit LSB shared object` | 129,830 | 8.2 MB | 5,382,176 B |
| aarch64 | no-pie | `python3` | `ELF 64-bit LSB executable` | 108,706 | 7.6 MB | 4,845,784 B |

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
| aarch64 | MongoDB | pie | **+34.30 %** | **+43.68 %** | **+42.71 %** |
| aarch64 | MongoDB | no-pie | **+40.97 %** | **+40.51 %** | **+40.55 %** |
| aarch64 | CPython | pie | **+19.72 %** | **+21.14 %** | **+18.32 %** |
| aarch64 | CPython | no-pie | **+21.34 %** | **+19.77 %** | **+19.93 %** |
| x86_64 | MariaDB | pie | **+10.27 %** | **+16.39 %** | **+22.40 %** |
| x86_64 | MariaDB | no-pie | **+20.69 %** | **+21.46 %** | **+21.44 %** |
| x86_64 | PostgreSQL | pie | **+7.66 %** | **+1.79 %** | **+2.46 %** |
| x86_64 | PostgreSQL | no-pie | **+16.36 %** | **+18.31 %** | **+15.59 %** |
| x86_64 | MongoDB | pie | **+24.35 %** | **+20.05 %** | — |
| x86_64 | MongoDB | no-pie | **+28.89 %** | **+32.73 %** | — |
| x86_64 | CPython | pie | **+10.2 %** | — | — |
| x86_64 | CPython | no-pie | **+10.5 %** | — | — |

On aarch64 `bolt` and `-rewrite` are within a few points of each other
(MongoDB `pie` is the outlier, where `-rewrite` leads by ~9 points), as
expected for a full re-emission vs. in-place patching; on x86_64 the variants
are closer and the ordering is within run-to-run noise. `bolt-rewrite-nohuge`
performs within run-to-run noise of `bolt-rewrite` on both architectures
(aarch64 −1.0 … +3.7 points, x86_64 −2.7 … +6.0 points; it is a *size* change,
not a reordering change). CPython's figures are `ops_per_sec` geomeans
(pyperformance); its aarch64 results use rev `d0a877f` and now include
`-rewrite` (§3.5), while the x86_64 `-rewrite` cells were not re-verified with
that revision (`—`). All deltas were measured at rev `d1723d9d` in one
four-variant session per app/mode; absolute levels vary between runs (see
§5.5), but the ordering and magnitude are stable.

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

**aarch64 — MongoDB — pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| workloada | TPS | 9,184.98 | 12,027.45 | 12,964.17 | 12,761.61 |
| workloadc | TPS | 12,579.53 | 17,327.81 | 18,400.13 | 18,438.83 |

**aarch64 — MongoDB — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| workloada | TPS | 9,202.43 | 13,101.50 | 12,788.70 | 12,810.39 |
| workloadc | TPS | 13,114.89 | 18,306.46 | 18,632.11 | 18,610.07 |

**x86_64 — MariaDB — pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 144,642.86 | 159,815.47 | 164,728.80 | 173,592.94 |
| oltp_read_write | TPS | 4,730.85 | 5,206.25 | 5,626.88 | 5,905.65 |
| oltp_read_write | QPS | 94,616.88 | 104,125.05 | 112,537.66 | 118,113.12 |

**x86_64 — MariaDB — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 142,912.38 | 168,070.83 | 175,419.27 | 173,751.39 |
| oltp_read_write | TPS | 4,808.81 | 5,955.72 | 5,779.43 | 5,832.80 |
| oltp_read_write | QPS | 96,176.20 | 119,114.36 | 115,588.48 | 116,656.08 |

**x86_64 — PostgreSQL — pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| select-only | TPS | 216,330.52 | 229,745.54 | 215,829.99 | 224,034.51 |
| tpcb-like | TPS | 32,582.77 | 35,561.69 | 33,834.67 | 33,026.34 |

**x86_64 — PostgreSQL — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| select-only | TPS | 186,550.06 | 222,622.19 | 215,895.88 | 209,699.53 |
| tpcb-like | TPS | 27,481.13 | 31,182.00 | 33,239.82 | 32,664.51 |

**x86_64 — MongoDB — pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| workloada | TPS | 36,509.89 | 45,886.50 | 43,349.49 |
| workloadc | TPS | 50,158.29 | 61,708.09 | 60,885.32 |

**x86_64 — MongoDB — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite |
|---|---|---|---|---|
| workloada | TPS | 32,247.78 | 41,753.12 | 44,134.14 |
| workloadc | TPS | 52,042.13 | 66,775.41 | 66,987.86 |

**aarch64 — CPython — pie** (`ops_per_sec`; rev `d0a877f`)

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| pyflate | ops_per_sec | 1.72 | 1.82 | 1.82 | 1.81 |
| scimark_sor | ops_per_sec | 5.51 | 6.08 | 6.09 | 6.05 |
| nbody | ops_per_sec | 9.45 | 9.55 | 9.48 | 9.51 |
| regex_v8 | ops_per_sec | 157.32 | 331.10 | 332.05 | 331.29 |
| scimark_lu | ops_per_sec | 6.31 | 7.27 | 7.35 | 7.38 |
| scimark_sparse_mat_mult | ops_per_sec | 2,381.30 | 5,501.38 | 5,483.05 | 5,466.92 |
| float | ops_per_sec | 9.42 | 20.60 | 20.47 | 20.34 |
| python_startup | ops_per_sec | 165.60 | 174.09 | 215.24 | 129.46 |
| nqueens | ops_per_sec | 7.73 | 8.97 | 8.98 | 8.91 |
| go | ops_per_sec | 5.92 | 6.02 | 6.07 | 6.06 |
| richards | ops_per_sec | 34.04 | 36.08 | 36.44 | 36.38 |
| scimark_fft | ops_per_sec | 2.26 | 2.55 | 2.55 | 2.54 |
| fannkuch | ops_per_sec | 1.70 | 2.03 | 2.01 | 1.99 |
| pickle | ops_per_sec | 31,365,866.67 | 33,890,600.00 | 33,953,833.33 | 34,020,633.33 |
| spectral_norm | ops_per_sec | 6.73 | 7.56 | 7.57 | 7.56 |
| telco | ops_per_sec | 1,351.25 | 1,582.19 | 1,577.06 | 1,569.64 |
| unpickle_pure_python | ops_per_sec | 111,542.33 | 118,363.33 | 120,249.67 | 120,662.00 |
| deltablue | ops_per_sec | 7,779.99 | 8,095.53 | 8,135.31 | 8,132.24 |
| json_loads | ops_per_sec | 6,689,893.33 | 7,819,353.33 | 7,748,923.33 | 7,729,736.67 |
| pickle_pure_python | ops_per_sec | 41,624.40 | 44,346.53 | 44,613.47 | 44,335.27 |
| scimark_monte_carlo | ops_per_sec | 22.34 | 24.46 | 25.09 | 24.90 |
| json_dumps | ops_per_sec | 530.65 | 614.95 | 616.91 | 616.92 |
| hexiom | ops_per_sec | 2,152.78 | 2,278.33 | 2,289.31 | 2,289.98 |
| regex_compile | ops_per_sec | 6.57 | 7.28 | 7.41 | 7.37 |

**aarch64 — CPython — no-pie** (`ops_per_sec`; switch-based eval loop, rev `d0a877f`)

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| pyflate | ops_per_sec | 1.63 | 1.75 | 1.75 | 1.75 |
| scimark_sor | ops_per_sec | 5.33 | 5.75 | 5.74 | 5.74 |
| nbody | ops_per_sec | 8.20 | 8.46 | 8.42 | 8.40 |
| regex_v8 | ops_per_sec | 146.69 | 155.06 | 155.63 | 155.40 |
| scimark_lu | ops_per_sec | 5.64 | 6.46 | 6.56 | 6.58 |
| scimark_sparse_mat_mult | ops_per_sec | 2,436.24 | 5,407.69 | 5,427.90 | 5,428.79 |
| float | ops_per_sec | 9.01 | 19.98 | 19.89 | 19.96 |
| python_startup | ops_per_sec | 129.00 | 175.81 | 130.69 | 134.89 |
| nqueens | ops_per_sec | 7.65 | 8.98 | 8.89 | 8.83 |
| go | ops_per_sec | 5.50 | 5.73 | 5.72 | 5.69 |
| richards | ops_per_sec | 30.54 | 33.92 | 33.86 | 33.89 |
| scimark_fft | ops_per_sec | 2.29 | 2.54 | 2.53 | 2.53 |
| fannkuch | ops_per_sec | 1.68 | 1.99 | 2.00 | 2.01 |
| pickle | ops_per_sec | 32,881,100.00 | 35,506,566.67 | 35,656,333.33 | 35,674,266.67 |
| spectral_norm | ops_per_sec | 6.38 | 7.00 | 7.03 | 7.04 |
| telco | ops_per_sec | 1,462.57 | 1,722.33 | 1,712.52 | 1,712.44 |
| unpickle_pure_python | ops_per_sec | 103,266.33 | 111,886.67 | 111,306.67 | 111,463.33 |
| deltablue | ops_per_sec | 7,204.21 | 7,844.41 | 7,841.76 | 7,845.46 |
| json_loads | ops_per_sec | 7,430,033.33 | 8,312,620.00 | 8,313,533.33 | 8,338,073.33 |
| pickle_pure_python | ops_per_sec | 38,480.77 | 41,465.20 | 41,339.63 | 41,304.93 |
| scimark_monte_carlo | ops_per_sec | 21.72 | 24.23 | 24.14 | 24.18 |
| json_dumps | ops_per_sec | 566.94 | 1,315.24 | 1,321.87 | 1,314.36 |
| hexiom | ops_per_sec | 1,757.08 | 1,867.45 | 1,869.08 | 1,872.81 |
| regex_compile | ops_per_sec | 5.91 | 6.50 | 6.45 | 6.45 |

### 4.3 Latency (geomean vs. baseline, lower is better)

| Arch | App | Mode | `bolt` | `bolt-rewrite` | `bolt-rewrite-nohuge` |
|---|---|---|---|---|---|
| aarch64 | MariaDB | pie | −30.44 % | −31.47 % | −30.90 % |
| aarch64 | MariaDB | no-pie | −32.36 % | −32.01 % | −33.78 % |
| aarch64 | PostgreSQL | pie | −26.08 % | −26.25 % | −27.66 % |
| aarch64 | PostgreSQL | no-pie | −26.03 % | −26.15 % | −26.91 % |
| aarch64 | MongoDB | pie | −25.59 % | −30.42 % | −29.94 % |
| aarch64 | MongoDB | no-pie | −29.17 % | −28.95 % | −28.96 % |
| x86_64 | MariaDB | pie | −9.04 % | −14.01 % | −19.02 % |
| x86_64 | MariaDB | no-pie | −15.70 % | −17.47 % | −17.82 % |
| x86_64 | PostgreSQL | pie | −7.11 % | −2.09 % | −2.71 % |
| x86_64 | PostgreSQL | no-pie | −14.15 % | −15.34 % | −13.32 % |
| x86_64 | MongoDB | pie | −19.64 % | −15.44 % | — |
| x86_64 | MongoDB | no-pie | −22.50 % | −23.94 % | — |

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
| aarch64 | MongoDB | pie | workloada | 1.70 | 1.30 | 1.20 | 1.22 |
| aarch64 | MongoDB | pie | workloadc | 1.24 | 0.90 | 0.85 | 0.85 |
| aarch64 | MongoDB | no-pie | workloada | 1.70 | 1.19 | 1.22 | 1.22 |
| aarch64 | MongoDB | no-pie | workloadc | 1.19 | 0.85 | 0.84 | 0.84 |
| x86_64 | MariaDB | pie | oltp_point_select | 0.11 | 0.10 | 0.10 | 0.09 |
| x86_64 | MariaDB | pie | oltp_read_write | 3.38 | 3.07 | 2.84 | 2.71 |
| x86_64 | MariaDB | no-pie | oltp_point_select | 0.11 | 0.10 | 0.09 | 0.09 |
| x86_64 | MariaDB | no-pie | oltp_read_write | 3.32 | 2.69 | 2.77 | 2.74 |
| x86_64 | PostgreSQL | pie | select-only | 0.07 | 0.07 | 0.07 | 0.07 |
| x86_64 | PostgreSQL | pie | tpcb-like | 0.49 | 0.45 | 0.47 | 0.48 |
| x86_64 | PostgreSQL | no-pie | select-only | 0.09 | 0.07 | 0.07 | 0.08 |
| x86_64 | PostgreSQL | no-pie | tpcb-like | 0.58 | 0.51 | 0.48 | 0.49 |
| x86_64 | MongoDB | pie | workloada | 0.43 | 0.34 | 0.36 | — |
| x86_64 | MongoDB | pie | workloadc | 0.28 | 0.23 | 0.24 | — |
| x86_64 | MongoDB | no-pie | workloada | 0.48 | 0.37 | 0.35 | — |
| x86_64 | MongoDB | no-pie | workloadc | 0.30 | 0.24 | 0.23 | — |

CPython/pyperformance reports only `ops_per_sec` (no latency metric), so it has
no row in the latency tables.

### 4.4 Binary size

The BOLT input is linked with `-Wl,-q`, so it carries non-allocatable `.rela.*`
sections and a symbol table that are not part of the deployed image; stripping
removes them (runtime `.rela.dyn`/`.rela.plt` are kept). Comparing raw file
sizes therefore flatters BOLT output, which no longer carries those sections,
so all deltas below use **stripped file size**, for both architectures.

**x86_64 (stripped file size)**

| App | Mode | baseline (bytes) | `bolt` (Δ) | `bolt-rewrite` (Δ) | `bolt-rewrite-nohuge` (Δ) |
|---|---|---|---|---|---|
| MariaDB | pie | 26,921,472 | 33,155,760 (**+23.2 %**) | 26,921,152 (**−0.0 %**) | 26,921,176 (**−0.0 %**) |
| MariaDB | no-pie | 22,346,312 | 28,593,264 (**+28.0 %**) | 22,367,000 (**+0.1 %**) | 22,367,016 (**+0.1 %**) |
| PostgreSQL | pie | 9,651,888 | 14,807,928 (**+53.4 %**) | 9,664,856 (**+0.1 %**) | 9,664,872 (**+0.1 %**) |
| PostgreSQL | no-pie | 9,367,352 | 14,523,208 (**+55.0 %**) | 9,376,200 (**+0.1 %**) | 9,376,224 (**+0.1 %**) |
| MongoDB | pie | 129,725,304 | 151,138,896 (**+16.5 %**) | 132,479,728 (**+2.1 %**) | — |
| MongoDB | no-pie | 125,596,536 | 147,191,320 (**+17.2 %**) | 128,482,616 (**+2.3 %**) | — |

**aarch64 (stripped file size; rev `d1723d9d`)**

| App | Mode | baseline (bytes) | `bolt` (Δ) | `bolt-rewrite` (Δ) | `bolt-rewrite-nohuge` (Δ) |
|---|---|---|---|---|---|
| MariaDB | pie | 26,151,200 | 41,727,128 (**+59.6 %**) | 31,608,128 (**+20.9 %**) | 30,166,360 (**+15.4 %**) |
| MariaDB | no-pie | 21,563,752 | 37,234,520 (**+72.7 %**) | 27,413,656 (**+27.1 %**) | 25,578,672 (**+18.6 %**) |
| PostgreSQL | pie | 9,541,128 | 19,163,888 (**+100.9 %**) | 12,621,424 (**+32.3 %**) | 11,703,944 (**+22.7 %**) |
| PostgreSQL | no-pie | 9,281,184 | 18,902,104 (**+103.7 %**) | 12,620,504 (**+36.0 %**) | 11,440,880 (**+23.3 %**) |
| MongoDB | pie | 120,792,312 | 201,400,376 (**+66.7 %**) | 125,297,664 (**+3.7 %**) | 124,904,472 (**+3.4 %**) |
| MongoDB | no-pie | 116,466,936 | 197,065,264 (**+69.2 %**) | 121,106,032 (**+4.0 %**) | 120,647,304 (**+3.6 %**) |
| CPython | pie | 5,382,176 | 11,144,656 (**+107.1 %**) | 7,417,912 (**+37.8 %**) | 6,565,968 (**+22.0 %**) |
| CPython | no-pie | 4,845,784 | 10,479,656 (**+116.3 %**) | 6,906,944 (**+42.5 %**) | 5,268,568 (**+8.7 %**) |

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

**aarch64**

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
| MongoDB | pie | baseline | 64 | 64 K | 51 KB | 51 KB | 0.04 % |
| MongoDB | pie | bolt | 2 M | 2 M | 51 KB | 2.05 MB | 1.07 % |
| MongoDB | pie | bolt-rewrite | 64 K | 2 M | 465 KB | 594 KB | 0.49 % |
| MongoDB | pie | bolt-rewrite-nohuge | 64 K | 64 K | 81 KB | 210 KB | 0.17 % |
| MongoDB | no-pie | baseline | 64 | 64 K | 9.5 KB | 9.5 KB | 0.01 % |
| MongoDB | no-pie | bolt | 2 M | 2 M | 9.5 KB | 2.01 MB | 1.07 % |
| MongoDB | no-pie | bolt-rewrite | 64 K | 2 M | 553 KB | 681 KB | 0.58 % |
| MongoDB | no-pie | bolt-rewrite-nohuge | 64 K | 64 K | 105 KB | 233 KB | 0.20 % |
| CPython | pie | baseline | 16 | 64 K | 26 KB | 26 KB | 0.50 % |
| CPython | pie | bolt | 2 M | 2 M | 26 KB | 2.03 MB | 19.06 % |
| CPython | pie | bolt-rewrite | 64 K | 2 M | 903 KB | 1.20 MB | 16.97 % |
| CPython | pie | bolt-rewrite-nohuge | 64 K | 64 K | 71 KB | 398 KB | 6.20 % |
| CPython | no-pie | baseline | 64 | 64 K | 13 KB | 13 KB | 0.27 % |
| CPython | no-pie | bolt | 2 M | 2 M | 13 KB | 2.01 MB | 20.13 % |
| CPython | no-pie | bolt-rewrite | 64 K | 2 M | 1.57 MB | 1.75 MB | 26.61 % |
| CPython | no-pie | bolt-rewrite-nohuge | 64 K | 64 K | 9.7 KB | 195 KB | 3.78 % |

**x86_64**

| App | Mode | variant | `.text` | LOAD | seghole | gaps | gaps % |
|---|---|---|---|---|---|---|---|
| MariaDB | pie | baseline | 16 | 4 K | 3.8 KB | 4.9 KB | 0.02 % |
| MariaDB | pie | bolt | 2 M | 2 M | 3.8 KB | 2.05 MB | 6.34 % |
| MariaDB | pie | bolt-rewrite | 4 K | 4 K | 4.3 KB | 10 KB | 0.04 % |
| MariaDB | pie | bolt-rewrite-nohuge | 4 K | 4 K | 4.3 KB | 10 KB | 0.04 % |
| MariaDB | no-pie | baseline | 16 | 4 K | 5.5 KB | 6.2 KB | 0.03 % |
| MariaDB | no-pie | bolt | 2 M | 2 M | 5.5 KB | 2.06 MB | 7.36 % |
| MariaDB | no-pie | bolt-rewrite | 4 K | 4 K | 7.8 KB | 14 KB | 0.07 % |
| MariaDB | no-pie | bolt-rewrite-nohuge | 4 K | 4 K | 7.8 KB | 14 KB | 0.07 % |
| PostgreSQL | pie | baseline | 16 | 4 K | 3.7 KB | 3.8 KB | 0.04 % |
| PostgreSQL | pie | bolt | 2 M | 2 M | 3.7 KB | 2.86 MB | 19.76 % |
| PostgreSQL | pie | bolt-rewrite | 4 K | 4 K | 8.9 KB | 13 KB | 0.14 % |
| PostgreSQL | pie | bolt-rewrite-nohuge | 4 K | 4 K | 8.9 KB | 13 KB | 0.14 % |
| PostgreSQL | no-pie | baseline | 16 | 4 K | 7.4 KB | 7.5 KB | 0.08 % |
| PostgreSQL | no-pie | bolt | 2 M | 2 M | 7.4 KB | 2.86 MB | 20.18 % |
| PostgreSQL | no-pie | bolt-rewrite | 4 K | 4 K | 6.2 KB | 12 KB | 0.13 % |
| PostgreSQL | no-pie | bolt-rewrite-nohuge | 4 K | 4 K | 6.2 KB | 12 KB | 0.13 % |
| MongoDB | pie | baseline | 64 | 4 K | 1.0 KB | 1.2 KB | 0.00 % |
| MongoDB | pie | bolt | 2 M | 2 M | 1.0 KB | 2.00 MB | 1.39 % |
| MongoDB | pie | bolt-rewrite | 4 K | 2 M | 1.83 MB | 1.83 MB | 1.45 % |
| MongoDB | no-pie | baseline | 64 | 4 K | 2.9 KB | 3.0 KB | 0.00 % |
| MongoDB | no-pie | bolt | 2 M | 2 M | 2.9 KB | 2.00 MB | 1.43 % |
| MongoDB | no-pie | bolt-rewrite | 4 K | 2 M | 1.76 MB | 1.76 MB | 1.44 % |

Observations:

* Without BOLT the binaries are essentially gap-free (x86_64 0.00 % … 0.08 %,
  aarch64 0.01 % … 0.71 %).
* `bolt` (no-rewrite) aligns its added hot-text segment to 2 M; on x86_64 that
  adds ≈2.0–2.9 MB of in-segment padding (1.4 % … 20 % of the file) and on
  aarch64 ≈2.0–2.2 MB (1 % … 20 %). Together with keeping the original code as
  `.bolt.org.text`, this is why `bolt` looks so much larger than its emitted
  code.
* `-rewrite` repacks the image. On **aarch64** it keeps a 64 K `.text`
  alignment but 2 M-aligns its new `PT_LOAD`, leaving a 0.46 … 1.89 MB segment
  hole (0.5 % … 26.6 % of the file); `bolt-rewrite-nohuge` removes the 2 M
  alignment (`.text` and `LOAD` both 64 K, `seghole` back to the baseline
  ≈ 9.5 … 105 KB) and roughly halves the rewrite gap (0.17 % … 6.2 %). On
  **x86_64** the default `-rewrite` is already regular-page (4 K) aligned
  (`.text` and all `PT_LOAD` segments 4 K, no segment hole), so `--no-huge-pages`
  is a no-op there — the two x86_64 rewrite binaries differ by 16 B. BOLT's 2 M
  alignment on x86_64 therefore shows up only in the `bolt` variant. The
  exception is MongoDB, whose `-rewrite` keeps a 2 M `PT_LOAD` on both
  architectures (`.text` 4 K on x86_64 / 64 K on aarch64, `LOAD` 2 M); its
  aarch64 `bolt-rewrite-nohuge` was collected here for both link modes
  (`.text`/`LOAD` 64 K; `seghole` 465 KB → 81 KB pie, 553 KB → 105 KB no-pie),
  while the x86_64 one was not.
* `bolt-rewrite-nohuge` cuts the aarch64 `-rewrite` size increase from
  +3.7 % … +42.5 % to **+3.4 % … +22.0 %** (0.39 … 1.8 MB per binary) with
  performance within run-to-run noise of `bolt-rewrite` (§4.1); on x86_64 it
  changes neither size nor layout.
* The 2 M alignment is BOLT's default; the harness does not request
  `--hugify`/`--hot-text`, so the huge pages are never actually used.
* `bolt`, `bolt-rewrite` and `bolt-rewrite-nohuge` all patch the ELF build-id
  (last bit flipped) — verified on every optimized binary
  (aarch64 + x86_64).

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

The x86_64 run (same revision, four-variant pipeline) reported the same
end-to-end properties: all twelve optimized outputs (`bolt`, `bolt-rewrite`,
`bolt-rewrite-nohuge` × 2 apps × 2 modes) produced, `--version` exits 0, and the
full workload completed with 0 errors (sysbench `ignored errors = 0` /
`reconnects = 0`; pgbench `failed transactions = 0`; no server
`SIGSEGV`/`FATAL`/`PANIC`); build-id patched for all variants.

MongoDB (x86_64, standard three-variant pipeline) was validated the same way:
`bolt` and `bolt-rewrite` exist for both `pie` and `no-pie`, `--version` exits
0, and the full YCSB workload (2 M records, `workloada`+`workloadc`, 1 warmup +
3 reps) completed with **0 errors** (`FAILED`/`NOT_FOUND` = 0; no server
`SIGSEGV`/`FATAL`/`PANIC`). The optimize logs contain no `BOLT-ERROR` and no
`corrupted control flow`; warning counts are 1 (`bolt`) and 51 (`bolt-rewrite`)
for each mode. Build-id is patched for all four MongoDB optimized binaries.

MongoDB was then validated on aarch64 in both link modes (2026-09-16) with the
four-variant `NOHUGE=1` pipeline: `bolt`, `bolt-rewrite` and
`bolt-rewrite-nohuge` are produced, `--version` exits 0, and the full YCSB
workload completed with **0 errors** (`FAILED`/`NOT_FOUND` = 0; no server
`SIGSEGV`/`FATAL`/`PANIC`). The optimize logs contain no `BOLT-ERROR`/`corrupted
control flow` (2 `BOLT-WARNING` each). Build-id is patched for all six aarch64
MongoDB optimized binaries.

CPython 3.13.9 was re-verified on aarch64 (2026-09-17, rev `d0a877f`) in both
modes with `-skip-funcs` removed from the optimization pass: all six optimized
targets (`bolt`, `-rewrite`, `-rewrite-nohuge` × 2 modes) pass `app_verify_bin`
(staging the `pie` `.so` and importing `sys, pyperf, pyperformance`) and the
full pyperformance suite (24 benchmarks, 1 warmup + 3 reps) completed with **0
errors** (no failed/skipped benchmarks, no crashes; no `.failed` outputs or
verify logs left behind). No `BOLT-ERROR`/`corrupted control flow` in any
optimize log. With the earlier rev `d1723d9d`, both `-rewrite` variants crashed
on import (`SIGSEGV`, exit 139) in both modes; the two `d0a877f` fixes resolve
this on aarch64. As noted in §3.5, aarch64 `no-pie` instrumentation additionally
requires `PY_COMPUTED_GOTO=0`.

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
   successfully merged profile. Also hit on MongoDB `pie` (aarch64) on
   2026-09-16 and recovered the same way. On MongoDB `no-pie` (aarch64) the
   merge did not abort but silently read a partially flushed file: it emitted a
   single `ignoring malformed entry` warning and produced a **truncated**
   profile (165 k of 265 k entries, 26 MB vs 46 MB). Re-running `merge-fdata`
   on the completed `.fdata` yielded the full profile, so the truncation would
   otherwise have gone unnoticed; always verify the merged entry count/`.fdata`
   size. Not seen in the other combinations.
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
10. **MongoDB.** MongoDB 7.0 is built with SCons and needs a
    non-default toolchain: Ubuntu 24.04 (host glibc ≥ 2.36 for the mounted BOLT)
    with GCC 12 and deadsnakes Python 3.10, because Noble's GCC 13 / Python 3.12
    do not satisfy its pinned SCons requirements. mozjs is disabled
    (`--js-engine=none`). `mongod` is large (~148 k functions, ~2.4 M
    relocations) and `llvm-bolt -instrument` peaks above a 16 GB machine's RAM,
    so the adapter appends `--no-threads`; the baseline is also stripped of
    DWARF (`objcopy --strip-debug`, 8.5 GB → ~220 MB). Both link modes share one
    SCons tree (only `LINKFLAGS` differ), so the second mode is a ~5 min relink.
    YCSB's `operationcount` is set effectively unlimited so `maxexecutiontime`
    bounds each run. Measured on x86_64 in both link modes and on aarch64 in
    both link modes (four variants; the aarch64 pass also needs
    `--drop-cortex-a53-843419-veneers`).
11. **CPython `-rewrite` and aarch64 non-PIE instrumentation.** With rev
    `d1723d9d`, both CPython `-rewrite` outputs crashed on import: passing
    `-skip-funcs` to the optimization pass silently corrupted the re-emitted
    image, and `pie` additionally hit an AArch64 TLSDESC descriptor retargeting
    bug. Rev `d0a877f` rejects `-rewrite` with `-skip-funcs` and fixes the
    TLSDESC retargeting; with `-skip-funcs` restricted to instrumentation, all
    six aarch64 targets work (2026-09-17 re-verification). Separately, on
    aarch64 the instrumented static `no-pie` `python3` aborts (`free(): invalid
    pointer`) inside `subprocess`/fork when pyperformance spawns its worker, so
    profiling cannot run with the default computed-goto eval loop; building that
    mode with `PY_COMPUTED_GOTO=0` (switch-based eval loop) avoids it. The `pie`
    target (shared libpython) profiles fine with computed gotos on. On x86_64 no
    such workaround was needed.

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

MongoDB uses its own container; the adapter appends
`--no-threads` automatically and both modes share one SCons tree:

```bash
cd $HOME/src/bolt-harness/apps/mongodb
LLVM_SRC=$HOME/src/llvm-project-23 ./rebuild.sh          # x86_64: image + clone + venv + YCSB
LLVM_SRC=$HOME/src/llvm-project-23 ./rebuild.sh exec \
  /harness/pipeline/run-all.sh pie no-pie
# aarch64: use LLVM_SRC=$HOME/src/llvm-23.1.1 and pass the veneer flag, e.g.
#   BOLT_INSTRUMENT_EXTRA_FLAGS=--drop-cortex-a53-843419-veneers
#   BOLT_OPT_FLAGS='<BOLT_FLAGS> --drop-cortex-a53-843419-veneers'
```

CPython uses its own container; `pie` BOLTs the shared libpython and `no-pie`
the static executable. On aarch64, add the veneer flag and build `no-pie` with
`PY_COMPUTED_GOTO=0` (§3.5). Re-verifying an existing build with rev `d0a877f`
re-profiles/optimizes/benchmarks with `SKIP_BUILD=1`:

```bash
cd $HOME/src/bolt-harness/apps/python
LLVM_SRC=$HOME/src/llvm-23.1.1 ./rebuild.sh              # image + clone CPython
LLVM_SRC=$HOME/src/llvm-23.1.1 ./rebuild.sh exec env NOHUGE=1 PY_COMPUTED_GOTO=0 \
  BOLT_INSTRUMENT_EXTRA_FLAGS="--drop-cortex-a53-843419-veneers" \
  BOLT_OPT_FLAGS="<BOLT_FLAGS> --drop-cortex-a53-843419-veneers" \
  bash -c 'SKIP_BUILD=1 /harness/pipeline/run-all.sh pie no-pie'
# `-skip-funcs` is applied to instrumentation only (app.sh); -rewrite rejects it.
# x86_64: omit the veneer flag and PY_COMPUTED_GOTO=0
```

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

# MongoDB (aarch64, both link modes, four variants; 2026-09-16):
docker exec -i bolt-harness-mongodb \
  env APP=mongodb HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build/bin \
      CC=gcc-12 CXX=g++-12 NOHUGE=1 BOLT_OPT_FLAGS="$FLAGS" \
  bash -c 'SKIP_BUILD=1 SKIP_PROFILE=1 /harness/pipeline/run-all.sh pie no-pie'

# Stripped size + section/segment alignment report for every variant:
APP=mariadb NOHUGE=1 pipeline/size-report.sh pie no-pie
APP=postgresql NOHUGE=1 HARNESS_WORK="$PWD/work/postgresql" \
  pipeline/size-report.sh pie no-pie
APP=mongodb NOHUGE=1 pipeline/size-report.sh pie no-pie
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
* MongoDB (x86_64): run log `bolt-harness/work/mongodb-x86_64-standard.out`;
  consolidated metrics/sizes/checks `bolt-harness/work/mongodb-x86_64-data.txt`;
  results under `…/_state/mongodb/results/<mode>/<variant>/<timestamp>/summary.tsv`;
  binaries/build info `…/_state/mongodb/binaries/<mode>/`; merged profiles
  `…/_state/mongodb/profiles/<mode>/profile.merged.fdata`; BOLT logs
  `…/_state/mongodb/binaries/<mode>/bolt-{bolt,bolt-rewrite}.log`.
* MongoDB (aarch64, both link modes, 2026-09-16 four-variant): run logs
  `bolt-harness/work/validate-aarch64-mongodb-nohuge.out` (pie) and
  `…-nopie.out` (no-pie); stripped size/alignment reports
  `bolt-harness/work/validate-aarch64-mongodb-{sizes,nopie-sizes}.txt`; results
  under `…/_state/mongodb/results/<mode>/<variant>/<timestamp>/summary.tsv`;
  binaries/build info `…/_state/mongodb/binaries/<mode>/`; merged profiles
  `…/_state/mongodb/profiles/<mode>/profile.merged.fdata`; BOLT logs
  `…/_state/mongodb/binaries/<mode>/bolt-{bolt,bolt-rewrite,bolt-rewrite-nohuge}.log`.
* CPython (aarch64, both link modes): first run 2026-09-16 (rev `d1723d9d`) logs
  `bolt-harness/work/validate-aarch64-python-pie.out` and `…-nopie.out`;
  2026-09-17 `-rewrite` re-verification (rev `d0a877f`, `SKIP_BUILD=1`)
  `bolt-harness/work/validate-aarch64-python-reverify.out`; stripped
  size/alignment report `bolt-harness/work/validate-aarch64-python-sizes.txt`;
  results under `…/_state/python/results/<mode>/<variant>/<timestamp>/summary.tsv`;
  binaries and build info `…/_state/python/binaries/<mode>/`; merged profile
  `…/_state/python/profiles/<mode>/profile.merged.fdata`; BOLT logs
  `…/_state/python/binaries/<mode>/bolt-{bolt,bolt-rewrite,bolt-rewrite-nohuge}.log`.
  x86_64 CPython figures are recorded in commit `a78e709`.
