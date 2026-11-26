#!/usr/bin/env python3
"""Compares two runs of the package benchmarks (`swift test ... --filter Benchmark`) by their
XCTest `measured [...] average:` lines, for the Performance workflow.

    Scripts/bench-compare.py <base log> <branch log> <json out>

Prints a Markdown table (also appended to $GITHUB_STEP_SUMMARY when set) and writes every
metric's base and branch averages, relative standard deviations and change as JSON. A change is
flagged only when it's larger than both runs' noise: CPU instructions retired are the steady
metric on a shared runner; clock time and cycles move with the machine's load.
"""
import json
import os
import re
import sys

LINE = re.compile(
    r"Test Case '-?\[?(?P<suite>[\w.]+)[ .](?P<test>\w+)\]?' measured \[(?P<metric>[^,\]]+), (?P<unit>[^\]]+)\] "
    r"average: (?P<avg>[\d.]+), relative standard deviation: (?P<rsd>[\d.]+)%"
)


def read(path):
    results = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE.search(line)
            if m:
                suite = m["suite"].split(".")[-1]
                key = (f"{suite}.{m['test']}", m["metric"])
                results[key] = {"unit": m["unit"], "average": float(m["avg"]), "rsd": float(m["rsd"])}
    return results


def main():
    base_path, branch_path, out_path = sys.argv[1:4]
    base, branch = read(base_path), read(branch_path)
    rows = []
    for key in sorted(set(base) | set(branch)):
        b, n = base.get(key), branch.get(key)
        row = {"test": key[0], "metric": key[1], "unit": (n or b)["unit"],
               "base": b and b["average"], "branch": n and n["average"],
               "baseRsd": b and b["rsd"], "branchRsd": n and n["rsd"], "changePercent": None, "verdict": "missing"}
        if b and n and b["average"]:
            change = (n["average"] - b["average"]) / b["average"] * 100
            noise = max(b["rsd"], n["rsd"], 1.0)
            row["changePercent"] = round(change, 2)
            row["verdict"] = "slower" if change > noise else "faster" if change < -noise else "within noise"
        rows.append(row)
    with open(out_path, "w") as f:
        json.dump({"rows": rows}, f, indent=2)

    def num(v):
        return "–" if v is None else f"{v:,.3f}".rstrip("0").rstrip(".")

    def cell(value, rsd):
        return "–" if value is None else f"{num(value)} ±{num(rsd)}%"

    lines = ["| Test | Metric | Base | Branch | Change | |", "|---|---|---:|---:|---:|---|"]
    for r in rows:
        change = "–" if r["changePercent"] is None else f"{r['changePercent']:+.1f}%"
        lines.append(f"| {r['test']} | {r['metric']} ({r['unit']}) | {cell(r['base'], r['baseRsd'])} "
                     f"| {cell(r['branch'], r['branchRsd'])} | {change} | {r['verdict']} |")
    if not rows:
        lines = ["No benchmark results were found in either log."]
    table = "\n".join(lines)
    print(table)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write("## Benchmarks, branch against base\n\n" + table + "\n")
    return 0 if rows else 1


if __name__ == "__main__":
    sys.exit(main())
