#!/usr/bin/env python3
"""Train a small, deterministic proposal ranker from certified PoB pairs.

The model only orders one-passive-node proposals. It never calculates or
approves a build. Input must be the sanitized JSONL exported by PoB's native
TrainingData module; failed quality gates do not create or replace an artifact.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import tempfile
from collections import defaultdict
from typing import Any

try:
    import numpy as np
except ImportError as exc:  # pragma: no cover - exercised by CLI diagnostics
    raise SystemExit("numpy is required by the offline trainer") from exc


FORMAT = "pob-optimizer-supervised-pairs"
ARTIFACT_FORMAT = "pob-optimizer-surrogate"
FEATURE_POLICY = "exact-pair-build-context-lineage-engine-manifest-v6"
GROUPING_POLICY = "reviewed-source-snapshot-union-v2"
MODEL_TYPE = "passive-one-node-build-context-mlp-v2"
SCHEMA_VERSION = 6
ARTIFACT_SCHEMA_VERSION = 7
FEATURE_DIMENSION = 1024
NUMERIC_NAMES = ("level", "allocatedPointCount", "baselineObjective", "baselineTotalEHP", "pointDelta")
HASH_MODULUS = 2147483647
MAX_INPUT_BYTES = 16 * 1024 * 1024
MAX_ROW_BYTES = 64 * 1024
MAX_ARTIFACT_BYTES = 4 * 1024 * 1024
MIN_TRAIN_GROUPS = 8
MIN_HOLDOUT_GROUPS = 5
MIN_TRAIN_ROWS = 128
MIN_HOLDOUT_ROWS = 50
MIN_SPEARMAN = 0.80
MIN_PARETO_RECALL = 0.90
MIN_COVERAGE = 0.80
BASELINE_NONREGRESSION_TOLERANCE = 1e-12
ALLOWED_HEADER_KEYS = {
    "recordType", "format", "datasetSchemaVersion", "featurePolicy", "groupingPolicy", "engine",
    "sourceLineages", "trainingSourceLineages", "holdoutSourceLineages",
    "trainingRows", "holdoutRows", "popularityFeaturesExcluded",
    "modelTrainingEnabled", "qualityGate",
}
ALLOWED_ROW_KEYS = {"recordType", "split", "sourceGroupId", "engine", "features", "labels"}
ALLOWED_FEATURE_KEYS = {
    "class", "classId", "ascendancy", "ascendancyId", "characterLevel", "mainSkill",
    "supportFeatureSchemaVersion", "allocatedNodeIds", "masterySelections", "skillGroups", "itemSlots", "kind", "experiment",
    "baselineMetrics",
}
REQUIRED_ENGINE_KEYS = ("pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint")


class DatasetError(ValueError):
    pass


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value))


def _positive_id(value: Any) -> int | None:
    if _is_number(value) and int(value) == value and 0 < int(value) <= 2147483647:
        return int(value)
    return None


def _sorted_ids(values: Any) -> list[int] | None:
    if not isinstance(values, list) or len(values) > 4096:
        return None
    result = [_positive_id(value) for value in values]
    if any(value is None for value in result) or len(set(result)) != len(result):
        return None
    return sorted(result)


def _safe_category(value: Any, maximum: int = 128) -> str | None:
    if not isinstance(value, str) or not value or len(value) > maximum or any(ord(char) < 32 for char in value):
        return None
    return value


def hash_token(token: str, dimension: int = FEATURE_DIMENSION) -> int:
    """Return the same one-based polynomial hash slot used by LuaJIT."""
    if not token or dimension < 1:
        raise ValueError("token and positive feature dimension are required")
    value = 0
    for byte in token.encode("utf-8"):
        value = (value * 131 + byte) % HASH_MODULUS
    return (value % dimension) + 1


def _add_build_context_tokens(tokens: set[str], skill_groups: Any, item_slots: Any) -> bool:
    """Validate and project configured skills/supports and equipped bases."""
    if not isinstance(skill_groups, list) or len(skill_groups) > 48:
        return False
    for group in skill_groups:
        if not isinstance(group, dict) or set(group) - {
            "groupIndex", "slot", "enabled", "slotEnabled", "includeInFullDPS", "selectedMainGroup",
            "mainActiveSkill", "supportProfileVersion", "socketValidation", "gems", "skills"
        }:
            return False
        profile_version = group.get("supportProfileVersion")
        if profile_version not in (None, 1, 2):
            return False
        socket_validation = group.get("socketValidation")
        socket_valid = False
        if profile_version == 2:
            if (not isinstance(socket_validation, dict) or set(socket_validation) - {"valid", "status"}
                    or type(socket_validation.get("valid")) is not bool
                    or _safe_category(socket_validation.get("status"), 32) is None):
                return False
            socket_valid = socket_validation["valid"]
        slot = _safe_category(group.get("slot"), 64) if group.get("slot") is not None else None
        if group.get("slot") is not None and slot is None:
            return False
        for key in ("enabled", "slotEnabled", "includeInFullDPS", "selectedMainGroup"):
            if key in group and type(group[key]) is not bool:
                return False
        if slot:
            tokens.add(f"skill-group-slot:{slot}")
        tokens.add(f"skill-group:enabled:{str(group.get('enabled') is True).lower()}")
        tokens.add(f"skill-group:slot-enabled:{str(group.get('slotEnabled') is True).lower()}")
        tokens.add(f"skill-group:full-dps:{str(group.get('includeInFullDPS') is True).lower()}")
        if group.get("selectedMainGroup") is True:
            tokens.add("selected-main-skill-group")
        tokens.add("support-profile:v2" if profile_version == 2 else "support-profile:legacy-unknown")
        if profile_version == 2:
            tokens.add(f"skill-group-socket-validation:{socket_validation['status']}")
        gems = group.get("gems", [])
        if not isinstance(gems, list) or len(gems) > 32:
            return False
        for gem in gems:
            if not isinstance(gem, dict) or set(gem) - {
                "gemId", "gameId", "variantId", "skillId", "level", "quality", "enabled", "count", "isSupport", "socketMatched"
            }:
                return False
            if any(key in gem and type(gem[key]) is not bool for key in ("enabled", "isSupport", "socketMatched")):
                return False
            if profile_version != 2 or not socket_valid or gem.get("enabled") is not True or gem.get("socketMatched") is not True:
                continue
            family = "support" if gem.get("isSupport") is True else "active-gem"
            for key, tokenPart, maximum in (("gameId", "game", 200), ("gemId", "variant", 160)):
                value = gem.get(key)
                if value is not None:
                    safe = _safe_category(value, maximum)
                    if safe is None:
                        return False
                    tokens.add(f"{family}:{tokenPart}:{safe}")
            skill_id = gem.get("skillId")
            if skill_id is not None:
                safe = _safe_category(skill_id, 180)
                if safe is None:
                    return False
                if gem.get("isSupport") is not True:
                    tokens.add(f"configured-skill-effect:{safe}")
            if slot:
                tokens.add(f"{family}:slot:{slot}")
            for key, tokenPart in (("level", "level"), ("quality", "quality")):
                value = gem.get(key)
                if value is not None:
                    if not _is_number(value) or not 0 <= value <= 100 or (key == "level" and value < 1):
                        return False
                    tokens.add(f"{family}:{tokenPart}:{int(value)}")

        skills = group.get("skills", [])
        if not isinstance(skills, list) or len(skills) > 12:
            return False
        for skill in skills:
            if not isinstance(skill, dict) or set(skill) - {
                "skillIndex", "name", "selectedMainSkill", "supportProfileVersion", "effects", "supports"
            }:
                return False
            if "selectedMainSkill" in skill and type(skill["selectedMainSkill"]) is not bool:
                return False
            skill_profile_version = skill.get("supportProfileVersion")
            if skill_profile_version not in (None, 1, 2):
                return False
            effects = skill.get("effects", [])
            if not isinstance(effects, list) or len(effects) > 16:
                return False
            for effect in effects:
                if not isinstance(effect, dict) or set(effect) - {"effectId", "selected"}:
                    return False
                if "selected" in effect and type(effect["selected"]) is not bool:
                    return False
                if effect.get("effectId") is not None and _safe_category(effect["effectId"], 180) is None:
                    return False
            supports = skill.get("supports", [])
            if not isinstance(supports, list) or len(supports) > 64:
                return False
            if skill_profile_version == 2:
                tokens.add("skill-support-profile:v2")
                if skill.get("selectedMainSkill") is True:
                    tokens.add("main-skill-support-profile:v2")
            for support in supports:
                support_keys = {
                    "gemId", "gameId", "variantId", "skillId", "effectId", "name", "level", "quality",
                    "origin", "sourceSlot", "sourceItemFingerprint", "targetGroupIndex", "targetSkillIndex",
                    "targetEffectId", "active", "supportProfileVersion", "configured", "calculatorApplied",
                    "socketMatched", "socketState", "linkState", "groupState", "playableActive",
                }
                if not isinstance(support, dict) or set(support) - support_keys:
                    return False
                if any(key in support and type(support[key]) is not bool for key in
                       ("active", "configured", "calculatorApplied", "socketMatched", "playableActive")):
                    return False
                support_version = support.get("supportProfileVersion")
                if support_version not in (None, 1, 2):
                    return False
                if support_version == 2:
                    if (support.get("socketState") not in {"matched", "invalid", "unknown", "not_applicable", "matched_unvalidated_group"}
                            or support.get("linkState") not in {"validated_link", "invalid", "not_same_skill_group", "verified_item_local", "cross_slot_unverified", "verified_imbued_slot", "unknown", "not_applicable"}
                            or support.get("groupState") not in {"active", "invalid", "inactive", "unknown"}):
                        return False
                if profile_version == 2 and support_version != 2:
                    return False
                if support.get("playableActive") is True:
                    if (profile_version != 2 or not socket_valid or support.get("configured") is not True
                            or support.get("calculatorApplied") is not True or support.get("active") is not True
                            or support.get("groupState") != "active"):
                        return False
                    origin = support.get("origin")
                    if origin == "socketed_gem":
                        if (support.get("socketMatched") is not True or support.get("socketState") != "matched"
                                or support.get("linkState") != "validated_link"):
                            return False
                    elif origin == "item_granted":
                        if (support.get("socketState") != "not_applicable" or support.get("linkState") != "verified_item_local"
                                or not support.get("sourceSlot") or not support.get("sourceItemFingerprint")):
                            return False
                    elif origin == "imbued":
                        if support.get("socketState") != "not_applicable" or support.get("linkState") != "verified_imbued_slot":
                            return False
                    else:
                        return False
                for key, maximum in (("gemId", 160), ("gameId", 200), ("variantId", 200), ("skillId", 180),
                                     ("effectId", 180), ("name", 120), ("origin", 32), ("sourceSlot", 64),
                                     ("targetEffectId", 180)):
                    if support.get(key) is not None and _safe_category(support[key], maximum) is None:
                        return False
                for key, maximum in (("level", 100), ("quality", 100)):
                    value = support.get(key)
                    if value is not None and (not _is_number(value) or not 0 <= value <= maximum
                                              or (key == "level" and value < 1)):
                        return False
                for key, maximum in (("targetGroupIndex", 48), ("targetSkillIndex", 12)):
                    value = support.get(key)
                    if value is not None and (_positive_id(value) is None or value > maximum):
                        return False
                fingerprint = support.get("sourceItemFingerprint")
                if fingerprint is not None and (not isinstance(fingerprint, str) or len(fingerprint) != 64
                                                or any(char not in "0123456789abcdefABCDEF" for char in fingerprint)):
                    return False
                if support_version != 2 or profile_version != 2 or not socket_valid or support.get("playableActive") is not True:
                    continue
                for key, prefix, maximum in (("origin", "support-origin", 32), ("effectId", "support-effect", 180),
                                             ("gameId", "support-game", 200), ("gemId", "support-variant", 160),
                                             ("variantId", "support-variant-name", 200), ("sourceSlot", "support-source-slot", 64),
                                             ("targetEffectId", "support-target-effect", 180)):
                    value = support.get(key)
                    if value is not None:
                        safe = _safe_category(value, maximum)
                        if safe is None:
                            return False
                        tokens.add(f"{prefix}:{safe}")
                group_index, skill_index = support.get("targetGroupIndex"), support.get("targetSkillIndex")
                if group_index is not None:
                    tokens.add(f"support-target-group:{int(group_index)}")
                if skill_index is not None:
                    tokens.add(f"support-target-skill-index:{int(skill_index)}")
                if fingerprint is not None:
                    tokens.add(f"support-source-item:{fingerprint.lower()}")
                for key, prefix in (("level", "support-level"), ("quality", "support-quality")):
                    value = support.get(key)
                    if value is not None:
                        number = int(value) if float(value).is_integer() else value
                        tokens.add(f"{prefix}:{number}")

    if not isinstance(item_slots, list) or len(item_slots) > 80:
        return False
    for item in item_slots:
        if not isinstance(item, dict) or set(item) - {"slot", "base", "rarity", "itemFingerprint"}:
            return False
        slot = _safe_category(item.get("slot"), 64)
        if slot is None:
            return False
        base, rarity = item.get("base"), item.get("rarity")
        if base is not None:
            base = _safe_category(base, 96)
            if base is None:
                return False
            tokens.add(f"equipped-item-base:{slot}:{base}")
        if rarity is not None:
            rarity = _safe_category(rarity, 32)
            if rarity is None:
                return False
            tokens.add(f"equipped-item-rarity:{slot}:{rarity}")
        fingerprint = item.get("itemFingerprint")
        if fingerprint is not None:
            if (not isinstance(fingerprint, str) or len(fingerprint) != 64
                    or any(char not in "0123456789abcdefABCDEF" for char in fingerprint)):
                return False
            tokens.add(f"equipped-item-fingerprint:{slot}:{fingerprint.lower()}")
    return True


def project_features(raw: Any, objective: str) -> dict[str, Any] | None:
    """Map a sanitized study row to the exact runtime allowlist."""
    if not isinstance(raw, dict) or set(raw) - ALLOWED_FEATURE_KEYS:
        return None
    support_schema = raw.get("supportFeatureSchemaVersion")
    if support_schema not in (None, 1, 2):
        return None
    if support_schema == 2:
        groups = raw.get("skillGroups")
        if not isinstance(groups, list) or any(not isinstance(group, dict) or group.get("supportProfileVersion") != 2
                                               for group in groups):
            return None
    experiment = raw.get("experiment")
    if (raw.get("kind") != "passive_node_pair" or not isinstance(experiment, dict)
            or experiment.get("unit") != "one_passive_node"):
        return None
    class_id = _positive_id(raw.get("classId"))
    ascendancy_id = raw.get("ascendancyId", 0)
    if not _is_number(ascendancy_id) or int(ascendancy_id) != ascendancy_id or not 0 <= ascendancy_id <= 2147483647:
        return None
    skill = _safe_category(raw.get("mainSkill"))
    level = raw.get("characterLevel")
    allocated = _sorted_ids(raw.get("allocatedNodeIds"))
    added = _sorted_ids(experiment.get("addedNodeIds", []))
    removed = _sorted_ids(experiment.get("removedNodeIds", []))
    metrics = raw.get("baselineMetrics")
    if (class_id is None or skill is None or not _is_number(level) or not 1 <= level <= 100
            or allocated is None or not allocated or added is None or removed is None
            or len(added) + len(removed) != 1 or not isinstance(metrics, dict)):
        return None
    objective_value = metrics.get(objective)
    ehp = metrics.get("TotalEHP")
    if not _is_number(objective_value) or not _is_number(ehp):
        return None

    tokens = {
        f"class:{class_id}", f"ascendancy:{int(ascendancy_id)}", f"skill:{skill}",
        *(f"allocated-node:{node_id}" for node_id in allocated),
        *(f"added-node:{node_id}" for node_id in added),
        *(f"removed-node:{node_id}" for node_id in removed),
    }
    masteries = raw.get("masterySelections", [])
    if not isinstance(masteries, list) or len(masteries) > 4096:
        return None
    for mastery in masteries:
        if not isinstance(mastery, dict):
            return None
        node_id = _positive_id(mastery.get("nodeId"))
        effect_id = _positive_id(mastery.get("effectId"))
        if node_id is None or effect_id is None:
            return None
        tokens.add(f"mastery:{node_id}:{effect_id}")
    if not _add_build_context_tokens(tokens, raw.get("skillGroups"), raw.get("itemSlots")):
        return None
    changed = sorted(added + removed)
    return {
        "featurePolicy": FEATURE_POLICY,
        "objectiveMetric": objective,
        "classId": class_id,
        "ascendancyId": int(ascendancy_id),
        "mainSkill": skill,
        "changedNodeIds": changed,
        "tokens": sorted(tokens),
        "numeric": [float(level), float(len(allocated)), float(objective_value), float(ehp), float(len(added) - len(removed))],
    }


def _exact_keys(value: Any, allowed: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) - allowed:
        raise DatasetError(f"{label} contains fields outside the PoB allowlist")
    return value


def load_dataset(path: pathlib.Path, objective: str) -> tuple[dict[str, Any], list[dict[str, Any]], list[dict[str, Any]]]:
    size = path.stat().st_size
    if size <= 0 or size > MAX_INPUT_BYTES:
        raise DatasetError("dataset size is outside the 1..16 MiB safety limit")
    parsed: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if len(line.encode("utf-8")) > MAX_ROW_BYTES:
                raise DatasetError(f"line {line_number} exceeds the 64 KiB row limit")
            try:
                value = json.loads(line)
            except (json.JSONDecodeError, UnicodeError) as exc:
                raise DatasetError(f"line {line_number} is not valid JSONL") from exc
            if not isinstance(value, dict):
                raise DatasetError(f"line {line_number} is not an object")
            parsed.append(value)
    if not parsed:
        raise DatasetError("dataset is empty")
    header = _exact_keys(parsed[0], ALLOWED_HEADER_KEYS, "dataset header")
    if (header.get("recordType") != "dataset_header" or header.get("format") != FORMAT
            or header.get("datasetSchemaVersion") != SCHEMA_VERSION
            or header.get("featurePolicy") != FEATURE_POLICY
            or header.get("groupingPolicy") != GROUPING_POLICY
            or header.get("popularityFeaturesExcluded") is not True):
        raise DatasetError("dataset format, schema, lineage policy, feature policy, or popularity exclusion is invalid")
    engine = header.get("engine")
    if not isinstance(engine, dict) or any(not isinstance(engine.get(key), (str, int, float)) or str(engine[key]) == "" for key in REQUIRED_ENGINE_KEYS):
        raise DatasetError("dataset does not carry a complete PoB/tree identity")
    fingerprint = engine.get("manifestFingerprint")
    if not isinstance(fingerprint, str) or len(fingerprint) != 64 or any(char not in "0123456789abcdef" for char in fingerprint):
        raise DatasetError("dataset does not carry a valid PoB manifest fingerprint")
    count_fields = ("sourceLineages", "trainingSourceLineages", "holdoutSourceLineages", "trainingRows", "holdoutRows")
    if any(type(header.get(key)) is not int or header[key] < 0 for key in count_fields):
        raise DatasetError("dataset declares invalid source-lineage or row counts")
    if (header["sourceLineages"] < 2 or header["trainingSourceLineages"] < 1
            or header["holdoutSourceLineages"] < 1
            or header["trainingSourceLineages"] + header["holdoutSourceLineages"] != header["sourceLineages"]):
        raise DatasetError("dataset does not declare two disjoint source-lineage groups")
    if not isinstance(objective, str) or not objective or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-" for char in objective):
        raise DatasetError("objective must be a PoB numeric metric key")

    splits: dict[str, list[dict[str, Any]]] = {"train": [], "holdout": []}
    group_splits: dict[str, str] = {}
    raw_row_counts = {"train": 0, "holdout": 0}
    for line_number, raw in enumerate(parsed[1:], 2):
        row = _exact_keys(raw, ALLOWED_ROW_KEYS, f"line {line_number}")
        if row.get("recordType") != "exact_pair" or row.get("split") not in splits:
            raise DatasetError(f"line {line_number} is not a train/holdout exact pair")
        raw_row_counts[row["split"]] += 1
        if row.get("engine") != engine:
            raise DatasetError(f"line {line_number} uses a different engine identity")
        group = row.get("sourceGroupId")
        if not isinstance(group, str) or not group or len(group) > 96:
            raise DatasetError(f"line {line_number} has an invalid source-group key")
        prior = group_splits.setdefault(group, row["split"])
        if prior != row["split"]:
            raise DatasetError("source lineages overlap train and holdout")
        features = _exact_keys(row.get("features"), ALLOWED_FEATURE_KEYS, f"line {line_number} features")
        labels = row.get("labels")
        if not isinstance(labels, dict) or any(not isinstance(key, str) or not _is_number(value) for key, value in labels.items()):
            raise DatasetError(f"line {line_number} contains invalid exact labels")
        projected = project_features(features, objective)
        baseline = features.get("baselineMetrics")
        if projected is None or objective not in labels or not isinstance(baseline, dict) or not _is_number(baseline.get(objective)):
            # Keep unsupported exact families outside the passive ranker rather
            # than silently broadening its feature or label policy.
            continue
        total_ehp_delta = labels.get("TotalEHP")
        if not _is_number(total_ehp_delta):
            continue
        splits[row["split"]].append({
            "group": group,
            "feature": projected,
            "target": float(labels[objective]) / max(abs(float(baseline[objective])), 1.0),
            "targetDelta": float(labels[objective]),
            "ehpDelta": float(total_ehp_delta),
            "pointDelta": projected["numeric"][4],
        })
    if not splits["train"] or not splits["holdout"]:
        raise DatasetError("no supported exact passive-node pairs exist in both splits")
    training_lineages = {group for group, split in group_splits.items() if split == "train"}
    holdout_lineages = {group for group, split in group_splits.items() if split == "holdout"}
    if (header.get("sourceLineages") != len(group_splits)
            or header.get("trainingSourceLineages") != len(training_lineages)
            or header.get("holdoutSourceLineages") != len(holdout_lineages)
            or header.get("trainingRows") != raw_row_counts["train"]
            or header.get("holdoutRows") != raw_row_counts["holdout"]
            or len(training_lineages | holdout_lineages) != len(group_splits)):
        raise DatasetError("declared source-lineage counts do not match the grouped rows")
    return header, splits["train"], splits["holdout"]


def _domain(rows: list[dict[str, Any]]) -> set[tuple[int, int, str, int]]:
    """Return only jointly observed class/ascendancy/skill/node mutations."""
    result: set[tuple[int, int, str, int]] = set()
    for row in rows:
        feature = row["feature"]
        changed_node_ids = feature["changedNodeIds"]
        if len(changed_node_ids) == 1:
            result.add((feature["classId"], feature["ascendancyId"], feature["mainSkill"], changed_node_ids[0]))
    return result


def _in_domain(row: dict[str, Any], domain: set[tuple[int, int, str, int]]) -> bool:
    feature = row["feature"]
    changed_node_ids = feature["changedNodeIds"]
    return (len(changed_node_ids) == 1
            and (feature["classId"], feature["ascendancyId"], feature["mainSkill"], changed_node_ids[0]) in domain)


def _vector(row: dict[str, Any], mean: np.ndarray, scale: np.ndarray) -> np.ndarray:
    vector = np.zeros(FEATURE_DIMENSION + len(NUMERIC_NAMES), dtype=np.float64)
    for token in row["feature"]["tokens"]:
        vector[hash_token(token) - 1] += 1.0
    numeric = np.asarray(row["feature"]["numeric"], dtype=np.float64)
    vector[FEATURE_DIMENSION:] = np.clip((numeric - mean) / scale, -8.0, 8.0)
    return vector


def _sigmoid_tanh(value: np.ndarray) -> np.ndarray:
    return np.tanh(value)


def _fit_mlp(rows: list[dict[str, Any]], hidden_size: int, seed: int) -> tuple[np.ndarray, ...]:
    numeric = np.asarray([row["feature"]["numeric"] for row in rows], dtype=np.float64)
    mean = numeric.mean(axis=0)
    scale = numeric.std(axis=0)
    scale[scale < 1e-9] = 1.0
    x = np.asarray([_vector(row, mean, scale) for row in rows], dtype=np.float64)
    y = np.asarray([row["target"] for row in rows], dtype=np.float64)
    y_mean, y_scale = float(y.mean()), float(y.std())
    if y_scale < 1e-10:
        raise DatasetError("training labels have no measurable variation")
    y = np.clip((y - y_mean) / y_scale, -10.0, 10.0)

    rng = np.random.default_rng(seed)
    input_size = x.shape[1]
    w1 = rng.normal(0.0, math.sqrt(2.0 / (input_size + hidden_size)), (input_size, hidden_size))
    b1 = np.zeros(hidden_size, dtype=np.float64)
    w2 = rng.normal(0.0, 0.05, hidden_size)
    b2 = np.zeros(1, dtype=np.float64)
    parameters = [w1, b1, w2, b2]
    first_moments = [np.zeros_like(value) for value in parameters]
    second_moments = [np.zeros_like(value) for value in parameters]
    step = 0
    learning_rate = 0.003
    batch_size = min(32, len(rows))
    for _epoch in range(300):
        # A fixed seeded permutation gives reproducible minibatch order.
        order = rng.permutation(len(rows))
        for start in range(0, len(rows), batch_size):
            indices = order[start:start + batch_size]
            xb, yb = x[indices], y[indices]
            hidden = _sigmoid_tanh(xb @ w1 + b1)
            prediction = hidden @ w2 + b2[0]
            error = prediction - yb
            grad_prediction = (2.0 / len(indices)) * error
            grad_w2 = hidden.T @ grad_prediction + 1e-5 * w2
            grad_b2 = np.asarray([grad_prediction.sum()])
            grad_hidden = grad_prediction[:, None] * w2[None, :]
            grad_pre_activation = grad_hidden * (1.0 - hidden * hidden)
            grad_w1 = xb.T @ grad_pre_activation + 1e-5 * w1
            grad_b1 = grad_pre_activation.sum(axis=0)
            gradients = [grad_w1, grad_b1, grad_w2, grad_b2]
            step += 1
            for index, gradient in enumerate(gradients):
                first_moments[index] = 0.9 * first_moments[index] + 0.1 * gradient
                second_moments[index] = 0.999 * second_moments[index] + 0.001 * gradient * gradient
                corrected_first = first_moments[index] / (1.0 - 0.9 ** step)
                corrected_second = second_moments[index] / (1.0 - 0.999 ** step)
                parameters[index] -= learning_rate * corrected_first / (np.sqrt(corrected_second) + 1e-8)
    return w1, b1, w2, b2, mean, scale


def _predict(rows: list[dict[str, Any]], model: tuple[np.ndarray, ...]) -> np.ndarray:
    w1, b1, w2, b2, mean, scale = model
    x = np.asarray([_vector(row, mean, scale) for row in rows], dtype=np.float64)
    return np.tanh(x @ w1 + b1) @ w2 + b2[0]


def _average_ranks(values: np.ndarray) -> np.ndarray:
    order = np.argsort(values, kind="mergesort")
    ranks = np.empty(len(values), dtype=np.float64)
    index = 0
    while index < len(order):
        end = index + 1
        while end < len(order) and values[order[end]] == values[order[index]]:
            end += 1
        rank = (index + 1 + end) / 2.0
        ranks[order[index:end]] = rank
        index = end
    return ranks


def _spearman(actual: np.ndarray, predicted: np.ndarray) -> float | None:
    if len(actual) < 2 or np.std(actual) == 0 or np.std(predicted) == 0:
        return None
    return float(np.corrcoef(_average_ranks(actual), _average_ranks(predicted))[0, 1])


def _pareto_indices(rows: list[dict[str, Any]]) -> set[int]:
    objectives = [(row["targetDelta"], row["ehpDelta"], -row["pointDelta"]) for row in rows]
    front: set[int] = set()
    for index, value in enumerate(objectives):
        dominated = False
        for other_index, other in enumerate(objectives):
            if other_index != index and all(a >= b for a, b in zip(other, value)) and any(a > b for a, b in zip(other, value)):
                dominated = True
                break
        if not dominated:
            front.add(index)
    return front


def _grouped_top_pareto_recall(rows: list[dict[str, Any]], predictions: np.ndarray) -> tuple[float, int, int]:
    """Measure candidate ordering only against alternatives from the same build baseline.

    A group with one supported candidate cannot measure ranking quality, so it is
    explicitly unscored and causes the caller's held-out gate to fail closed.
    A singleton Pareto *front* inside a group with multiple candidates is valid:
    it means one candidate dominates the others and its retrieval is measurable.
    """
    grouped: dict[str, list[tuple[int, dict[str, Any]]]] = defaultdict(list)
    for index, row in enumerate(rows):
        grouped[row["group"]].append((index, row))

    recalls: list[float] = []
    unscored_groups = 0
    for group in sorted(grouped):
        indexed_rows = grouped[group]
        if len(indexed_rows) < 2:
            unscored_groups += 1
            continue
        group_rows = [row for _, row in indexed_rows]
        front = _pareto_indices(group_rows)
        if not front:
            unscored_groups += 1
            continue
        group_predictions = np.asarray([predictions[index] for index, _ in indexed_rows], dtype=np.float64)
        top_count = len(front)
        predicted_top = set(np.argsort(-group_predictions, kind="mergesort")[:top_count].tolist())
        recalls.append(len(front & predicted_top) / top_count)

    macro_recall = float(np.mean(recalls)) if recalls else 0.0
    return macro_recall, len(recalls), unscored_groups


def _grouped_spearman(rows: list[dict[str, Any]], predictions: np.ndarray) -> tuple[float, int]:
    """Macro-average within-build rank correlation for a candidate ordering."""
    grouped_actual: dict[str, list[float]] = defaultdict(list)
    grouped_predicted: dict[str, list[float]] = defaultdict(list)
    for row, predicted in zip(rows, predictions):
        grouped_actual[row["group"]].append(row["target"])
        grouped_predicted[row["group"]].append(float(predicted))
    correlations = []
    for group in sorted(grouped_actual):
        correlation = _spearman(np.asarray(grouped_actual[group]), np.asarray(grouped_predicted[group]))
        if correlation is not None and math.isfinite(correlation):
            correlations.append(correlation)
    return (float(np.mean(correlations)) if correlations else 0.0), len(correlations)


def evaluate(model: tuple[np.ndarray, ...], train: list[dict[str, Any]], holdout: list[dict[str, Any]], hidden_size: int, seed: int) -> dict[str, Any]:
    domain = _domain(train)
    supported = [row for row in holdout if _in_domain(row, domain)]
    coverage = len(supported) / len(holdout) if holdout else 0.0
    predictions = _predict(supported, model) if supported else np.asarray([], dtype=np.float64)
    spearman, correlation_groups = _grouped_spearman(supported, predictions)
    pareto_recall, pareto_scored_groups, pareto_unscored_groups = _grouped_top_pareto_recall(supported, predictions)
    # Exact-pair study rows do not contain the production search queue ordinal.
    # Use their deterministic serialized order only as a conservative no-op
    # proxy; this comparison is not a measurement of live route-search lift.
    # The model still cannot pass the absolute gates while regressing either
    # objective ranking or Pareto retrieval against this persisted reference.
    input_order_predictions = -np.arange(len(supported), dtype=np.float64)
    baseline_spearman, baseline_correlation_groups = _grouped_spearman(supported, input_order_predictions)
    baseline_pareto_recall, baseline_pareto_scored_groups, baseline_pareto_unscored_groups = _grouped_top_pareto_recall(
        supported, input_order_predictions)
    baseline_non_regression = (
        spearman + BASELINE_NONREGRESSION_TOLERANCE >= baseline_spearman
        and pareto_recall + BASELINE_NONREGRESSION_TOLERANCE >= baseline_pareto_recall
    )
    holdout_group_ids = {row["group"] for row in holdout}
    supported_group_ids = {row["group"] for row in supported}
    # A whole held-out baseline outside the model domain has no within-build
    # Pareto comparison. Count it as unscored instead of letting row-level
    # coverage silently hide the missing group from macro validation.
    pareto_unscored_groups += len(holdout_group_ids - supported_group_ids)
    return {
        "status": "passed" if correlation_groups >= MIN_HOLDOUT_GROUPS and spearman >= MIN_SPEARMAN
                  and pareto_scored_groups >= MIN_HOLDOUT_GROUPS and pareto_unscored_groups == 0
                  and pareto_recall >= MIN_PARETO_RECALL and coverage >= MIN_COVERAGE
                  and baseline_correlation_groups >= MIN_HOLDOUT_GROUPS
                  and baseline_pareto_scored_groups >= MIN_HOLDOUT_GROUPS
                  and baseline_pareto_unscored_groups == 0 and baseline_non_regression else "failed",
        "heldOutSpearman": spearman,
        "topParetoRecall": float(pareto_recall),
        "baselineInputOrderSpearman": baseline_spearman,
        "baselineInputOrderTopParetoRecall": float(baseline_pareto_recall),
        "baselineNonRegression": baseline_non_regression,
        "baselineScoredSourceLineages": baseline_correlation_groups,
        "baselineParetoScoredGroups": baseline_pareto_scored_groups,
        "baselineParetoUnscoredGroups": baseline_pareto_unscored_groups,
        "paretoScoredGroups": pareto_scored_groups,
        "paretoUnscoredGroups": pareto_unscored_groups,
        "paretoGroupCoverage": (pareto_scored_groups / len(holdout_group_ids)) if holdout_group_ids else 0.0,
        "heldOutCoverage": float(coverage),
        "heldOutRows": len(holdout),
        "supportedHeldOutRows": len(supported),
        "scoredSourceLineages": correlation_groups,
        "heldOutSourceLineages": len({row["group"] for row in holdout}),
        "hiddenSize": hidden_size,
        "seed": seed,
    }


def _artifact(header: dict[str, Any], train: list[dict[str, Any]], holdout: list[dict[str, Any]], metric: str,
              model: tuple[np.ndarray, ...], validation: dict[str, Any], hidden_size: int) -> dict[str, Any]:
    w1, b1, w2, b2, mean, scale = model
    domain = _domain(train)
    return {
        "format": ARTIFACT_FORMAT,
        "schemaVersion": ARTIFACT_SCHEMA_VERSION,
        "featurePolicy": FEATURE_POLICY,
        "groupingPolicy": GROUPING_POLICY,
        "modelType": MODEL_TYPE,
        "deterministic": True,
        "engine": {key: header["engine"][key] for key in REQUIRED_ENGINE_KEYS},
        "trainingSourceLineages": len({row["group"] for row in train}),
        "holdoutSourceLineages": len({row["group"] for row in holdout}),
        "trainingRows": len(train),
        "holdoutRows": len(holdout),
        "objectiveMetric": metric,
        "featureDimension": FEATURE_DIMENSION,
        "hiddenSize": hidden_size,
        "numericMean": mean.tolist(),
        "numericScale": scale.tolist(),
        "weights": {
            "inputHidden": w1.tolist(),
            "biasHidden": b1.tolist(),
            "hiddenOutput": w2.tolist(),
            "biasOutput": float(b2[0]),
        },
        "domain": {"supportedMutations": [
            {"classId": class_id, "ascendancyId": ascendancy_id, "mainSkill": main_skill, "changedNodeId": node_id}
            for class_id, ascendancy_id, main_skill, node_id in sorted(domain)
        ]},
        "validation": {key: validation[key] for key in (
            "status", "heldOutSpearman", "topParetoRecall", "paretoScoredGroups", "paretoUnscoredGroups",
            "baselineInputOrderSpearman", "baselineInputOrderTopParetoRecall", "baselineNonRegression",
            "baselineScoredSourceLineages", "baselineParetoScoredGroups", "baselineParetoUnscoredGroups",
            "paretoGroupCoverage", "heldOutCoverage", "heldOutRows", "supportedHeldOutRows",
            "scoredSourceLineages", "heldOutSourceLineages",
        )},
    }


def train(dataset_path: pathlib.Path, output_path: pathlib.Path, objective: str, hidden_size: int = 12, seed: int = 17) -> dict[str, Any]:
    header, train_rows, holdout_rows = load_dataset(dataset_path, objective)
    train_groups = {row["group"] for row in train_rows}
    holdout_groups = {row["group"] for row in holdout_rows}
    counts = {
        "trainingRows": len(train_rows), "holdoutRows": len(holdout_rows),
        "trainingSourceLineages": len(train_groups), "holdoutSourceLineages": len(holdout_groups),
    }
    if (train_groups & holdout_groups or len(train_groups) < MIN_TRAIN_GROUPS or len(holdout_groups) < MIN_HOLDOUT_GROUPS
            or len(train_rows) < MIN_TRAIN_ROWS or len(holdout_rows) < MIN_HOLDOUT_ROWS):
        return {"status": "blocked_insufficient_source_lineages", **counts, "artifactWritten": False}
    domain = _domain(train_rows)
    eligible_train = [row for row in train_rows if _in_domain(row, domain)]
    eligible_holdout = [row for row in holdout_rows if _in_domain(row, domain)]
    if len(eligible_train) < MIN_TRAIN_ROWS or not eligible_holdout:
        return {"status": "blocked_model_domain_coverage", **counts, "artifactWritten": False}
    model = _fit_mlp(eligible_train, hidden_size, seed)
    validation = evaluate(model, eligible_train, holdout_rows, hidden_size, seed)
    result = {"status": validation["status"], **counts, "validation": validation, "artifactWritten": False}
    if validation["status"] != "passed":
        result["message"] = "Held-out quality gates failed; no model artifact was written"
        return result
    artifact = _artifact(header, eligible_train, eligible_holdout, objective, model, validation, hidden_size)
    numeric_values = np.asarray(artifact["numericMean"] + artifact["numericScale"], dtype=np.float64)
    model_weights = [model[0], model[1], model[2], model[3]]
    if (not np.isfinite(numeric_values).all() or np.max(np.abs(numeric_values)) > 1e18
            or any(not np.isfinite(weights).all() or np.max(np.abs(weights)) > 100 for weights in model_weights)
            or np.any(np.asarray(artifact["numericScale"]) <= 0)):
        return {"status": "blocked_artifact_numeric_bounds", **counts, "artifactWritten": False}
    encoded = json.dumps(artifact, allow_nan=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_ARTIFACT_BYTES:
        return {"status": "blocked_artifact_too_large", **counts, "artifactWritten": False}
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: pathlib.Path | None = None
    try:
        with tempfile.NamedTemporaryFile("wb", dir=output_path.parent, prefix=".surrogate-", suffix=".tmp", delete=False) as handle:
            temporary_path = pathlib.Path(handle.name)
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, output_path)
    finally:
        if temporary_path and temporary_path.exists():
            temporary_path.unlink()
    result["artifactWritten"] = True
    result["artifactBytes"] = len(encoded)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=pathlib.Path, help="sanitized JSONL exported by PoB StudyRecords")
    parser.add_argument("output", type=pathlib.Path, help="destination artifact; use the PoB user path's OptimizerModels/active.json")
    parser.add_argument("--metric", default="CombinedDPS", help="PoB objective metric key (default: CombinedDPS)")
    parser.add_argument("--hidden-size", type=int, default=12, choices=range(1, 33))
    parser.add_argument("--seed", type=int, default=17)
    args = parser.parse_args(argv)
    try:
        result = train(args.dataset, args.output, args.metric, args.hidden_size, args.seed)
    except (DatasetError, OSError, ValueError) as exc:
        result = {"status": "blocked_invalid_dataset", "artifactWritten": False, "message": str(exc)}
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result.get("artifactWritten") else 2


if __name__ == "__main__":
    raise SystemExit(main())
