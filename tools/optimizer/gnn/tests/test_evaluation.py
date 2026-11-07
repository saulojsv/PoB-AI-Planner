import unittest

from tools.optimizer.gnn.evaluation import pareto_front, spearman
from tools.optimizer.gnn.tests.fixtures import row


class EvaluationTests(unittest.TestCase):
    def test_spearman_handles_ties_and_order(self):
        self.assertAlmostEqual(spearman([1, 2, 3], [2, 4, 6]), 1.0)
        self.assertAlmostEqual(spearman([1, 2, 3], [6, 4, 2]), -1.0)
        self.assertAlmostEqual(spearman([1, 1, 2], [2, 2, 4]), 1.0)

    def test_pareto_front_ignores_candidates_not_exactly_feasible(self):
        a, b = row(record_id="a", proposal_index=0), row(record_id="b", proposal_index=1)
        b["exactMetrics"]["feasible"] = False
        b["exactMetrics"]["CombinedDPS"] = 100_000_000
        self.assertEqual(pareto_front([a, b]), {"a"})


if __name__ == "__main__":
    unittest.main()
