"""Explicit, fail-closed copy of a gate-passing staging package to approved."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REQUIRED_GATES = {"volume_and_lineage", "ranking", "pareto", "efficiency", "latency"}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _read(path: Path) -> dict[str, Any]:
    result = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(result, dict):
        raise ValueError(f"{path.name} must be a JSON object")
    return result


def promote(staging_package: Path, approved_root: Path) -> Path:
    stage = staging_package.resolve(strict=True)
    if not stage.is_dir() or not stage.name.startswith("staging_"):
        raise ValueError("only an explicitly selected staging_* model directory can be promoted")
    weights, hyper, report_path = stage / "model_weights.pt", stage / "hyperparameters.json", stage / "evaluation_report.json"
    for path in (weights, hyper, report_path):
        resolved = path.resolve(strict=True)
        if stage not in resolved.parents or not resolved.is_file():
            raise ValueError(f"required artifact is missing or escapes staging package: {path.name}")
    report = _read(report_path)
    if report.get("status") != "passed" or set(report.get("gates", {})) != REQUIRED_GATES:
        raise ValueError("all five named promotion gates must pass")
    if any(not isinstance(gate, dict) or gate.get("passed") is not True for gate in report["gates"].values()):
        raise ValueError("one or more promotion gates did not pass")
    if report.get("artifactHashes") != {"model_weights.pt": _sha256(weights), "hyperparameters.json": _sha256(hyper)}:
        raise ValueError("staging artifact hash differs from the evaluated report")
    identity = report.get("runIdentity")
    training = report.get("training")
    provenance = report.get("provenance")
    gates = report["gates"]
    if not isinstance(identity, dict) or not isinstance(training, dict) or not isinstance(provenance, dict):
        raise ValueError("training identity, volume or source provenance is incomplete")
    if provenance.get("consent") is not True or provenance.get("sourceReview") != "passed":
        raise ValueError("explicit consent and source review are required")
    lineages = provenance.get("authorizedLineageIds")
    if not isinstance(lineages, list) or len(set(lineages)) < 13:
        raise ValueError("at least 13 distinct authorized lineages are required")
    metrics = {
        "spearmanMacro": gates["ranking"].get("spearmanMacro", -1),
        "paretoRecall": gates["pareto"].get("recall", -1),
        "exactEvaluationReduction": gates["efficiency"].get("exactEvaluationReduction", -1),
        "ipcLatencyRatio": gates["latency"].get("ratio", 1),
        "status": "passed",
    }
    if metrics["ipcLatencyRatio"] is None:
        raise ValueError("latency gate has no measured native exact benchmark")
    if metrics["spearmanMacro"] < 0.80 or metrics["paretoRecall"] < 0.90 \
            or metrics["exactEvaluationReduction"] < 0.20 or metrics["ipcLatencyRatio"] >= 0.20:
        raise ValueError("reported metrics do not meet all numeric promotion thresholds")
    manifest = {
        "schemaVersion": 1, "packageId": stage.name, "status": "approved",
        "approvedUtc": datetime.now(timezone.utc).isoformat(),
        "modelType": "hetero-gatv2-ensemble-v1", "featureSchema": "pob-heterograph-v1",
        "skill": {"effectId": identity["skill"]["effectId"], "gemId": identity["skill"]["gemId"]},
        "scenario": identity["scenario"], "engine": identity["engine"],
        "files": {"model_weights.pt": _sha256(weights), "hyperparameters.json": _sha256(hyper)},
        "provenance": {"consent": True, "sourceReview": "passed", "authorizedLineageIds": sorted(set(lineages))},
        "training": training, "gates": metrics,
    }
    destination_root = approved_root.resolve()
    destination_root.mkdir(parents=True, exist_ok=True)
    destination = destination_root / stage.name
    if destination.exists():
        raise FileExistsError(f"approved package already exists: {destination}")
    temp_root = Path(tempfile.mkdtemp(prefix=".promoting-", dir=destination_root))
    try:
        package_temp = temp_root / stage.name
        package_temp.mkdir()
        shutil.copy2(weights, package_temp / weights.name)
        shutil.copy2(hyper, package_temp / hyper.name)
        (package_temp / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        # Re-read through the production registry before making it visible.
        from .registry import verify_package
        package, reason = verify_package(package_temp)
        if package is None:
            raise ValueError(f"production registry rejected staged promotion: {reason}")
        os.replace(package_temp, destination)
        return destination
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staging-package", type=Path, required=True)
    parser.add_argument("--approved-root", type=Path, required=True)
    args = parser.parse_args(argv)
    print(promote(args.staging_package, args.approved_root))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
