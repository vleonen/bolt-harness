# bolt-harness — PostgreSQL 17

Builds and benchmarks **PostgreSQL 17** with llvm-bolt in two ELF link modes
(`pie`, `no-pie`) and three variants (plus an opt-in fourth,
`bolt-rewrite-nohuge`, enabled with `NOHUGE=1`):

| Variant | Binary | Description |
|---|---|---|
| baseline | `postgres` | unmodified build |
| bolt | `postgres.bolt` | BOLT README flags, profile-driven |
| bolt-rewrite | `postgres.bolt-rewrite` | same + experimental `-rewrite` |
| bolt-rewrite-nohuge | `postgres.bolt-rewrite-nohuge` | `-rewrite --no-huge-pages` (regular-page code alignment); only with `NOHUGE=1` |

The workload is **pgbench** (`select-only` + `tpcb-like`) against a locally
initialized `pgbench` database.

## Container

`rebuild.sh` builds `bolt-harness-postgresql:ubuntu24.04` and starts a
container that runs as a **non-root `postgres` user** (PostgreSQL refuses to
run as root) whose uid/gid match the host, so `work/` artifacts are
host-owned. It bind-mounts:

- host LLVM checkout **read-only** at `/llvm` (BOLT runs from the build dir
  `rebuild.sh` auto-detects, e.g. `/llvm/build23/bin/llvm-bolt`)
- the harness **read-only** at `/harness`
- `work/` **read-write** at `/work`

```bash
./rebuild.sh          # build image, (re)create container, clone PostgreSQL, shell
./rebuild.sh stop     # tear down
```

Overridable: `LLVM_SRC` (`$HOME/src/llvm-project`), `LLVM_BUILD_DIR`
(auto-detected under `LLVM_SRC`), `POSTGRES_VERSION` (`REL_17_11`).

## Running the pipeline

Full run (both modes):

```bash
./rebuild.sh exec /harness/pipeline/run-all.sh pie no-pie
```

Stage by stage / interactively:

```bash
docker exec -it bolt-harness-postgresql bash
export APP=postgresql HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build/bin CC=gcc
# BOLT_BIN_DIR is auto-set by `rebuild.sh exec`; adjust the build dir here
# (e.g. /llvm/build23/bin) only for manual `docker exec` sessions.

/harness/apps/postgresql/build.sh pie          # build baseline + install tree
/harness/pipeline/profile.sh pie               # instrument + pgbench load + merge
/harness/pipeline/optimize.sh pie              # postgres.bolt[.bolt-rewrite]
/harness/pipeline/bench.sh pie baseline        # bench a variant
/harness/pipeline/compare.sh pie               # deltas + geomean

# re-bench only:
SKIP_BUILD=1 SKIP_PROFILE=1 SKIP_OPTIMIZE=1 \
  /harness/pipeline/run-all.sh pie
```

## Build recipe

`build.sh` configures PostgreSQL out-of-tree (VPATH) with:

```
--without-icu --without-readline --without-zlib --without-llvm
CFLAGS='-O2 -fno-omit-frame-pointer -fno-stack-protector
        [-mbranch-protection=none]            # aarch64 only
        [-fno-reorder-blocks-and-partition]'  # GCC only
LDFLAGS_EX='-Wl,-q'          # pie
LDFLAGS_EX='-no-pie -Wl,-q'  # no-pie
```

`-mbranch-protection=none` (aarch64 only) keeps PAC/BTI out (BOLT cannot
rewrite pointer-auth code); `-fno-stack-protector` removes SSP; `-Wl,-q` keeps
linker relocations so BOLT can recover control flow. On x86_64 GCC's default
CET/IBT is kept (add `-fcf-protection=none` here only if BOLT rejects the
endbr64 binary). BOLT link flags go through `LDFLAGS_EX` (executables only), so
shared modules built via `LDFLAGS_SL` stay PIC. PostgreSQL JIT is disabled
(`--without-llvm`) to keep the served code comparable.

`build.sh` also passes `pgac_cv_computed_goto=no` to `configure`, disabling
PostgreSQL's computed-goto (direct-threaded) expression interpreter
(`EEO_USE_COMPUTED_GOTO` → switch-based dispatch). The static `dispatch_table`
of 99 `&&label` pointers in `.data.rel.ro` is misdetected by `llvm-bolt
-instrument` as a jump table; its rewritten entries land 1–3 bytes off the real
handler entry points, so backends SIGSEGV on the first query (crash IP equals a
rewritten entry). There is no compiler/linker flag to turn off labels-as-values,
so the configure cache variable is the supported way out. Set `PG_COMPUTED_GOTO=1`
to re-enable it (e.g. to test a BOLT fix). The switch-based interpreter is
slightly slower, but equally so for baseline/bolt/bolt-rewrite, so within-run
deltas remain valid.

Each mode installs to `$STATE/installs/<mode>` and snapshots
`$BINARIES/<mode>/postgres`; `build-info.txt` records flags, ELF type,
relocation count, size, sha256 and `--version`.

## Workload and tuning

The dataset is created once per mode (`initdb -A trust` then `pgbench -i -s
$PGBENCH_SCALE`) and reused for profiling and benchmarking so the profile
matches the measured workload. Defaults:

| Variable | Default | Meaning |
|---|---|---|
| `PGBENCH_SCRIPTS` | `select-only,tpcb-like` | workloads |
| `PGBENCH_SCALE` | `100` | pgbench scale (~10M account rows) |
| `PGBENCH_CLIENTS` / `PGBENCH_JOBS` | `16` / `4` | client connections / threads |
| `PGBENCH_MODE` | `prepared` | `-M` protocol |
| `PGBENCH_TIME` | `15` | seconds per script per rep |
| `WARMUP` / `REPS` | `1` / `3` | discarded / recorded rounds |
| `PROFILE_SLEEP_TIME` | `10` | BOLT profile dump interval (s) |
| `SHARED_BUFFERS` | `4GB` | sized to hold the dataset in memory |
| `PROFILE_PORT` / `BENCH_PORT` | `55432` / `55433` | TCP ports |
| `SERVER_CPUS` / `CLIENT_CPUS` | arch-aware (`0-3`/`8-11` on aarch64) | CPU pinning |

The server runs with `fsync=off`, `synchronous_commit=off`,
`full_page_writes=off` and `autovacuum=off` to reduce run-to-run noise; these
settings apply to both profiling and benchmarking. `pgbench` runs with `-n`
(no vacuum before each run).

Set `RESET_DATA=1` to wipe and re-initialize the dataset.

## Notes and limitations

- **Profiling uses periodic dumps** (`-instrumentation-sleep-time` +
  `-instrumentation-no-counters-clear`): each dump is cumulative, so the last
  dump always holds the complete profile. The workload must run longer than the
  dump interval; `profile.sh` enforces this.

`pipeline/profile-exit.sh` is the complementary variant: no periodic dump
options are passed, the profile is written when processes exit. PostgreSQL
forks a backend per connection, so each backend dumps on exit — keep the
variant's default `-instrumentation-file-append-pid` on unless deliberately
testing the raw single-file behavior (`PROFILE_EXIT_APPEND_PID=0`). The
script fails the run on backend crash markers ("terminated by signal") in
the server log.
- **PostgreSQL's computed-goto expression interpreter is disabled** at build
  time (`pgac_cv_computed_goto=no`, see Build recipe) because `llvm-bolt
  -instrument` corrupts its `&&label` dispatch table. Re-enable with
  `PG_COMPUTED_GOTO=1` once BOLT handles it (tracked as a BOLT bug, not a
  harness issue).
- **`-rewrite` is experimental**; check the build-id of
  `postgres.bolt-rewrite` — `-rewrite` currently leaves the baseline build-id
  in place (see the BOLT `-rewrite` build-id notes).
- Only the `postgres` server binary is optimized; client tools are not.
- **Functional check**: confirm each optimized server completes a `bench.sh`
  run with zero pgbench errors before trusting the numbers.
- `static-pie` is intentionally not supported.
