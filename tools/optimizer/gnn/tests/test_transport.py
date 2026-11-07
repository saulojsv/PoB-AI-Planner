import json
import os
import socket
import socketserver
import secrets
import tempfile
import threading
import time
import unittest
from pathlib import Path

from tools.optimizer.gnn.service import RPCService
from tools.optimizer.gnn.transport import PIPE_PREFIX, serve_unix_socket, serve_windows_pipe


class TransportImportTests(unittest.TestCase):
    def test_daemon_transports_import_on_current_platform(self):
        from tools.optimizer.gnn import daemon

        self.assertTrue(callable(daemon.main))
        self.assertTrue(callable(serve_windows_pipe))


@unittest.skipUnless(hasattr(socket, "AF_UNIX") and hasattr(socketserver, "UnixStreamServer"),
                     "Unix domain sockets are unavailable")
class UnixTransportTests(unittest.TestCase):
    def test_authenticated_json_rpc_round_trip_over_local_socket(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "daemon.sock"
            stop = threading.Event()
            service = RPCService("local-token", temp)
            server = threading.Thread(target=serve_unix_socket, args=(service, path, stop), daemon=True)
            server.start()
            try:
                deadline = time.monotonic() + 3
                while not path.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.settimeout(2)
                client.connect(str(path))
                request = {"jsonrpc": "2.0", "id": 7, "method": "build_planner/status",
                           "params": {"authToken": "local-token"}}
                client.sendall((json.dumps(request) + "\n").encode())
                stream = client.makefile("rb")
                response = json.loads(stream.readline())
                self.assertEqual(response["result"]["status"], "ready")
                stream.close()
                client.close()
            finally:
                stop.set()
                server.join(timeout=3)
                service.close()
            self.assertFalse(server.is_alive())


@unittest.skipUnless(os.name == "nt", "Windows Named Pipe transport requires Windows")
class WindowsNamedPipeTests(unittest.TestCase):
    def test_authenticated_json_rpc_round_trip_over_named_pipe(self):
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                         wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel32.CreateFileW.restype = wintypes.HANDLE
        kernel32.WaitNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD]
        kernel32.WaitNamedPipeW.restype = wintypes.BOOL
        kernel32.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD,
                                       ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
        kernel32.WriteFile.restype = wintypes.BOOL
        kernel32.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                                      ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
        kernel32.ReadFile.restype = wintypes.BOOL
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]

        with tempfile.TemporaryDirectory() as temp:
            pipe_name = PIPE_PREFIX + secrets.token_hex(12)
            stop = threading.Event()
            service = RPCService("local-pipe-token", temp)
            server = threading.Thread(target=serve_windows_pipe, args=(service, pipe_name, stop), daemon=True)
            server.start()
            handle = None
            invalid = ctypes.c_void_p(-1).value
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    handle = kernel32.CreateFileW(pipe_name, 0xC0000000, 0, None, 3, 0, None)
                    if handle != invalid:
                        break
                    kernel32.WaitNamedPipeW(pipe_name, 100)
                self.assertNotEqual(handle, invalid, "the local Named Pipe did not become available")
                request = {"jsonrpc": "2.0", "id": 19, "method": "build_planner/status",
                           "params": {"authToken": "local-pipe-token"}}
                payload = (json.dumps(request) + "\n").encode()
                written = wintypes.DWORD(0)
                buffer = ctypes.create_string_buffer(payload)
                self.assertTrue(kernel32.WriteFile(handle, buffer, len(payload), ctypes.byref(written), None))
                self.assertEqual(written.value, len(payload))
                response_bytes = bytearray()
                while b"\n" not in response_bytes:
                    chunk = ctypes.create_string_buffer(4096)
                    read = wintypes.DWORD(0)
                    self.assertTrue(kernel32.ReadFile(handle, chunk, len(chunk), ctypes.byref(read), None))
                    self.assertGreater(read.value, 0)
                    response_bytes.extend(chunk.raw[:read.value])
                response = json.loads(bytes(response_bytes).split(b"\n", 1)[0])
                self.assertEqual(response["result"]["status"], "ready")
            finally:
                stop.set()
                if handle not in (None, invalid):
                    kernel32.CloseHandle(handle)
                server.join(timeout=5)
                service.close()
            self.assertFalse(server.is_alive())


if __name__ == "__main__":
    unittest.main()
