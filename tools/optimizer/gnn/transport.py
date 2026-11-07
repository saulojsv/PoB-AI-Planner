"""Local JSONL IPC: Windows Named Pipe or Unix Domain Socket only."""

from __future__ import annotations

import os
import socket
import socketserver
import threading
from pathlib import Path
from typing import Any

from .service import JsonLineSession, RPCService

PIPE_PREFIX = r"\\.\pipe\pob-ai-planner-"


def serve_windows_pipe(service: RPCService, pipe_name: str, stop: threading.Event) -> None:
    """Serve newline-delimited JSON-RPC through a same-user Windows named pipe."""
    if os.name != "nt":
        raise RuntimeError("Windows Named Pipe transport requires Windows")
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                         wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
                                         wintypes.DWORD, wintypes.LPVOID]
    kernel32.CreateNamedPipeW.restype = wintypes.HANDLE
    kernel32.ConnectNamedPipe.argtypes = [wintypes.HANDLE, wintypes.LPVOID]
    kernel32.ConnectNamedPipe.restype = wintypes.BOOL
    kernel32.SetNamedPipeHandleState.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD),
                                                 ctypes.POINTER(wintypes.DWORD), ctypes.POINTER(wintypes.DWORD)]
    kernel32.SetNamedPipeHandleState.restype = wintypes.BOOL
    kernel32.DisconnectNamedPipe.argtypes = [wintypes.HANDLE]
    kernel32.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                                  ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
    kernel32.ReadFile.restype = wintypes.BOOL
    kernel32.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD,
                                   ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
    kernel32.WriteFile.restype = wintypes.BOOL
    kernel32.FlushFileBuffers.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]

    invalid = ctypes.c_void_p(-1).value
    pipe_mode = 0x00000009  # PIPE_REJECT_REMOTE_CLIENTS | PIPE_NOWAIT; byte mode is zero.
    open_mode = 0x00000003  # PIPE_ACCESS_DUPLEX
    error_pipe_connected = 535
    error_pipe_listening = 536

    def serve_handle(handle: Any) -> None:
        write_lock = threading.Lock()

        def write(raw: bytes) -> None:
            offset = 0
            while offset < len(raw):
                chunk = raw[offset:offset + 16 * 1024]
                written = wintypes.DWORD(0)
                buffer = ctypes.create_string_buffer(chunk)
                if not kernel32.WriteFile(handle, buffer, len(chunk), ctypes.byref(written), None):
                    raise OSError(ctypes.get_last_error(), "WriteFile failed")
                if written.value == 0:
                    raise OSError("Named Pipe write returned zero bytes")
                offset += written.value

        session = JsonLineSession(service, write)
        pending = bytearray()
        try:
            while not stop.is_set():
                buffer = ctypes.create_string_buffer(16 * 1024)
                read = wintypes.DWORD(0)
                ok = kernel32.ReadFile(handle, buffer, len(buffer), ctypes.byref(read), None)
                if not ok or read.value == 0:
                    break
                pending.extend(buffer.raw[:read.value])
                if len(pending) > 16 * 1024 * 1024:
                    raise ValueError("IPC line exceeds 16 MiB")
                while True:
                    newline = pending.find(b"\n")
                    if newline < 0:
                        break
                    line = bytes(pending[:newline]).rstrip(b"\r")
                    del pending[:newline + 1]
                    if line:
                        with write_lock:
                            session.handle_line(line)
        finally:
            try:
                kernel32.FlushFileBuffers(handle)
            except Exception:
                pass
            kernel32.DisconnectNamedPipe(handle)
            kernel32.CloseHandle(handle)

    while not stop.is_set():
        handle = kernel32.CreateNamedPipeW(pipe_name, open_mode, pipe_mode, 4,
                                           1024 * 1024, 1024 * 1024, 1000, None)
        if handle == invalid:
            raise OSError(ctypes.get_last_error(), "CreateNamedPipeW failed")
        connected = False
        while not stop.is_set():
            connected = bool(kernel32.ConnectNamedPipe(handle, None))
            if connected or ctypes.get_last_error() == error_pipe_connected:
                connected = True
                break
            if ctypes.get_last_error() != error_pipe_listening:
                break
            stop.wait(0.05)
        if not connected:
            kernel32.CloseHandle(handle)
            continue
        blocking_mode = wintypes.DWORD(0)  # PIPE_WAIT for normal byte-stream reads after accept.
        if not kernel32.SetNamedPipeHandleState(handle, ctypes.byref(blocking_mode), None, None):
            kernel32.DisconnectNamedPipe(handle)
            kernel32.CloseHandle(handle)
            continue
        client = threading.Thread(target=serve_handle, args=(handle,), daemon=True)
        client.start()


class _UnixHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        server = self.server
        lock = threading.Lock()
        session = JsonLineSession(server.service, lambda raw: (self.wfile.write(raw), self.wfile.flush()))
        while not server.stop_event.is_set():
            line = self.rfile.readline(16 * 1024 * 1024 + 1)
            if not line:
                return
            if len(line) > 16 * 1024 * 1024:
                return
            with lock:
                session.handle_line(line.rstrip(b"\r\n"))


if hasattr(socketserver, "UnixStreamServer"):
    class _ThreadedUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        daemon_threads = True
        allow_reuse_address = False

        def __init__(self, path: str, service: RPCService, stop_event: threading.Event):
            self.service = service
            self.stop_event = stop_event
            super().__init__(path, _UnixHandler)
else:
    _ThreadedUnixServer = None


def serve_unix_socket(service: RPCService, path: str | Path, stop: threading.Event) -> None:
    if _ThreadedUnixServer is None or not hasattr(socket, "AF_UNIX"):
        raise RuntimeError("Unix Domain Sockets are not supported by this Python runtime")
    socket_path = Path(path)
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    server = _ThreadedUnixServer(str(socket_path), service, stop)
    try:
        os.chmod(socket_path, 0o600)
        while not stop.is_set():
            server.timeout = 0.25
            server.handle_request()
    finally:
        server.server_close()
        try:
            socket_path.unlink()
        except FileNotFoundError:
            pass
