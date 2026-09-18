# bolt-harness — MariaDB 11.4 LTS

Builds and benchmarks **MariaDB 11.4 LTS** with llvm-bolt in two ELF link
modes (`pie`, `no-pie`) and three variants (plus an opt-in fourth,
`bolt-rewrite-nohuge`, enabled with `NOHUGE=1`):

| Variant | Binary | Description |
|---|---|---|
| baseline | `mariadbd` | unmodified build |
| bolt | `mariadbd.bolt` | BOLT README flags, profile-driven |
| bolt-rewrite | `mariadbd.bolt-rewrite` | same + experimental `-rewrite` |
| bolt-rewrite-nohuge | `mariadbd.bolt-rewrite-nohuge` | `-rewrite --no-huge-pages` (regular-page code alignment); only with `NOHUGE=1` |

The workload is **sysbench OLTP** (`oltp_point_select` + `oltp_read_write`)
against a locally prepared `sbtest` dataset.

## Container

`rebuild.sh` builds `bolt-harness-mariadb:ubuntu24.04`, starts a container and
bind-mounts:

- host LLVM checkout **read-only** at `/llvm` (BOLT runs from the build dir
  `rebuild.sh` auto-detects, e.g. `/llvm/build23/bin/llvm-bolt`)
- the harness **read-only** at `/harness`
- `work/` **read-write** at `/work`

```bash
./rebuild.sh          # build image, (re)create container, clone MariaDB, shell
./rebuild.sh stop     # tear down
```

Overridable: `LLVM_SRC` (`$HOME/src/llvm-project`), `LLVM_BUILD_DIR`
(auto-detected under `LLVM_SRC`), `MARIADB_VERSION` (`mariadb-11.4.13`).

## Running the pipeline

Full run (both modes):

```bash
./rebuild.sh exec /harness/pipeline/run-all.sh pie no-pie
```

Stage by stage / interactively:

```bash
docker exec -it bolt-harness-mariadb bash
export APP=mariadb HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build/bin CC=gcc
# BOLT_BIN_DIR is auto-set by `rebuild.sh exec`; adjust the build dir here
# (e.g. /llvm/build23/bin) only for manual `docker exec` sessions.

/harness/apps/mariadb/build.sh pie          # build baseline + install tree
/harness/pipeline/profile.sh pie            # instrument + sysbench load + merge
/harness/pipeline/optimize.sh pie           # mariadbd.bolt[.bolt-rewrite]
/harness/pipeline/bench.sh pie baseline     # bench a variant
/harness/pipeline/compare.sh pie            # deltas + geomean

# re-bench only:
SKIP_BUILD=1 SKIP_PROFILE=1 SKIP_OPTIMIZE=1 \
  /harness/pipeline/run-all.sh pie
```

## Build recipe

`build.sh` configures MariaDB out-of-tree with:

```
-O2 -fno-omit-frame-pointer -fno-stack-protector
[-mbranch-protection=none]              # aarch64 only
[-fno-reorder-blocks-and-partition]     # GCC only
-DSECURITY_HARDENED=OFF -DWITH_UNIT_TESTS=OFF -DWITH_MARIABACKUP=OFF
-DWITH_SYSTEMD=OFF -DWITH_WSREP=OFF
-DWITH_MYSQLD_LDFLAGS='-Wl,-q'          # pie
-DWITH_MYSQLD_LDFLAGS='-no-pie -Wl,-q'  # no-pie
```

`-mbranch-protection=none` (aarch64 only) keeps PAC/BTI out (BOLT cannot
rewrite pointer-auth code); `-fno-stack-protector`/`SECURITY_HARDENED=OFF`
remove SSP; `-Wl,-q` keeps linker relocations so BOLT can recover control flow.
On x86_64 GCC's default CET/IBT is kept (add `-fcf-protection=none` here only
if BOLT rejects the endbr64 binary). The executable-only `WITH_MYSQLD_LDFLAGS`
avoids propagating `-no-pie` into the plugin `.so` builds.

Each mode installs to `$STATE/installs/<mode>` and snapshots
`$BINARIES/<mode>/mariadbd`; `build-info.txt` records flags, ELF type,
relocation count, size, sha256 and `--version`.

## Workload and tuning

The dataset is prepared once per mode (`mariadb-install-db` + `sysbench ...
prepare`) and reused for profiling and benchmarking so the profile matches the
measured workload. Defaults:

| Variable | Default | Meaning |
|---|---|---|
| `SYSBENCH_TESTS` | `oltp_point_select,oltp_read_write` | workloads |
| `SYSBENCH_TABLES` / `SYSBENCH_TABLE_SIZE` | `10` / `100000` | dataset |
| `SYSBENCH_THREADS` | `16` | sysbench client threads |
| `BENCH_TIME` | `15` | seconds per test per rep |
| `WARMUP` / `REPS` | `1` / `3` | discarded / recorded rounds |
| `PROFILE_SLEEP_TIME` | `10` | BOLT profile dump interval (s) |
| `PROFILE_EXIT_TEST_TIME` | `30` | workload seconds for `profile-exit.sh` (dump at finalization) |
| `INNODB_BUFFER_POOL_SIZE` | `4G` | sized to hold the dataset in memory |
| `PROFILE_PORT` / `BENCH_PORT` | `3307` / `3308` | TCP ports |
| `SERVER_CPUS` / `CLIENT_CPUS` | arch-aware (`0-3`/`8-11` on aarch64) | CPU pinning |

`MYSQLD_EXTRA_ARGS` disables the binlog, slows/drops durable flush
(`--innodb-flush-log-at-trx-commit=2 --innodb-doublewrite=0`) and turns off the
performance schema to reduce run-to-run noise. These settings apply to both
profiling and benchmarking.

Set `RESET_DATA=1` to wipe and re-prepare the dataset.

## Notes and limitations

- **Profiling uses periodic dumps** (`-instrumentation-sleep-time` +
  `-instrumentation-no-counters-clear`): each dump is cumulative, so the last
  dump always holds the complete profile. The workload must run longer than the
  dump interval; `profile.sh` enforces this.

`pipeline/profile-exit.sh` is the complementary variant: no periodic dump
options are passed, the profile is written when the instrumented server
exits, and the script verifies the server survives the workload and shuts
down without crash markers. Single-process server; the default
`-instrumentation-file-append-pid` is harmless.
- **`-rewrite` is experimental**, especially on a large C++ server with
  MariaDB's `ro_after_init` linker script. If it fails, `optimize.sh` stops
  before benchmarking, but a regular `bolt` build is still produced.
- **Plugins are `.so` files** and are not BOLT-optimized; only `mariadbd` is.
- **Functional check**: always confirm the optimized server completes a
  `bench.sh` run with zero sysbench errors before trusting the numbers; C++
  exception handling is the main risk area for BOLT.
- `static-pie` is intentionally not supported (dynamic plugins).
