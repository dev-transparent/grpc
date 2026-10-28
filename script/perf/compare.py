#!/usr/bin/env python3
"""Compares benchmark results produced by script/perf/run.sh.

    compare.py OUT_DIR [--base-label main] [--head-label PR] [--title TEXT]

Prints a markdown report. Changes are only highlighted when they are
significant:

* instruction counts (deterministic): |change| >= 0.5%;
* allocations per operation of micro benchmarks (deterministic):
  |change| >= 1%;
* allocations per call of end-to-end benchmarks, which vary a little with
  scheduling: the 95% bootstrap confidence interval of the change of the
  median excludes zero and |change| >= 2%;
* wall-clock metrics: the confidence interval excludes zero and
  |change| >= 3% (shared CI runners are noisy).

The report is informational: the script never fails because of a
regression.
"""

import argparse
import glob
import json
import os
import random
import statistics
import sys

MARKER = "<!-- grpc-crystal-perf-report -->"


def load(directory):
    """Returns {(bench, metric): {"values": [...], "unit": .., "better": ..}}."""
    results = {}
    for path in sorted(glob.glob(os.path.join(directory, "*.jsonl"))):
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                record = json.loads(line)
                key = (record["bench"], record["metric"])
                entry = results.setdefault(key, {"values": [], "unit": record["unit"], "better": record["better"]})
                entry["values"].append(float(record["value"]))
    return results


def change(base, head):
    """Relative change in percent (positive: head is larger)."""
    if base == 0:
        return 0.0 if head == 0 else float("inf")
    return (head - base) / abs(base) * 100.0


def bootstrap_ci(base_values, head_values, samples=2000, seed=0):
    """95% confidence interval of the change of the median, in percent."""
    rng = random.Random(seed)
    changes = []
    for _ in range(samples):
        b = statistics.median(rng.choice(base_values) for _ in base_values)
        h = statistics.median(rng.choice(head_values) for _ in head_values)
        changes.append(change(b, h))
    changes.sort()
    return changes[int(0.025 * samples)], changes[int(0.975 * samples) - 1]


def classify(metric, base_values, head_values, better, end_to_end):
    """Returns (delta %, ci or None, verdict) where verdict is
    "regression", "improvement" or "neutral"."""
    base = statistics.median(base_values)
    head = statistics.median(head_values)
    delta = change(base, head)
    ci = None
    if metric == "instructions":
        significant = abs(delta) >= 0.5
    elif metric == "alloc" and not end_to_end:
        significant = abs(delta) >= 1.0
    elif len(base_values) >= 3 and len(head_values) >= 3:
        ci = bootstrap_ci(base_values, head_values)
        threshold = 2.0 if metric == "alloc" else 3.0
        significant = abs(delta) >= threshold and (ci[0] > 0 or ci[1] < 0)
    else:
        significant = False
    if not significant:
        return delta, ci, "neutral"
    worse = delta > 0 if better == "lower" else delta < 0
    return delta, ci, "regression" if worse else "improvement"


def fmt(value, unit):
    if unit in ("ops/s",):
        return f"{value:,.0f} {unit}"
    if value >= 1000:
        return f"{value:,.0f} {unit}"
    return f"{value:,.2f} {unit}" if value < 100 else f"{value:,.1f} {unit}"


SECTIONS = [
    ("Instructions per operation (deterministic, cachegrind)", lambda b, m: m == "instructions"),
    ("Allocations per operation", lambda b, m: m == "alloc"),
    ("Micro benchmarks (time per operation)", lambda b, m: m == "time"),
    ("End-to-end gRPC (loopback, client and server in one process)", lambda b, m: m in ("throughput", "p50", "p99")),
]
ICONS = {"regression": "🔴", "improvement": "🟢", "neutral": ""}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--base-label", default="main")
    parser.add_argument("--head-label", default="PR")
    parser.add_argument("--title", default="Performance comparison")
    args = parser.parse_args()

    base = load(os.path.join(args.out, "base"))
    head = load(os.path.join(args.out, "head"))
    rounds = len(glob.glob(os.path.join(args.out, "head", "round-*.jsonl")))

    lines = [MARKER, f"## {args.title}", ""]
    if not base:
        lines.append(f"No baseline could be built for `{args.base_label}`; showing `{args.head_label}` results only.")
        lines.append("")

    regressions = improvements = 0
    body = []
    for title, matches in SECTIONS:
        keys = sorted(k for k in set(base) | set(head) if matches(*k))
        if not keys:
            continue
        body += [f"### {title}", ""]
        if base:
            body += [f"| Benchmark | Metric | {args.base_label} | {args.head_label} | Change | |",
                     "|---|---|---:|---:|---:|---|"]
        else:
            body += [f"| Benchmark | Metric | {args.head_label} |", "|---|---|---:|"]
        for bench, metric in keys:
            h = head.get((bench, metric))
            b = base.get((bench, metric))
            if not base:
                body.append(f"| `{bench}` | {metric} | {fmt(statistics.median(h['values']), h['unit'])} |")
                continue
            if h is None:
                body.append(f"| `{bench}` | {metric} | {fmt(statistics.median(b['values']), b['unit'])} | removed | | |")
                continue
            if b is None:
                body.append(f"| `{bench}` | {metric} | new | {fmt(statistics.median(h['values']), h['unit'])} | | |")
                continue
            end_to_end = (bench, "throughput") in head
            delta, ci, verdict = classify(metric, b["values"], h["values"], h["better"], end_to_end)
            regressions += verdict == "regression"
            improvements += verdict == "improvement"
            ci_text = f" ({ci[0]:+.1f}…{ci[1]:+.1f}%)" if ci else ""
            body.append(
                f"| `{bench}` | {metric} | {fmt(statistics.median(b['values']), b['unit'])} | "
                f"{fmt(statistics.median(h['values']), h['unit'])} | {delta:+.2f}%{ci_text} | {ICONS[verdict]} |")
        body.append("")

    if base:
        summary = []
        if regressions:
            summary.append(f"🔴 **{regressions} regression{'s' if regressions != 1 else ''}**")
        if improvements:
            summary.append(f"🟢 **{improvements} improvement{'s' if improvements != 1 else ''}**")
        lines.append(", ".join(summary) + "." if summary else "No significant changes.")
        lines.append("")
    lines += body
    lines += [
        "<details><summary>How to read this</summary>",
        "",
        f"Both builds ran on the same runner in {rounds} interleaved rounds; values are medians.",
        "Changes are marked only when significant: instructions ≥ 0.5% (deterministic), micro benchmark",
        "allocations ≥ 1%; end-to-end allocations ≥ 2% and wall-clock ≥ 3%, with a 95% bootstrap confidence",
        "interval (shown in brackets) that excludes zero.",
        "Shared CI runners are noisy, so treat wall-clock results as indicative. This report is informational",
        "and never blocks a merge. Raw results are attached to the workflow run as an artifact.",
        "</details>",
    ]
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
