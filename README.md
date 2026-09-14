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
│   ├── optimize.sh        # <binary>.bolt and <binary>.bolt-rewrite
│   ├── bench.sh           # server lifecycle + warmup/reps + normalized results
│   ├── compare.sh         # baseline vs bolt vs bolt-rewrite + geomean
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

## Pipeline

| Stage | Script | What it does |
|---|---|---|
| 1 | `apps/<app>/build.sh` | App-specific build with BOLT-friendly flags; snapshots the baseline binary + build info. |
| 2 | `pipeline/profile.sh` | Instruments the baseline with `llvm-bolt -instrument`, runs the application workload longer than the periodic dump interval, merges the `.fdata` with `merge-fdata`. |
| 3 | `pipeline/optimize.sh` | Produces `<binary>.bolt` (README flags) and `<binary>.bolt-rewrite` (`+ -rewrite`) from the merged profile. |
| 4 | `pipeline/bench.sh` | Starts a fresh server per variant, runs `WARMUP` discarded + `REPS` recorded workload rounds, stores raw output and normalized `summary.tsv`. |
| 5 | `pipeline/compare.sh` | Averages each variant's newest run and prints per-metric deltas + geomean. |

Stages are skippable with `SKIP_BUILD`, `SKIP_PROFILE`, `SKIP_OPTIMIZE`,
`SKIP_BENCH`, `SKIP_COMPARE`.

## Adding an application

1. Create `apps/<name>/`.
2. `build.sh` must build the app and populate:
   - `$BINARIES/<mode>/<binary>` (baseline) and a `build-info.txt`.
   - `$INSTALLS/<mode>/` (runtime files) if the app needs a run-time tree.
3. `app.sh` implements the adapter hooks (see `apps/mariadb/app.sh`):
   `app_variant_bin`, `app_basedir`, `app_prepare_data`, `app_server_start`,
   `app_server_wait`, `app_server_stop`, `app_workload`, `app_parse_workload`;
   optional `app_describe` records app-specific params in `env.txt`.
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
