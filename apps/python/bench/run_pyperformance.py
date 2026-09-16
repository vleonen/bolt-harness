#!/usr/bin/env python3
"""Run a curated pyperformance selection against a target interpreter.

This is a thin replacement for `pyperformance run` that avoids pyperformance's
per-benchmark virtual environments (which need pip/network) and instead runs
each benchmark's ``run_benchmark.py`` directly under the target interpreter,
using the ``pyperf`` installed in that interpreter's prefix.

It is invoked by apps/python/app.sh's app_workload through the target
interpreter (`$APP_PY`), which is where ``pyperf`` and ``tomllib`` live. The
benchmark workers are separate processes, so BOLT instrumentation/profiling of
the target still covers them.

Outputs:
  --tsv     one line per benchmark:   <name>\t<metric>\t<value>
            metric is `ops_per_sec` (higher is better; compare.sh defaults to
            higher-better for unknown metrics)
  --output  combined pyperf JSON suite (all benchmark objects), for forensics
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
import tomllib

import pyperf


# ---------------------------------------------------------------------------
# Manifest / metadata resolution
# ---------------------------------------------------------------------------
def load_manifest(benchmarks_dir: str) -> dict[str, str]:
    """Return {name: metafile} from the pyperformance MANIFEST."""
    path = os.path.join(benchmarks_dir, "MANIFEST")
    if not os.path.isfile(path):
        sys.exit(f"ERROR: pyperformance MANIFEST not found: {path}")
    entries: dict[str, str] = {}
    in_benchmarks = False
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("["):
                in_benchmarks = line == "[benchmarks]"
                continue
            if not in_benchmarks:
                continue
            parts = line.split()
            if len(parts) >= 2:
                entries[parts[0]] = parts[1]
    return entries


def metafile_for(name: str, metafile: str, benchmarks_dir: str) -> str | None:
    if metafile == "<local>":
        return os.path.join(benchmarks_dir, f"bm_{name}", "pyproject.toml")
    if metafile.startswith("<local:"):
        base = metafile[len("<local:"):-1]
        return os.path.join(benchmarks_dir, f"bm_{base}", f"bm_{name}.toml")
    # A plain name points at another benchmark's metadata.
    manifest = load_manifest(benchmarks_dir)
    nxt = manifest.get(metafile)
    if nxt is None:
        return None
    return metafile_for(metafile, nxt, benchmarks_dir)


def load_metadata(name: str, metafile: str, benchmarks_dir: str) -> dict | None:
    path = metafile_for(name, metafile, benchmarks_dir)
    if not path or not os.path.isfile(path):
        return None
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
    project = data.get("project", {})
    tool = data.get("tool", {}).get("pyperformance", {})
    rootdir = os.path.dirname(path)
    runscript = tool.get("runscript") or os.path.join(rootdir, "run_benchmark.py")
    return {
        "name": tool.get("name", name),
        "runscript": runscript,
        "extra_opts": list(tool.get("extra_opts", [])),
        "requires_python": project.get("requires-python"),
    }


# ---------------------------------------------------------------------------
# Minimal requires-python check (no packaging dependency)
# ---------------------------------------------------------------------------
def python_ok(spec: str | None, version: tuple[int, ...]) -> bool:
    if not spec:
        return True
    for clause in re.split(r"\s*,\s*", spec.strip()):
        if not clause:
            continue
        m = re.match(r"(==|>=|<=|>|<|!=)\s*(\d+(?:\.\d+)*)", clause)
        if not m:
            continue
        op, raw = m.group(1), tuple(int(x) for x in m.group(2).split("."))
        cur = version[: len(raw)]
        if op == "==" and cur != raw:
            return False
        if op == ">=" and cur < raw:
            return False
        if op == "<=" and cur > raw:
            return False
        if op == ">" and cur <= raw:
            return False
        if op == "<" and cur >= raw:
            return False
        if op == "!=" and cur == raw:
            return False
    return True


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------
def run_benchmark(python: str, meta: dict, pyperf_args: list[str]) -> list:
    runscript = meta["runscript"]
    if not os.path.isfile(runscript):
        print(f"WARNING: runscript missing, skipping {meta['name']}: {runscript}",
              file=sys.stderr)
        return []
    args = [*meta["extra_opts"], *pyperf_args]
    if "--copy-env" not in args:
        args.append("--copy-env")
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "result.json")
        cmd = [python, "-u", runscript, *args, "--output", out]
        proc = subprocess.run(cmd, env=os.environ)
        if proc.returncode != 0:
            print(f"WARNING: {meta['name']} failed (exit {proc.returncode}); skipping",
                  file=sys.stderr)
            return []
        if not os.path.isfile(out):
            print(f"WARNING: {meta['name']} produced no output; skipping",
                  file=sys.stderr)
            return []
        return list(pyperf.BenchmarkSuite.load(out))


def ops_per_sec(bench) -> float:
    median = bench.median()
    if median <= 0:
        return 0.0
    try:
        loops = int(bench.get_loops() or 1)
    except (TypeError, ValueError):
        loops = 1
    return (loops if loops > 0 else 1) / median


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", default=sys.executable,
                        help="target interpreter (default: this interpreter)")
    parser.add_argument("--benchmarks-dir", required=True)
    parser.add_argument("--benchmarks", required=True,
                        help="comma-separated pyperformance benchmark names")
    parser.add_argument("--output", required=True, help="combined JSON output")
    parser.add_argument("--tsv", required=True, help="normalized TSV output")
    opts, pyperf_args = parser.parse_known_args()

    manifest = load_manifest(opts.benchmarks_dir)
    version = tuple(sys.version_info[:3])
    selected = [n.strip() for n in opts.benchmarks.split(",") if n.strip()]

    merged: dict[str, object] = {}
    seen: set[tuple[str, tuple[str, ...]]] = set()
    for name in selected:
        if name not in manifest:
            print(f"WARNING: no benchmark named {name!r}; skipping", file=sys.stderr)
            continue
        meta = load_metadata(name, manifest[name], opts.benchmarks_dir)
        if not meta:
            print(f"WARNING: metadata for {name!r} not found; skipping", file=sys.stderr)
            continue
        if not python_ok(meta["requires_python"], version):
            print(f"WARNING: {name!r} requires python {meta['requires_python']}; skipping",
                  file=sys.stderr)
            continue
        key = (meta["runscript"], tuple(meta["extra_opts"]))
        if key in seen:
            continue
        seen.add(key)
        print(f"[pyperformance] {name}: {os.path.basename(os.path.dirname(meta['runscript']))} "
              f"{' '.join(meta['extra_opts'])}", flush=True)
        for bench in run_benchmark(opts.python, meta, pyperf_args):
            bench_name = bench.get_name()
            if bench_name and bench_name not in merged:
                merged[bench_name] = bench

    suite = pyperf.BenchmarkSuite(list(merged.values()))
    suite.dump(opts.output)

    with open(opts.tsv, "w", encoding="utf-8") as fh:
        for bench in merged.values():
            fh.write(f"{bench.get_name()}\tops_per_sec\t{ops_per_sec(bench):.6g}\n")

    print(f"[pyperformance] {len(merged)} benchmark(s) -> {opts.tsv}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
