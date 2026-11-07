"""Strict, dependency-free validation for the local PoB GNN protocol."""

from __future__ import annotations

import math
import re
from collections.abc import Mapping
from typing import Any

RUN_SPEC_VERSION = 1
BUILD_SNAPSHOT_VERSION = 1
IPC_VERSION = "2.0"
MAX_PROPOSALS = 10_000
MAX_EXACT_EVALUATIONS = 10_000
MAX_SEARCH_TIMEOUT_SECONDS = 3_600
MAX_NODES = 20_000
MAX_EDGES = 80_000
MAX_STRING = 512
SHA256_RE = re.compile(r"^[0-9a-f]{64}$", re.IGNORECASE)

DPS_TIERS = {"TIER_1M_TO_5M": 1_000_000, "TIER_5M_TO_10M": 5_000_000,
             "TIER_10M_TO_25M": 10_000_000, "TIER_25M_TO_50M": 25_000_000,
             "TIER_50M_PLUS": 50_000_000}
EHP_TIERS = {"TIER_20K_TO_50K": 20_000, "TIER_50K_TO_100K": 50_000,
             "TIER_100K_PLUS": 100_000}
HIT_TIERS = {"TIER_5K_TO_10K": 5_000, "TIER_10K_TO_20K": 10_000,
             "TIER_15K_TO_25K": 15_000, "TIER_20K_PLUS": 20_000}
RESIST_STRATEGIES = {"CAP_EFFECTIVE", "OVERCAP_30_ALL"}
CHAOS_STRATEGIES = {"POSITIVE_OR_CAP", "CAP_EFFECTIVE"}
SEARCH_MODES = {"SINGLE_SKILL_ONLY", "CROSS_SKILL_COMBINATION"}
MUTATION_MODES = {"CONSERVATIVE_FINE_TUNE", "BALANCED_LOCAL_SEARCH", "AGGRESSIVE_CLUSTER_EXPANSION"}


class ContractError(ValueError):
    """A protocol payload is malformed or outside its documented bounds."""


def _mapping(value: Any, name: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ContractError(f"{name} must be an object")
    return value


def _string(value: Any, name: str, *, maximum: int = MAX_STRING) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum or any(ord(c) < 32 for c in value):
        raise ContractError(f"{name} must be a non-empty printable string up to {maximum} characters")
    return value


def _integer(value: Any, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ContractError(f"{name} must be an integer from {minimum} to {maximum}")
    return value


def _finite_number(value: Any, name: str, *, minimum: float = -1e18, maximum: float = 1e18) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ContractError(f"{name} must be finite")
    if value < minimum or value > maximum:
        raise ContractError(f"{name} is outside the accepted range")
    return float(value)


def validate_engine(engine: Any) -> dict[str, Any]:
    source = _mapping(engine, "engine")
    result: dict[str, Any] = {}
    for key in ("pobVersion", "pobBranch", "dataVersion", "treeVersion"):
        result[key] = _string(source.get(key), f"engine.{key}", maximum=128)
    fingerprint = _string(source.get("manifestFingerprint"), "engine.manifestFingerprint", maximum=64)
    if not SHA256_RE.fullmatch(fingerprint):
        raise ContractError("engine.manifestFingerprint must be a SHA-256 hex digest")
    result["manifestFingerprint"] = fingerprint.lower()
    return result


def validate_run_spec(run_spec: Any) -> dict[str, Any]:
    source = _mapping(run_spec, "run_spec")
    if source.get("schemaVersion") != RUN_SPEC_VERSION:
        raise ContractError("run_spec.schemaVersion must be 1")
    mode = source.get("modelMode", "approved_or_fallback")
    if mode not in {"approved_or_fallback", "deterministic_fallback", "approved_gnn"}:
        raise ContractError("run_spec.modelMode is unsupported")
    package_id = source.get("modelPackageId")
    if package_id is not None:
        package_id = _string(package_id, "run_spec.modelPackageId", maximum=128)
    skill = _mapping(source.get("skill"), "run_spec.skill")
    skill_result = {
        "groupIndex": _integer(skill.get("groupIndex"), "skill.groupIndex", 1, 48),
        "skillIndex": _integer(skill.get("skillIndex"), "skill.skillIndex", 1, 12),
        "effectId": _string(skill.get("effectId"), "skill.effectId", maximum=180),
        "gemId": _string(skill.get("gemId"), "skill.gemId", maximum=160),
        "slot": _string(skill.get("slot"), "skill.slot", maximum=64),
    }
    search_mode = source.get("searchMode", "SINGLE_SKILL_ONLY")
    if search_mode not in SEARCH_MODES:
        raise ContractError("run_spec.searchMode is unsupported")
    scenario = _mapping(source.get("scenario"), "run_spec.scenario")
    profile = scenario.get("profile", "Current")
    if profile not in {"Current", "PinnacleUnbuffed", "PinnacleChassis"}:
        raise ContractError("run_spec.scenario.profile is unsupported")
    enemy = scenario.get("enemyPreset", "Active")
    if enemy not in {"Active", "None", "Boss", "Pinnacle", "Uber"}:
        raise ContractError("run_spec.scenario.enemyPreset is unsupported")
    targets = _mapping(source.get("targets"), "run_spec.targets")
    tier_values: dict[str, str] = {}
    for name, choices in (("dps", DPS_TIERS), ("ehp", EHP_TIERS),
                          ("elementalMaxHit", HIT_TIERS), ("physicalMaxHit", HIT_TIERS)):
        tier = targets.get(name)
        if tier not in choices:
            raise ContractError(f"run_spec.targets.{name} is unsupported")
        tier_values[name] = tier
    resists = _mapping(source.get("resistances"), "run_spec.resistances")
    elemental = resists.get("elemental", "CAP_EFFECTIVE")
    chaos = resists.get("chaos", "POSITIVE_OR_CAP")
    if elemental not in RESIST_STRATEGIES or chaos not in CHAOS_STRATEGIES:
        raise ContractError("run_spec.resistances contains an unsupported strategy")
    mutation = source.get("mutationAggressiveness", "BALANCED_LOCAL_SEARCH")
    if mutation not in MUTATION_MODES:
        raise ContractError("run_spec.mutationAggressiveness is unsupported")
    cross_skill = source.get("crossSkillMode", "SINGLE_SKILL_ONLY")
    if cross_skill not in {"SINGLE_SKILL_ONLY", "ALLOW_COC_AND_CWC", "ALLOW_SPELLSLINGER_AND_TRIGGERS", "ALLOW_DEBUFF_PRIMERS"}:
        raise ContractError("run_spec.crossSkillMode is unsupported")
    budget = _mapping(source.get("budget"), "run_spec.budget")
    min_proposals = _integer(budget.get("minProposals", 1000), "budget.minProposals", 1, MAX_PROPOSALS)
    max_exact = _integer(budget.get("maxExactEvaluations", 5000), "budget.maxExactEvaluations", 1, MAX_EXACT_EVALUATIONS)
    timeout = _integer(budget.get("timeoutSeconds", 1800), "budget.timeoutSeconds", 1, MAX_SEARCH_TIMEOUT_SECONDS)
    graph = _mapping(source.get("graph"), "run_spec.graph")
    radius = _integer(graph.get("radius", 4), "graph.radius", 2, 6)
    if radius not in {2, 4, 6}:
        raise ContractError("graph.radius must be 2, 4, or 6")
    return {
        "schemaVersion": RUN_SPEC_VERSION,
        "modelMode": mode,
        "modelPackageId": package_id,
        "searchMode": search_mode,
        "skill": skill_result,
        "scenario": {"profile": profile, "enemyPreset": enemy},
        "targets": tier_values,
        "resistances": {"elemental": elemental, "chaos": chaos},
        "crossSkillMode": cross_skill,
        "mutationAggressiveness": mutation,
        "graph": {"radius": radius},
        "budget": {"minProposals": min_proposals, "maxExactEvaluations": max_exact, "timeoutSeconds": timeout},
    }


def validate_build_snapshot(snapshot: Any) -> dict[str, Any]:
    source = _mapping(snapshot, "build_snapshot")
    if source.get("schemaVersion") != BUILD_SNAPSHOT_VERSION:
        raise ContractError("build_snapshot.schemaVersion must be 1")
    engine = validate_engine(source.get("engine"))
    skill = _mapping(source.get("skill"), "build_snapshot.skill")
    skill_result = {
        "groupIndex": _integer(skill.get("groupIndex"), "skill.groupIndex", 1, 48),
        "skillIndex": _integer(skill.get("skillIndex"), "skill.skillIndex", 1, 12),
        "effectId": _string(skill.get("effectId"), "skill.effectId", maximum=180),
        "gemId": _string(skill.get("gemId"), "skill.gemId", maximum=160),
        "slot": _string(skill.get("slot"), "skill.slot", maximum=64),
    }
    nodes = source.get("passiveNodes")
    edges = source.get("passiveEdges")
    if not isinstance(nodes, list) or not 1 <= len(nodes) <= MAX_NODES:
        raise ContractError(f"build_snapshot.passiveNodes must contain 1 to {MAX_NODES} nodes")
    if not isinstance(edges, list) or len(edges) > MAX_EDGES:
        raise ContractError(f"build_snapshot.passiveEdges must contain at most {MAX_EDGES} edges")
    node_ids: set[int] = set()
    normalized_nodes = []
    for index, row in enumerate(nodes):
        row = _mapping(row, f"passiveNodes[{index}]")
        node_id = _integer(row.get("id"), f"passiveNodes[{index}].id", 1, 2_147_483_647)
        if node_id in node_ids:
            raise ContractError("build_snapshot.passiveNodes repeats an id")
        node_ids.add(node_id)
        normalized_nodes.append({"id": node_id, "allocated": row.get("allocated") is True,
                                 "category": _string(row.get("category", "unknown"), "passive node category", maximum=64)})
    normalized_edges = []
    seen_edges = set()
    for index, row in enumerate(edges):
        row = _mapping(row, f"passiveEdges[{index}]")
        left = _integer(row.get("source"), f"passiveEdges[{index}].source", 1, 2_147_483_647)
        right = _integer(row.get("target"), f"passiveEdges[{index}].target", 1, 2_147_483_647)
        if left not in node_ids or right not in node_ids or left == right:
            raise ContractError("build_snapshot.passiveEdges must reference distinct included nodes")
        pair = (min(left, right), max(left, right))
        if pair in seen_edges:
            continue
        seen_edges.add(pair)
        normalized_edges.append({"source": pair[0], "target": pair[1]})
    items = source.get("items", [])
    groups = source.get("skillGroups", [])
    if not isinstance(items, list) or len(items) > 80:
        raise ContractError("build_snapshot.items must contain at most 80 entries")
    if not isinstance(groups, list) or len(groups) > 48:
        raise ContractError("build_snapshot.skillGroups must contain at most 48 entries")
    normalized_items = []
    for item in items:
        item = _mapping(item, "item")
        fingerprint = str(item.get("fingerprint", ""))
        if not SHA256_RE.fullmatch(fingerprint):
            raise ContractError("item fingerprint must be a SHA-256 hex digest")
        normalized_items.append({"slot": _string(item.get("slot"), "item.slot", maximum=64),
                                 "base": _string(item.get("base", "unknown"), "item.base", maximum=120),
                                 "rarity": _string(item.get("rarity", "unknown"), "item.rarity", maximum=40),
                                 "fingerprint": fingerprint.lower()})
    normalized_groups = []
    for group in groups:
        group = _mapping(group, "skill group")
        group_index = _integer(group.get("index"), "skill group index", 1, 48)
        group_gems = group.get("gems", [])
        if not isinstance(group_gems, list) or len(group_gems) > 32:
            raise ContractError("skill group gems must contain at most 32 entries")
        normalized_gems = []
        for gem in group_gems:
            gem = _mapping(gem, "skill group gem")
            origin = gem.get("origin", "unknown")
            if origin not in {"socketed_gem", "item_granted", "imbued", "unknown"}:
                raise ContractError("skill gem origin is unsupported")
            normalized_gems.append({"gemId": _string(gem.get("gemId"), "gem.gemId", maximum=160),
                                    "effectId": _string(gem.get("effectId"), "gem.effectId", maximum=180),
                                    "level": _integer(gem.get("level", 1), "gem.level", 1, 100),
                                    "quality": _finite_number(gem.get("quality", 0), "gem.quality", minimum=0, maximum=100),
                                    "origin": origin, "support": gem.get("support") is True})
        normalized_groups.append({"index": group_index,
                                  "slot": _string(group.get("slot", "unknown"), "skill group.slot", maximum=64),
                                  "enabled": group.get("enabled") is True,
                                  "includedInFullDPS": group.get("includedInFullDPS") is True,
                                  "gems": normalized_gems})
    scenario = _mapping(source.get("scenario"), "build_snapshot.scenario")
    if scenario.get("profile") not in {"Current", "PinnacleUnbuffed", "PinnacleChassis"}:
        raise ContractError("build_snapshot.scenario.profile is unsupported")
    if scenario.get("enemyPreset", "Active") not in {"Active", "None", "Boss", "Pinnacle", "Uber"}:
        raise ContractError("build_snapshot.scenario.enemyPreset is unsupported")
    metrics = _mapping(source.get("baselineMetrics", {}), "build_snapshot.baselineMetrics")
    normalized_metrics = {str(k): _finite_number(v, f"baselineMetrics.{k}") for k, v in metrics.items() if v is not None}
    return {"schemaVersion": BUILD_SNAPSHOT_VERSION, "engine": engine, "skill": skill_result,
            "scenario": {"profile": scenario["profile"], "enemyPreset": scenario.get("enemyPreset", "Active")},
            "passiveNodes": normalized_nodes, "passiveEdges": normalized_edges,
            "items": normalized_items, "skillGroups": normalized_groups, "baselineMetrics": normalized_metrics}


def validate_proposals(proposals: Any) -> list[dict[str, Any]]:
    if not isinstance(proposals, list) or not 1 <= len(proposals) <= MAX_PROPOSALS:
        raise ContractError(f"proposals must contain 1 to {MAX_PROPOSALS} entries")
    result = []
    seen = set()
    for index, source in enumerate(proposals):
        source = _mapping(source, f"proposals[{index}]")
        proposal_id = _string(source.get("proposalId"), f"proposals[{index}].proposalId", maximum=128)
        if proposal_id in seen:
            raise ContractError("proposalId values must be unique")
        seen.add(proposal_id)
        family = source.get("family")
        if family not in {"tree", "skill", "equipment", "jewel", "configuration", "cross_skill", "hybrid", "baseline", "other"}:
            raise ContractError(f"proposals[{index}].family is unsupported")
        added = source.get("addedNodeIds", [])
        removed = source.get("removedNodeIds", [])
        if not isinstance(added, list) or not isinstance(removed, list) or len(added) > 120 or len(removed) > 120:
            raise ContractError(f"proposals[{index}] passive node changes are invalid")
        for node_id in added + removed:
            _integer(node_id, "proposal node id", 1, 2_147_483_647)
        feature_tokens = source.get("featureTokens", [])
        numeric_features = source.get("numericFeatures", [])
        changed_slots = source.get("changedItemSlots", [])
        if not isinstance(feature_tokens, list) or len(feature_tokens) > 256:
            raise ContractError(f"proposals[{index}].featureTokens must be a list of at most 256 strings")
        if not isinstance(numeric_features, list) or len(numeric_features) > 64:
            raise ContractError(f"proposals[{index}].numericFeatures must be a list of at most 64 numbers")
        if not isinstance(changed_slots, list) or len(changed_slots) > 20:
            raise ContractError(f"proposals[{index}].changedItemSlots must contain at most 20 slots")
        result.append({"proposalId": proposal_id, "family": family,
                       "addedNodeIds": added, "removedNodeIds": removed,
                       "changedItemSlots": [_string(slot, "changed item slot", maximum=64) for slot in changed_slots],
                       "featureTokens": [_string(t, "feature token", maximum=256) for t in feature_tokens],
                       "numericFeatures": [_finite_number(v, "numeric feature", minimum=-1e9, maximum=1e9) for v in numeric_features]})
    return result
