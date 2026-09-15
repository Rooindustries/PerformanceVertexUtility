import copy
from pathlib import Path
import runpy
import unittest

analyze = runpy.run_path(str(Path(__file__).with_name("analyze_storage_measurement.py")))["analyze"]


def experiment():
    trials = []
    for block in range(10):
        for enabled in (False, True):
            foreground = {"seconds": 9, "readCount": 10000, "readBytes": 40960000,
                          "p50Milliseconds": .1, "p95Milliseconds": .2, "p99Milliseconds": .5 if enabled else 1,
                          "powerScheme": "unchanged-plan"}
            count = 95000 if enabled else 100000
            background = {"seconds": 9, "readCount": count, "readBytes": count * 131072,
                          "p50Milliseconds": .2, "p95Milliseconds": .4, "p99Milliseconds": .8,
                          "powerScheme": "unchanged-plan"}
            trials.append({"block": block, "enabled": enabled, "requestedIoPriority": 1 if enabled else 2,
                           "liveRestoreVerified": enabled, "exitedFixtureReconciled": True,
                           "foreground": foreground, "background": background})
    return {"schemaVersion": 1, "status": "completed", "fixturesRemoved": True, "priority": 1,
            "blocks": 10, "seconds": 9, "externalBefore": [], "externalAfter": [], "trials": trials}


class StorageMeasurementChecks(unittest.TestCase):
    def test_known_ratios_and_background_progress_gate(self):
        data = experiment()
        result = analyze(data)
        self.assertEqual(result["foregroundP99RuleToNormalRatio"]["estimate"], .5)
        self.assertAlmostEqual(result["backgroundThroughputRuleToNormalRatio"]["estimate"], .95)
        self.assertTrue(result["predeclaredGateMet"])
        for trial in data["trials"]:
            if trial["enabled"]:
                trial["background"].update(readCount=10, readBytes=10 * 131072)
        self.assertFalse(analyze(data)["predeclaredGateMet"])

    def test_conflicting_evidence_cannot_support_favorable_latency(self):
        mutations = [
            (lambda data: data.update(fixturesRemoved=False), "cleanup"),
            (lambda data: data.update(status="running"), "completed"),
            (lambda data: data["trials"][1].update(liveRestoreVerified=False), "recovery"),
            (lambda data: data["trials"][1].update(exitedFixtureReconciled=False), "recovery"),
            (lambda data: data["trials"][1].update(requestedIoPriority=2), "Control"),
            (lambda data: data["trials"][1]["background"].update(readBytes=1), "read workload"),
            (lambda data: data["trials"][1]["background"].update(seconds=8.94), "windows"),
            (lambda data: data["trials"][1]["foreground"].update(p99Milliseconds=float("nan")), "metrics"),
            (lambda data: data["trials"][1]["foreground"].update(powerScheme="changed-plan"), "Power-plan"),
            (lambda data: data["trials"][1].update(enabled=False), "one normal"),
        ]
        original = experiment()
        for change, message in mutations:
            with self.subTest(message=message):
                data = copy.deepcopy(original)
                change(data)
                with self.assertRaisesRegex(ValueError, message):
                    analyze(data)


if __name__ == "__main__":
    unittest.main()
