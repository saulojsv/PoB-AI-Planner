"""Evaluate a staged checkpoint against its never-trained-on holdout partition."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from .dataset import rows_in
from .evaluation import predict_rows, score_gates
from .model import require_runtime


def _identity(rows: list[dict[str, Any]], name: str) -> dict[str, Any]:
    if not rows:
        raise ValueError(f"{name} partition is empty")
    identity = {key: rows[0][key] for key in ("engine", "skill", "scenario")}
    for row in rows[1:]:
        if any(row[key] != identity[key] for key in identity):
            raise ValueError(f"{name} partition contains mixed engine, skill or scenario identities")
    return identity


def evaluate(package_dir: Path, data_root: Path, native_exact_1000_seconds: float,
             ipc_overhead_seconds: float = 0.0) -> dict[str, Any]:
    require_runtime()
    package_dir = package_dir.resolve(strict=True)
    summary = json.loads((package_dir / "training_summary.json").read_text(encoding="utf-8"))
    hyper = json.loads((package_dir / "hyperparameters.json").read_text(encoding="utf-8"))
    weights_path = package_dir / "model_weights.pt"
    train_rows = rows_in(data_root / "train")
    validation_rows = rows_in(data_root / "validation")
    holdout_rows = rows_in(data_root / "holdout")
    train_ids, validation_ids, holdout_ids = ({row["lineageId"] for row in rows} for rows in
                                              (train_rows, validation_rows, holdout_rows))
    if train_ids & validation_ids or train_ids & holdout_ids or validation_ids & holdout_ids:
        raise ValueError("lineage leakage across train, validation and holdout")
    identity = _identity(train_rows + validation_rows + holdout_rows, "combined")
    if identity != summary.get("runIdentity"):
        raise ValueError("holdout engine, skill or scenario differs from the staged model context")
    actual_hashes = {"model_weights.pt": hashlib.sha256(weights_path.read_bytes()).hexdigest(),
                     "hyperparameters.json": hashlib.sha256((package_dir / "hyperparameters.json").read_bytes()).hexdigest()}
    if summary.get("artifactHashes") != actual_hashes:
        raise ValueError("staged model changed after training summary was written")
    package = {"directory": str(package_dir), "hyperparameters": hyper}
    predictions, inference_seconds = predict_rows(package, holdout_rows)
    result = score_gates(train_rows, validation_rows, holdout_rows, predictions, inference_seconds,
                         native_exact_1000_seconds, ipc_overhead_seconds)
    result.update({"packageId": package_dir.name, "artifactHashes": actual_hashes, "runIdentity": identity,
                   "provenance": {"consent": all(row["sourceReview"]["consent"] is True for row in train_rows + validation_rows + holdout_rows),
                                  "sourceReview": "passed" if all(row["sourceReview"]["reviewed"] is True for row in train_rows + validation_rows + holdout_rows) else "failed",
                                  "authorizedLineageIds": sorted(train_ids | validation_ids | holdout_ids),
                                  "trainingLineageIds": sorted(train_ids), "validationLineageIds": sorted(validation_ids),
                                  "holdoutLineageIds": sorted(holdout_ids)},
                   "training": {"trainingLineages": len(train_ids), "holdoutLineages": len(holdout_ids),
                                "trainingLabels": len(train_rows), "holdoutLabels": len(holdout_rows)}})
    (package_dir / "evaluation_report.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--data-root", type=Path, required=True)
    parser.add_argument("--native-exact-1000-seconds", type=float, required=True)
    parser.add_argument("--ipc-overhead-seconds", type=float, default=0.0)
    args = parser.parse_args(argv)
    result = evaluate(args.package, args.data_root, args.native_exact_1000_seconds, args.ipc_overhead_seconds)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["status"] == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
