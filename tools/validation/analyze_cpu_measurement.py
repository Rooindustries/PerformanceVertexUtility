"""Analyze paired CPU-contention trials without treating individual bursts as independent runs."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import random
import statistics


def quantile(values, probability):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(probability * len(ordered)) - 1)]


def ratio_interval(ratios):
    logs = [math.log(value) for value in ratios]
    randomizer = random.Random(20260916)
    means = [math.exp(statistics.mean(randomizer.choices(logs, k=len(logs)))) for _ in range(10000)]
    return {"estimate": math.exp(statistics.mean(logs)), "lower95": quantile(means, .025), "upper95": quantile(means, .975)}


def analyze(data):
    if data.get("status") != "completed" or data.get("schemaVersion") != 1:
        raise ValueError("Only a completed versioned experiment can support a comparison.")
    blocks = data["blocks"]
    if not isinstance(blocks, int) or blocks < 2 or len(data["trials"]) != blocks * 2:
        raise ValueError("At least two complete paired blocks are required.")
    if data["externalBefore"] != data["externalAfter"]:
        raise ValueError("External controller identity or binary changed during the experiment.")
    interval = data["intervalMilliseconds"]
    seconds = data["seconds"]
    expected_count = seconds * 1000 // interval
    per_run = []
    pairs = {}
    checksums = set()
    for trial in data["trials"]:
        block, enabled = trial["block"], trial["enabled"]
        if type(block) is not int or block not in range(blocks) or type(enabled) is not bool or enabled in pairs.get(block, {}):
            raise ValueError("Trial blocks must contain distinct normal and rule conditions.")
        if trial["backgroundPriority"] != ("BelowNormal" if enabled else "Normal") or trial["foregroundPriority"] != "Normal" or trial["restoredPriority"] != "Normal":
            raise ValueError("The independently observed controls or recovery do not match the experiment.")
        front, back = trial["foreground"], trial["background"]
        samples = front["samples"]
        if len(samples) != expected_count or front["operations"] != expected_count * data["iterationsPerBurst"]:
            raise ValueError("Foreground work differs between trials.")
        if trial["backgroundCpuSeconds"] < seconds * .5 or trial["foregroundCpuSeconds"] < seconds * .01:
            raise ValueError("Independent CPU time does not establish the intended workload.")
        checksums.add(front["checksum"])
        latency = []
        for index, sample in enumerate(samples):
            scheduled, wake, finished = (sample[name] for name in ("scheduledMs", "wakeMs", "finishedMs"))
            if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in (scheduled, wake, finished)) or scheduled != index * interval or wake < scheduled or finished < wake:
                raise ValueError("A timing sample is missing, reordered or contradictory.")
            latency.append(finished - scheduled)
        if back["seconds"] <= 0 or back["operations"] <= 0:
            raise ValueError("Background work made no measurable progress.")
        run = {"block": block, "ruleEnabled": enabled, "p50Milliseconds": quantile(latency, .5),
               "p95Milliseconds": quantile(latency, .95), "p99Milliseconds": quantile(latency, .99),
               "deadlineMissFraction": sum(value > interval for value in latency) / len(latency),
               "backgroundOperationsPerSecond": back["operations"] / back["seconds"]}
        pairs.setdefault(block, {})[enabled] = run
        per_run.append(run)
    if len(checksums) != 1:
        raise ValueError("The deterministic foreground work produced different checksums.")
    p99 = ratio_interval([pair[True]["p99Milliseconds"] / pair[False]["p99Milliseconds"] for pair in pairs.values()])
    throughput = ratio_interval([pair[True]["backgroundOperationsPerSecond"] / pair[False]["backgroundOperationsPerSecond"] for pair in pairs.values()])
    return {"blocks": blocks, "samplesPerRun": expected_count, "perRun": per_run,
            "p99RuleToNormalRatio": p99, "backgroundThroughputRuleToNormalRatio": throughput,
            "predeclaredGateMet": blocks >= 10 and p99["upper95"] < 1 and throughput["lower95"] >= .8,
            "method": "Geometric mean of paired run ratios; percentile bootstrap over paired blocks, 10000 resamples, seed 20260916. Nearest-rank within-run quantiles.",
            "scope": "Periodic work competing on one logical CPU. Existing external controllers stayed active. No FPS, input-latency or isolated Lasso-superiority inference."}


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
