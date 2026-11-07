"""Optional PyTorch Geometric inference. Import fails closed without the private runtime."""

from __future__ import annotations

from typing import Any

try:
    import torch
    from torch import nn
    from torch_geometric.nn import GATv2Conv, HeteroConv, global_mean_pool
except ImportError as exc:  # pragma: no cover - exercised on machines without the optional runtime
    torch = None
    nn = None
    GATv2Conv = None
    HeteroConv = None
    global_mean_pool = None
    _IMPORT_ERROR = exc
else:
    _IMPORT_ERROR = None

from .graph import EDGE_TYPES, NODE_TYPES, TOKEN_BUCKETS, to_pyg

OUTPUT_CLASSES = {"dps": 6, "ehp": 4, "elemental_max_hit": 5, "physical_max_hit": 5,
                  "elemental_resist": 4, "chaos_resist": 4}


def require_runtime() -> None:
    if torch is None or HeteroConv is None:
        raise RuntimeError("Private GNN runtime is unavailable: install the pinned torch/PyG environment") from _IMPORT_ERROR


def model_class():
    require_runtime()

    class HeteroGATv2(nn.Module):
        def __init__(self, hidden_size: int = 64, heads: int = 2, dropout: float = 0.1):
            super().__init__()
            if not 32 <= hidden_size <= 256 or not 1 <= heads <= 8:
                raise ValueError("unsupported GNN dimensions")
            self.hidden_size = hidden_size
            self.dropout = nn.Dropout(dropout)
            self.token_embeddings = nn.ModuleDict({kind: nn.Embedding(TOKEN_BUCKETS, hidden_size, padding_idx=0) for kind in NODE_TYPES})
            self.numeric_encoders = nn.ModuleDict({kind: nn.Sequential(nn.Linear(16, hidden_size), nn.ReLU(), nn.Linear(hidden_size, hidden_size)) for kind in NODE_TYPES})
            self.conv1 = HeteroConv({edge: GATv2Conv((hidden_size, hidden_size), hidden_size, heads=heads,
                                                     concat=False, dropout=dropout, add_self_loops=False) for edge in EDGE_TYPES}, aggr="sum")
            self.conv2 = HeteroConv({edge: GATv2Conv((hidden_size, hidden_size), hidden_size, heads=heads,
                                                     concat=False, dropout=dropout, add_self_loops=False) for edge in EDGE_TYPES}, aggr="sum")
            self.norm1 = nn.ModuleDict({kind: nn.LayerNorm(hidden_size) for kind in NODE_TYPES})
            self.norm2 = nn.ModuleDict({kind: nn.LayerNorm(hidden_size) for kind in NODE_TYPES})
            self.heads = nn.ModuleDict({name: nn.Linear(hidden_size, classes) for name, classes in OUTPUT_CLASSES.items()})

        def encode(self, data: Any) -> dict[str, Any]:
            x: dict[str, Any] = {}
            for kind in NODE_TYPES:
                categorical = data[kind].x
                numeric = data[kind].numeric
                token_embeddings = self.token_embeddings[kind](categorical)
                mask = categorical.ne(0).unsqueeze(-1)
                pooled = (token_embeddings * mask).sum(dim=1) / mask.sum(dim=1).clamp(min=1)
                x[kind] = pooled + self.numeric_encoders[kind](numeric)
            edges = {edge: data[edge].edge_index for edge in EDGE_TYPES if data[edge].edge_index.numel() > 0}
            first = self.conv1(x, edges)
            x = {kind: self.norm1[kind](x[kind] + self.dropout(first.get(kind, torch.zeros_like(x[kind])))) for kind in NODE_TYPES}
            second = self.conv2(x, edges)
            x = {kind: self.norm2[kind](x[kind] + self.dropout(second.get(kind, torch.zeros_like(x[kind])))) for kind in NODE_TYPES}
            return x

        def forward(self, data: Any) -> dict[str, Any]:
            encoded = self.encode(data)
            batch = getattr(data["candidate"], "batch", None)
            if batch is None:
                candidate = encoded["candidate"].mean(dim=0, keepdim=True)
            else:
                candidate = global_mean_pool(encoded["candidate"], batch)
            return {name: head(candidate) for name, head in self.heads.items()}

    return HeteroGATv2


def load_ensemble(package: dict[str, Any]) -> list[Any]:
    require_runtime()
    import json
    from pathlib import Path

    directory = Path(package["directory"])
    hyper = package["hyperparameters"]
    if hyper.get("modelType") != "hetero-gatv2-ensemble-v1" or hyper.get("featureSchema") != "pob-heterograph-v1":
        raise ValueError("model hyperparameter schema mismatch")
    hidden = int(hyper.get("hiddenSize", 64))
    heads = int(hyper.get("attentionHeads", 2))
    members_count = int(hyper.get("ensembleMembers", 5))
    if not 32 <= hidden <= 256 or not 1 <= heads <= 8 or not 3 <= members_count <= 16:
        raise ValueError("model hyperparameters are outside supported bounds")
    payload = torch.load(directory / "model_weights.pt", map_location="cpu", weights_only=True)
    if not isinstance(payload, dict) or payload.get("format") != "pob-gnn-state-dict-v1" or not isinstance(payload.get("members"), dict):
        raise ValueError("tensor-only checkpoint container is malformed")
    if len(payload["members"]) != members_count:
        raise ValueError("checkpoint ensemble count mismatches hyperparameters")
    model_type = model_class()
    models = []
    for member_index in range(members_count):
        state = payload["members"].get(f"member_{member_index}")
        if not isinstance(state, dict):
            raise ValueError("checkpoint is missing an ensemble member")
        model = model_type(hidden_size=hidden, heads=heads, dropout=0.0)
        model.load_state_dict(state, strict=True)
        model.eval()
        models.append(model)
    return models


def rank_graph_records(package: dict[str, Any], records: list[dict[str, Any]], run_spec: dict[str, Any],
                       cancelled: Any, progress: Any) -> list[dict[str, Any]]:
    require_runtime()
    from .contracts import DPS_TIERS, EHP_TIERS, HIT_TIERS

    models = load_ensemble(package)
    HeteroData = __import__("torch_geometric.data", fromlist=["HeteroData"]).HeteroData
    DataLoader = __import__("torch_geometric.loader", fromlist=["DataLoader"]).DataLoader
    threshold_indexes = {
        "dps": list(DPS_TIERS).index(run_spec["targets"]["dps"]) + 1,
        "ehp": list(EHP_TIERS).index(run_spec["targets"]["ehp"]) + 1,
        "elemental_max_hit": list(HIT_TIERS).index(run_spec["targets"]["elementalMaxHit"]) + 1,
        "physical_max_hit": list(HIT_TIERS).index(run_spec["targets"]["physicalMaxHit"]) + 1,
        "elemental_resist": 3 if run_spec["resistances"]["elemental"] == "OVERCAP_30_ALL" else 2,
        # Labels: < -60, [-60, 0), [0, 75), >= 75.
        "chaos_resist": 3 if run_spec["resistances"]["chaos"] == "CAP_EFFECTIVE" else 2,
    }
    graphs = [to_pyg(record, torch, HeteroData) for record in records]
    loader = DataLoader(graphs, batch_size=min(32, max(1, len(graphs))), shuffle=False)
    ranked = []
    processed = 0
    with torch.no_grad():
        for batch in loader:
            if cancelled.is_set():
                break
            member_probabilities = []
            for model in models:
                outputs = model(batch)
                metric_probabilities = {name: output.softmax(dim=-1) for name, output in outputs.items()}
                joint = torch.ones(next(iter(outputs.values())).shape[0], dtype=torch.float32)
                for name, threshold in threshold_indexes.items():
                    joint *= metric_probabilities[name][:, threshold:].sum(dim=1).cpu()
                member_probabilities.append(joint.tolist())
            batch_size = len(member_probabilities[0]) if member_probabilities else 0
            for batch_index in range(batch_size):
                member_scores = [member[batch_index] for member in member_probabilities]
                mean = sum(member_scores) / len(member_scores)
                variance = sum((score - mean) ** 2 for score in member_scores) / max(1, len(member_scores) - 1)
                proposal_index = processed + batch_index
                ranked.append({"proposalId": records[proposal_index]["proposalId"], "predictedFeasibility": mean,
                               "epistemicUncertainty": variance ** 0.5, "originalIndex": proposal_index})
            processed += batch_size
            if progress:
                progress(processed, len(records))

    if not ranked:
        return []
    exact_count = min(len(ranked), run_spec["budget"]["maxExactEvaluations"])
    explore_count = int(exact_count * 0.20)
    exploit_count = exact_count - explore_count
    indexed = {row["proposalId"]: row for row in ranked}
    exploit = sorted(ranked, key=lambda row: (-row["predictedFeasibility"], -row["epistemicUncertainty"], row["originalIndex"]))[:exploit_count]
    exploit_ids = {row["proposalId"] for row in exploit}
    explore = sorted((row for row in ranked if row["proposalId"] not in exploit_ids),
                     key=lambda row: (-row["epistemicUncertainty"], row["originalIndex"]))[:explore_count]
    selected = exploit + explore
    selected_ids = {row["proposalId"] for row in selected}
    remainder = sorted((row for row in ranked if row["proposalId"] not in selected_ids),
                       key=lambda row: (-row["predictedFeasibility"], -row["epistemicUncertainty"], row["originalIndex"]))
    # The 80/20 split applies to the exact-evaluation prefix, with stable ordering after that prefix.
    selected_ids_ordered = [row["proposalId"] for row in selected + remainder]
    return [{"proposalId": proposal_id, "predictedFeasibility": indexed[proposal_id]["predictedFeasibility"],
             "epistemicUncertainty": indexed[proposal_id]["epistemicUncertainty"]} for proposal_id in selected_ids_ordered]
