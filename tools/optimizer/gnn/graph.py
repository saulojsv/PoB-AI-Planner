"""Deterministic typed-graph assembly shared by training and inference."""

from __future__ import annotations

import hashlib
from typing import Any

NODE_TYPES = ("candidate", "passive", "skill_group", "gem", "item", "scenario")
EDGE_TYPES = (
    ("passive", "path", "passive"),
    ("skill_group", "contains", "gem"),
    ("gem", "supports", "candidate"),
    ("item", "equipped_in", "skill_group"),
    ("passive", "changed_by", "candidate"),
    ("item", "changed_by", "candidate"),
    ("scenario", "evaluates", "candidate"),
)
TOKEN_BUCKETS = 8192
TOKEN_LIMIT = 32


def token_id(value: str) -> int:
    digest = hashlib.blake2b(value.encode("utf-8"), digest_size=8, person=b"pobgnnv1").digest()
    # Zero is the reserved padding index for torch.nn.Embedding.
    return 1 + int.from_bytes(digest, "little") % (TOKEN_BUCKETS - 1)


def _tokens(*values: Any) -> list[int]:
    return [token_id(str(value)) for value in values if value is not None][:TOKEN_LIMIT]


def graph_record(snapshot: dict[str, Any], proposal: dict[str, Any]) -> dict[str, Any]:
    """Create one candidate graph without exposing raw item text or build XML."""
    nodes: dict[str, list[dict[str, Any]]] = {kind: [] for kind in NODE_TYPES}
    edges: dict[str, list[list[int]]] = {"|".join(key): [] for key in EDGE_TYPES}

    passive_index: dict[int, int] = {}
    for row in snapshot["passiveNodes"]:
        passive_index[row["id"]] = len(nodes["passive"])
        allocated = row["allocated"]
        changed = row["id"] in proposal["addedNodeIds"] or row["id"] in proposal["removedNodeIds"]
        nodes["passive"].append({"tokens": _tokens("passive", row["category"], "allocated" if allocated else "unallocated",
                                                   "changed" if changed else "stable", row["id"]),
                                  "numeric": [float(allocated), float(changed)]})
    for edge in snapshot["passiveEdges"]:
        left, right = passive_index.get(edge["source"]), passive_index.get(edge["target"])
        if left is not None and right is not None:
            edges["passive|path|passive"].append([left, right])
            edges["passive|path|passive"].append([right, left])

    for group in snapshot["skillGroups"]:
        group_index = len(nodes["skill_group"])
        slot = group.get("slot", "unknown")
        nodes["skill_group"].append({"tokens": _tokens("skill_group", slot,
                                                          "enabled" if group.get("enabled") else "disabled",
                                                          "full_dps" if group.get("includedInFullDPS") else "not_full_dps"),
                                      "numeric": [float(group.get("enabled") is True), float(group.get("includedInFullDPS") is True)]})
        for gem in group.get("gems", []):
            gem_index = len(nodes["gem"])
            nodes["gem"].append({"tokens": _tokens("gem", gem.get("gemId"), gem.get("effectId"), gem.get("origin"),
                                                     "support" if gem.get("support") else "active"),
                                 "numeric": [float(gem.get("level", 1)), float(gem.get("quality", 0)), float(gem.get("support") is True)]})
            edges["skill_group|contains|gem"].append([group_index, gem_index])
            edges["gem|supports|candidate"].append([gem_index, 0])
    item_group_by_slot: dict[str, int] = {}
    for index, group in enumerate(snapshot["skillGroups"]):
        item_group_by_slot[str(group.get("slot", ""))] = index
    for item in snapshot["items"]:
        item_index = len(nodes["item"])
        nodes["item"].append({"tokens": _tokens("item", item.get("slot"), item.get("base"), item.get("rarity"), item.get("fingerprint")),
                              "numeric": [1.0]})
        group_index = item_group_by_slot.get(str(item.get("slot", "")))
        if group_index is not None:
            edges["item|equipped_in|skill_group"].append([item_index, group_index])
        if item.get("slot") in proposal.get("changedItemSlots", []):
            edges["item|changed_by|candidate"].append([item_index, 0])
    for node_id in proposal["addedNodeIds"] + proposal["removedNodeIds"]:
        index = passive_index.get(node_id)
        if index is not None:
            edges["passive|changed_by|candidate"].append([index, 0])
    candidate_tokens = _tokens("candidate", proposal["family"], *proposal.get("featureTokens", []))
    nodes["candidate"].append({"tokens": candidate_tokens,
                                "numeric": list(proposal.get("numericFeatures", []))[:16] or [0.0]})
    scenario = snapshot["scenario"]
    nodes["scenario"].append({"tokens": _tokens("scenario", scenario["profile"], scenario.get("enemyPreset")), "numeric": [1.0]})
    edges["scenario|evaluates|candidate"].append([0, 0])
    return {"nodes": nodes, "edges": edges, "proposalId": proposal["proposalId"]}


def to_pyg(record: dict[str, Any], torch: Any, HeteroData: Any) -> Any:
    data = HeteroData()
    for node_type in NODE_TYPES:
        values = record["nodes"][node_type]
        if not values:
            data[node_type].x = torch.empty((0, TOKEN_LIMIT), dtype=torch.long)
            data[node_type].numeric = torch.empty((0, 16), dtype=torch.float32)
            continue
        tokens = [row["tokens"] or [0] for row in values]
        x = [(row + [0] * TOKEN_LIMIT)[:TOKEN_LIMIT] for row in tokens]
        numeric = [(row.get("numeric", []) + [0.0] * 16)[:16] for row in values]
        data[node_type].x = torch.tensor(x, dtype=torch.long)
        data[node_type].numeric = torch.tensor(numeric or [[0.0]], dtype=torch.float32)
    for edge_type in EDGE_TYPES:
        key = "|".join(edge_type)
        pairs = record["edges"].get(key, [])
        data[edge_type].edge_index = torch.tensor(pairs, dtype=torch.long).t().contiguous() if pairs else torch.empty((2, 0), dtype=torch.long)
    return data
