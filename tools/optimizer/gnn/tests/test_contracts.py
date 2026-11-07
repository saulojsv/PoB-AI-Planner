import math
import unittest

from tools.optimizer.gnn.contracts import ContractError, validate_build_snapshot, validate_proposals, validate_run_spec
from tools.optimizer.gnn.dataset import validate_training_row
from tools.optimizer.gnn.graph import graph_record, token_id
from tools.optimizer.gnn.tests.fixtures import proposal, row, run_spec, snapshot


class ContractsTests(unittest.TestCase):
    def test_valid_run_and_snapshot_round_trip(self):
        self.assertEqual(validate_run_spec(run_spec())["budget"]["maxExactEvaluations"], 5000)
        self.assertEqual(validate_run_spec(run_spec())["budget"]["timeoutSeconds"], 1800)
        self.assertEqual(validate_build_snapshot(snapshot())["engine"]["treeVersion"], "3_29")

    def test_run_budget_and_metric_enums_are_bounded(self):
        value = run_spec()
        value["budget"]["maxExactEvaluations"] = 5001
        with self.assertRaises(ContractError):
            validate_run_spec(value)
        value = run_spec()
        value["budget"]["maxExactEvaluations"] = 5000
        value["budget"]["timeoutSeconds"] = 1800
        self.assertEqual(validate_run_spec(value)["budget"]["maxExactEvaluations"], 5000)
        value["budget"]["maxExactEvaluations"] = 10000
        value["budget"]["timeoutSeconds"] = 3600
        self.assertEqual(validate_run_spec(value)["budget"]["maxExactEvaluations"], 10000)
        value["budget"]["timeoutSeconds"] = 3601
        with self.assertRaises(ContractError):
            validate_run_spec(value)
        value = run_spec()
        value["budget"]["maxExactEvaluations"] = 10001
        with self.assertRaises(ContractError):
            validate_run_spec(value)
        value = run_spec()
        value["targets"]["dps"] = "FREE_TEXT"
        with self.assertRaises(ContractError):
            validate_run_spec(value)

    def test_snapshot_rejects_orphan_edges(self):
        value = snapshot()
        value["passiveEdges"].append({"source": 1, "target": 99})
        with self.assertRaises(ContractError):
            validate_build_snapshot(value)

    def test_proposals_are_unique_and_numeric_features_finite(self):
        with self.assertRaises(ContractError):
            validate_proposals([proposal(), proposal()])
        bad = proposal("p2")
        bad["numericFeatures"] = [math.nan]
        with self.assertRaises(ContractError):
            validate_proposals([bad])

    def test_exact_dataset_row_requires_valid_native_certificates_and_floor_match(self):
        normalized = validate_training_row(row())
        self.assertEqual(normalized["labels"]["dps"], 3)
        self.assertEqual(normalized["labels"]["chaos_resist"], 2)
        bad = row()
        bad["nativeValidation"]["resourcesValid"] = False
        with self.assertRaises(ContractError):
            validate_training_row(bad)
        bad = row()
        bad["exactMetrics"]["feasible"] = False
        with self.assertRaises(ContractError):
            validate_training_row(bad)

    def test_graph_is_typed_and_never_uses_padding_token_for_real_values(self):
        record = graph_record(validate_build_snapshot(snapshot()), validate_proposals([proposal(added=[2])])[0])
        self.assertEqual(len(record["nodes"]["candidate"]), 1)
        self.assertEqual(len(record["edges"]["passive|changed_by|candidate"]), 1)
        self.assertGreater(token_id("ice-spear"), 0)


if __name__ == "__main__":
    unittest.main()
