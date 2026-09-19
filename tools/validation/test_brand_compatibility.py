import copy
from pathlib import Path
import runpy
import unittest

root = Path(__file__).parent
branding = runpy.run_path(str(root / "check_branding.py"))
experiment = runpy.run_path(str(root / "test_reference_measurement.py"))["experiment"]
analyze = runpy.run_path(str(root / "analyze_reference_measurement.py"))["analyze"]

class BrandCompatibilityTests(unittest.TestCase):
    def test_short_names_are_rejected_without_matching_unrelated_words(self):
        for text in ("Roo Game Controls", "namespace Roo.Optimizer;", "Get-RooLog", "ROO_BACKEND_ROOT", "roo-blue", "p99RooToLassoRatio"):
            self.assertTrue(branding["shortened"](text), text)
        for text in ("Roo Industries", "RooIndustries.Optimizer", "ROO_INDUSTRIES_BACKEND_ROOT", "roo-industries-blue", "RootElement", "serviroo", "RooCode.RooCode"):
            self.assertFalse(branding["shortened"](text), text)

    def test_legacy_measurements_remain_readable_without_rewriting_evidence(self):
        current = experiment()
        legacy = copy.deepcopy(current)
        for trial in legacy["trials"]:
            if trial["controller"] == "roo-industries":
                trial["controller"] = "roo"
        original = copy.deepcopy(legacy)
        self.assertEqual(analyze(legacy), analyze(current))
        self.assertEqual(legacy, original)

    def test_aliases_cannot_count_as_two_different_conditions(self):
        data = experiment()
        data["trials"][2]["controller"] = "roo"
        with self.assertRaisesRegex(ValueError, "distinct"):
            analyze(data)

if __name__ == "__main__":
    unittest.main()
