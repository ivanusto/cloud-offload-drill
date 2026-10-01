import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("oc", HERE / "offload-cost.py")
oc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oc)

TIERS = [[1024, 0.12], [10240, 0.11], [None, 0.08]]
WAN = {"upload_mbps": 500, "efficiency": 0.85}


class Egress(unittest.TestCase):
    def test_first_tier(self):
        self.assertAlmostEqual(oc.egress_cost(100, TIERS), 12.0)

    def test_crosses_tiers(self):
        # 1024 at 0.12, 976 at 0.11
        self.assertAlmostEqual(oc.egress_cost(2000, TIERS), 1024 * 0.12 + 976 * 0.11)

    def test_top_tier(self):
        self.assertAlmostEqual(oc.egress_cost(20000, TIERS), 1024 * 0.12 + 9216 * 0.11 + 9760 * 0.08)

    def test_zero(self):
        self.assertEqual(oc.egress_cost(0, TIERS), 0.0)


class Upload(unittest.TestCase):
    def test_hours_uses_bits(self):
        # 1 GiB at 425 Mbps effective = 8 * 2**30 / 425e6 s
        h = oc.hours(1, WAN)
        self.assertAlmostEqual(h * 3600, 8 * 2 ** 30 / 425e6, places=3)


class Rows(unittest.TestCase):
    def setUp(self):
        self.prov = {"egress_per_gb_tiers": TIERS}
        self.std = {"storage_per_gb_month": 0.02, "min_days": 0, "retrieval_per_gb": 0.0,
                    "class_a_per_1k": 0.005, "class_b_per_1k": 0.0004}
        self.arc = {"storage_per_gb_month": 0.0012, "min_days": 365, "retrieval_per_gb": 0.05,
                    "class_a_per_1k": 0.05, "class_b_per_1k": 0.05}

    def test_standard_simple(self):
        ds = {"name": "x", "gb": 100, "files": 1000, "change_gb_month": 0, "change_files_month": 0}
        r = oc.class_row(ds, "standard", self.std, self.prov, WAN, 12, 1)
        self.assertAlmostEqual(r["storage"], 2.0)
        self.assertAlmostEqual(r["put"], 0.005)
        self.assertAlmostEqual(r["restore"], 12.0 + 0.0004)
        self.assertAlmostEqual(r["total"], 24.0 + 0.005 + 12.0004)

    def test_archive_min_duration_billed(self):
        ds = {"name": "x", "gb": 100, "files": 1000, "change_gb_month": 10, "change_files_month": 0}
        r = oc.class_row(ds, "archive", self.arc, self.prov, WAN, 12, 0)
        # churn: 10 GB * 0.0012 * (365/30) per month
        self.assertAlmostEqual(r["churn"], 10 * 0.0012 * 365 / 30)
        # 12 months stored is less than 365 days min, so the first upload is topped up
        self.assertAlmostEqual(r["total"], 100 * 0.0012 * 365 / 30 + 0.05 + r["churn"] * 12)


if __name__ == "__main__":
    unittest.main()
