"""Holdout quality gates for ranking quality, Pareto recall, efficiency and latency."""

from __future__ import annotations

import math
import statistics
import time
from typing import Any

from .dataset import exact_labels
from .graph import graph_record, to_pyg
from .model import OUTPUT_CLASSES, load_ensemble, require_runtime, torch


def _average_rank(values: list[float]) -> list[float]:
    ordered = sorted(enumerate(values), key=lambda item: item[1])
    ranks = [0.0] * len(values)
    index = 0
    while index < len(ordered):
        end = index + 1
        while end < len(ordered) and ordered[end][1] == ordered[index][1]:
            end += 1
        rank = (index + 1 + end) / 2
        for position in range(index, end):
            ranks[ordered[position][0]] = rank
        index = end
    return ranks


def spearman(left: list[float], right: list[float]) -> float | None:
    if len(left) != len(right) or len(left) < 2:
        return None
    x, y = _average_rank(left), _average_rank(right)
    mean_x, mean_y = statistics.mean(x), statistics.mean(y)
    numerator = sum((a - mean_x) * (b - mean_y) for a, b in zip(x, y))
    denominator = math.sqrt(sum((a - mean_x) ** 2 for a in x) * sum((b - mean_y) ** 2 for b in y))
    return numerator / denominator if denominator else 0.0


def exact_metrics(row: dict[str, Any]) -> tuple[float, float, float, float]:
    source = row["exactMetrics"]
    dps_key = "FullDPS" if row["runSpec"]["searchMode"] == "CROSS_SKILL_COMBINATION" else "CombinedDPS"
    return (float(source[dps_key]), float(source["TotalEHP"]),
            min(float(source[key]) for key in ("FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken")),
            float(source["PhysicalMaximumHitTaken"]))


def pareto_front(rows: list[dict[str, Any]]) -> set[str]:
    metrics = {row["recordId"]: exact_metrics(row) for row in rows if row["exactMetrics"].get("feasible") is True}
    front = set()
    for candidate_id, candidate in metrics.items():
        dominated = False
        for other_id, other in metrics.items():
            if other_id == candidate_id:
                continue
            if all(a >= b for a, b in zip(other, candidate)) and any(a > b for a, b in zip(other, candidate)):
                dominated = True
                break
        if not dominated:
            front.add(candidate_id)
    return front


def predict_rows(package: dict[str, Any], rows: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], float]:
    require_runtime()
    models = load_ensemble(package)
    HeteroData = __import__("torch_geometric.data", fromlist=["HeteroData"]).HeteroData
    results = []
    started = time.perf_counter()
    with torch.no_grad():
        for row in rows:
            record = graph_record(row["buildSnapshot"], row["proposal"])
            graph = to_pyg(record, torch, HeteroData)
            outputs_by_member = []
            for model in models:
                outputs = model(graph)
                outputs_by_member.append({key: value.softmax(-1).squeeze(0) for key, value in outputs.items()})
            means = {name: sum(member[name] for member in outputs_by_member) / len(outputs_by_member) for name in OUTPUT_CLASSES}
            predicted_dps = float(sum(i * p for i, p in enumerate(means["dps"])).item())
            predicted_defense = sum(float(sum(i * p for i, p in enumerate(means[name])).item()) for name in
                                    ("ehp", "elemental_max_hit", "physical_max_hit", "elemental_resist", "chaos_resist")) / 5
            results.append({"recordId": row["recordId"], "setId": row["setId"], "proposalIndex": row["proposalIndex"],
                            "dpsScore": predicted_dps, "defenseScore": predicted_defense})
    elapsed = time.perf_counter() - started
    return results, elapsed


def _ordered_recall(rows: list[dict[str, Any]], ordered_ids: list[str], front: set[str], budget: int) -> float:
    if not front:
        return 1.0
    found = set(ordered_ids[:budget]) & front
    return len(found) / len(front)


def _evaluations_for_recall(order: list[str], front: set[str], target: float) -> int | None:
    if not front:
        return 0
    found = set()
    for index, record_id in enumerate(order, 1):
        if record_id in front:
            found.add(record_id)
        if len(found) / len(front) >= target:
            return index
    return None


def score_gates(train_rows: list[dict[str, Any]], validation_rows: list[dict[str, Any]],
                holdout_rows: list[dict[str, Any]], predictions: list[dict[str, Any]],
                inference_seconds: float, native_exact_1000_seconds: float | None,
                ipc_overhead_seconds: float = 0.0) -> dict[str, Any]:
    pred_by_id = {row["recordId"]: row for row in predictions}
    holdout_lineages = {row["lineageId"] for row in holdout_rows}
    train_lineages = {row["lineageId"] for row in train_rows}
    leakage = bool(train_lineages & holdout_lineages)
    dps_ranks, defense_ranks = [], []
    groups: dict[str, list[dict[str, Any]]] = {}
    for row in holdout_rows:
        groups.setdefault(row["setId"], []).append(row)
    pareto_recalls = []
    pareto_sets_with_front = 0
    efficiency_reductions = []
    exact_budget = min(250, max((row["runSpec"]["budget"]["maxExactEvaluations"] for row in holdout_rows), default=250))
    for set_id, rows in groups.items():
        rows = sorted(rows, key=lambda row: row["proposalIndex"])
        predicted = [pred_by_id[row["recordId"]] for row in rows]
        true_dps = [exact_metrics(row)[0] for row in rows]
        true_defense = [sum(exact_metrics(row)[1:]) / 3 for row in rows]
        dps_rho, defense_rho = spearman([p["dpsScore"] for p in predicted], true_dps), spearman([p["defenseScore"] for p in predicted], true_defense)
        if dps_rho is not None: dps_ranks.append(dps_rho)
        if defense_rho is not None: defense_ranks.append(defense_rho)
        front = pareto_front(rows)
        if front:
            pareto_sets_with_front += 1
        else:
            continue
        model_order = [row["recordId"] for row in sorted(predicted, key=lambda p: (-p["dpsScore"], -p["defenseScore"], p["proposalIndex"]))]
        baseline_order = [row["recordId"] for row in rows]
        pareto_recalls.append(_ordered_recall(rows, model_order, front, exact_budget))
        target_recall = 0.90
        baseline_count = _evaluations_for_recall(baseline_order, front, target_recall)
        model_count = _evaluations_for_recall(model_order, front, target_recall)
        if baseline_count and model_count:
            efficiency_reductions.append(1 - model_count / baseline_count)
    macro_dps = statistics.mean(dps_ranks) if dps_ranks else -1.0
    macro_defense = statistics.mean(defense_ranks) if defense_ranks else -1.0
    macro_spearman = statistics.mean([macro_dps, macro_defense])
    pareto_recall = statistics.mean(pareto_recalls) if pareto_recalls else 0.0
    efficiency = statistics.mean(efficiency_reductions) if efficiency_reductions else -1.0
    scaled_model_seconds = inference_seconds * 1000 / max(len(holdout_rows), 1)
    ipc_plus_inference = max(0.0, ipc_overhead_seconds) + scaled_model_seconds
    latency_ratio = ipc_plus_inference / native_exact_1000_seconds if native_exact_1000_seconds and native_exact_1000_seconds > 0 else None
    gate1 = len(train_lineages) >= 8 and len(holdout_lineages) >= 5 and len(train_rows) >= 128 and len(holdout_rows) >= 50 and not leakage
    gates = {
        "volume_and_lineage": {"passed": gate1, "trainLineages": len(train_lineages), "holdoutLineages": len(holdout_lineages), "trainLabels": len(train_rows), "holdoutLabels": len(holdout_rows), "lineageLeakage": leakage},
        "ranking": {"passed": macro_dps >= 0.80 and macro_defense >= 0.80, "spearmanMacro": macro_spearman, "dpsSpearmanMacro": macro_dps, "defenseSpearmanMacro": macro_defense},
        "pareto": {"passed": pareto_sets_with_front > 0 and pareto_recall >= 0.90, "recall": pareto_recall,
                   "setCount": len(groups), "setsWithFeasibleFront": pareto_sets_with_front, "exactBudget": exact_budget},
        "efficiency": {"passed": efficiency >= 0.20, "exactEvaluationReduction": efficiency, "setsScored": len(efficiency_reductions), "qualityTargetParetoRecall": 0.90},
        "latency": {"passed": latency_ratio is not None and latency_ratio < 0.20, "ipcPlusInferenceSecondsPer1000": ipc_plus_inference,
                    "nativeExactSecondsPer1000": native_exact_1000_seconds, "ratio": latency_ratio},
    }
    return {"status": "passed" if all(row["passed"] for row in gates.values()) else "failed",
            "gates": gates, "inferenceSeconds": inference_seconds, "validationRows": len(validation_rows)}
