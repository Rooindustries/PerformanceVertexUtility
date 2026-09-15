"""Compare foreground read latency and background progress across paired storage runs."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import runpy

ratio_interval = runpy.run_path(str(Path(__file__).with_name("paired_statistics.py")))["ratio_interval"]


def analyze(data):
    if data.get("schemaVersion") != 1 or data.get("status") != "completed" or data.get("fixturesRemoved") is not True:
        raise ValueError("A completed experiment with verified cleanup is required.")
    blocks = data["blocks"]
    if type(blocks) is not int or blocks < 2 or len(data["trials"]) != blocks * 2:
        raise ValueError("Complete paired blocks are required.")
    if data["externalBefore"] != data["externalAfter"]:
        raise ValueError("External controllers changed during the experiment.")
    if data["priority"] not in (0, 1):
        raise ValueError("The treatment must lower background I/O priority.")
    pairs = {}
    rows = []
    power_schemes = set()
    for trial in data["trials"]:
        block, enabled = trial["block"], trial["enabled"]
        if type(block) is not int or block not in range(blocks) or type(enabled) is not bool or enabled in pairs.get(block, {}):
            raise ValueError("Each block must contain one normal and one rule condition.")
        if trial["requestedIoPriority"] != (data["priority"] if enabled else 2) or trial["exitedFixtureReconciled"] is not True or (enabled and trial["liveRestoreVerified"] is not True):
            raise ValueError("Control or recovery evidence contradicts the requested trial.")
        for name, block_bytes in (("foreground", 4096), ("background", 131072)):
            run = trial[name]
            numbers = [run[key] for key in ("seconds", "readCount", "readBytes", "p50Milliseconds", "p95Milliseconds", "p99Milliseconds")]
            if not all(type(value) in (int, float) and math.isfinite(value) and value >= 0 for value in numbers):
                raise ValueError("Missing or invalid workload metrics.")
            if abs(run["seconds"] - data["seconds"]) > .25 or run["readCount"] <= 0 or run["readBytes"] != run["readCount"] * block_bytes:
                raise ValueError("The expected read workload was not completed.")
            if not 0 <= run["p50Milliseconds"] <= run["p95Milliseconds"] <= run["p99Milliseconds"] or run["p99Milliseconds"] == 0:
                raise ValueError("Latency percentiles are inconsistent.")
            power_schemes.add(run["powerScheme"])
        front, back = trial["foreground"], trial["background"]
        if abs(front["seconds"] - back["seconds"]) > .05:
            raise ValueError("Foreground and background measured windows disagree.")
        row = {"block": block, "ruleEnabled": enabled, "foregroundP99Milliseconds": front["p99Milliseconds"],
               "foregroundReadsPerSecond": front["readCount"] / front["seconds"],
               "backgroundBytesPerSecond": back["readBytes"] / back["seconds"]}
        rows.append(row)
        pairs.setdefault(block, {})[enabled] = row
    if len(power_schemes) != 1 or not next(iter(power_schemes)):
        raise ValueError("Power-plan evidence is missing or changed between trials.")
    latency = ratio_interval([pair[True]["foregroundP99Milliseconds"] / pair[False]["foregroundP99Milliseconds"] for pair in pairs.values()])
    throughput = ratio_interval([pair[True]["backgroundBytesPerSecond"] / pair[False]["backgroundBytesPerSecond"] for pair in pairs.values()])
    return {"blocks": blocks, "priority": data["priority"], "perRun": rows,
            "foregroundP99RuleToNormalRatio": latency, "backgroundThroughputRuleToNormalRatio": throughput,
            "predeclaredGateMet": blocks >= 10 and latency["upper95"] < 1 and throughput["lower95"] >= .8,
            "method": "Geometric mean of paired run ratios; 10000 paired-block bootstrap resamples, seed 20260916. DiskSpd read-latency percentiles.",
            "scope": "Uncached reads on disposable files with the existing external controllers active. Latency gains must be assessed alongside background progress."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = analyze(json.loads(args.input.read_text(encoding="utf-8-sig")))
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "perRun"}, indent=2))


if __name__ == "__main__":
    main()
