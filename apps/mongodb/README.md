# bolt-harness — MongoDB 7.0

Builds and benchmarks **MongoDB 7.0** (`mongod`, WiredTiger) with llvm-bolt in
two ELF link modes (`pie`, `no-pie`) and three variants (plus an opt-in fourth,
`bolt-rewrite-nohuge`, enabled with `NOHUGE=1`):

| Variant | Binary | Description |
|---|---|---|
| baseline | `mongod` | unmodified build |
| bolt | `mongod.bolt` | BOLT README flags, profile-driven |
| bolt-rewrite | `mongod.bolt-rewrite` | same + experimental `-rewrite` |
| bolt-rewrite-nohuge | `mongod.bolt-rewrite-nohuge` | `-rewrite --no-huge-pages` (regular-page code alignment); only with `NOHUGE=1` |

The workload is **YCSB** (`workloada` + `workloadc`) against a locally loaded
`ycsb` database.

MongoDB 7.0 is used because it is the last release built with **SCons**, whose
`CCFLAGS`/`CXXFLAGS`/`LINKFLAGS` command-line variables let the harness inject
BOLT's flags natively. MongoDB 8.0 is Bazel-only and is not supported here.
`mongo-perf` is not used either: it needs the removed legacy `mongo` 5.0 shell.
YCSB `master` is used because its `mongodb` binding uses
`mongodb-driver-sync`, which can talk to MongoDB 7.0 (YCSB 0.17's legacy 3.x
driver cannot).

## Container

`rebuild.sh` builds `bolt-harness-mongodb:ubuntu24.04` and starts a container
that bind-mounts:

- host LLVM checkout **read-only** at `/llvm` (BOLT runs from the build dir
  `rebuild.sh` auto-detects, e.g. `/llvm/build23/bin/llvm-bolt`)
- the harness **read-only** at `/harness`
- `work/` **read-write** at `/work`

MongoDB runs as root (the image does not switch user), so it shares the root
`work/` tree and its state lives under `work/_state/mongodb/` (like MariaDB).

**Why Ubuntu 24.04 with an old MongoDB toolchain.** The container base must be
at least the host's glibc, because the pipeline runs the host-built `llvm-bolt`
*inside* the container (Ubuntu 22.04's glibc 2.35 cannot run a host BOLT linked
against 2.36+). Noble ships Python 3.12 / GCC 13, which do not satisfy MongoDB
7.0's SCons requirements, so the image adds **Python 3.10 from the deadsnakes
PPA** and builds with **GCC 12** (`CC=gcc-12 CXX=g++-12`).

```bash
./rebuild.sh          # image, container, MongoDB clone, Python venv, YCSB, shell
./rebuild.sh stop     # tear down
```

`rebuild.sh` also:
- creates a Python **venv on the bind-mounted work tree**
  (`work/mongodb/venv`, using the container's Python 3.10) and installs
  `work/mongodb/etc/pip/compile-requirements.txt` (with `Cython<3`, needed to
  build the pinned `PyYAML==5.3.1` sdist);
- builds a **YCSB distribution** at `work/ycsb` from `YCSB_REF` (default
  `master`): `bin/`, `lib/` (core + its runtime deps), `mongodb-binding/lib/`
  (binding + its runtime deps) and `workloads/`. A source checkout would invoke
  Maven on every run.

Overridable: `LLVM_SRC` (`$HOME/src/llvm-project`), `LLVM_BUILD_DIR`
(auto-detected under `LLVM_SRC`), `MONGODB_VERSION` (`r7.0.43`), `YCSB_REF`
(`master`).

## Running the pipeline

Full run (both modes):

```bash
./rebuild.sh exec /harness/pipeline/run-all.sh pie no-pie
```

Stage by stage / interactively:

```bash
docker exec -it bolt-harness-mongodb bash
export APP=mongodb HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build/bin CC=gcc-12 CXX=g++-12
export MONGODB_PYTHON=/work/mongodb/venv/bin/python3 YCSB_DIR=/work/ycsb
# BOLT_BIN_DIR is auto-set by `rebuild.sh exec`; adjust the build dir here
# (e.g. /llvm/build23/bin) only for manual `docker exec` sessions.

/harness/apps/mongodb/build.sh pie         # baseline + install tree
/harness/pipeline/profile.sh pie           # instrument + YCSB load + merge
/harness/pipeline/optimize.sh pie          # mongod.bolt[.bolt-rewrite]
/harness/pipeline/bench.sh pie baseline    # bench a variant
/harness/pipeline/compare.sh pie           # deltas + geomean

# re-bench only:
SKIP_BUILD=1 SKIP_PROFILE=1 SKIP_OPTIMIZE=1 \
  /harness/pipeline/run-all.sh pie
```

For LLVM 23 BOLT (matching the recorded results), run with
`LLVM_SRC=$HOME/src/llvm-23.1.1` (the default since 2026-09-19).

### Build time and monitoring

MongoDB is a large C++20 codebase: the **first build of a mode takes ~2
hours**. Both modes share **one** SCons tree (`$STATE/build/pie`): compile
flags are identical and only `LINKFLAGS` differ, so once one mode is built the
other is just a relink (minutes), not a second full compile. `MONGO_JOBS`
(default `4`) is deliberately low because the large translation units are
memory-hungry; raising it can OOM a 16 GB host.

The build directory name is historical and must stay `pie`: it is embedded in
every compile command line (`-I$build/opt`) and in generated headers, so
renaming it invalidates all objects.

Run long builds detached and watch progress instead of blocking a terminal:

```bash
# start the build detached, logging to a file
nohup ./rebuild.sh exec /harness/apps/mongodb/build.sh no-pie \
  > /tmp/mongodb-nopie.log 2>&1 &

# watch progress (objects compiled and free memory)
watch -n30 'find work/_state/mongodb/build/pie -name "*.o" | wc -l; free -h'
```

The harness redirects SCons output to
`work/_state/mongodb/build-<mode>.log`; errors show up there and in the
detached log. Re-running `build.sh <mode>` afterwards is incremental (SCons
reuses the existing build tree), so it is safe to resume after an interruption.
Once a mode is built, use `SKIP_BUILD=1` to reuse it.

## Build recipe

`build.sh` invokes SCons out-of-tree (`--build-dir=$STATE/build/<mode>`,
`DESTDIR=$STATE/installs/<mode>`) with:

```
install-mongod
CCFLAGS/CXXFLAGS='-fno-omit-frame-pointer -fno-stack-protector
                  [-mbranch-protection=none]             # aarch64 only
                  [-fno-reorder-blocks-and-partition]'    # GCC only
LINKFLAGS='-Wl,--emit-relocs'          # pie
LINKFLAGS='-no-pie -Wl,--emit-relocs'  # no-pie
--opt=on --dbg=off --runtime-hardening=off --js-engine=none
--linker=gold --disable-warnings-as-errors --allocator=system
```

- Compile flags are identical for `pie` and `no-pie`; the mode only changes the
  link (`-no-pie`). PIE objects link into a `-no-pie` executable, so both modes
  share one build tree and the second mode is a relink.
- `--emit-relocs` (GNU ld `-q`) keeps static relocations so BOLT can recover
  control flow and rewrite. The portable spelling is used because MongoDB's
  linkers do not all accept the `-q` alias.
- `--linker=gold` because MongoDB's default `lld` is not installed and its
  `bfd`/gold fallback must be selected explicitly.
- `--runtime-hardening=off` + `-fno-stack-protector` remove SSP; on aarch64
  `-mbranch-protection=none` keeps PAC/BTI out (BOLT cannot rewrite
  pointer-auth code).
- `--js-engine=none` drops the bundled **mozjs** JavaScript engine. It is
  unused by the workload, it dominates build time/size, and its direct-threaded
  computed-goto interpreter is a known BOLT jump-table hazard (cf. PostgreSQL's
  computed goto).
- `--allocator=system` links glibc malloc instead of the bundled tcmalloc,
  shrinking the binary and the BOLT input. Set `MONGODB_ALLOCATOR=tcmalloc|auto`
  to change it.
- `MONGO_JOBS` (default `4`) caps build parallelism because MongoDB's large
  translation units are memory-hungry.

After copying the baseline, `build.sh` runs `objcopy --strip-debug` on it
(`MONGODB_STRIP_DEBUG=1`, default). MongoDB compiles with full DWARF, so the raw
binary is ~8.5 GB; stripping debug brings the BOLT input down to ~220 MB while
keeping the symbol table, `.eh_frame` and the `.rela.*` sections. Disable with
`MONGODB_STRIP_DEBUG=0`, or keep debug in separate files at build time with
`MONGODB_SEPARATE_DEBUG=on`.

Each mode installs to `$STATE/installs/<mode>` and snapshots
`$BINARIES/<mode>/mongod`; `build-info.txt` records flags, ELF type,
relocation count, size, sha256 and `mongod --version`.

## Workload and tuning

The dataset is loaded once per mode (`ycsb load mongodb`) and reused for
profiling and benchmarking so the profile matches the measured workload.
Defaults:

| Variable | Default | Meaning |
|---|---|---|
| `YCSB_WORKLOADS` | `workloada,workloadc` | 50/50 read-update + read-only |
| `YCSB_RECORDCOUNT` / `YCSB_FIELDCOUNT` | `2000000` / `10` | dataset (~2 GB) |
| `YCSB_THREADS` | `16` | YCSB client threads |
| `YCSB_TIME` | `15` | seconds per workload per rep (`maxexecutiontime`) |
| `YCSB_OPERATIONCOUNT` | `1000000000` | effectively unlimited so the time bound governs |
| `WARMUP` / `REPS` | `1` / `3` | discarded / recorded rounds |
| `PROFILE_SLEEP_TIME` | `10` | BOLT profile dump interval (s) |
| `MONGODB_CACHE_GB` | `4` | WiredTiger cache, sized to hold the dataset |
| `MONGO_START_TIMEOUT` | `300` | server startup wait (instrumented mongod is slow) |
| `PROFILE_PORT` / `BENCH_PORT` | `27018` / `27019` | TCP ports |
| `SERVER_CPUS` / `CLIENT_CPUS` | arch-aware (`0-3`/`8-11` on aarch64) | CPU pinning |

YCSB stops at whichever of `operationcount` / `maxexecutiontime` is reached
first, so `YCSB_OPERATIONCOUNT` is set effectively unlimited; otherwise YCSB's
default of 1000 operations ends the run in under a second.

`mongod` additionally runs with `--setParameter ttlMonitorEnabled=false` and
`--setParameter diagnosticDataCollectionEnabled=false` to reduce background
noise; these settings apply to both profiling and benchmarking. Extra flags can
be passed through `MONGODB_EXTRA_ARGS`.

Set `RESET_DATA=1` to wipe and re-load the dataset. `YCSB_RECORDCOUNT` (and
`YCSB_FIELDCOUNT`) must be the same for the load, profile and bench runs, or
YCSB will look up keys that were never inserted.

## Notes and limitations

- **BOLT memory.** `mongod` has ~148k functions and ~2.4M relocations. BOLT's
  default multithreaded `-instrument` peaks above the RAM of a 16 GB machine
  and gets OOM-killed while emitting the instrumented binary. The adapter
  appends `--no-threads` to `BOLT_INSTRUMENT_EXTRA_FLAGS` and `BOLT_OPT_FLAGS`
  (disable with `MONGODB_BOLT_NO_THREADS=0`). Expect several GB of RSS; do not
  run BOLT alongside other memory-heavy work.
- **Profiling uses periodic dumps** (`-instrumentation-sleep-time` +
  `-instrumentation-no-counters-clear`): each dump is cumulative, so the last
  dump holds the complete profile. The workload must run longer than the dump
  interval; `profile.sh` enforces this.

`pipeline/profile-exit.sh` is **not applicable** to MongoDB: mongod
terminates via `quickExit()` (`_exit()`), which bypasses the DT_FINI hook
where BOLT's runtime writes the at-exit profile, so no exit dump can be
produced regardless of flags (root-caused 2026-09-18; see §8.2 of
`LLVM-23.1.1-bolt-rewrite-results.md`). Profile MongoDB with the
periodic-dump `profile.sh`, i.e. rely on `-instrumentation-sleep-time`
(the app default, 10 s) instead of at-exit dumping. Also note
`llvm-bolt -instrument` on mongod peaks at ~16 GB RSS — it needs a
correspondingly large host.
- **`-rewrite` is experimental**; a failure is non-fatal and the variant is
  skipped (`optimize.sh`).
- Only the `mongod` server binary is optimized; mongosh/YCSB are clients.
- **Functional check**: confirm each optimized server completes a `bench.sh`
  run with zero YCSB errors before trusting the numbers; C++ exception handling
  is the main BOLT risk area.
- `static-pie` is intentionally not supported.
