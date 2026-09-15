"""Analyze paired offscreen GPU work without treating it as a presented-frame benchmark."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import runpy

statistics_api = runpy.run_path(str(Path(__file__).with_name("paired_statistics.py")))
quantile = statistics_api["quantile"]
ratio_interval = statistics_api["ratio_interval"]


def analyze(data):
    if data.get("schemaVersion") != 1 or data.get("status") != "completed" or data.get("fixturesRemoved") is not True:
        raise ValueError("A completed experiment with verified cleanup is required.")
    blocks = data["blocks"]
    if type(blocks) is not int or blocks < 2 or len(data["trials"]) != blocks * 2:
        raise ValueError("Complete paired blocks are required.")
    if data["externalBefore"] != data["externalAfter"]:
        raise ValueError("External controllers changed during the experiment.")
    interval, seconds = data["intervalMilliseconds"], data["seconds"]
    expected_count = seconds * 1000 // interval
    pairs, rows, adapters, foreground_values = {}, [], set(), set()
    for trial in data["trials"]:
        block, enabled = trial["block"], trial["enabled"]
        if type(block) is not int or block not in range(blocks) or type(enabled) is not bool or enabled in pairs.get(block, {}):
            raise ValueError("Each block must contain one normal and one rule condition.")
        if trial["foregroundPriority"] != 2 or trial["backgroundPriority"] != (1 if enabled else 2) or trial["restoredPriority"] != 2:
            raise ValueError("GPU controls or restoration contradict the requested trial.")
        front, back = trial["foreground"], trial["background"]
        for run, elements, iterations in ((front, 16384, 256), (back, 262144, 4096)):
            adapter = run["adapter"]
            if adapter["vendorId"] != data["vendorId"] or adapter["deviceId"] != data["deviceId"]:
                raise ValueError("A workload used another GPU.")
            adapters.add((adapter["vendorId"], adapter["deviceId"], adapter["luid"]))
            if run["elements"] != elements or run["iterations"] != iterations or len(run["verifiedValues"]) != 4:
                raise ValueError("The expected GPU work or output verification is missing.")
            if not all(type(run[key]) in (int, float) and math.isfinite(run[key]) and run[key] > 0 for key in ("seconds", "gpuMilliseconds", "dispatches")):
                raise ValueError("GPU completion or work counters are invalid.")
            if abs(run["seconds"] - seconds) > .5:
                raise ValueError("The requested contention window was not maintained.")
        foreground_values.add(tuple(front["verifiedValues"]))
        if front["dispatches"] != expected_count or len(front["samples"]) != expected_count or back["dispatches"] % 4 != 0:
            raise ValueError("The requested number of GPU dispatches was not completed.")
        response, submitted, gpu_times = [], [], []
        for index, sample in enumerate(front["samples"]):
            scheduled, start, end, gpu = (sample[key] for key in ("scheduledMs", "submittedMs", "completedMs", "gpuMs"))
            if not all(type(value) in (int, float) and math.isfinite(value) for value in (scheduled, start, end, gpu)) or scheduled != index * interval or start < scheduled or end < start or gpu <= 0 or gpu > end - start + .1:
                raise ValueError("GPU timing samples are missing, reordered or contradictory.")
            response.append(end - scheduled); submitted.append(end - start); gpu_times.append(gpu)
        if not math.isclose(sum(gpu_times), front["gpuMilliseconds"], rel_tol=1e-9, abs_tol=1e-6):
            raise ValueError("GPU sample totals disagree with the recorded work.")
        row = {"block": block, "ruleEnabled": enabled, "p50Milliseconds": quantile(response, .5),
               "p95Milliseconds": quantile(response, .95), "p99Milliseconds": quantile(response, .99),
               "submittedP99Milliseconds": quantile(submitted, .99), "gpuTimestampP99Milliseconds": quantile(gpu_times, .99),
               "deadlineMissFraction": sum(value > interval for value in response) / len(response),
               "backgroundDispatchesPerSecond": back["dispatches"] / back["seconds"]}
        pairs.setdefault(block, {})[enabled] = row; rows.append(row)
    if len(adapters) != 1 or len(foreground_values) != 1:
        raise ValueError("Adapter identity or deterministic foreground output changed between trials.")
    latency = ratio_interval([pair[True]["p99Milliseconds"] / pair[False]["p99Milliseconds"] for pair in pairs.values()])
    throughput = ratio_interval([pair[True]["backgroundDispatchesPerSecond"] / pair[False]["backgroundDispatchesPerSecond"] for pair in pairs.values()])
    return {"blocks": blocks, "perRun": rows, "foregroundP99RuleToNormalRatio": latency,
            "backgroundThroughputRuleToNormalRatio": throughput,
            "predeclaredGateMet": blocks >= 10 and latency["upper95"] < 1 and throughput["lower95"] >= .8,
            "method": "Geometric mean of paired run ratios; 10000 paired-block bootstrap resamples, seed 20260916. Nearest-rank within-run quantiles.",
            "scope": "Offscreen compute submission/completion and GPU timestamp intervals. Existing external controllers stayed active. No displayed-frame, input-latency or isolated Lasso-superiority inference."}


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
