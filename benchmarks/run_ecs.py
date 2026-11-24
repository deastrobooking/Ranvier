#!/usr/bin/env python3
"""Compare bounded archetype ECS and flat AoS. Verify results before timing report."""
import argparse, csv, pathlib, random, statistics, subprocess, sys, time
p = argparse.ArgumentParser()
p.add_argument('--runs', type=int, default=7)
p.add_argument('--warmups', type=int, default=2)
p.add_argument('--skip-build', action='store_true')
p.add_argument('--zig', default='zig')
p.add_argument('--out', type=pathlib.Path, default=pathlib.Path('ecs_benchmark_results.csv'))
args = p.parse_args()
if args.runs < 1 or args.warmups < 0: p.error('invalid trial count')
root = pathlib.Path(__file__).resolve().parent.parent
if not args.skip_build:
    subprocess.run([args.zig, 'build', 'bench-ecs', '-Doptimize=fast'], cwd=root, check=True)
N, rounds = 200_000, 80
expected = sum(i + (rounds * (i % 17 + 1) if i % 2 == 0 else 0) + i % 256 for i in range(N))
labels = ['aos', 'ecs']
results = []
for trial in range(-args.warmups, args.runs):
    order = labels.copy(); random.Random(2026+trial).shuffle(order)
    for label in order:
        exe = root / 'zig-out' / 'bin' / ('ranvier-ecs-bench-' + label + ('.exe' if sys.platform == 'win32' else ''))
        start = time.perf_counter_ns()
        run = subprocess.run([str(exe)], capture_output=True, text=True, check=True)
        elapsed = time.perf_counter_ns() - start
        lines = [line.split() for line in (run.stdout + '\n' + run.stderr).splitlines() if line.startswith('RESULT ')]
        if len(lines) != 1: raise RuntimeError(f'expected one RESULT, got {lines}')
        _, actual, n, r, checksum = lines[0]
        if (actual, int(n), int(r), int(checksum)) != (label, N, rounds, expected):
            raise RuntimeError(f'wrong result: {lines[0]}')
        if trial >= 0: results.append(dict(layout=label, trial=trial, elapsed_ns=elapsed, entities=N, rounds=rounds, checksum=expected))
with args.out.open('w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=list(results[0])); writer.writeheader(); writer.writerows(results)
base = statistics.median(x['elapsed_ns'] for x in results if x['layout'] == 'aos')
for label in labels:
    median = statistics.median(x['elapsed_ns'] for x in results if x['layout'] == label)
    print(f'{label}: median {median/1e6:.3f} ms; {base/median:.3f}x AoS')
print(f'Raw trials: {args.out}')
