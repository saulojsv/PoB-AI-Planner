from __future__ import annotations

import tempfile
import threading
import unittest
from pathlib import Path

from tools.optimizer.gnn import model as model_module
from tools.optimizer.gnn.contracts import validate_build_snapshot, validate_run_spec
from tools.optimizer.gnn.graph import graph_record, to_pyg
from tools.optimizer.gnn.tests.fixtures import proposal, run_spec, snapshot


@unittest.skipUnless(model_module.torch is not None, "the pinned optional PyTorch/PyG runtime is unavailable")
class ModelRuntimeTests(unittest.TestCase):
    def test_batched_training_forward_and_tensor_only_ensemble_ranking(self):
        torch = model_module.torch
        HeteroData = __import__("torch_geometric.data", fromlist=["HeteroData"]).HeteroData
        DataLoader = __import__("torch_geometric.loader", fromlist=["DataLoader"]).DataLoader
        spec = validate_run_spec(run_spec())
        spec["budget"]["maxExactEvaluations"] = 5
        build = validate_build_snapshot(snapshot())
        records = [graph_record(build, proposal(f"p{index}")) for index in range(1, 6)]
        graphs = [to_pyg(record, torch, HeteroData) for record in records]
        for graph in graphs:
            graph.y = torch.tensor([[3, 2, 2, 2, 2, 2]], dtype=torch.long)

        batch = next(iter(DataLoader(graphs[:2], batch_size=2, shuffle=False)))
        model = model_module.model_class()(hidden_size=32, heads=2, dropout=0.0)
        outputs = model(batch)
        self.assertTrue(all(output.shape[0] == 2 for output in outputs.values()))
        loss = sum(torch.nn.functional.cross_entropy(outputs[name], batch.y[:, index])
                   for index, name in enumerate(model_module.OUTPUT_CLASSES))
        loss.backward()
        self.assertTrue(any(parameter.grad is not None for parameter in model.parameters()))

        hyper = {"modelType": "hetero-gatv2-ensemble-v1", "featureSchema": "pob-heterograph-v1",
                 "hiddenSize": 32, "attentionHeads": 2, "ensembleMembers": 3}
        with tempfile.TemporaryDirectory() as temp:
            torch.save({"format": "pob-gnn-state-dict-v1", "members": {
                f"member_{index}": model.state_dict() for index in range(3)}}, Path(temp) / "model_weights.pt")
            progress = []
            ranked = model_module.rank_graph_records({"directory": temp, "hyperparameters": hyper}, records,
                                                       spec, threading.Event(), lambda done, total: progress.append((done, total)))
        self.assertEqual({row["proposalId"] for row in ranked}, {f"p{index}" for index in range(1, 6)})
        self.assertTrue(progress)
        self.assertEqual(progress[-1], (5, 5))


if __name__ == "__main__":
    unittest.main()
