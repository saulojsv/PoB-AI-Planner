"""JSON-RPC 2.0 service. It ranks native PoB proposals; it never certifies a build."""

from __future__ import annotations

import secrets
import threading
import time
import hashlib
import json
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from dataclasses import dataclass, field
from typing import Any, Callable

from .contracts import ContractError, validate_build_snapshot, validate_proposals, validate_run_spec
from .dataset import validate_training_row
from .graph import graph_record
from .model import rank_graph_records
from .registry import ModelRegistry

JSONRPC_ERROR = {"parse": -32700, "invalid_request": -32600, "method_not_found": -32601,
                 "invalid_params": -32602, "internal": -32603, "unauthorized": -32001,
                 "model_unavailable": -32010, "job_not_found": -32011}


@dataclass
class Job:
    job_id: str
    status: str = "queued"
    created_at: float = field(default_factory=time.monotonic)
    updated_at: float = field(default_factory=time.monotonic)
    processed: int = 0
    total: int = 0
    result: dict[str, Any] | None = None
    error: str | None = None
    cancel_event: threading.Event = field(default_factory=threading.Event)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            value = {"job_id": self.job_id, "status": self.status,
                     "progress": {"phase": "GNN ranking", "processed": self.processed, "total": self.total}}
            if self.result is not None:
                value["result"] = self.result
            if self.error:
                value["error"] = self.error
            return value


class RPCService:
    def __init__(self, token: str, approved_dir: str, *, inbox_dir: str | None = None, max_workers: int = 1):
        self._token = token
        self.registry = ModelRegistry(approved_dir)
        approved_path = Path(approved_dir)
        self.inbox_dir = Path(inbox_dir) if inbox_dir else approved_path.parent / "01_Inbox"
        self.executor = ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix="pob-gnn")
        self.jobs: dict[str, Job] = {}
        self.jobs_lock = threading.Lock()

    def close(self) -> None:
        self.executor.shutdown(wait=False, cancel_futures=True)

    def _authorize(self, params: dict[str, Any]) -> None:
        supplied = params.get("authToken")
        if not isinstance(supplied, str) or not secrets.compare_digest(supplied, self._token):
            raise PermissionError("local IPC authentication failed")

    @staticmethod
    def _compatible(package: dict[str, Any], run_spec: dict[str, Any], snapshot: dict[str, Any]) -> bool:
        manifest = package["manifest"]
        return (package["engine"] == snapshot["engine"]
                and manifest.get("skill") == {"effectId": snapshot["skill"]["effectId"], "gemId": snapshot["skill"]["gemId"]}
                and manifest.get("scenario") == run_spec["scenario"])

    def _find_model(self, params: dict[str, Any], run_spec: dict[str, Any], snapshot: dict[str, Any]) -> dict[str, Any] | None:
        requested = run_spec.get("modelPackageId") or params.get("modelPackageId")
        if requested:
            package = self.registry.get(requested)
            return package if package and self._compatible(package, run_spec, snapshot) else None
        for entry in self.registry.list_models(engine=snapshot["engine"],
                                               skill={"effectId": snapshot["skill"]["effectId"], "gemId": snapshot["skill"]["gemId"]},
                                               scenario=run_spec["scenario"]):
            package = self.registry.get(entry["packageId"])
            if package and self._compatible(package, run_spec, snapshot):
                return package
        return None

    def _rank_job(self, job: Job, package: dict[str, Any], run_spec: dict[str, Any],
                  snapshot: dict[str, Any], proposals: list[dict[str, Any]]) -> None:
        with job.lock:
            job.status = "running"
            job.total = len(proposals)
            job.updated_at = time.monotonic()

        def progress(processed: int, total: int) -> None:
            with job.lock:
                job.processed = processed
                job.total = total
                job.updated_at = time.monotonic()

        try:
            records = [graph_record(snapshot, proposal) for proposal in proposals]
            ranked = rank_graph_records(package, records, run_spec, job.cancel_event, progress)
            with job.lock:
                job.updated_at = time.monotonic()
                if job.cancel_event.is_set():
                    job.status = "cancelled"
                    job.result = None
                else:
                    exact_limit = run_spec["budget"]["maxExactEvaluations"]
                    ordered_ids = [row["proposalId"] for row in ranked]
                    job.status = "completed"
                    job.result = {
                        "rankedProposalIds": ordered_ids,
                        "proposalsRanked": len(ordered_ids),
                        "exactPrefixCount": min(len(ordered_ids), exact_limit),
                        "exactValidationRequired": True,
                        "predictionsAreNotBuildMetrics": True,
                    }
        except Exception as exc:  # Fail closed; Lua falls back to native input order.
            with job.lock:
                job.status = "failed"
                job.error = f"{type(exc).__name__}: {str(exc)[:500]}"
                job.updated_at = time.monotonic()

    def _start_optimize(self, params: dict[str, Any]) -> dict[str, Any]:
        run_spec = validate_run_spec(params.get("runSpec"))
        snapshot = validate_build_snapshot(params.get("buildSnapshot"))
        proposals = validate_proposals(params.get("proposals"))
        if snapshot["skill"] != run_spec["skill"] or snapshot["scenario"] != run_spec["scenario"]:
            raise ContractError("RunSpec skill/scenario do not match the native BuildSnapshot")
        if run_spec["modelMode"] == "deterministic_fallback":
            raise ContractError("deterministic fallback does not use the GNN daemon")
        package = self._find_model(params, run_spec, snapshot)
        if package is None:
            raise LookupError("no approved package matches the current skill, scenario, and PoB fingerprints")
        job = Job(job_id=secrets.token_urlsafe(18), total=len(proposals))
        with self.jobs_lock:
            now = time.monotonic()
            self.jobs = {key: value for key, value in self.jobs.items() if now - value.created_at < 1800}
            if len(self.jobs) >= 64:
                raise ContractError("local daemon job capacity is full")
            self.jobs[job.job_id] = job
        self.executor.submit(self._rank_job, job, package, run_spec, snapshot, proposals)
        return {"job_id": job.job_id, "status": job.status, "proposalsReceived": len(proposals),
                "modelPackageId": package["packageId"], "exactValidationRequired": True}

    def _export_dataset(self, params: dict[str, Any]) -> dict[str, Any]:
        if params.get("consent") is not True or params.get("rightsBasis") != "user_authored":
            raise ContractError("export requires explicit offline-training consent and the user-authored-build attestation")
        raw_rows = params.get("records")
        if not isinstance(raw_rows, list) or not 1 <= len(raw_rows) <= 250:
            raise ContractError("export requires 1 to 250 exact native candidate rows")
        rows = [validate_training_row(row) for row in raw_rows]
        context = {(json.dumps(row["engine"], sort_keys=True), json.dumps(row["skill"], sort_keys=True),
                    json.dumps(row["scenario"], sort_keys=True), json.dumps(row["runSpec"], sort_keys=True),
                    row["lineageId"], row["setId"]) for row in rows}
        if len(context) != 1:
            raise ContractError("one export shard must contain one build lineage, skill, scenario, RunSpec, and proposal set")
        payload = "".join(json.dumps(row, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n" for row in rows).encode("utf-8")
        if len(payload) > 16 * 1024 * 1024:
            raise ContractError("sanitized exact shard exceeds the 16 MiB IPC/export limit")
        digest = hashlib.sha256(payload).hexdigest()
        self.inbox_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        filename = f"exact_gnn_{stamp}_{digest[:16]}.jsonl"
        destination = (self.inbox_dir / filename).resolve()
        inbox_root = self.inbox_dir.resolve()
        if inbox_root != destination.parent:
            raise ContractError("export path must stay inside the configured inbox")
        if destination.exists():
            raise FileExistsError("an identical shard already exists in the inbox")
        temporary = destination.with_suffix(destination.suffix + ".tmp")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        descriptor = os.open(temporary, flags, 0o600)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, destination)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
        return {"status": "inbox", "fileName": filename, "sha256": digest, "rows": len(rows),
                "directory": str(inbox_root)}

    def call(self, message: Any) -> dict[str, Any] | None:
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0" or not isinstance(message.get("method"), str):
            return {"jsonrpc": "2.0", "id": message.get("id") if isinstance(message, dict) else None,
                    "error": {"code": JSONRPC_ERROR["invalid_request"], "message": "Invalid JSON-RPC 2.0 request"}}
        request_id = message.get("id")
        notification = "id" not in message
        params = message.get("params", {})
        if not isinstance(params, dict):
            response = {"error": {"code": JSONRPC_ERROR["invalid_params"], "message": "params must be an object"}}
            return None if notification else {"jsonrpc": "2.0", "id": request_id, **response}
        try:
            self._authorize(params)
            method = message["method"]
            if method == "build_planner/status":
                result = {"status": "ready", "schemaVersion": 1, "approvedModelCount": len(self.registry.list_models())}
            elif method == "build_planner/list_models":
                result = {"models": self.registry.list_models(
                    engine=params.get("engine"), skill=params.get("skill"), scenario=params.get("scenario"))}
            elif method == "build_planner/optimize":
                result = self._start_optimize(params)
            elif method == "build_planner/export_dataset":
                result = self._export_dataset(params)
            elif method == "build_planner/poll":
                job = self.jobs.get(str(params.get("job_id", "")))
                if job is None:
                    raise KeyError("unknown or expired job_id")
                result = job.snapshot()
            elif method == "build_planner/cancel":
                job = self.jobs.get(str(params.get("job_id", "")))
                if job is None:
                    raise KeyError("unknown or expired job_id")
                job.cancel_event.set()
                result = {"job_id": job.job_id, "status": "cancelling"}
            else:
                raise NotImplementedError(f"unknown method: {method}")
            response = {"jsonrpc": "2.0", "id": request_id, "result": result}
        except PermissionError as exc:
            response = {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": JSONRPC_ERROR["unauthorized"], "message": str(exc)}}
        except LookupError as exc:
            response = {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": JSONRPC_ERROR["model_unavailable"], "message": str(exc)}}
        except NotImplementedError as exc:
            response = {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": JSONRPC_ERROR["method_not_found"], "message": str(exc)}}
        except KeyError as exc:
            response = {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": JSONRPC_ERROR["job_not_found"], "message": str(exc).strip("'")}}
        except ContractError as exc:
            response = {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": JSONRPC_ERROR["invalid_params"], "message": str(exc)}}
        except Exception as exc:
            response = {"jsonrpc": "2.0", "id": request_id,
                        "error": {"code": JSONRPC_ERROR["internal"], "message": f"{type(exc).__name__}: {str(exc)[:500]}"}}
        return None if notification else response


class JsonLineSession:
    """One byte-stream client; responses are newline-delimited JSON-RPC objects."""
    def __init__(self, service: RPCService, write: Callable[[bytes], None]):
        self.service = service
        self.write = write
        self.lock = threading.Lock()

    def handle_line(self, raw: bytes) -> None:
        import json
        if len(raw) > 16 * 1024 * 1024:
            raise ValueError("IPC message exceeds 16 MiB")
        try:
            message = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            response = {"jsonrpc": "2.0", "id": None,
                        "error": {"code": JSONRPC_ERROR["parse"], "message": "Invalid JSON"}}
        else:
            response = self.service.call(message)
        if response is not None:
            encoded = (json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
            with self.lock:
                self.write(encoded)
