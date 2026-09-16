"""Compare randomized CPU trials with normal priority, Roo and a verified reference governor."""
from __future__ import annotations

import argparse
import copy
import json
import math
from pathlib import Path
import runpy


cpu_api = runpy.run_path(str(Path(__file__).with_name("analyze_cpu_measurement.py")))
reference_sha256 = "EA338D4C47F61BB3AA107A26DE3614D112F19DA9438291B3A8212F21BB01D495"


def analyze(data):
    if data.get("schemaVersion") != 2 or data.get("status") != "completed":
        raise ValueError("A completed versioned reference experiment is required.")
    if data.get("referenceSha256") != reference_sha256 or data.get("referencePollRequestKey") != "Performance.UpdateSpeedCore" or data.get("referencePollRequestMilliseconds") != 500:
        raise ValueError("The verified reference binary or requested polling interval differs.")
    blocks = data["blocks"]
    if type(blocks) is not int or blocks < 2 or len(data["trials"]) != blocks * 3:
        raise ValueError("At least two complete three-condition blocks are required.")
    if any(item.get("name", "").lower() == "processgovernor" for item in data["externalBefore"] + data["externalAfter"]):
        raise ValueError("An external governor invalidates controller isolation.")
    seen = set()
    for trial in data["trials"]:
        controller = trial.get("controller")
        block = trial["block"]
        if type(block) is not int or block not in range(blocks) or controller not in ("normal", "roo", "lasso") or (block, controller) in seen:
            raise ValueError("Every block needs distinct normal, Roo and Lasso conditions.")
        seen.add((block, controller))
        if trial.get("enabled") is not (controller != "normal"):
            raise ValueError("The controller label contradicts its enabled state.")
        expected_restore = {"normal": "unchanged", "roo": "controller", "lasso": "harnessAfterReferenceExit"}[controller]
        if trial.get("restoration") != expected_restore:
            raise ValueError("Controller and harness restoration must remain distinct.")
        values = [trial.get(name) for name in ("applyMilliseconds", "controllerCpuSeconds", "controllerPrivateBytes")]
        if controller == "normal":
            if any(value is not None for value in values):
                raise ValueError("The normal condition must not contain an active controller.")
        elif not all(type(value) in (int, float) and math.isfinite(value) and value >= 0 for value in values):
            raise ValueError("Controller measurements are missing or invalid.")
    comparisons = {}
    for controller in ("roo", "lasso"):
        pair = {**data, "schemaVersion": 1,
                "trials": [copy.deepcopy(trial) for trial in data["trials"] if trial["controller"] in ("normal", controller)]}
        comparisons[controller] = cpu_api["analyze"](pair)
    runs = {controller: {run["block"]: run for run in summary["perRun"] if run["ruleEnabled"]}
            for controller, summary in comparisons.items()}
    p99 = cpu_api["ratio_interval"]([runs["roo"][block]["p99Milliseconds"] / runs["lasso"][block]["p99Milliseconds"] for block in range(blocks)])
    throughput = cpu_api["ratio_interval"]([runs["roo"][block]["backgroundOperationsPerSecond"] / runs["lasso"][block]["backgroundOperationsPerSecond"] for block in range(blocks)])
    overhead = {}
    for controller in ("roo", "lasso"):
        trials = [trial for trial in data["trials"] if trial["controller"] == controller]
        overhead[controller] = {
            "medianApplyMilliseconds": cpu_api["quantile"]([trial["applyMilliseconds"] for trial in trials], .5),
            "medianMeasuredCpuSeconds": cpu_api["quantile"]([trial["controllerCpuSeconds"] for trial in trials], .5),
            "medianPrivateBytes": cpu_api["quantile"]([trial["controllerPrivateBytes"] for trial in trials], .5),
        }
    return {"blocks": blocks, "samplesPerRun": comparisons["roo"]["samplesPerRun"],
            "versusNormal": {controller: {key: value for key, value in summary.items() if key not in ("scope", "perRun")}
                             for controller, summary in comparisons.items()},
            "p99RooToLassoRatio": p99, "backgroundThroughputRooToLassoRatio": throughput,
            "nonRegressionGateMet": blocks >= 10 and p99["upper95"] <= 1.05 and throughput["lower95"] >= .8,
            "improvementGateMet": blocks >= 10 and p99["upper95"] < 1 and throughput["lower95"] >= .8,
            "controllerMeasurements": overhead,
            "scope": "Matched BelowNormal CPU rules on one synthetic CPU workload. Startup-to-apply includes configuration preparation; CPU and memory samples cover the measured workload, not idle use. No gameplay, adaptive-algorithm or universal-superiority inference."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = analyze(json.loads(args.input.read_text(encoding="utf-8-sig")))
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
