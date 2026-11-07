"""Train a small HeteroGATv2 ensemble from authorized exact PoB observations."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import time
from pathlib import Path
from typing import Any

from .dataset import rows_in
from .graph import graph_record, to_pyg
from .model import OUTPUT_CLASSES, model_class, require_runtime, torch


def _split(rows: list[dict[str, Any]], name: str) -> None:
    if not rows:
        raise ValueError(f"{name} dataset is empty")
    lineage_ids = [row["lineageId"] for row in rows]
    if len(lineage_ids) != len(set(lineage_ids)):
        # Multiple candidate labels within a lineage are expected. Only require
        # that a lineage maps to one immutable source build fingerprint.
        sources: dict[str, str] = {}
        for row in rows:
            lineage = row["lineageId"]
            fingerprint = row["buildSnapshot"]["engine"]["manifestFingerprint"] + ":" + str(row["buildSnapshot"]["skill"]["effectId"])
            previous = sources.setdefault(lineage, fingerprint)
            if previous != fingerprint:
                raise ValueError(f"{name} lineage {lineage} contains conflicting engine/skill identities")


def _one_training_context(rows: list[dict[str, Any]]) -> dict[str, Any]:
    identity = {"engine": rows[0]["engine"], "skill": rows[0]["skill"], "scenario": rows[0]["scenario"]}
    for row in rows[1:]:
        if any(row[key] != identity[key] for key in identity):
            raise ValueError("a model package may contain one exact PoB engine, skill, and scenario only")
    return identity


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _seed_everything(seed: int) -> None:
    random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def _tensor_graph(row: dict[str, Any], HeteroData: Any) -> Any:
    graph = to_pyg(graph_record(row["buildSnapshot"], row["proposal"]), torch, HeteroData)
    graph.y = torch.tensor([[row["labels"][name] for name in OUTPUT_CLASSES]], dtype=torch.long)
    return graph


def train(train_dir: Path, validation_dir: Path, staging_root: Path,
          *, epochs: int = 30, ensemble_members: int = 5, hidden_size: int = 64,
          learning_rate: float = 0.0005, seed: int = 1729) -> dict[str, Any]:
    require_runtime()
    if not 1 <= epochs <= 500 or not 3 <= ensemble_members <= 16 or not 32 <= hidden_size <= 256:
        raise ValueError("training parameters are outside their supported bounds")
    train_rows, validation_rows = rows_in(train_dir), rows_in(validation_dir)
    for name, rows in (("train", train_rows), ("validation", validation_rows)):
        _split(rows, name)
    train_lineages = {row["lineageId"] for row in train_rows}
    validation_lineages = {row["lineageId"] for row in validation_rows}
    if train_lineages & validation_lineages:
        raise ValueError("lineage leakage across train/validation partitions")
    identity = _one_training_context(train_rows + validation_rows)
    HeteroData = __import__("torch_geometric.data", fromlist=["HeteroData"]).HeteroData
    DataLoader = __import__("torch_geometric.loader", fromlist=["DataLoader"]).DataLoader
    train_graphs = [_tensor_graph(row, HeteroData) for row in train_rows]
    validation_graphs = [_tensor_graph(row, HeteroData) for row in validation_rows]
    model_type = model_class()
    members: dict[str, Any] = {}
    for member_index in range(ensemble_members):
        _seed_everything(seed + member_index)
        model = model_type(hidden_size=hidden_size, heads=2, dropout=0.1)
        optimizer = torch.optim.AdamW(model.parameters(), lr=learning_rate, weight_decay=1e-4)
        best_loss, best_state = float("inf"), None
        stale = 0
        for _epoch in range(epochs):
            model.train()
            loader = DataLoader(train_graphs, batch_size=8, shuffle=True,
                                generator=torch.Generator().manual_seed(seed + member_index * 1009 + _epoch))
            for graph in loader:
                outputs = model(graph)
                loss = sum(torch.nn.functional.cross_entropy(outputs[name], graph.y[:, target_index])
                           for target_index, name in enumerate(OUTPUT_CLASSES))
                optimizer.zero_grad(set_to_none=True)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), 2.0)
                optimizer.step()
            model.eval()
            losses = []
            with torch.no_grad():
                for graph in DataLoader(validation_graphs, batch_size=8, shuffle=False):
                    outputs = model(graph)
                    losses.append(sum(float(torch.nn.functional.cross_entropy(outputs[name], graph.y[:, target_index]).item())
                                      for target_index, name in enumerate(OUTPUT_CLASSES)))
            validation_loss = sum(losses) / max(len(losses), 1)
            if validation_loss < best_loss:
                best_loss, stale = validation_loss, 0
                best_state = {key: value.detach().cpu().clone() for key, value in model.state_dict().items()}
            else:
                stale += 1
                if stale >= 6:
                    break
        if best_state is None:
            raise RuntimeError("validation did not produce a checkpoint")
        members[f"member_{member_index}"] = best_state
    package_id = "staging_" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "_" + str(seed)
    package_dir = staging_root / package_id
    package_dir.mkdir(parents=True, exist_ok=False)
    weights_path = package_dir / "model_weights.pt"
    torch.save({"format": "pob-gnn-state-dict-v1", "members": members}, weights_path)
    hyper = {"modelType": "hetero-gatv2-ensemble-v1", "featureSchema": "pob-heterograph-v1",
             "hiddenSize": hidden_size, "attentionHeads": 2, "ensembleMembers": ensemble_members,
             "dropout": 0.1, "learningRate": learning_rate, "epochsMax": epochs, "seed": seed,
             "torchVersion": torch.__version__, "pytorchGeometricVersion": __import__("torch_geometric").__version__}
    hyper_path = package_dir / "hyperparameters.json"
    hyper_path.write_text(json.dumps(hyper, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    summary = {"status": "trained_pending_holdout", "packageId": package_id,
               "artifactHashes": {"model_weights.pt": _sha256(weights_path), "hyperparameters.json": _sha256(hyper_path)},
               "runIdentity": identity,
               "provenance": {"consent": all(row["sourceReview"]["consent"] is True for row in train_rows + validation_rows),
                              "sourceReview": "passed" if all(row["sourceReview"]["reviewed"] is True for row in train_rows + validation_rows) else "failed",
                              "trainingLineageIds": sorted(train_lineages), "validationLineageIds": sorted(validation_lineages)},
               "training": {"trainingLineages": len(train_lineages), "trainingLabels": len(train_rows)},
               "validation": {"lineages": len(validation_lineages), "labels": len(validation_rows)}}
    (package_dir / "training_summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", type=Path, required=True, help="02_Validated_Datasets with train/validation directories")
    parser.add_argument("--staging", type=Path, required=True, help="03_Models_Staging")
    parser.add_argument("--epochs", type=int, default=30)
    parser.add_argument("--ensemble-members", type=int, default=5)
    parser.add_argument("--hidden-size", type=int, default=64)
    parser.add_argument("--seed", type=int, default=1729)
    args = parser.parse_args(argv)
    report = train(args.data_root / "train", args.data_root / "validation", args.staging,
                   epochs=args.epochs, ensemble_members=args.ensemble_members, hidden_size=args.hidden_size,
                   seed=args.seed)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["status"] == "trained_pending_holdout" else 2


if __name__ == "__main__":
    raise SystemExit(main())
