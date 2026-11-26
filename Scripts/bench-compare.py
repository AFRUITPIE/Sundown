#!/usr/bin/env python3
"""Compares rounds of the package benchmarks (`swift test ... --filter Benchmark`) run on a base
commit and on a branch, by XCTest's `measured [...]` lines, for the Performance workflow.

    Scripts/bench-compare.py <json out> --base <log>... --branch <log>...

Each log is one round. Run the rounds interleaved (base, branch, base, branch, ...): two runs one
after the other on the same runner differ by several percent with identical code, far more than
XCTest's spread within a run, so a change counts only when every branch round is beyond every
base round and the medians differ by at least the metric's threshold: 10% for times, which differ
by that much between identical builds on a runner, and 3% for memory. Prints a Markdown table (also appended
to $GITHUB_STEP_SUMMARY when set) and writes every metric's rounds and verdict as JSON. All of
these metrics are better lower.
"""
import json
import os
import re
import statistics
import sys

MIN_CHANGE = {"time": 10.0, "other": 3.0}  # percent


def threshold(metric):
    return MIN_CHANGE["time"] if "Time" in metric else MIN_CHANGE["other"]
LINE = re.compile(
    r"Test Case '-?\[?(?P<suite>[\w.]+)[ .](?P<test>\w+)\]?' measured \[(?P<metric>[^,\]]+), (?P<unit>[^\]]+)\] "
    r"average: (?P<avg>[\d.]+), relative standard deviation: (?P<rsd>[\d.]+)%(?:, values: \[(?P<values>[^\]]*)\])?"
)


def read(path):
    """One round: {(test, metric): (unit, mean, rsd)}, the mean from the raw values when printed."""
    results = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE.search(line)
            if not m:
                continue
            values = [float(v) for v in (m["values"] or "").split(",") if v.strip()]
            mean = statistics.fmean(values) if values else float(m["avg"])
            key = (f"{m['suite'].split('.')[-1]}.{m['test']}", m["metric"])
            results[key] = (m["unit"], mean, float(m["rsd"]))
    return results


def parse_args(argv):
    out, groups, current = argv[0], {"--base": [], "--branch": []}, None
    for arg in argv[1:]:
        if arg in groups:
            current = arg
        elif current:
            groups[current].append(arg)
    return out, groups["--base"], groups["--branch"]


def main():
    out_path, base_logs, branch_logs = parse_args(sys.argv[1:])
    base = [read(p) for p in base_logs]
    branch = [read(p) for p in branch_logs]
    keys = sorted({k for r in base + branch for k in r})
    rows = []
    for key in keys:
        a = [r[key] for r in base if key in r]
        b = [r[key] for r in branch if key in r]
        unit = (a or b)[0][0]
        am, bm = [x[1] for x in a], [x[1] for x in b]
        row = {"test": key[0], "metric": key[1], "unit": unit, "baseRounds": am, "branchRounds": bm,
               "base": statistics.median(am) if am else None, "branch": statistics.median(bm) if bm else None,
               "changePercent": None}
        if max(am + bm) == 0:
            row["verdict"] = "unavailable"  # e.g. CPU counters on a virtual machine
        elif max(x[2] for x in a + b) > 50:
            row["verdict"] = "unreliable"
        elif not am or not bm:
            row["verdict"] = "missing"
        else:
            change = (row["branch"] - row["base"]) / row["base"] * 100 if row["base"] else 0.0
            row["changePercent"] = round(change, 2)
            limit = threshold(key[1])
            row["thresholdPercent"] = limit
            if change >= limit and min(bm) > max(am):
                row["verdict"] = "worse"
            elif change <= -limit and max(bm) < min(am):
                row["verdict"] = "better"
            else:
                row["verdict"] = "within noise"
        rows.append(row)
    with open(out_path, "w") as f:
        json.dump({"minChangePercent": MIN_CHANGE, "baseRounds": len(base), "branchRounds": len(branch),
                   "rows": rows}, f, indent=2)

    def num(v):
        return "–" if v is None else f"{v:,.6g}"

    def spread(rounds):
        return "" if len(rounds) < 2 else f" ({num(min(rounds))}–{num(max(rounds))})"

    shown = [r for r in rows if r["verdict"] not in ("unavailable", "unreliable")]
    hidden = sorted({f"{r['metric']}" for r in rows if r["verdict"] in ("unavailable", "unreliable")})
    lines = [f"Median of {len(base)} base and {len(branch)} branch rounds, interleaved; a change counts at "
             f"{MIN_CHANGE['time']:g}% or more for times and {MIN_CHANGE['other']:g}% for memory, with no overlap "
             "between the rounds. Lower is better.", "",
             "| Test | Metric | Base | Branch | Change | |", "|---|---|---:|---:|---:|---|"]
    for r in shown:
        change = "–" if r["changePercent"] is None else f"{r['changePercent']:+.1f}%"
        lines.append(f"| {r['test']} | {r['metric']} ({r['unit']}) | {num(r['base'])}{spread(r['baseRounds'])} "
                     f"| {num(r['branch'])}{spread(r['branchRounds'])} | {change} | {r['verdict']} |")
    if hidden:
        lines += ["", "Left out, as zero or too noisy on this machine: " + ", ".join(hidden) + "."]
    if not rows:
        lines = ["No benchmark results were found."]
    table = "\n".join(lines)
    print(table)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("## Benchmarks, branch against base\n\n" + table + "\n")
    return 0 if rows else 1


if __name__ == "__main__":
    sys.exit(main())
