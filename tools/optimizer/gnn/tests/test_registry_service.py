import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools.optimizer.gnn.service import RPCService
from tools.optimizer.gnn.tests.fixtures import proposal, row, run_spec, snapshot
from tools.optimizer.gnn.registry import verify_package


def make_package(root: Path, package_id="test_model"):
    package = root / package_id
    package.mkdir()
    weights = b"tensor-only-test-payload"
    hyper = {"modelType": "hetero-gatv2-ensemble-v1", "featureSchema": "pob-heterograph-v1", "hiddenSize": 64, "attentionHeads": 2, "ensembleMembers": 5}
    (package / "model_weights.pt").write_bytes(weights)
    (package / "hyperparameters.json").write_text(json.dumps(hyper), encoding="utf-8")
    e = snapshot()["engine"]
    manifest = {"schemaVersion": 1, "packageId": package_id, "status": "approved", "modelType": hyper["modelType"], "featureSchema": hyper["featureSchema"],
                "skill": {"effectId": "IceSpear", "gemId": run_spec()["skill"]["gemId"]}, "scenario": run_spec()["scenario"], "engine": e,
                "files": {"model_weights.pt": hashlib.sha256(weights).hexdigest(), "hyperparameters.json": hashlib.sha256((package / "hyperparameters.json").read_bytes()).hexdigest()},
                "provenance": {"consent": True, "sourceReview": "passed", "authorizedLineageIds": [f"l{i}" for i in range(13)]},
                "training": {"trainingLineages": 8, "holdoutLineages": 5, "trainingLabels": 128, "holdoutLabels": 50},
                "gates": {"status": "passed", "spearmanMacro": .81, "paretoRecall": .91, "exactEvaluationReduction": .21, "ipcLatencyRatio": .19}}
    (package / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return package


class RegistryServiceTests(unittest.TestCase):
    def test_registry_accepts_only_hash_verified_approved_package(self):
        with tempfile.TemporaryDirectory() as temp:
            package = make_package(Path(temp))
            loaded, reason = verify_package(package)
            self.assertEqual(reason, "approved")
            self.assertIsNotNone(loaded)
            (package / "model_weights.pt").write_bytes(b"changed")
            self.assertIsNone(verify_package(package)[0])

    def test_json_rpc_status_requires_local_auth_token(self):
        with tempfile.TemporaryDirectory() as temp:
            service = RPCService("private-local-token", temp)
            try:
                denied = service.call({"jsonrpc": "2.0", "id": 1, "method": "build_planner/status", "params": {}})
                self.assertEqual(denied["error"]["code"], -32001)
                ok = service.call({"jsonrpc": "2.0", "id": 2, "method": "build_planner/status", "params": {"authToken": "private-local-token"}})
                self.assertEqual(ok["result"]["status"], "ready")
            finally:
                service.close()

    def test_missing_compatible_model_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            service = RPCService("token", temp)
            try:
                params = {"authToken": "token", "runSpec": run_spec(), "buildSnapshot": snapshot(), "proposals": [proposal()]}
                result = service.call({"jsonrpc": "2.0", "id": 1, "method": "build_planner/optimize", "params": params})
                self.assertEqual(result["error"]["code"], -32010)
            finally:
                service.close()

    def test_mismatched_package_context_is_not_listed(self):
        with tempfile.TemporaryDirectory() as temp:
            make_package(Path(temp))
            service = RPCService("token", temp)
            try:
                params = {"authToken": "token", "engine": snapshot()["engine"],
                          "skill": {"effectId": "OtherSkill", "gemId": run_spec()["skill"]["gemId"]}, "scenario": run_spec()["scenario"]}
                result = service.call({"jsonrpc": "2.0", "id": 1, "method": "build_planner/list_models", "params": params})
                self.assertEqual(result["result"]["models"], [])
            finally:
                service.close()

    def test_dataset_export_requires_attestation_and_writes_validated_jsonl_to_inbox(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp) / "PoB - IA"
            approved = base / "04_Models_Approved"
            service = RPCService("token", str(approved))
            try:
                self.assertEqual(service.inbox_dir, base / "01_Inbox")
                request = {"jsonrpc": "2.0", "id": 8, "method": "build_planner/export_dataset",
                           "params": {"authToken": "token", "consent": True, "rightsBasis": "user_authored", "records": [row()]}}
                response = service.call(request)
                self.assertEqual(response["result"]["status"], "inbox")
                path = base / "01_Inbox" / response["result"]["fileName"]
                self.assertTrue(path.is_file())
                self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["recordId"], "record-1")
                request["id"] = 9
                request["params"]["consent"] = False
                denied = service.call(request)
                self.assertEqual(denied["error"]["code"], -32602)
                self.assertEqual(len(list((base / "01_Inbox").glob("*.jsonl"))), 1)
            finally:
                service.close()


if __name__ == "__main__":
    unittest.main()
