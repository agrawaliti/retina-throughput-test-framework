#!/usr/bin/env python3
"""
aggregate_three_cluster.sh — per-payload stats across repeated 3-cluster sweeps.

Usage:
  ./scripts/aggregate_three_cluster.sh <csv1> <csv2> ...

Reads any number of *_three_cluster_summary.csv files and, for each payload
size, computes n / mean / median / min / max / stddev / CV% for the three
throughput columns (noretina_gbps, perf_array_gbps, ring_buffer_gbps). Also
reports the Retina cost of each mode vs the no-Retina mean.

CV% (coefficient of variation = stddev/mean*100) is the trust signal: a low CV
means the number is repeatable; a high CV (>~10%) means single-run deltas for
that payload/mode cannot be trusted yet.
"""
import csv
import statistics
import sys


def fmt(x):
    return f"{x:.2f}" if x is not None else "NA"


def stats(vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return None
    n = len(vals)
    mean = statistics.mean(vals)
    median = statistics.median(vals)
    sd = statistics.stdev(vals) if n > 1 else 0.0
    cv = (sd / mean * 100) if mean else 0.0
    return {
        "n": n, "mean": mean, "median": median,
        "min": min(vals), "max": max(vals), "sd": sd, "cv": cv,
    }


def main(files):
    # payload -> {col -> [values]}
    data = {}
    cols = ["noretina_gbps", "perf_array_gbps", "ring_buffer_gbps"]
    used = []
    for path in files:
        try:
            with open(path, newline="") as fh:
                rows = list(csv.DictReader(fh))
        except OSError as exc:
            print(f"! skip {path}: {exc}", file=sys.stderr)
            continue
        if not rows:
            print(f"! skip {path}: empty (no data rows)", file=sys.stderr)
            continue
        used.append(path)
        for row in rows:
            p = row.get("payload_bytes")
            if not p:
                continue
            slot = data.setdefault(p, {c: [] for c in cols})
            for c in cols:
                try:
                    slot[c].append(float(row[c]))
                except (TypeError, ValueError, KeyError):
                    slot[c].append(None)

    if not data:
        print("No usable CSV rows found.", file=sys.stderr)
        return 1

    print(f"Aggregated {len(used)} run(s):")
    for p in used:
        print(f"  - {p}")
    print()

    label = {"noretina_gbps": "no-retina",
             "perf_array_gbps": "perf-array",
             "ring_buffer_gbps": "ring-buffer"}

    header = (f"{'payload':>8} {'mode':>11} {'n':>2} {'mean':>7} {'median':>7} "
              f"{'min':>6} {'max':>6} {'sd':>6} {'cv%':>6} {'cost%':>7}")
    for p in sorted(data, key=lambda x: int(x)):
        print(f"--- payload {p} bytes ---")
        print(header)
        nr = stats(data[p]["noretina_gbps"])
        nr_mean = nr["mean"] if nr else None
        for c in cols:
            s = stats(data[p][c])
            if not s:
                print(f"{p:>8} {label[c]:>11}  no data")
                continue
            if c == "noretina_gbps" or not nr_mean:
                cost = ""
            else:
                cost = f"{(nr_mean - s['mean']) / nr_mean * 100:6.1f}%"
            print(f"{p:>8} {label[c]:>11} {s['n']:>2} {fmt(s['mean']):>7} "
                  f"{fmt(s['median']):>7} {fmt(s['min']):>6} {fmt(s['max']):>6} "
                  f"{fmt(s['sd']):>6} {s['cv']:6.1f} {cost:>7}")
        print()
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
