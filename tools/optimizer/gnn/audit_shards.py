"""Review exact authorized inbox shards and admit them into lineage-separated datasets."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

from .contracts import ContractError
from .dataset import read_jsonl_files


def _sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def _context_key(row: dict[str, Any]) -> str:
    identity = {"engine": row["engine"], "skill": row["skill"], "scenario": row["scenario"]}
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()[:20]


def _split_lineages(lineages: list[str]) -> dict[str, str]:
    ordered = sorted(lineages, key=lambda value: hashlib.sha256(value.encode("utf-8")).hexdigest())
    count = len(ordered)
    holdout_count = max(5, math.ceil(count * 0.20))
    validation_count = max(2, math.ceil(count * 0.10))
    train_count = count - holdout_count - validation_count
    if train_count < 8:
        raise ContractError(f"context has {count} lineages; at least 15 are needed for 8 train, 2 validation, and 5 holdout lineages")
    result = {}
    for lineage in ordered[:train_count]:
        result[lineage] = "train"
    for lineage in ordered[train_count:train_count + validation_count]:
        result[lineage] = "validation"
    for lineage in ordered[train_count + validation_count:]:
        result[lineage] = "holdout"
    return result


def audit(inbox: Path, validated_root: Path, admit: bool) -> dict[str, Any]:
    files = sorted(inbox.rglob("*.jsonl")) if inbox.is_dir() else []
    if not files:
        raise ContractError(f"no .jsonl shards found under {inbox}")
    rows = read_jsonl_files(files)
    record_ids = [row["recordId"] for row in rows]
    if len(record_ids) != len(set(record_ids)):
        raise ContractError("Inbox contains duplicate recordId values")
    contexts: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        contexts[_context_key(row)].append(row)
    report = {"schemaVersion": 1, "inbox": str(inbox.resolve()), "admitted": False,
              "sourceFiles": [{"name": str(path.relative_to(inbox)), "sha256": _sha(path)} for path in files],
              "contexts": []}
    batch_source = json.dumps(report["sourceFiles"], sort_keys=True, separators=(",", ":")).encode("utf-8")
    batch_id = hashlib.sha256(batch_source).hexdigest()[:20]
    if admit:
        existing_rows = read_jsonl_files(sorted(validated_root.rglob("*.jsonl"))) if validated_root.is_dir() else []
        existing_ids = {row["recordId"] for row in existing_rows}
        overlap = existing_ids.intersection(record_ids)
        if overlap:
            raise ContractError(f"admission would duplicate {len(overlap)} validated recordId value(s)")
    for context_key, context_rows in sorted(contexts.items()):
        by_lineage: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for row in context_rows:
            by_lineage[row["lineageId"]].append(row)
        split = _split_lineages(sorted(by_lineage))
        counts = {name: {"lineages": 0, "labels": 0} for name in ("train", "validation", "holdout")}
        for lineage, lineage_rows in by_lineage.items():
            target = counts[split[lineage]]
            target["lineages"] += 1
            target["labels"] += len(lineage_rows)
        context_report = {"contextId": context_key, "skill": context_rows[0]["skill"],
                          "scenario": context_rows[0]["scenario"], "engine": context_rows[0]["engine"],
                          "rows": len(context_rows), "splitCounts": counts,
                          "gate1Ready": counts["train"]["lineages"] >= 8 and counts["holdout"]["lineages"] >= 5
                          and counts["train"]["labels"] >= 128 and counts["holdout"]["labels"] >= 50}
        report["contexts"].append(context_report)
        if admit:
            for split_name in ("train", "validation", "holdout"):
                destination = validated_root / split_name / context_key
                destination.mkdir(parents=True, exist_ok=True)
                selected = [row for row in context_rows if split[row["lineageId"]] == split_name]
                if not selected:
                    continue
                shard_path = destination / f"exact_observations_{batch_id}.jsonl"
                if shard_path.exists():
                    raise ContractError(f"validated batch already exists: {shard_path.name}")
                temporary = shard_path.with_suffix(shard_path.suffix + ".tmp")
                temporary.write_text("".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in selected), encoding="utf-8")
                temporary.replace(shard_path)
            manifest_path = validated_root / "context_manifests" / context_key / f"{batch_id}.json"
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            manifest = {"schemaVersion": 1, "contextId": context_key, "engine": context_rows[0]["engine"],
                        "skill": context_rows[0]["skill"], "scenario": context_rows[0]["scenario"],
                        "sourceFiles": report["sourceFiles"], "lineageSplits": split,
                        "rows": counts, "admittedUtc": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat()}
            if manifest_path.exists():
                raise ContractError(f"context manifest already exists: {manifest_path.name}")
            temporary = manifest_path.with_suffix(".json.tmp")
            temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
            temporary.replace(manifest_path)
    report["admitted"] = admit
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inbox", type=Path, required=True)
    parser.add_argument("--validated-root", type=Path, required=True)
    parser.add_argument("--admit", action="store_true", help="Copy passing, reviewed exact shards into the validated lineage split")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)
    try:
        report = audit(args.inbox, args.validated_root, args.admit)
    except (OSError, ContractError) as exc:
        print(json.dumps({"status": "rejected", "reason": str(exc)}, indent=2), file=sys.stderr)
        return 2
    encoded = json.dumps(report, indent=2, sort_keys=True)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(encoded, encoding="utf-8")
    print(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
