#!/usr/bin/env python3
"""Whole-process timing; no benchmark numbers are bundled or fabricated."""
import argparse, csv, pathlib, random, statistics, subprocess, sys, time

p = argparse.ArgumentParser()
p.add_argument('--runs', type=int, default=7)
p.add_argument('--warmups', type=int, default=2)
p.add_argument('--zig', default='zig')
p.add_argument('--out', type=pathlib.Path, default=pathlib.Path('benchmark_results.csv'))
p.add_argument('--skip-build', action='store_true')
args = p.parse_args()
if args.runs < 1 or args.warmups < 0: p.error('invalid run count')
root = pathlib.Path(__file__).resolve().parent.parent
if not args.skip_build:
    subprocess.run([args.zig, 'build', 'bench', '-Doptimize=fast'], cwd=root, check=True)
layouts = ['aos', 'soa', 'aosoa']
expected = 1_000_000 * 999_999 // 2 + 40 * sum(i % 17 + 1 for i in range(1_000_000)) + sum(i % 256 for i in range(1_000_000))
records = []
for trial in range(-args.warmups, args.runs):
    order = layouts.copy(); random.Random(42 + trial).shuffle(order)
    for layout in order:
        exe = root / 'zig-out' / 'bin' / ('ranvier-bench-' + layout + ('.exe' if sys.platform == 'win32' else ''))
        start = time.perf_counter_ns()
        proc = subprocess.run([str(exe)], capture_output=True, text=True, check=True)
        elapsed = time.perf_counter_ns() - start
        result = next(line.split() for line in (proc.stdout + '\n' + proc.stderr).splitlines() if line.startswith('RESULT '))
        _, label, n, rounds, size, checksum = result
        if label != layout or int(n) != 1_000_000 or int(rounds) != 40 or int(checksum) != expected:
            raise RuntimeError(f'checksum/workload mismatch: {result}')
        if trial >= 0:
            records.append(dict(layout=layout, trial=trial, elapsed_ns=elapsed, rows=int(n), rounds=int(rounds), storage_bytes=int(size), checksum=int(checksum)))
with args.out.open('w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=list(records[0])); writer.writeheader(); writer.writerows(records)
base = statistics.median(r['elapsed_ns'] for r in records if r['layout'] == 'aos')
for layout in layouts:
    rs = [r for r in records if r['layout'] == layout]
    median = statistics.median(r['elapsed_ns'] for r in rs)
    print(f'{layout:5} median {median/1e6:9.3f} ms; {base/median:.3f}x AoS; storage {rs[0]["storage_bytes"]} bytes')
print(f'Raw trials: {args.out}')
