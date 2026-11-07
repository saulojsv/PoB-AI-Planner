"""Dataset loading and exact-label tier mapping shared by audit and training."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Iterable

from .contracts import ContractError, validate_build_snapshot, validate_proposals, validate_run_spec

DPS_BOUNDS = (1_000_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000)
EHP_BOUNDS = (20_000, 50_000, 100_000)
HIT_BOUNDS = (5_000, 10_000, 15_000, 20_000)
RESIST_BOUNDS = (0, 75, 105)


def _class(value: float, boundaries: tuple[float, ...]) -> int:
    for index, threshold in enumerate(boundaries):
        if value < threshold:
            return index
    return len(boundaries)


def exact_labels(row: dict[str, Any]) -> dict[str, int]:
    metrics = row["exactMetrics"]
    if metrics.get("exactCalculated") is not True:
        raise ContractError("training labels must come from an exact native PoB calculation")
    dps_metric = "FullDPS" if row["runSpec"]["searchMode"] == "CROSS_SKILL_COMBINATION" else "CombinedDPS"
    elemental_hit = min(float(metrics[key]) for key in ("FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken"))
    return {
        "dps": _class(float(metrics[dps_metric]), DPS_BOUNDS),
        "ehp": _class(float(metrics["TotalEHP"]), EHP_BOUNDS),
        "elemental_max_hit": _class(elemental_hit, HIT_BOUNDS),
        "physical_max_hit": _class(float(metrics["PhysicalMaximumHitTaken"]), HIT_BOUNDS),
        "elemental_resist": _class(min(float(metrics[k]) for k in ("FireResist", "ColdResist", "LightningResist")), RESIST_BOUNDS),
        "chaos_resist": _class(float(metrics["ChaosResist"]), (-60, 0, 75)),
    }


def validate_training_row(row: Any) -> dict[str, Any]:
    if not isinstance(row, dict) or row.get("schemaVersion") != 1:
        raise ContractError("dataset row must use schemaVersion 1")
    review = row.get("sourceReview")
    if not isinstance(review, dict) or review.get("rights") != "authorized" or review.get("consent") is not True \
            or review.get("reviewed") is not True or review.get("rightsBasis") not in {"user_authored", "creator_permission", "open_license"} \
            or not isinstance(review.get("reviewer"), str) or not 1 <= len(review["reviewer"]) <= 80 \
            or not isinstance(review.get("evidence"), str) or not 1 <= len(review["evidence"]) <= 512 \
            or any(ord(char) < 32 for char in review["reviewer"] + review["evidence"]):
        raise ContractError("dataset row is missing affirmative rights, consent, and review evidence")
    snapshot = validate_build_snapshot(row.get("buildSnapshot"))
    run_spec = validate_run_spec(row.get("runSpec"))
    proposal_rows = validate_proposals([row.get("proposal")])
    if row.get("engine") != snapshot["engine"] or row.get("skill") != run_spec["skill"] or row.get("scenario") != run_spec["scenario"]:
        raise ContractError("dataset engine/skill/scenario identity differs from its exact BuildSnapshot and RunSpec")
    metrics = row.get("exactMetrics")
    if not isinstance(metrics, dict) or metrics.get("exactCalculated") is not True:
        raise ContractError("exactMetrics must certify exact PoB calculation")
    validation = row.get("nativeValidation")
    required_validation = ("exactRecalculated", "skillCompatible", "resourcesValid", "scenarioCertified",
                           "metricsContextValid", "triggerCertified", "unsupportedModesAbsent")
    if not isinstance(validation, dict) or any(validation.get(key) is not True for key in required_validation):
        raise ContractError("nativeValidation must certify exact, compatible, resource-valid, scenario-valid and supported metrics")
    for key in ("CombinedDPS", "FullDPS", "TotalEHP", "PhysicalMaximumHitTaken", "FireMaximumHitTaken",
                "ColdMaximumHitTaken", "LightningMaximumHitTaken", "FireResist", "ColdResist", "LightningResist", "ChaosResist"):
        if isinstance(metrics.get(key), bool) or not isinstance(metrics.get(key), (int, float)) or not math.isfinite(metrics[key]):
            raise ContractError(f"exactMetrics.{key} must be a finite number")
    if not isinstance(row.get("lineageId"), str) or not row["lineageId"] or not isinstance(row.get("setId"), str) or not row["setId"]:
        raise ContractError("lineageId and setId are required")
    if isinstance(row.get("proposalIndex"), bool) or not isinstance(row.get("proposalIndex"), int) or row["proposalIndex"] < 0:
        raise ContractError("proposalIndex must be a non-negative integer")
    if not isinstance(row.get("recordId"), str) or not row["recordId"] or len(row["recordId"]) > 128:
        raise ContractError("recordId must be a stable non-empty identifier")
    if isinstance(metrics.get("feasible"), bool) is False:
        raise ContractError("exactMetrics.feasible must be a native hard-gate boolean")
    dps_key = "FullDPS" if run_spec["searchMode"] == "CROSS_SKILL_COMBINATION" else "CombinedDPS"
    from .contracts import DPS_TIERS, EHP_TIERS, HIT_TIERS
    floors = [float(metrics[dps_key]) >= DPS_TIERS[run_spec["targets"]["dps"]],
              float(metrics["TotalEHP"]) >= EHP_TIERS[run_spec["targets"]["ehp"]],
              min(float(metrics[k]) for k in ("FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken")) >= HIT_TIERS[run_spec["targets"]["elementalMaxHit"]],
              float(metrics["PhysicalMaximumHitTaken"]) >= HIT_TIERS[run_spec["targets"]["physicalMaxHit"]]]
    elemental_values = [float(metrics[k]) for k in ("FireResist", "ColdResist", "LightningResist")]
    if run_spec["resistances"]["elemental"] == "CAP_EFFECTIVE":
        floors.append(min(elemental_values) >= 75)
    else:
        overcaps = [metrics.get(k) for k in ("FireResistOverCap", "ColdResistOverCap", "LightningResistOverCap")]
        if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) for value in overcaps):
            raise ContractError("30% overcap rows need three exact native overcap metrics")
        floors.append(min(float(value) for value in overcaps) >= 30)
    floors.append(float(metrics["ChaosResist"]) >= (75 if run_spec["resistances"]["chaos"] == "CAP_EFFECTIVE" else 0))
    if metrics["feasible"] != all(floors):
        raise ContractError("exactMetrics.feasible disagrees with the native metrics and RunSpec floors")
    normalized = dict(row)
    normalized["buildSnapshot"] = snapshot
    normalized["runSpec"] = run_spec
    normalized["proposal"] = proposal_rows[0]
    normalized["nativeValidation"] = {key: validation[key] for key in required_validation}
    normalized["labels"] = exact_labels(normalized)
    return normalized


def read_jsonl_files(paths: Iterable[Path]) -> list[dict[str, Any]]:
    rows = []
    seen_ids: set[str] = set()
    for path in paths:
        with path.open("r", encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    continue
                try:
                    raw = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise ContractError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
                row = validate_training_row(raw)
                if row["recordId"] in seen_ids:
                    raise ContractError(f"{path}:{line_number}: duplicate recordId {row['recordId']}")
                seen_ids.add(row["recordId"])
                rows.append(row)
    return rows


def rows_in(directory: str | Path) -> list[dict[str, Any]]:
    root = Path(directory)
    return read_jsonl_files(sorted(root.rglob("*.jsonl"))) if root.exists() else []
