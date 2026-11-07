"""Fail-closed model discovery for 04_Models_Approved."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

from .contracts import ContractError, validate_engine

MAX_MANIFEST_BYTES = 128 * 1024
MAX_HYPERPARAMETER_BYTES = 64 * 1024
MAX_WEIGHTS_BYTES = 256 * 1024 * 1024


def _sha256(path: Path, limit: int) -> str:
    if path.stat().st_size > limit:
        raise ContractError(f"{path.name} exceeds its maximum size")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _read_json(path: Path, limit: int) -> dict[str, Any]:
    if path.stat().st_size > limit:
        raise ContractError(f"{path.name} exceeds its maximum size")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ContractError(f"{path.name} must contain a JSON object")
    return value


def verify_package(package_dir: Path) -> tuple[dict[str, Any] | None, str]:
    """Return a package manifest only when every approval and integrity gate is met."""
    try:
        root = package_dir.resolve(strict=True)
        manifest_path = root / "manifest.json"
        weights_path = root / "model_weights.pt"
        hyper_path = root / "hyperparameters.json"
        for path in (manifest_path, weights_path, hyper_path):
            resolved = path.resolve(strict=True)
            if root not in resolved.parents:
                raise ContractError("model package path escapes its package directory")
        manifest = _read_json(manifest_path, MAX_MANIFEST_BYTES)
        hyper = _read_json(hyper_path, MAX_HYPERPARAMETER_BYTES)
        if manifest.get("schemaVersion") != 1 or manifest.get("status") != "approved":
            raise ContractError("model package is not approved schema v1")
        package_id = manifest.get("packageId")
        if not isinstance(package_id, str) or package_id != root.name or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", package_id):
            raise ContractError("packageId must match the safe package directory name")
        if manifest.get("modelType") != "hetero-gatv2-ensemble-v1" or manifest.get("featureSchema") != "pob-heterograph-v1":
            raise ContractError("model type or graph schema is incompatible")
        expected = manifest.get("files")
        if not isinstance(expected, dict):
            raise ContractError("manifest file hashes are missing")
        if _sha256(weights_path, MAX_WEIGHTS_BYTES) != str(expected.get("model_weights.pt", "")).lower():
            raise ContractError("model_weights.pt hash mismatch")
        if _sha256(hyper_path, MAX_HYPERPARAMETER_BYTES) != str(expected.get("hyperparameters.json", "")).lower():
            raise ContractError("hyperparameters.json hash mismatch")
        engine = validate_engine(manifest.get("engine"))
        training = manifest.get("training")
        provenance = manifest.get("provenance")
        gates = manifest.get("gates")
        if not isinstance(training, dict) or training.get("trainingLineages", 0) < 8 or training.get("holdoutLineages", 0) < 5 \
                or training.get("trainingLabels", 0) < 128 or training.get("holdoutLabels", 0) < 50:
            raise ContractError("minimum authorized train/holdout volume gate failed")
        if not isinstance(provenance, dict) or provenance.get("consent") is not True \
                or provenance.get("sourceReview") != "passed" or len(provenance.get("authorizedLineageIds", [])) < 13:
            raise ContractError("source authorization or lineage provenance is incomplete")
        if not isinstance(gates, dict) or gates.get("status") != "passed" \
                or gates.get("spearmanMacro", 0) < 0.80 or gates.get("paretoRecall", 0) < 0.90 \
                or gates.get("exactEvaluationReduction", 0) < 0.20 or gates.get("ipcLatencyRatio", 1) >= 0.20:
            raise ContractError("one or more promotion quality gates failed")
        if hyper.get("featureSchema") != manifest.get("featureSchema") \
                or hyper.get("modelType") != manifest.get("modelType"):
            raise ContractError("hyperparameters disagree with the package manifest")
        return {"packageId": package_id, "directory": str(root), "manifest": manifest,
                "hyperparameters": hyper, "engine": engine}, "approved"
    except (OSError, ValueError, TypeError, KeyError, ContractError) as exc:
        return None, str(exc)


class ModelRegistry:
    def __init__(self, approved_dir: str | Path):
        self.approved_dir = Path(approved_dir)

    def list_models(self, *, engine: dict[str, Any] | None = None,
                    skill: dict[str, Any] | None = None,
                    scenario: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        if not self.approved_dir.is_dir():
            return []
        models = []
        for package_dir in sorted(self.approved_dir.iterdir(), key=lambda p: p.name.casefold()):
            if not package_dir.is_dir():
                continue
            package, _ = verify_package(package_dir)
            if package is None:
                continue
            manifest = package["manifest"]
            if engine is not None and package["engine"] != validate_engine(engine):
                continue
            if skill is not None and not self._skill_matches(manifest.get("skill"), skill):
                continue
            if scenario is not None and manifest.get("scenario") != scenario:
                continue
            models.append({"packageId": package["packageId"], "modelType": manifest["modelType"],
                           "skill": manifest["skill"], "scenario": manifest["scenario"],
                           "engine": package["engine"], "gates": manifest["gates"]})
        return models

    def get(self, package_id: str, **compatibility: Any) -> dict[str, Any] | None:
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", str(package_id)):
            return None
        package, _ = verify_package(self.approved_dir / package_id)
        if package is None:
            return None
        manifest = package["manifest"]
        if compatibility.get("engine") is not None and package["engine"] != validate_engine(compatibility["engine"]):
            return None
        if compatibility.get("skill") is not None and not self._skill_matches(manifest.get("skill"), compatibility["skill"]):
            return None
        if compatibility.get("scenario") is not None and manifest.get("scenario") != compatibility["scenario"]:
            return None
        return package

    @staticmethod
    def _skill_matches(model_skill: Any, requested_skill: Any) -> bool:
        """Model identity is gem/effect based; socket group indexes are build-local."""
        if not isinstance(model_skill, dict) or not isinstance(requested_skill, dict):
            return False
        return all(model_skill.get(key) == requested_skill.get(key) for key in ("effectId", "gemId"))
