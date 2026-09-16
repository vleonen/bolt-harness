# bolt-harness — CPython 3.13 (libpython)

Builds and benchmarks **CPython 3.13.9** with llvm-bolt. The app has two
configurations, mapped onto the harness modes, that optimize two different
artifacts:

| Mode | CPython build | BOLT target | Runtime |
|---|---|---|---|
| `pie` | `--enable-shared` | `libpython3.13.so.1.0` (+ `.bolt`, `.bolt-rewrite`) | installed `bin/python3` launcher, with the selected `.so` staged under its SONAME on `LD_LIBRARY_PATH` |
| `no-pie` | default (static libpython in the executable), `-fno-pie -no-pie` | `python3` executable (+ variants) | the variant executable directly |

Each mode has its own baseline, so `compare.sh` compares within a mode. The
workload is the **pyperformance** suite.

## Container

`rebuild.sh` builds `bolt-harness-python:ubuntu24.04`, starts a container and
bind-mounts:

- host LLVM checkout **read-only** at `/llvm` (BOLT runs from the build dir
  `rebuild.sh` auto-detects, e.g. `/llvm/build23/bin/llvm-bolt`)
- the harness **read-only** at `/harness`
- `work/` **read-write** at `/work`

The image bakes a `/wheelhouse` of `pyperformance==1.14.0` (plus `pyperf`,
`psutil`, `packaging`) so `build.sh` can install the benchmark stack into each
CPython prefix **offline**.

```bash
./rebuild.sh          # build image, (re)create container, clone CPython, shell
./rebuild.sh stop     # tear down
```

Overridable: `LLVM_SRC` (`$HOME/src/llvm-project`), `LLVM_BUILD_DIR`
(auto-detected), `PYTHON_VERSION` (`v3.13.9`).

> BOLT must support `--skip-funcs` (LLVM ≥ 19); the harness reference is LLVM
> 23.1.1.

## Running the pipeline

```bash
./rebuild.sh exec /harness/pipeline/run-all.sh pie no-pie
```

Stage by stage / interactively:

```bash
docker exec -it bolt-harness-python bash
export APP=python HARNESS_WORK=/work BOLT_BIN_DIR=/llvm/build23/bin CC=gcc

/harness/apps/python/build.sh pie no-pie     # build baselines
/harness/pipeline/profile.sh pie             # instrument + pyperformance + merge
/harness/pipeline/optimize.sh pie            # libpython....so.bolt[.bolt-rewrite]
/harness/pipeline/bench.sh pie baseline
/harness/pipeline/bench.sh pie bolt
/harness/pipeline/compare.sh pie
```

## Build recipe

`build.sh` configures CPython out-of-tree with `-O2` (`OPT="-O2 -Wall"`) and:

```
CFLAGS:        -O2 -fno-omit-frame-pointer -fno-stack-protector
               -fno-reorder-blocks-and-partition [-mbranch-protection=none]
LDFLAGS:       -Wl,-q                       # relocation sections for BOLT
pie:           --enable-shared
no-pie:        CFLAGS_NODIST=-fno-pie LINKCC='gcc -fno-pie -no-pie'
--with-ensurepip=install --disable-test-modules [--with-computed-gotos]
```

For `no-pie`, `-fno-pie` is applied through **`CFLAGS_NODIST`** (build-only, so
configure's conftest links stay PIE) and `-no-pie` only through **`LINKCC`**
(executables: `python`, `_bootstrap_python`, `_freeze_module`). It must not go
into `LDFLAGS`, because `gcc -shared -no-pie` builds an executable. Extension
modules stay PIC via `-fPIC` from `CCSHARED`.

`--with-computed-gotos=no` (via `PY_COMPUTED_GOTO=0`) builds a switch-based eval
loop — the fallback if BOLT `-instrument` chokes on the computed-goto tables.

After `make install`, `python3 -m pip install --no-index --find-links
/wheelhouse pyperformance==1.14.0` installs the benchmark stack into
`$INSTALLS/<mode>`.

## Workload (pyperformance)

pyperformance normally runs each benchmark in a per-benchmark venv and pip
installs its requirements. That needs network and makes BOLT profiling awkward,
so `bench/run_pyperformance.py` runs each benchmark's `run_benchmark.py`
directly under the target interpreter using the `pyperf` installed in the
prefix. It reads the bundled `MANIFEST`/`pyproject.toml` to resolve runscripts
and `extra_opts`, and emits `name<TAB>ops_per_sec<TAB>value` rows that
`compare.sh` consumes.

Default selection (all `pyperf`-only, override with `PYTHON_BENCH_TESTS`):

```
python_startup,nbody,spectral_norm,fannkuch,pyflate,deltablue,richards,
json_dumps,json_loads,regex_v8,regex_compile,pickle,pickle_pure_python,
unpickle_pure_python,go,hexiom,nqueens,scimark,float,telco
```

| Variable | Default | Meaning |
|---|---|---|
| `PYTHON_BENCH_TESTS` | see above | comma-separated pyperformance selection |
| `PYTHON_BENCH_ARGS` | `--fast` | extra pyperf args passed to each benchmark |
| `WARMUP` / `REPS` | `1` / `3` | discarded / recorded pyperformance passes |
| `PROFILE_SLEEP_TIME` | `0` | see below |
| `PY_COMPUTED_GOTO` | `1` | `0` builds a switch-based eval loop |
| `SERVER_CPUS` | arch-aware | CPU pinning for the benchmark runs |

`PROFILE_SLEEP_TIME=0` is intentional: pyperformance forks a worker per
benchmark, which deadlocks with BOLT's periodic dump thread. BOLT therefore
dumps the profile at each process exit (its default with sleep-time 0), and
`profile.sh` merges the ~440 per-process `.fdata` files.

## BOLT flags and verification

- `-instrumentation-file-append-pid` is required (one profile per forked
  benchmark worker).
- `-skip-funcs=_PyEval_EvalFrameDefault,sre_ucs1_match/1,sre_ucs2_match/1,sre_ucs4_match/1`
  excludes the computed-goto functions from instrumentation and optimization
  (mirrors CPython's own `--enable-bolt` support).
- `app_verify_bin` gives `optimize.sh` a library-aware health check: it stages
  the `.so` under its SONAME, then runs the launcher with
  `-c 'import sys, pyperf, pyperformance; print(sys.version)'` so a miscompiled
  variant that survives `--version` but crashes on real imports is caught and
  parked as `<binary>.failed`.

## Notes and limitations

- Only the executable (no-pie) or `libpython3.13.so` (pie) is BOLT-optimized;
  stdlib C extensions (`.so`) and, in `pie` mode, the thin `python3` launcher
  are not.
- `-rewrite` is experimental. On the reference LLVM 23.1.1 hosts (x86_64 and
  aarch64) both modes' `-rewrite` outputs crash on import and are automatically
  skipped.
- On aarch64, `no-pie` must be built with `PY_COMPUTED_GOTO=0`. With the
  default computed-goto eval loop, the BOLT-instrumented static executable
  aborts (`free(): invalid pointer`) inside `subprocess`/fork when
  pyperformance spawns its worker, so profiling cannot run; the switch-based
  eval loop avoids it. The `pie` target profiles fine with computed gotos on,
  and x86_64 needs no workaround.
- There is no persistent server: `app_server_start` records the target (and
  stages the `.so`); `app_workload` runs a fresh interpreter per pass; wait/stop
  are no-ops. `bench.sh` logs a benign "affinity check failed" because there is
  no server pid.
- Set `RESET_DATA=1` to re-run the (trivial) data preparation.
