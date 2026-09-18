# bolt-harness

A multi-application benchmark harness that measures **llvm-bolt**
optimizations on real server applications on aarch64 and x86_64.

The pipeline mirrors the proven `redis/bolt-bench` flow:

```
build app ──► instrument with BOLT ──► run workload ──► merge-fdata
                                                         │
              benchmark baseline ◄── optimize with BOLT ◄┘  (2 variants:
                                                           bolt / bolt-rewrite)
```

It is split into a generic orchestration layer and per-application adapters so
new projects can be added without touching the pipeline.

## Layout

```
bolt-harness/
├── lib/common.sh          # shared paths, pinning, ports, BOLT tool locations
├── pipeline/              # application-agnostic stages
│   ├── profile.sh         # llvm-bolt -instrument + app workload + merge-fdata
│   ├── profile-exit.sh    # same, but profile dumped at app finalization only
│   ├── optimize.sh        # <binary>.bolt and <binary>.bolt-rewrite
│   ├── bench.sh           # server lifecycle + warmup/reps + normalized results
│   ├── compare.sh         # baseline vs bolt vs bolt-rewrite + geomean
│   ├── size-report.sh     # stripped size + section/segment alignment overhead
│   └── run-all.sh         # APP=<app> ./run-all.sh [modes...]
├── apps/<app>/            # per-application code
│   ├── build.sh           # REQUIRED: application-specific build
│   ├── app.sh             # REQUIRED: adapter hooks
│   ├── Dockerfile         # container with build/benchmark dependencies
│   ├── rebuild.sh         # container lifecycle helper
│   └── README.md
└── work/                  # bind-mounted state (gitignored)
```

## Applications

| App | Directory | Server | Workload |
|---|---|---|---|
| MariaDB 11.4 LTS | `apps/mariadb/` | `mariadbd` | sysbench OLTP (`oltp_point_select`, `oltp_read_write`) |
| PostgreSQL 17 | `apps/postgresql/` | `postgres` | pgbench (`select-only`, `tpcb-like`) |
| MongoDB 7.0 | `apps/mongodb/` | `mongod` | YCSB (`workloada`, `workloadc`) |
| CPython 3.13 | `apps/python/` | (none; interpreter) | pyperformance |

## Quick start (MariaDB)

```bash
cd apps/mariadb
./rebuild.sh                 # build image, start container, clone MariaDB
./rebuild.sh exec /harness/pipeline/run-all.sh pie no-pie
```

See `apps/mariadb/README.md` for details and tuning knobs.

## Quick start (PostgreSQL)

```bash
cd apps/postgresql
./rebuild.sh                 # build image, start container, clone PostgreSQL
./rebuild.sh exec /harness/pipeline/run-all.sh pie no-pie
```

See `apps/postgresql/README.md` for details and tuning knobs.

## Quick start (MongoDB)

```bash
cd apps/mongodb
./rebuild.sh                 # build image, start container, clone MongoDB + YCSB
./rebuild.sh exec /harness/pipeline/run-all.sh pie no-pie
```

MongoDB 7.0 is the last **SCons** release (whose `CCFLAGS`/`LINKFLAGS`
variables accept BOLT's flags directly); 8.0 is Bazel-only and unsupported.
The container is Ubuntu 24.04 (required so the host-built `llvm-bolt` runs
inside it) with Python 3.10 from deadsnakes and GCC 12, matching MongoDB 7.0's
SCons requirements. The build disables the mozjs JavaScript engine
(`--js-engine=none`), whose computed-goto interpreter is a BOLT hazard, and
strips DWARF from the baseline so the BOLT input is ~220 MB instead of ~8.5 GB.
See `apps/mongodb/README.md` for details and tuning knobs. MongoDB builds are
much longer than the other apps (~2 h for the first mode); both modes share one
SCons tree, so the second is just a relink. Run builds detached and watch the
per-mode log.

## Quick start (CPython)

```bash
cd apps/python
./rebuild.sh                 # build image, start container, clone CPython 3.13
./rebuild.sh exec /harness/pipeline/run-all.sh pie no-pie
```

The two modes optimize different artifacts: `pie` builds a shared
`libpython3.13.so.1.0` and BOLTs the library (loaded by the installed `python3`
launcher via `LD_LIBRARY_PATH`); `no-pie` builds a static non-PIE `python3` and
BOLTs the executable. The workload is **pyperformance** (a dependency-free,
pyperf-only subset run without pyperformance's per-benchmark venvs).
See `apps/python/README.md` for the recipe, flags and knobs.

## Pipeline

| Stage | Script | What it does |
|---|---|---|
| 1 | `apps/<app>/build.sh` | App-specific build with BOLT-friendly flags; snapshots the baseline binary + build info. |
| 2 | `pipeline/profile.sh` | Instruments the baseline with `llvm-bolt -instrument`, runs the application workload longer than the periodic dump interval, merges the `.fdata` with `merge-fdata`. |
| 2b | `pipeline/profile-exit.sh` | Optional (`PROFILE_EXIT=1` in `run-all.sh`, or standalone): instruments **without** `-instrumentation-sleep-time`/`-instrumentation-no-counters-clear` so the profile is dumped at application finalization (process exit) only, and checks that the instrumented binary stays alive through the workload, exits cleanly on shutdown (no crash markers in the server log) and actually produces the exit-dump `.fdata`. Output: `profile.exit.merged.fdata`, separate from the periodic profile. `-instrumentation-file-append-pid` is on by default (forking servers, e.g. PostgreSQL backends, would overwrite one shared `.fdata`); disable with `PROFILE_EXIT_APPEND_PID=0`. |
| 3 | `pipeline/optimize.sh` | Produces `<binary>.bolt` (README flags) and `<binary>.bolt-rewrite` (`+ -rewrite`) from the merged profile. |
| 4 | `pipeline/bench.sh` | Starts a fresh server per variant, runs `WARMUP` discarded + `REPS` recorded workload rounds, stores raw output and normalized `summary.tsv`. |
| 5 | `pipeline/compare.sh` | Averages each variant's newest run and prints per-metric deltas + geomean. |

Stages are skippable with `SKIP_BUILD`, `SKIP_PROFILE`, `SKIP_OPTIMIZE`,
`SKIP_BENCH`, `SKIP_COMPARE`. The exit-dump profiling variant is enabled with
`PROFILE_EXIT=1` (skippable alone via `SKIP_PROFILE_EXIT=1`); tunables:
`PROFILE_EXIT_TEST_TIME` (workload seconds, default 30), `PROFILE_EXIT_WAIT`
(max wait for exit dumps, default 60), `PROFILE_EXIT_APPEND_PID` (default 1)
and `PROFILE_EXIT_VALIDATE_BOLT=1` to additionally parse the merged profile
with `llvm-bolt -data=`.

## Adding an application

1. Create `apps/<name>/`.
2. `build.sh` must build the app and populate:
   - `$BINARIES/<mode>/<binary>` (baseline) and a `build-info.txt`.
   - `$INSTALLS/<mode>/` (runtime files) if the app needs a run-time tree.
3. `app.sh` implements the adapter hooks (see `apps/mariadb/app.sh`):
   `app_variant_bin`, `app_basedir`, `app_prepare_data`, `app_server_start`,
   `app_server_wait`, `app_server_stop`, `app_workload`, `app_parse_workload`;
   optional `app_describe` records app-specific params in `env.txt`, and
   optional `app_verify_bin <mode> <variant> <path>` overrides `optimize.sh`'s
   `--version` health check (needed for non-executable targets such as a shared
   library; the hook owns its own timeout). See `apps/python/app.sh`.
4. Add a `Dockerfile` + `rebuild.sh` (copy `apps/mariadb/` as a template).
   If the app cannot run as root, run the container as a host-matching
   non-root uid and mount a per-app state dir (see `apps/postgresql/`).
5. Run with `APP=<name> pipeline/run-all.sh <modes...>`.

An app container mounting a per-app state root keeps its artifacts under
`work/<app>/`, e.g. PostgreSQL uses `work/postgresql/` (host) mounted at
`/work` in the container.

## State layout

Everything the pipeline produces lives under `$STATE` (`work/_state/<app>/`
when the container shares the root `work/` tree, as MariaDB does):

```
binaries/<mode>/    baseline + .bolt + .bolt-rewrite, build-info.txt, logs
installs/<mode>/    installed run-time tree used by the server
data/<mode>/        prepared benchmark dataset
profiles/<mode>/    instrumented binary, raw/merged .fdata
results/<mode>/<which>/<timestamp>/   raw output, summary.tsv, env.txt
```

## Configuration

All tunables are environment variables read in `lib/common.sh` / the app
adapter. Common ones:

| Variable | Default | Meaning |
|---|---|---|
| `APP` | `mariadb` | application under test |
| `HARNESS_WORK` | `<repo>/work` | state root (container: `/work`) |
| `BOLT_BIN_DIR` | `$HOME/src/llvm-project/build/bin` | `llvm-bolt`, `merge-fdata` |
| `BOLT_OPT_FLAGS` | bolt README flags | optimization flags for `optimize.sh` |
| `NOHUGE` | `0` | when `1`, also build/bench `bolt-rewrite-nohuge` (`-rewrite --no-huge-pages`), a rewrite with BOLT's default 2M huge-page code alignment replaced by the regular page size (4K x86_64 / 64K aarch64) |
| `SERVER_CPUS` / `CLIENT_CPUS` | arch-aware | `taskset -c` CPU lists (empty = off) |

Inside a container, `BOLT_BIN_DIR` is set by `rebuild.sh`, which auto-detects
the LLVM build dir containing `bin/llvm-bolt` under `LLVM_SRC` (override with
`LLVM_BUILD_DIR`). A checkout whose build lives in `build23/` therefore needs
no extra flags. **Build flags are architecture-conditional**: `-mbranch-protection=none`
is applied on aarch64 only; x86_64 keeps GCC's default CET/IBT.

## Requirements

- aarch64 or x86_64 Linux host with `llvm-bolt` (a build that supports the
  target's instrumentation and `-rewrite`).
- Docker (the container only supplies the build toolchain; BOLT itself runs
  from the host checkout mounted read-only).
- BOLT cannot rewrite pointer-auth or stack-protector code, so builds disable
  PAC/BTI (aarch64) and the stack protector, plus GCC's
  `-freorder-blocks-and-partition`. x86_64 keeps GCC's default CET/IBT; if BOLT
  rejects endbr64 binaries, add `-fcf-protection=none` in the app `build.sh`.
