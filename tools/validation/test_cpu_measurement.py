import copy
from pathlib import Path
import runpy
import unittest

analyze = runpy.run_path(str(Path(__file__).with_name("analyze_cpu_measurement.py")))["analyze"]


def experiment(blocks=2):
    trials = []
    for block in range(blocks):
        for enabled, delay in ((False, 4), (True, 1)):
            trials.append({
                "block": block, "enabled": enabled,
                "backgroundPriority": "BelowNormal" if enabled else "Normal",
                "foregroundPriority": "Normal", "restoredPriority": "Normal",
                "backgroundCpuSeconds": .9, "foregroundCpuSeconds": .1,
                "foreground": {"operations": 5000, "checksum": 714,
                               "samples": [{"scheduledMs": index * 20, "wakeMs": index * 20,
                                            "finishedMs": index * 20 + delay} for index in range(50)]},
                "background": {"operations": 100000, "seconds": 1},
            })
    return {"schemaVersion": 1, "status": "completed", "blocks": blocks,
            "seconds": 1, "intervalMilliseconds": 20, "iterationsPerBurst": 100,
            "externalBefore": [], "externalAfter": [], "trials": trials}


class CpuMeasurementChecks(unittest.TestCase):
    def test_known_pair_ratios_and_minimum_replication(self):
        result = analyze(experiment())
        self.assertEqual(result["p99RuleToNormalRatio"], {"estimate": .25, "lower95": .25, "upper95": .25})
        self.assertEqual(result["backgroundThroughputRuleToNormalRatio"]["estimate"], 1)
        self.assertFalse(result["predeclaredGateMet"])
        self.assertTrue(analyze(experiment(10))["predeclaredGateMet"])

    def test_fast_foreground_does_not_override_background_starvation(self):
        data = experiment(10)
        for trial in data["trials"]:
            if trial["enabled"]:
                trial["background"]["operations"] = 50000
        self.assertFalse(analyze(data)["predeclaredGateMet"])

    def test_conflicting_control_and_timing_evidence_is_rejected(self):
        changes = [
            (lambda data: data.update(status="running"), "completed"),
            (lambda data: data["trials"][1].update(backgroundPriority="Normal"), "controls"),
            (lambda data: data["trials"][1].update(restoredPriority="High"), "recovery"),
            (lambda data: data["trials"][1].update(backgroundCpuSeconds=0), "CPU time"),
            (lambda data: data["trials"][1]["foreground"]["samples"].pop(), "work differs"),
            (lambda data: data["trials"][1]["foreground"]["samples"][1].update(wakeMs=0), "contradictory"),
            (lambda data: data["trials"][1]["foreground"].update(checksum=715), "checksums"),
            (lambda data: data["trials"][1].update(enabled=False), "distinct"),
            (lambda data: data.update(externalAfter=[{"processId": 42}]), "controller"),
        ]
        original = experiment()
        for change, message in changes:
            with self.subTest(message=message):
                data = copy.deepcopy(original)
                change(data)
                with self.assertRaisesRegex(ValueError, message):
                    analyze(data)


if __name__ == "__main__":
    unittest.main()
