import copy
from pathlib import Path
import runpy
import unittest

analyze = runpy.run_path(str(Path(__file__).with_name("analyze_gpu_measurement.py")))["analyze"]


def experiment():
    trials = []
    for block in range(10):
        for enabled in (False, True):
            adapter = {"vendorId": 4098, "deviceId": 30032, "luid": 42}
            foreground = {"adapter": dict(adapter), "elements": 16384, "iterations": 256, "dispatches": 150,
                          "seconds": 3, "gpuMilliseconds": 15, "verifiedValues": [7, 11, 13, 17],
                          "samples": [{"scheduledMs": index * 20, "submittedMs": index * 20,
                                       "completedMs": index * 20 + (.5 if enabled else 1), "gpuMs": .1} for index in range(150)]}
            background = {"adapter": dict(adapter), "elements": 262144, "iterations": 4096, "dispatches": 400,
                          "seconds": 3, "gpuMilliseconds": 2900, "verifiedValues": [19, 23, 29, 31]}
            trials.append({"block": block, "enabled": enabled, "foregroundPriority": 2,
                           "backgroundPriority": 1 if enabled else 2, "restoredPriority": 2,
                           "foreground": foreground, "background": background})
    return {"schemaVersion": 1, "status": "completed", "fixturesRemoved": True, "blocks": 10,
            "seconds": 3, "intervalMilliseconds": 20, "vendorId": 4098, "deviceId": 30032,
            "externalBefore": [], "externalAfter": [], "trials": trials}


class GpuMeasurementChecks(unittest.TestCase):
    def test_known_ratio_and_background_progress(self):
        data = experiment()
        result = analyze(data)
        self.assertEqual(result["foregroundP99RuleToNormalRatio"]["estimate"], .5)
        self.assertEqual(result["backgroundThroughputRuleToNormalRatio"]["estimate"], 1)
        self.assertTrue(result["predeclaredGateMet"])
        for trial in data["trials"]:
            if trial["enabled"]:
                trial["background"]["dispatches"] = 200
        self.assertFalse(analyze(data)["predeclaredGateMet"])

    def test_contradictory_gpu_evidence_is_rejected(self):
        mutations = [
            (lambda data: data.update(fixturesRemoved=False), "cleanup"),
            (lambda data: data["trials"][1].update(backgroundPriority=2), "controls"),
            (lambda data: data["trials"][1].update(restoredPriority=1), "restoration"),
            (lambda data: data["trials"][1]["background"]["adapter"].update(vendorId=32902), "another GPU"),
            (lambda data: data["trials"][1]["background"]["adapter"].update(luid=43), "Adapter identity"),
            (lambda data: data["trials"][1]["foreground"].update(verifiedValues=[0]), "verification"),
            (lambda data: data["trials"][1]["foreground"].update(verifiedValues=[1, 2, 3, 4]), "output changed"),
            (lambda data: data["trials"][1]["foreground"]["samples"][1].update(submittedMs=0), "contradictory"),
            (lambda data: data["trials"][1]["foreground"].update(gpuMilliseconds=1), "totals disagree"),
            (lambda data: data["trials"][1]["background"].update(seconds=5), "window"),
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
