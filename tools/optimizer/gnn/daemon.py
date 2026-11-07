"""Start the per-user PoB AI Planner worker service."""

from __future__ import annotations

import argparse
import json
import os
import secrets
import signal
import sys
import threading
import time
from pathlib import Path

from .transport import PIPE_PREFIX, serve_unix_socket, serve_windows_pipe
from .service import RPCService


def _default_runtime_dir() -> Path:
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    else:
        base = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    return base / "PathOfBuilding" / "AIPlanner"


def _write_json_atomic(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True), encoding="utf-8")
    if os.name != "nt":
        os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Local GNN ranker for the native Path of Building optimizer")
    parser.add_argument("--runtime-dir", type=Path, default=_default_runtime_dir())
    parser.add_argument("--approved-dir", type=Path,
                        default=Path(os.environ.get("POB_AI_APPROVED_DIR", r"G:\O meu disco\00 - Projetos\PoB - IA\04_Models_Approved")))
    parser.add_argument("--check", action="store_true", help="Print whether the private runtime has torch/PyG")
    args = parser.parse_args(argv)
    if args.check:
        try:
            from .model import require_runtime
            require_runtime()
            print(json.dumps({"torch_geometric": "available"}))
            return 0
        except Exception as exc:
            print(json.dumps({"torch_geometric": "unavailable", "reason": str(exc)}))
            return 2

    args.runtime_dir.mkdir(parents=True, exist_ok=True)
    if os.name != "nt":
        os.chmod(args.runtime_dir, 0o700)
    token = secrets.token_urlsafe(32)
    stop = threading.Event()
    protocol = "windows_named_pipe" if os.name == "nt" else "unix_domain_socket"
    if os.name == "nt":
        pipe_name = PIPE_PREFIX + secrets.token_hex(20)
        endpoint = {"protocol": protocol, "address": pipe_name, "authToken": token, "pid": os.getpid(), "createdUtc": time.time()}
        _write_json_atomic(args.runtime_dir / "endpoint.json", endpoint)
        service = RPCService(token, str(args.approved_dir))
        print(json.dumps({"status": "ready", "protocol": protocol, "endpoint": str(args.runtime_dir / "endpoint.json")}), flush=True)
        try:
            serve_windows_pipe(service, pipe_name, stop)
        except KeyboardInterrupt:
            stop.set()
        finally:
            service.close()
            try:
                (args.runtime_dir / "endpoint.json").unlink()
            except FileNotFoundError:
                pass
    else:
        address = args.runtime_dir / ("pob-ai-" + secrets.token_hex(12) + ".sock")
        endpoint = {"protocol": protocol, "address": str(address), "authToken": token, "pid": os.getpid(), "createdUtc": time.time()}
        _write_json_atomic(args.runtime_dir / "endpoint.json", endpoint)
        service = RPCService(token, str(args.approved_dir))
        print(json.dumps({"status": "ready", "protocol": protocol, "endpoint": str(args.runtime_dir / "endpoint.json")}), flush=True)
        try:
            serve_unix_socket(service, address, stop)
        except KeyboardInterrupt:
            stop.set()
        finally:
            service.close()
            try:
                (args.runtime_dir / "endpoint.json").unlink()
            except FileNotFoundError:
                pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
