import copy
from pathlib import Path
import runpy
import unittest

analyze = runpy.run_path(str(Path(__file__).with_name("analyze_reference_measurement.py")))["analyze"]


def experiment(blocks=2):
    trials = []
    for block in range(blocks):
        for controller, delay, recovery in (("normal", 8, "unchanged"), ("roo-industries", 1, "controller"), ("lasso", 2, "harnessAfterReferenceExit")):
            active = controller != "normal"
            trials.append({"block": block, "controller": controller, "enabled": active, "restoration": recovery,
                           "backgroundPriority": "BelowNormal" if active else "Normal", "foregroundPriority": "Normal", "restoredPriority": "Normal",
                           "applyMilliseconds": 500 if active else None, "controllerCpuSeconds": .01 if active else None,
                           "controllerPrivateBytes": 4096 if active else None, "backgroundCpuSeconds": .8, "foregroundCpuSeconds": .1,
                           "foreground": {"operations": 5000, "checksum": 913,
                                          "samples": [{"scheduledMs": index * 20, "wakeMs": index * 20, "finishedMs": index * 20 + delay} for index in range(50)]},
                           "background": {"operations": 100000, "seconds": 1}})
    return {"schemaVersion": 2, "status": "completed", "blocks": blocks, "seconds": 1, "intervalMilliseconds": 20,
            "iterationsPerBurst": 100, "externalBefore": [], "externalAfter": [], "trials": trials,
            "referenceSha256": "EA338D4C47F61BB3AA107A26DE3614D112F19DA9438291B3A8212F21BB01D495",
            "referencePollRequestKey": "Performance.UpdateSpeedCore", "referencePollRequestMilliseconds": 500}


class ReferenceMeasurementChecks(unittest.TestCase):
    def test_independent_three_condition_ratios(self):
        result = analyze(experiment())
        self.assertEqual(result["p99RooIndustriesToLassoRatio"], {"estimate": .5, "lower95": .5, "upper95": .5})
        self.assertAlmostEqual(result["versusNormal"]["roo-industries"]["p99RuleToNormalRatio"]["estimate"], .125)
        self.assertAlmostEqual(result["versusNormal"]["lasso"]["p99RuleToNormalRatio"]["estimate"], .25)
        self.assertFalse(result["improvementGateMet"])
        self.assertTrue(analyze(experiment(10))["improvementGateMet"])

    def test_equal_results_do_not_establish_improvement(self):
        data = experiment(10)
        for trial in data["trials"]:
            if trial["controller"] == "lasso":
                for sample in trial["foreground"]["samples"]:
                    sample["finishedMs"] -= 1
        result = analyze(data)
        self.assertTrue(result["nonRegressionGateMet"])
        self.assertFalse(result["improvementGateMet"])

    def test_fast_result_cannot_override_starvation(self):
        data = experiment(10)
        for trial in data["trials"]:
            if trial["controller"] == "roo-industries":
                trial["background"]["operations"] = 100
        result = analyze(data)
        self.assertFalse(result["improvementGateMet"])
        self.assertFalse(result["nonRegressionGateMet"])

    def test_conflicting_missing_or_unisolated_evidence_is_rejected(self):
        changes = [
            (lambda d: d.update(status="running"), "completed"),
            (lambda d: d.update(referenceSha256="0" * 64), "binary"),
            (lambda d: d.update(referencePollRequestMilliseconds=1500), "polling"),
            (lambda d: d.update(referencePollRequestKey="Performance.UpdateSpeed"), "polling"),
            (lambda d: d["trials"].pop(), "complete"),
            (lambda d: d["trials"][2].update(controller="roo-industries"), "distinct"),
            (lambda d: d["trials"][2].update(enabled=False), "contradicts"),
            (lambda d: d["trials"][2].update(backgroundPriority="Normal"), "controls"),
            (lambda d: d["trials"][2].update(restoration="controller"), "restoration"),
            (lambda d: d["trials"][2].update(restoredPriority="BelowNormal"), "recovery"),
            (lambda d: d["trials"][2].update(controllerCpuSeconds=float("nan")), "invalid"),
            (lambda d: d["trials"][2]["foreground"].update(checksum=914), "checksums"),
            (lambda d: d.update(externalBefore=[{"name": "ProcessGovernor"}], externalAfter=[{"name": "ProcessGovernor"}]), "isolation"),
            (lambda d: d.update(externalAfter=[{"name": "ProcessLasso", "processId": 27}]), "identity"),
        ]
        for change, message in changes:
            with self.subTest(message=message):
                data = copy.deepcopy(experiment())
                change(data)
                with self.assertRaisesRegex(ValueError, message):
                    analyze(data)


if __name__ == "__main__":
    unittest.main()
