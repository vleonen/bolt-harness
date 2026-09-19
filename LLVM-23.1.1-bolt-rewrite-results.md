# LLVM 23.1.1 BOLT `-rewrite` — Results on MariaDB, PostgreSQL, MongoDB and CPython (aarch64 & x86_64)

Date: 2026-09-15 (aarch64 MongoDB/CPython added 2026-09-16; aarch64 re-validated at `d0a877f` on 2026-09-17; x86_64 re-validated at `d0a877f` on 2026-09-17 with re-instrumentation; CPython x86_64 re-evaluated at `059e374` on 2026-09-18)
Harness: `bolt-harness`
Tool under test: `llvm-bolt`, LLVM **23.1.1**, branch `llvmorg-23.1.1-rewrite`
(x86_64 checkout moved `$HOME/src/llvm-project-23` → `$HOME/src/llvm-23.1.1`
on 2026-09-19, making the BOLT path uniform with aarch64; harness containers
recreated against the new path):

- **aarch64**: `$HOME/src/llvm-23.1.1/build/bin/llvm-bolt`, revision
  `d1723d9d8a4d763722331379ab265e94b6c3cb14` (34 `[BOLT][Rewrite]` commits
  rebased onto tag `llvmorg-23.1.1`). The aarch64 results below were
  re-validated on 2026-09-15 with this revision after three additional
  `-rewrite` fixes landed on the branch (see §2.2); the earlier aarch64 run
  used `502a8fc3a4ce`. The aarch64 set also includes a fourth configuration,
  `bolt-rewrite-nohuge` (`-rewrite --no-huge-pages`), added to quantify BOLT's
  default 2 M huge-page code alignment (see §2.3 and §4.4). The whole aarch64
  set was re-validated on 2026-09-17 with revision `d0a877fc33a1` (36
  `[BOLT][Rewrite]` commits), which adds *Reject `-rewrite` with `-skip-funcs`*
  and *Fix AArch64 TLSDESC descriptor retargeting*: CPython needed those fixes
  (§3.5), while for MariaDB/PostgreSQL/MongoDB they are a no-op (none of the
  baselines has TLS-family relocations and none uses `-skip-funcs`) — binary
  sizes are byte-identical and the re-benchmark deltas are within run-to-run
  noise (§4.1).
- **x86_64**: `$HOME/src/llvm-23.1.1/build23/bin/llvm-bolt`, same branch
  (checkout at `$HOME/src/llvm-project-23` until 2026-09-19).
  The x86_64 set includes the fourth configuration, `bolt-rewrite-nohuge`. The
  whole x86_64 set was re-validated on 2026-09-17 with revision
  `d0a877fc33a1` (the same revision as aarch64; both architectures are now on
  one revision) with baselines and datasets reused (`SKIP_BUILD=1`) and
  **re-instrumentation**: profile → optimize → bench → compare re-run in one
  four-variant session per app/mode. For MariaDB/PostgreSQL/MongoDB the new
  `d0a877f` behavior is a no-op vs. `d1723d9d` (no TLS-family relocations, no
  `-skip-funcs`), so their `-rewrite`/`-rewrite-nohuge` outputs are produced,
  verified and benched on x86_64 as well — closing the earlier "x86_64
  `-rewrite` not re-verified" gap. At that revision CPython on x86_64 kept
  `-skip-funcs` in the optimization pass and only `bolt` was measured (§3.5);
  the 2026-09-18 re-evaluation at `059e374b470e` (below) removed that
  constraint.
- **MongoDB**: MongoDB 7.0 (`r7.0.43`, built from source with SCons) was added
  to the harness and measured with YCSB on x86_64 (2026-09-15, standard three
  configurations) and, on 2026-09-16, on aarch64 (both link modes, four
  configurations including `bolt-rewrite-nohuge`) with the same BOLT revision
  (see §3.4).
- **CPython**: CPython 3.13.9 (`v3.13.9`) is measured with the **pyperformance**
  suite (`ops_per_sec`). It is validated with LLVM 23.1.1 on x86_64 (both
  modes; `bolt` +10.02 % pie / +18.55 % no-pie at rev `d0a877f`, 2026-09-17
  re-validation) and on aarch64 (2026-09-17, both
  modes, four configurations; `bolt` +19.72 % pie / +21.34 % no-pie,
  `-rewrite` +21.14 % / +19.77 %, `-rewrite-nohuge` +18.32 % / +19.93 %). The
  two modes BOLT different targets: `pie` optimizes shared
  `libpython3.13.so.1.0`, `no-pie` the static `python3` executable. The aarch64
  `-rewrite` outputs were the motivation for the two fixes in `d0a877fc33a1`
  and now run (see §3.5). On x86_64 `-rewrite` used to be unavailable *by
  construction* (the optimization pass needed `-skip-funcs`, which `d0a877f`
  BOLT rejects in `-rewrite` mode); revision `059e374b470e` removes that
  constraint — the x86_64 optimization pass handles the computed-goto dispatch
  without `-skip-funcs`, and all four configurations now run on x86_64
  (2026-09-18): with the standard skip-funcs instrumentation `bolt` +9.04 % pie
  / +15.22 % no-pie, `-rewrite` +6.69 % / +13.89 %, `-rewrite-nohuge` +5.15 % /
  +12.79 %; with full-profile instrumentation (`PY_INSTR_SKIP_FUNCS=0`, see
  §3.5) `bolt` +10.13 % pie / +20.46 % no-pie, `-rewrite` +7.33 % / +17.18 %,
  `-rewrite-nohuge` +8.52 % / +15.87 %.

## Summary

The `-rewrite` feature was validated end-to-end on three real server
applications plus the CPython interpreter, in both ELF link modes, on
**aarch64** and **x86_64**, against the standard profile-driven BOLT pipeline.

**aarch64** (rev `d0a877f`, 2026-09-17 re-validation; four configurations)

| App | Mode | `bolt` | `bolt-rewrite` | `bolt-rewrite-nohuge` | workload errors |
|---|---|---|---|---|---|
| MariaDB | pie | **+43.63 %** | **+41.14 %** | **+43.71 %** | 0 |
| MariaDB | no-pie | **+45.08 %** | **+45.03 %** | **+45.61 %** | 0 |
| PostgreSQL | pie | **+33.83 %** | **+33.84 %** | **+34.45 %** | 0 |
| PostgreSQL | no-pie | **+33.89 %** | **+34.48 %** | **+34.41 %** | 0 |
| MongoDB | pie | **+38.67 %** | **+38.05 %** | **+37.45 %** | 0 |
| MongoDB | no-pie | **+35.39 %** | **+36.05 %** | **+38.05 %** | 0 |
| CPython | pie | **+19.72 %** | **+21.14 %** | **+18.32 %** | 0 |
| CPython | no-pie | **+21.34 %** | **+19.77 %** | **+19.93 %** | 0 |

**x86_64** (rev `d0a877f`, 2026-09-17 re-validation with re-instrumentation; four configurations)

| App | Mode | `bolt` | `bolt-rewrite` | `bolt-rewrite-nohuge` | workload errors |
|---|---|---|---|---|---|
| MariaDB | pie | **+16.79 %** | **+10.58 %** | **+8.93 %** | 0 |
| MariaDB | no-pie | **+23.96 %** | **+22.42 %** | **+22.14 %** | 0 |
| PostgreSQL | pie | **+15.65 %** | **+12.78 %** | **+9.67 %** | 0 |
| PostgreSQL | no-pie | **+15.76 %** | **+14.97 %** | **+15.15 %** | 0 |
| MongoDB | pie | **+17.78 %** | **+13.96 %** | **+11.05 %** | 0 |
| MongoDB | no-pie | **+20.40 %** | **+15.30 %** | **+14.71 %** | 0 |
| CPython | pie | **+10.02 %** | rej. | rej. | 0 |
| CPython | no-pie | **+18.55 %** | rej. | rej. | 0 |

(Throughput geomean vs. the unmodified baseline; higher is better. All rows are
the 2026-09-17 re-validation at rev `d0a877f` — baselines and datasets reused
(`SKIP_BUILD=1`), BOLT **re-instrumentation** included, optimization and
benchmark re-run in one four-variant session per app/mode. MongoDB was first
measured on x86_64 on 2026-09-15;
CPython is measured with pyperformance, so its figure is the `ops_per_sec`
geomean. `bolt-rewrite-nohuge`
is the regular `-rewrite` build with BOLT's default 2 M huge-page code
alignment replaced by the target's regular page size, i.e.
`-rewrite --no-huge-pages` — see §2.3. "rej." = BOLT rejects the combination
(`-rewrite` with `-skip-funcs`, required for CPython on x86_64 at `d0a877f`,
§3.5); the pipeline parks nothing and simply skips the variant. CPython x86_64
was re-evaluated at `059e374` — table below.)

**x86_64 CPython** (rev `059e374b470e`, 2026-09-18; four configurations × two instrumentation variants)

| Instrumentation | Mode | `bolt` | `bolt-rewrite` | `bolt-rewrite-nohuge` | workload errors |
|---|---|---|---|---|---|
| skip-funcs (default) | pie | **+9.04 %** | **+6.69 %** | **+5.15 %** | 0 |
| skip-funcs (default) | no-pie | **+15.22 %** | **+13.89 %** | **+12.79 %** | 0 |
| full profile (`PY_INSTR_SKIP_FUNCS=0`) | pie | **+10.13 %** | **+7.33 %** | **+8.52 %** | 0 |
| full profile (`PY_INSTR_SKIP_FUNCS=0`) | no-pie | **+20.46 %** | **+17.18 %** | **+15.87 %** | 0 |

(First x86_64 session in which CPython `-rewrite` runs: BOLT `8bba80ca2a95`
recognizes the computed-goto label tables on X86, so the optimization pass runs
over every function. "Full profile" additionally drops `-skip-funcs` from
*instrumentation*, so the profile finally covers `_PyEval_EvalFrameDefault` and
the `sre_*` matchers — worth ~+1.1 pt (pie) / ~+5.2 pt (no-pie) on `bolt` at no
measurable profile-time cost (444 s vs 447 s workload). All eight targets pass
`app_verify_bin` and complete the full pyperformance suite with zero errors.)

All optimized `-rewrite` binaries (plain and `bolt-rewrite-nohuge`) in the
configurations above are produced, start, and complete the full benchmark
workload with zero errors — on **both** architectures and for **all four
applications** now. (With rev `d1723d9d`, CPython's aarch64 `-rewrite` outputs
crashed on import; the rev `d0a877f` fixes resolve that on aarch64 — see
§3.5, §4.5. On x86_64 CPython `-rewrite` was rejected at `d0a877f` and works
since `059e374`, see the CPython bullet above.)

Binary size (measured on **stripped** binaries, §4.4): on **x86_64** `bolt`
grows the runtime image by +16.6 % … +28 % for the servers and +89 % … +98 %
for CPython (it keeps the original code), while
`-rewrite` is near size-neutral (≤ 2.3 %); for MariaDB/PostgreSQL x86_64
`-rewrite` is already regular-page aligned and `bolt-rewrite-nohuge` matches it
(≤ 24 B), while MongoDB `-rewrite` retains a 2 M-aligned PT_LOAD that
`--no-huge-pages` removes (+2.1 %/+2.3 % → +0.7 %/+0.8 %); x86_64 CPython
`-rewrite` adds +1.2 % (pie) / +0.8 % (no-pie), byte-identical with
`--no-huge-pages`. On **aarch64** `bolt` grows the runtime image by +60 % … +116 % and
`-rewrite` by +3.7 % … +42.5 %; a substantial part of both is alignment/placement
padding introduced by BOLT's default 2 M code alignment. Replacing it with the
regular page size (`bolt-rewrite-nohuge`) removes the aarch64 `-rewrite`
overhead (down to +3.4 % … +23 %). MongoDB `bolt` adds +16.6 % / +17.3 %
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
| BOLT | `$HOME/src/llvm-23.1.1/build/bin/llvm-bolt` (LLVM 23.1.1; aarch64 results re-validated at rev `d0a877fc33a1`, 2026-09-17) |
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
| BOLT | `$HOME/src/llvm-23.1.1/build23/bin/llvm-bolt` (LLVM 23.1.1; x86_64 results re-validated at rev `d0a877fc33a1`, 2026-09-17) |
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
| `d7136fcb56ab` | common | Reject `-rewrite` combined with `-skip-funcs` (skipped functions are not disassembled/emitted; callers would branch into reused addresses). |
| `d0a877fc33a1` | aarch64 | Fix AArch64 TLSDESC descriptor retargeting (CPython `pie` crashed in `Py_InitializeFromConfig`). |
| `8bba80ca2a95` | x86_64 | Recognize computed-goto label tables as jump tables on X86: resolve register-held table bases to their defining RIP-relative LEA, accept the notrack (`DS`) prefix, and take `R_X86_64_RELATIVE` addends (PIE) / raw values (non-PIE) as `JTT_NORMAL` entry relocations. Removes the need for `-skip-funcs` on GCC/clang computed-goto dispatches (CPython eval loop, `sre_*_match`). |
| `059e374b470e` | common | `-rewrite`: map interior function addresses via address translation. |

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

**x86_64.** Historical note: through rev `d0a877f` the x86_64 *optimization*
pass corrupted the computed-goto dispatch when run without `-skip-funcs` (the
optimized library segfaulted on the first import, jumping into a wild address;
same hazard class as PostgreSQL's `dispatch_table`), so `app.sh` kept
`-skip-funcs` in `BOLT_OPT_FLAGS` on x86_64 — and since `d0a877f` BOLT rejects
`-rewrite` with `-skip-funcs`, x86_64 CPython was `bolt`-only. Revision
`059e374b470e` (specifically `8bba80ca2a95`) teaches the x86 optimization pass
to recognize the label-address tables, and the constraint is gone: with
`-skip-funcs` dropped from `BOLT_OPT_FLAGS` on every arch, all four
configurations are produced, verified and benched on x86_64 (2026-09-18,
§4.5).

**Instrumentation coverage (`PY_INSTR_SKIP_FUNCS`).** Instrumentation still
skips the four computed-goto functions by default (mirroring CPython's own
`--enable-bolt`), which means the profile carries no counters for the hottest
function. With the new x86 jump-table recognition, instrumentation can run
without `-skip-funcs` too; `apps/python/app.sh` exposes this as
`PY_INSTR_SKIP_FUNCS=0`. Measured on x86_64 (2026-09-18): the full profile
costs nothing in wall time (444 s vs 447 s pyperformance workload; 949 MB of
raw per-process dumps) and buys `bolt` +1.1 pt (pie) / +5.2 pt
(no-pie) — see the Summary table. Recommended for future x86_64 CPython runs;
pending the same experiment on aarch64 the default stays `1` for
cross-architecture comparability.

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
| aarch64 | MariaDB | pie | **+43.63 %** | **+41.14 %** | **+43.71 %** |
| aarch64 | MariaDB | no-pie | **+45.08 %** | **+45.03 %** | **+45.61 %** |
| aarch64 | PostgreSQL | pie | **+33.83 %** | **+33.84 %** | **+34.45 %** |
| aarch64 | PostgreSQL | no-pie | **+33.89 %** | **+34.48 %** | **+34.41 %** |
| aarch64 | MongoDB | pie | **+38.67 %** | **+38.05 %** | **+37.45 %** |
| aarch64 | MongoDB | no-pie | **+35.39 %** | **+36.05 %** | **+38.05 %** |
| aarch64 | CPython | pie | **+19.72 %** | **+21.14 %** | **+18.32 %** |
| aarch64 | CPython | no-pie | **+21.34 %** | **+19.77 %** | **+19.93 %** |
| x86_64 | MariaDB | pie | **+16.79 %** | **+10.58 %** | **+8.93 %** |
| x86_64 | MariaDB | no-pie | **+23.96 %** | **+22.42 %** | **+22.14 %** |
| x86_64 | PostgreSQL | pie | **+15.65 %** | **+12.78 %** | **+9.67 %** |
| x86_64 | PostgreSQL | no-pie | **+15.76 %** | **+14.97 %** | **+15.15 %** |
| x86_64 | MongoDB | pie | **+17.78 %** | **+13.96 %** | **+11.05 %** |
| x86_64 | MongoDB | no-pie | **+20.40 %** | **+15.30 %** | **+14.71 %** |
| x86_64 | CPython | pie | **+10.02 %** | rej. | rej. |
| x86_64 | CPython | no-pie | **+18.55 %** | rej. | rej. |
| x86_64 | CPython ¹ | pie | **+10.13 %** | **+7.33 %** | **+8.52 %** |
| x86_64 | CPython ¹ | no-pie | **+20.46 %** | **+17.18 %** | **+15.87 %** |

On aarch64 `bolt` and `-rewrite` are within a few points of each other
(MariaDB `pie` aside, where `bolt` leads by ~2.5 points in this session), as
expected for a full re-emission vs. in-place patching; on x86_64 the variants
are similarly spaced, with `bolt` leading `-rewrite` by ~2–6 points in this
session. `bolt-rewrite-nohuge`
performs within run-to-run noise of `bolt-rewrite` on both architectures
(aarch64 −2.8 … +2.6 points, x86_64 −2.7 … +6.0 points; it is a *size* change,
not a reordering change). CPython's figures are `ops_per_sec` geomeans
(pyperformance); its aarch64 results use rev `d0a877f` and now include
`-rewrite` (§3.5); the x86_64 CPython rows marked ¹ are the 2026-09-18
re-evaluation at rev `059e374b470e` with **full-profile instrumentation**
(`PY_INSTR_SKIP_FUNCS=0`) — the first x86_64 session with a working
`-rewrite`; at the same rev with the default skip-funcs instrumentation
`bolt` measured +9.04 % (pie) / +15.22 % (no-pie), `-rewrite` +6.69 % /
+13.89 %, `-rewrite-nohuge` +5.15 % / +12.79 %. All x86_64 server-app
deltas were re-measured at rev `d0a877f` in one four-variant session per
app/mode (2026-09-17) with fresh instrumentation; absolute levels vary
between runs (see §5.5), but the ordering and magnitude are stable.

### 4.2 Per-workload throughput means

**aarch64 — MariaDB — pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 38,477.48 | 58,120.74 | 56,308.34 | 58,030.04 |
| oltp_read_write | TPS | 1,353.17 | 1,848.08 | 1,841.95 | 1,853.14 |
| oltp_read_write | QPS | 27,063.42 | 36,961.54 | 36,839.11 | 37,062.84 |

**aarch64 — MariaDB — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 37,937.58 | 58,300.64 | 58,244.66 | 58,924.10 |
| oltp_read_write | TPS | 1,354.38 | 1,854.94 | 1,855.58 | 1,848.74 |
| oltp_read_write | QPS | 27,087.57 | 37,098.71 | 37,111.54 | 36,974.83 |

**aarch64 — PostgreSQL — pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| select-only | TPS | 35,183.25 | 48,123.41 | 48,230.43 | 48,454.66 |
| tpcb-like | TPS | 6,000.61 | 7,857.61 | 7,841.13 | 7,875.92 |

**aarch64 — PostgreSQL — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| select-only | TPS | 34,377.13 | 47,223.23 | 47,539.28 | 47,412.90 |
| tpcb-like | TPS | 5,879.63 | 7,672.55 | 7,689.39 | 7,702.04 |

**aarch64 — MongoDB — pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| workloada | TPS | 9,409.72 | 12,987.42 | 12,755.69 | 12,859.48 |
| workloadc | TPS | 13,152.24 | 18,323.55 | 18,490.42 | 18,182.09 |

**aarch64 — MongoDB — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| workloada | TPS | 9,522.92 | 12,584.84 | 12,877.22 | 12,929.71 |
| workloadc | TPS | 13,234.92 | 18,357.67 | 18,114.98 | 18,576.85 |

**x86_64 — MariaDB — pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 164,544.34 | 194,877.33 | 190,397.25 | 184,428.40 |
| oltp_read_write | TPS | 5,900.37 | 6,795.93 | 6,235.45 | 6,246.39 |
| oltp_read_write | QPS | 118,007.46 | 135,918.52 | 124,709.07 | 124,927.77 |

**x86_64 — MariaDB — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| oltp_point_select | TPS/QPS | 143,140.17 | 180,356.29 | 176,625.18 | 174,548.93 |
| oltp_read_write | TPS | 5,015.64 | 6,117.12 | 6,091.39 | 6,135.92 |
| oltp_read_write | QPS | 100,312.80 | 122,342.38 | 121,827.75 | 122,718.47 |

**x86_64 — PostgreSQL — pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| select-only | TPS | 223,170.05 | 258,974.68 | 253,297.19 | 248,334.32 |
| tpcb-like | TPS | 34,401.51 | 39,653.40 | 38,553.12 | 37,186.91 |

**x86_64 — PostgreSQL — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| select-only | TPS | 199,594.08 | 232,125.13 | 230,133.40 | 230,636.75 |
| tpcb-like | TPS | 31,036.63 | 35,761.91 | 35,581.23 | 35,616.28 |

**x86_64 — MongoDB — pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| workloada | TPS | 39,430.06 | 46,672.31 | 45,285.31 | 47,297.68 |
| workloadc | TPS | 64,115.32 | 75,140.09 | 72,503.33 | 65,909.76 |

**x86_64 — MongoDB — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| workloada | TPS | 39,179.90 | 51,731.91 | 49,946.49 | 48,946.36 |
| workloadc | TPS | 66,616.91 | 73,138.58 | 69,469.88 | 70,168.43 |

**x86_64 — CPython — pie**

(Rev `059e374b470e`, 2026-09-18, full-profile instrumentation
(`PY_INSTR_SKIP_FUNCS=0`); four configurations.)

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| deltablue | ops_per_sec | 31,346.87 | 32,060.53 | 31,515.03 | 31,058.73 |
| fannkuch | ops_per_sec | 3.49 | 3.86 | 3.82 | 3.88 |
| float | ops_per_sec | 34.62 | 36.46 | 36.41 | 36.42 |
| go | ops_per_sec | 21.26 | 21.80 | 21.83 | 21.94 |
| hexiom | ops_per_sec | 7,958.46 | 8,415.28 | 8,211.40 | 8,236.91 |
| json_dumps | ops_per_sec | 1,979.73 | 2,208.38 | 2,193.81 | 2,198.83 |
| json_loads | ops_per_sec | 27,068,500.00 | 31,226,400.00 | 31,057,566.67 | 31,660,333.33 |
| nbody | ops_per_sec | 35.84 | 36.48 | 36.48 | 36.39 |
| nqueens | ops_per_sec | 29.14 | 31.82 | 30.98 | 30.38 |
| pickle | ops_per_sec | 119,114,666.67 | 127,736,000.00 | 126,271,333.33 | 124,686,666.67 |
| pickle_pure_python | ops_per_sec | 152,618.67 | 158,214.33 | 156,474.67 | 157,433.67 |
| pyflate | ops_per_sec | 3.28 | 3.43 | 3.39 | 3.41 |
| python_startup | ops_per_sec | 2,131.04 | 2,292.76 | 2,320.18 | 2,328.82 |
| regex_compile | ops_per_sec | 21.16 | 22.32 | 22.53 | 22.33 |
| regex_v8 | ops_per_sec | 589.64 | 592.25 | 590.25 | 596.84 |
| richards | ops_per_sec | 130.01 | 136.14 | 132.78 | 131.72 |
| scimark_fft | ops_per_sec | 4.61 | 5.04 | 4.96 | 4.99 |
| scimark_lu | ops_per_sec | 27.39 | 32.91 | 31.59 | 32.13 |
| scimark_monte_carlo | ops_per_sec | 94.61 | 99.11 | 102.32 | 102.24 |
| scimark_sor | ops_per_sec | 23.39 | 24.82 | 24.53 | 24.57 |
| scimark_sparse_mat_mult | ops_per_sec | 9,834.70 | 21,017.10 | 13,468.97 | 16,728.87 |
| spectral_norm | ops_per_sec | 27.24 | 29.99 | 30.09 | 29.90 |
| telco | ops_per_sec | 5,332.82 | 5,817.25 | 5,871.84 | 5,907.22 |
| unpickle_pure_python | ops_per_sec | 437,579.33 | 461,476.67 | 453,720.00 | 462,485.33 |

**x86_64 — CPython — no-pie**

| workload | metric | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|
| deltablue | ops_per_sec | 33,138.80 | 35,217.07 | 34,820.93 | 34,218.50 |
| fannkuch | ops_per_sec | 4.24 | 4.99 | 4.96 | 5.01 |
| float | ops_per_sec | 67.55 | 89.16 | 88.63 | 89.78 |
| go | ops_per_sec | 22.11 | 22.32 | 22.48 | 22.33 |
| hexiom | ops_per_sec | 8,764.63 | 8,549.75 | 8,750.14 | 8,748.31 |
| json_dumps | ops_per_sec | 2,238.74 | 5,109.74 | 4,209.64 | 5,132.33 |
| json_loads | ops_per_sec | 30,910,600.00 | 35,054,866.67 | 36,057,300.00 | 35,494,000.00 |
| nbody | ops_per_sec | 94.52 | 97.36 | 94.31 | 94.55 |
| nqueens | ops_per_sec | 35.92 | 38.80 | 38.11 | 37.13 |
| pickle | ops_per_sec | 123,358,000.00 | 130,322,333.33 | 131,131,333.33 | 135,600,666.67 |
| pickle_pure_python | ops_per_sec | 166,065.00 | 167,823.33 | 171,718.00 | 174,740.00 |
| pyflate | ops_per_sec | 3.62 | 3.55 | 3.58 | 3.62 |
| python_startup | ops_per_sec | 2,355.59 | 3,248.35 | 2,462.08 | 2,460.51 |
| regex_compile | ops_per_sec | 24.12 | 25.05 | 25.40 | 24.87 |
| regex_v8 | ops_per_sec | 849.09 | 1,363.28 | 1,368.27 | 1,367.34 |
| richards | ops_per_sec | 135.97 | 151.04 | 145.40 | 149.55 |
| scimark_fft | ops_per_sec | 5.36 | 6.49 | 6.35 | 6.51 |
| scimark_lu | ops_per_sec | 34.12 | 83.07 | 65.98 | 53.70 |
| scimark_monte_carlo | ops_per_sec | 116.92 | 117.55 | 119.64 | 120.68 |
| scimark_sor | ops_per_sec | 25.73 | 28.71 | 29.45 | 28.68 |
| scimark_sparse_mat_mult | ops_per_sec | 23,726.40 | 26,366.97 | 27,957.93 | 27,426.93 |
| spectral_norm | ops_per_sec | 34.20 | 53.41 | 51.87 | 39.15 |
| telco | ops_per_sec | 6,460.51 | 7,200.65 | 7,013.80 | 7,183.17 |
| unpickle_pure_python | ops_per_sec | 508,019.33 | 552,702.33 | 557,615.00 | 548,043.00 |

### 4.3 Latency (geomean vs. baseline, lower is better)

| Arch | App | Mode | `bolt` | `bolt-rewrite` | `bolt-rewrite-nohuge` |
|---|---|---|---|---|---|
| aarch64 | MariaDB | pie | −29.97 % | −29.02 % | −30.51 % |
| aarch64 | MariaDB | no-pie | −31.08 % | −31.08 % | −31.37 % |
| aarch64 | PostgreSQL | pie | −25.29 % | −25.28 % | −25.61 % |
| aarch64 | PostgreSQL | no-pie | −25.28 % | −25.61 % | −25.61 % |
| aarch64 | MongoDB | pie | −27.97 % | −27.67 % | −27.34 % |
| aarch64 | MongoDB | no-pie | −26.20 % | −26.57 % | −27.65 % |
| x86_64 | MariaDB | pie | −16.71 % | −11.24 % | −7.79 % |
| x86_64 | MariaDB | no-pie | −18.20 % | −18.05 % | −18.36 % |
| x86_64 | PostgreSQL | pie | −13.43 % | −11.47 % | −8.96 % |
| x86_64 | PostgreSQL | no-pie | −13.60 % | −13.22 % | −13.25 % |
| x86_64 | MongoDB | pie | −16.02 % | −13.12 % | −10.99 % |
| x86_64 | MongoDB | no-pie | −16.96 % | −13.29 % | −12.90 % |

Per-workload average latency (ms):

| Arch | App | Mode | workload | baseline | bolt | bolt-rewrite | bolt-rewrite-nohuge |
|---|---|---|---|---|---|---|---|
| aarch64 | MariaDB | pie | oltp_point_select | 0.41 | 0.28 | 0.28 | 0.27 |
| aarch64 | MariaDB | pie | oltp_read_write | 11.81 | 8.65 | 8.68 | 8.62 |
| aarch64 | MariaDB | no-pie | oltp_point_select | 0.42 | 0.27 | 0.27 | 0.27 |
| aarch64 | MariaDB | no-pie | oltp_read_write | 11.80 | 8.61 | 8.61 | 8.65 |
| aarch64 | PostgreSQL | pie | select-only | 0.45 | 0.33 | 0.33 | 0.33 |
| aarch64 | PostgreSQL | pie | tpcb-like | 2.67 | 2.04 | 2.04 | 2.03 |
| aarch64 | PostgreSQL | no-pie | select-only | 0.47 | 0.34 | 0.34 | 0.34 |
| aarch64 | PostgreSQL | no-pie | tpcb-like | 2.72 | 2.09 | 2.08 | 2.08 |
| aarch64 | MongoDB | pie | workloada | 1.66 | 1.20 | 1.22 | 1.21 |
| aarch64 | MongoDB | pie | workloadc | 1.19 | 0.85 | 0.84 | 0.86 |
| aarch64 | MongoDB | no-pie | workloada | 1.64 | 1.24 | 1.21 | 1.21 |
| aarch64 | MongoDB | no-pie | workloadc | 1.18 | 0.85 | 0.86 | 0.84 |
| x86_64 | MariaDB | pie | oltp_point_select | 0.10 | 0.08 | 0.08 | 0.09 |
| x86_64 | MariaDB | pie | oltp_read_write | 2.71 | 2.35 | 2.56 | 2.56 |
| x86_64 | MariaDB | no-pie | oltp_point_select | 0.11 | 0.09 | 0.09 | 0.09 |
| x86_64 | MariaDB | no-pie | oltp_read_write | 3.20 | 2.62 | 2.63 | 2.61 |
| x86_64 | PostgreSQL | pie | select-only | 0.07 | 0.06 | 0.06 | 0.06 |
| x86_64 | PostgreSQL | pie | tpcb-like | 0.47 | 0.40 | 0.41 | 0.43 |
| x86_64 | PostgreSQL | no-pie | select-only | 0.08 | 0.07 | 0.07 | 0.07 |
| x86_64 | PostgreSQL | no-pie | tpcb-like | 0.52 | 0.45 | 0.45 | 0.45 |
| x86_64 | MongoDB | pie | workloada | 0.39 | 0.32 | 0.33 | 0.33 |
| x86_64 | MongoDB | pie | workloadc | 0.25 | 0.21 | 0.22 | 0.23 |
| x86_64 | MongoDB | no-pie | workloada | 0.38 | 0.31 | 0.32 | 0.32 |
| x86_64 | MongoDB | no-pie | workloadc | 0.24 | 0.20 | 0.21 | 0.21 |

CPython/pyperformance reports only `ops_per_sec` (no latency metric), so it has
no row in the latency tables.

### 4.4 Binary size

The BOLT input is linked with `-Wl,-q`, so it carries non-allocatable `.rela.*`
sections and a symbol table that are not part of the deployed image; stripping
removes them (runtime `.rela.dyn`/`.rela.plt` are kept). Comparing raw file
sizes therefore flatters BOLT output, which no longer carries those sections,
so all deltas below use **stripped file size**, for both architectures.

**x86_64 (stripped file size; rev `d0a877f`, 2026-09-17 re-validation; CPython rows at rev `059e374`, 2026-09-18)**

| App | Mode | baseline (bytes) | `bolt` (Δ) | `bolt-rewrite` (Δ) | `bolt-rewrite-nohuge` (Δ) |
|---|---|---|---|---|---|
| MariaDB | pie | 26,921,472 | 33,155,048 (**+23.2 %**) | 26,921,152 (**−0.0 %**) | 26,921,176 (**−0.0 %**) |
| MariaDB | no-pie | 22,346,312 | 28,592,016 (**+28.0 %**) | 22,367,000 (**+0.1 %**) | 22,367,016 (**+0.1 %**) |
| PostgreSQL | pie | 9,651,888 | 14,807,656 (**+53.4 %**) | 9,664,856 (**+0.1 %**) | 9,664,872 (**+0.1 %**) |
| PostgreSQL | no-pie | 9,367,352 | 14,523,096 (**+55.0 %**) | 9,376,200 (**+0.1 %**) | 9,376,224 (**+0.1 %**) |
| MongoDB | pie | 129,725,304 | 151,228,760 (**+16.6 %**) | 132,482,336 (**+2.1 %**) | 130,569,520 (**+0.7 %**) |
| MongoDB | no-pie | 125,596,536 | 147,260,992 (**+17.3 %**) | 128,484,864 (**+2.3 %**) | 126,645,784 (**+0.8 %**) |
| CPython | pie | 5,365,936 | 10,138,920 (**+89.0 %**) | 5,432,128 (**+1.2 %**) | 5,432,152 (**+1.2 %**) |
| CPython | no-pie | 4,870,872 | 9,630,792 (**+97.7 %**) | 4,908,256 (**+0.8 %**) | 4,908,280 (**+0.8 %**) |

**aarch64 (stripped file size; rev `d0a877f`, byte-identical to `d1723d9d`)**

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

The 2026-09-17 re-validation at rev `d0a877f` (three apps × 2 modes × 3
variants, plus CPython) passed the same checks: every optimized binary exists,
passes `--version`/`app_verify_bin`, and completes the full workload with 0
errors; no `.failed` artifacts, no verify logs, and no `BOLT-ERROR`/
`corrupted control flow` in any optimize log.

Historical `d1723d9d` validation (MariaDB + PostgreSQL):

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

**x86_64 (2026-09-17, rev `d0a877f`, re-instrumentation).** All twenty-six
optimized targets that BOLT produces (4 server variants × 2 modes × 3 apps = 24,
plus CPython `bolt` × 2 modes; CPython `-rewrite`/`-rewrite-nohuge` are rejected by
BOLT, §3.5) pass their health check — `app_verify_bin` for CPython (staging the
`pie` `.so` and importing `sys, pyperf, pyperformance`), `--version` for the
servers — and every bench completed with **0 workload errors**; no `.failed`
outputs were left behind. For the three servers this is the first x86_64
`-rewrite` validation at the fixed revision (the earlier gap noted in previous
revisions of this report).

**x86_64 CPython (2026-09-18, rev `059e374`, two instrumentation variants).**
With the x86 computed-goto jump-table recognition (`8bba80ca2a95`), all eight
CPython x86_64 targets (`bolt`, `-rewrite`, `-rewrite-nohuge` × pie/no-pie) are
produced, pass `app_verify_bin` and complete the full pyperformance suite with
**0 errors** — in the default skip-funcs-instrumentation session and in the
full-profile (`PY_INSTR_SKIP_FUNCS=0`) session alike; no `.failed` outputs, no
`BOLT-ERROR`. This is the first x86_64 CPython `-rewrite` validation.

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
   `/llvm:ro`; the x86_64 containers mount `$HOME/src/llvm-23.1.1`
   (moved from `$HOME/src/llvm-project-23` on 2026-09-19).
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
12. **CPython on x86_64 needed `-skip-funcs` in the optimization pass (through
    rev `d0a877f`).** With `-skip-funcs` removed from `BOLT_OPT_FLAGS`, the
    x86_64 optimization pass corrupted the computed-goto dispatch (confirmed at
    `d0a877f`: the optimized library segfaulted on the first import), and since
    `d0a877f` BOLT rejects `-rewrite` with `-skip-funcs`, x86_64 CPython was
    `bolt`-only by construction. Resolved by `8bba80ca2a95` (x86 computed-goto
    jump-table recognition): at rev `059e374` the no-skip optimization pass is
    correct on x86_64 and all four configurations run (2026-09-18, §4.5).
13. **`optimize.sh` verification under `set -e`.** `run_bolt` runs with `set -e`
    active when invoked as a plain command (the required `bolt` variant), so a
    failing health check used to exit the script one command before `rc=$?`
    could capture it — silently, with no diagnostic. The verification call now
    uses `|| rc=$?` so the existing required/optional handling (`die` vs.
    warn + `.failed`) always runs. Found during the 2026-09-17 x86_64
    re-validation when the first CPython `bolt` output failed its import smoke
    test (issue 12).
15. **CPython instrumentation coverage knob (`PY_INSTR_SKIP_FUNCS`).** The
    default skip-funcs instrumentation leaves the hottest function
    (`_PyEval_EvalFrameDefault`) with no profile counters, capping what BOLT's
    layout can do. With the x86 jump-table recognition in place, dropping
    `-skip-funcs` from instrumentation is safe on x86_64: profile wall time was
    unchanged (444 s vs 447 s) and `bolt` gained +1.1 pt (pie) / +5.2 pt
    (no-pie). The knob defaults to `1` (skip) for cross-architecture
    comparability until the same experiment runs on aarch64, where the
    instrumented `no-pie` interpreter is known to be fragile under
    computed-goto (issue 11).
14. **MongoDB: dump-at-finalization profiling is not applicable (root-caused
    2026-09-18).** Two independent causes, in sequence:
    (a) `llvm-bolt -instrument` on mongod peaks at ~15.5-16.3 GB RSS and was
    OOM-killed on the 15 GB host (silent SIGKILL, no error text, log ends
    right after `clear procedure is ...`, where the ~177 MB instrumentation
    tables are materialized); fixed by raising the WSL VM to 20 GB.
    (b) With instrumentation succeeding, mongod still produces **no** exit
    dump: mongod terminates via `quickExit()` (`_exit()`) in
    `logAndQuickExit_inlock()` (`src/mongo/util/exit.cpp`, right after the
    `Shutting down ... exitCode: 0` log line), which bypasses `_dl_fini`/the
    DT_FINI hook where BOLT's runtime writes the at-exit profile. The
    instrumented binary is correct (DT_FINI verified to point at
    `__bolt_instr_fini`). Inherent mongod behavior - and, as terminating via
    `_exit()`/`quick_exit()` is not a regular way to finish application
    execution, it is **not** something BOLT handles in the regular path.
    **Recommendation:** profile such applications (MongoDB included) with
    `-instrumentation-sleep-time=N` periodic dumps (`profile.sh`); the
    exit-dump variant (`profile-exit.sh`) is only applicable to applications
    that terminate through regular ELF finalization (`exit()`/return from
    `main`). Details: §8.2.

---

## 6. Reproduction

```bash
# 0. Tools under test
$HOME/src/llvm-23.1.1/build/bin/llvm-bolt --version       # aarch64, rev d0a877f
$HOME/src/llvm-23.1.1/build23/bin/llvm-bolt --version  # x86_64,  rev 059e374

# 1. Point each harness container at the build for the target host
#    (aarch64 example)
cd $HOME/src/bolt-harness/apps/mariadb
LLVM_SRC=$HOME/src/llvm-23.1.1 ./rebuild.sh
cd ../postgresql
LLVM_SRC=$HOME/src/llvm-23.1.1 ./rebuild.sh
#    x86_64: same with LLVM_SRC=$HOME/src/llvm-23.1.1

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
LLVM_SRC=$HOME/src/llvm-23.1.1 ./rebuild.sh          # x86_64: image + clone + venv + YCSB
LLVM_SRC=$HOME/src/llvm-23.1.1 ./rebuild.sh exec \
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
# The optimization pass never skips functions (BOLT >= 8bba80ca2a95 recognizes
#   the computed-goto tables on x86_64); -rewrite requires that.
# Instrumentation skips by default; PY_INSTR_SKIP_FUNCS=0 profiles the eval
#   loop too (larger gains, see §3.5/§5.15).
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

### 2026-09-17 aarch64 re-validation at `d0a877f` (no re-profiling)

The whole aarch64 set was re-validated with rev `d0a877fc33a1`, which adds
*Reject `-rewrite` with `-skip-funcs`* and *Fix AArch64 TLSDESC descriptor
retargeting*. CPython required those fixes (§3.5); for MariaDB, PostgreSQL and
MongoDB they are a no-op — none of the baselines has TLS-family relocations and
none uses `-skip-funcs` — and the re-optimized binaries kept their stripped
sizes, alignments and BOLT `dyno-stats` byte-for-byte (only the embedded BOLT
revision differs). Baselines, datasets and merged profiles were reused;
optimization and benchmark re-ran in one four-variant session per app/mode
(`NOHUGE=1`), and the refreshed numbers are the ones in §Summary and §4.
The prior `d1723d9d` optimized binaries are kept under
`work/backup-d1723d9d/`; run logs are
`work/validate-aarch64-{mariadb,postgresql,mongodb}-d0a877f.out`.

---

## 7. Data sources

* Pipeline logs: `bolt-harness/work/newbolt-*.out` (first run),
  `bolt-harness/work/validate-aarch64-{mariadb,postgresql}.out` (2026-09-15
  re-validation) and `…-nohuge.out` (2026-09-15 four-variant/NOHUGE run);
  `bolt-harness/work/validate-aarch64-{mariadb,postgresql,mongodb}-d0a877f.out`
  (2026-09-17 re-validation at rev `d0a877f`)
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

## 8. Dump-at-finalization instrumentation validation (2026-09-18, x86_64)

Validates BOLT instrumentation with the profile written **only at application
finalization** (process exit): `pipeline/profile-exit.sh` (added in commit
`fdc7100`) instruments **without** `-instrumentation-sleep-time` and
**without** `-instrumentation-no-counters-clear`, keeps
`-instrumentation-file-append-pid` on by default, and asserts that the
instrumented binary stays alive through its workload, exits cleanly on
graceful shutdown (bounded wait + crash-marker scan of the server log), and
actually produces stable exit-dump `.fdata` files that `merge-fdata` can
merge into `profiles/<mode>/profile.exit.merged.fdata`. The periodic-dump
`profile.sh` flow is unchanged and was not re-run here.

Environment: x86_64 host (8 cores, 15 GB RAM), the four running app
containers, `llvm-bolt` from `/llvm/build23` (branch
`llvmorg-23.1.1-rewrite`, including the computed-goto jump-table fixes
`8bba80ca2a95` and `059e374b470e`).

### 8.1 Result matrix

| App | pie | no-pie |
|---|---|---|
| MariaDB | PASS — 1 exit dump, merged 5.1 MB | PASS — 1 exit dump, merged 5.2 MB; a second run with `PROFILE_EXIT_VALIDATE_BOLT=1` additionally parsed the merged profile with `llvm-bolt -data=` cleanly |
| PostgreSQL | PASS — 41 exit dumps (postmaster + forked backends), merged 1.7 MB | PASS — 41 exit dumps, merged 1.7 MB |
| CPython | PASS — 26 exit dumps (forked pyperf workers), merged 2.8 MB | PASS — 26 exit dumps, merged 2.8 MB |
| MongoDB | **N/A (root-caused)** — instrument OK after RAM raise (peak 15.8 GB), clean shutdown, but no exit dump: mongod exits via `quickExit` | **N/A (root-caused)** — same (peak 16.3 GB) |

CPython ran with `PYTHON_BENCH_TESTS=regex_v8,nbody` (subset; its workload is
pyperf-driven, not wall-clock-bounded). All PASSing combos satisfied every
check: server liveness through the workload, clean exit after shutdown, no
crash markers in the server log, stable `.fdata` exit dumps, successful merge.

### 8.2 MongoDB — investigation result (2026-09-18, root-caused)

Two independent, sequential causes; both verified.

**Cause 1 (fixed): kernel OOM kill during `llvm-bolt -instrument`.**
On the original 15 GB host, both modes were killed by the OOM killer
(`dmesg`: `Out of memory: Killed process ... (llvm-bolt) ... anon-rss:
15.57 GB / 15.52 GB`) — a silent SIGKILL, hence no error text, non-zero
exit, no output binary, and a log that ends right after
`BOLT-INFO: clear procedure is ...`: the next step,
`InstrumentationRuntimeLibrary::emitTablesAsELFNote` → `buildTables()`,
materializes the ~177 MB descriptor tables (plus two further ~177 MB
copies) on top of the peak. The Sept 17 periodic run had succeeded by a
small margin; the computed-goto jump-table fixes in BOLT (commits
`8bba80ca2a95`, `059e374b470e`) claim slightly more tables on mongod
(+305 indirect-call sites, descriptors 177.64 MB vs 177.59 MB) and tipped
the peak over. The flag deltas of the failing invocation
(no `-instrumentation-sleep-time`, no `-instrumentation-no-counters-clear`,
plus `-instrumentation-file-append-pid`) were exonerated. After raising
the WSL VM to 20 GB, instrumentation completes: measured peak VmHWM
15.79 GB (pie) / 16.31 GB (no-pie).

**Cause 2 (inherent, not fixable harness-side): mongod bypasses DT_FINI.**
With instrumentation succeeding, both modes still produce no exit dump:
mongod shuts down cleanly (WiredTiger checkpoint, `exitCode: 0` in the
server log) but terminates via `quickExit()` — `_exit()` — in
`logAndQuickExit_inlock()` (`src/mongo/util/exit.cpp`), immediately after
logging `Shutting down ... exitCode: 0`. `_exit()` does not run
`_dl_fini`/DT_FINI handlers, so BOLT's runtime finalizer
`__bolt_instr_fini` (verified: output DT_FINI points at it,
`0x14605580`; entry point hooked likewise) never executes, and with
sleep-time 0 that finalizer is the only dump path. No kernel crash record
(`dmesg` clean), the dump simply never runs. This is by-design mongod
behavior; the only BOLT-side workarounds would be a signal-triggered or
periodic dump — i.e. the existing periodic `profile.sh`, which remains the
supported way to profile MongoDB. Test result: `profile-exit.sh` correctly
fails fast with
`no stable .fdata exit dumps produced within 60s`.

**Independence from the `-rewrite` work.** The full sequence reproduces
identically on a stock upstream build (tag `llvmorg-23.1.1`, BOLT rev
`6dfe1677ab8d`, host `build_base`): instrumentation completes (DT_FINI hook
verified in the output), peak VmHWM 16.08 GB (pie) / 16.33 GB (no-pie),
clean mongod shutdown, empty `fdata-exit/`, and the same
`no stable .fdata exit dumps` failure. The exit-dump gap is therefore a
property of mongod's `quickExit` termination on stock BOLT 23.1.1, not of
the `-rewrite` feature or this branch's changes.

**Recommendation.** Terminating via `_exit()`/`quick_exit()` skips regular
ELF finalization (`_dl_fini`/`atexit`), so it is not a common or correct
way to finish application execution, and BOLT intentionally does not
handle it in the regular path: the at-exit dump relies on the DT_FINI
hook. Applications that terminate this way (mongod, or any process killed
with `SIGKILL`) cannot produce a finalization dump by design — profile
them with `-instrumentation-sleep-time=N` periodic dumps (`profile.sh`).
The `profile-exit.sh` variant is applicable only to applications that
exit through regular ELF finalization (`exit()`, `return` from `main`).

* Repro: §8.3. Artifacts: `…/_state/mongodb/profiles/{pie,no-pie}/`
  `instrument-exit.log` (complete instrument), `server-profile-exit.log`
  (clean shutdown), `fdata-exit/` (empty); verification transcripts
  `bolt-harness/work/verify-mongodb-exit-{pie,nopie}.out` (with VmHWM
  poller output). Reference success (periodic, pre-RAM-raise):
  `…/profiles/pie/instrument.log`.

### 8.3 Reproducing the matrix (x86_64)

```
docker exec bolt-harness-mariadb    bash -c 'export APP=mariadb    HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build23/bin CC=gcc;    /harness/pipeline/profile-exit.sh pie'
docker exec bolt-harness-postgresql bash -c 'export APP=postgresql HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build23/bin CC=gcc;    /harness/pipeline/profile-exit.sh no-pie'
docker exec bolt-harness-python    bash -c 'export APP=python     HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build23/bin CC=gcc PYTHON_BENCH_TESTS=regex_v8,nbody; /harness/pipeline/profile-exit.sh pie'
docker exec bolt-harness-mongodb   bash -c 'export APP=mongodb    HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build23/bin CC=gcc-12 CXX=g++-12 MONGODB_PYTHON=/work/mongodb/venv/bin/python3 YCSB_DIR=/work/ycsb; /harness/pipeline/profile-exit.sh pie'
```
`profile-exit.sh` takes a single mode argument; repeat per mode. Outputs live
next to the periodic profiles as `fdata-exit/`, `*.instr-exit` and
`profile.exit.merged.fdata` (PostgreSQL under its app-local
`work/postgresql/_state/postgresql/profiles/<mode>/` mount).
