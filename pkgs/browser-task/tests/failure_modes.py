import base64
import fcntl
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
from protocol import Client


class Peer:
    def __init__(self):
        self.instance = "fixture-instance-1"
        self.targets = {"manual": {"targetId": "manual", "type": "page", "title": "Manual", "url": "about:blank"}}
        self.calls = []
        self.stalled = threading.Event()
        self.next_target = 0
        self.connections = 0
        self.short_version = False
        self.stall_navigation = False
        peer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                if self.path == "/json/version":
                    body = json.dumps({"webSocketDebuggerUrl": f"ws://{self.headers['Host']}/devtools/browser/{peer.instance}"}).encode()
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body) + (64 if peer.short_version else 0)))
                    self.end_headers()
                    self.wfile.write(body)
                    self.close_connection = peer.short_version
                    return
                key = self.headers["Sec-WebSocket-Key"]
                peer.connections += 1
                accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept)
                self.end_headers()
                try:
                    while True:
                        head = self.rfile.read(2)
                        if len(head) != 2 or head[0] & 0x0F == 8:
                            break
                        length = head[1] & 0x7F
                        if length == 126:
                            length = struct.unpack("!H", self.rfile.read(2))[0]
                        elif length == 127:
                            length = struct.unpack("!Q", self.rfile.read(8))[0]
                        assert length <= 1024 * 1024
                        mask = self.rfile.read(4) if head[1] & 0x80 else None
                        data = self.rfile.read(length)
                        if mask:
                            data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
                        message = json.loads(data)
                        peer.calls.append(message)
                        result = peer.respond(message)
                        if result is None:
                            continue
                        payload = json.dumps({"id": message["id"], "result": result}).encode()
                        header = bytes([0x81, len(payload)]) if len(payload) < 126 else bytes([0x81, 126]) + struct.pack("!H", len(payload))
                        self.wfile.write(header + payload)
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                self.close_connection = True

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def port(self):
        return self.server.server_port

    def respond(self, message):
        method, params = message["method"], message.get("params", {})
        if method == "Target.getTargets":
            return {"targetInfos": list(self.targets.values())}
        if method == "Target.createTarget":
            assert params["background"] is True
            assert params.get("focus", False) is False
            self.next_target += 1
            target = f"owned-{self.next_target}"
            self.targets[target] = {"targetId": target, "type": "page", "title": "Owned", "url": "about:blank"}
            return {"targetId": target}
        if method == "Target.attachToTarget":
            assert params["targetId"] in self.targets
            assert params["targetId"] != "manual", "Backend attached to an unowned tab"
            return {"sessionId": "session-" + params["targetId"]}
        if method == "Target.closeTarget":
            assert params["targetId"] != "manual", "Cleanup closed an unowned tab"
            return {"success": self.targets.pop(params["targetId"], None) is not None}
        if method == "Page.getFrameTree":
            return {"frameTree": {"frame": {"id": "frame-main", "loaderId": "loader-1", "url": "about:blank"}}}
        if method == "Page.navigate" and self.stall_navigation:
            self.stalled.set()
            return None
        if method == "DOM.getDocument":
            return {"root": {"nodeId": 1, "backendNodeId": 1, "nodeName": "#document"}}
        if method == "Page.getLayoutMetrics":
            return {
                "cssContentSize": {"x": 0, "y": 0, "width": 800, "height": 600},
                "cssVisualViewport": {"clientWidth": 800, "clientHeight": 600, "pageX": 0, "pageY": 0, "scale": 1},
            }
        if method == "Runtime.evaluate":
            expression = params.get("expression", "")
            if "__native_stall__" in expression:
                self.stalled.set()
                return None
            if "readyState" in expression:
                return {"result": {"type": "string", "value": "complete"}}
            return {"result": {"type": "number", "value": 42}}
        if method == "Page.captureScreenshot":
            self.stalled.set()
            return None
        assert method != "Target.activateTarget", "Ordinary work activated the browser"
        return {}

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def check(launcher):
    peer = Peer()
    try:
        with tempfile.TemporaryDirectory(prefix="browser-native-failures-") as temporary:
            root = Path(temporary)
            config = root / "profiles.json"
            command = [launcher, "--config", str(config), "--state-dir", str(root / "tasks")]

            headless = {
                "development": {"port": 1, "appId": "fixture-development", "headless": True},
                "accounts": {"port": 2, "appId": "fixture-accounts", "headless": True},
            }
            config.write_text(json.dumps(headless))
            for args in [("show", "--profile", "development"), ("show",)]:
                result = subprocess.run(command + list(args), capture_output=True, text=True, timeout=5)
                assert result.returncode == 1 and "screenshot" in result.stderr, result
            for invalid in [
                {name: {key: value for key, value in profile.items() if key != "headless"}
                 for name, profile in headless.items()},
                {**headless, "development": {**headless["development"], "headless": "true"}},
            ]:
                config.write_text(json.dumps(invalid))
                result = subprocess.run(command + ["list"], capture_output=True, text=True, timeout=5)
                assert result.returncode == 1 and "Invalid managed browser config" in result.stderr, result
            config.write_text(json.dumps({
                "development": {"port": peer.port, "appId": "fixture-development", "headless": False},
                "accounts": {"port": 1, "appId": "fixture-accounts", "headless": False},
            }))

            peer.short_version = True
            truncated = subprocess.run(command + ["start", "development", "--label", "Truncated reply"], capture_output=True, text=True, timeout=5)
            assert truncated.returncode == 1 and "panicked" not in truncated.stderr, truncated
            peer.short_version = False

            def run(*args, action=None, ok=True):
                result = subprocess.run(command + list(args), input=json.dumps(action) if action else None,
                                        capture_output=True, text=True, timeout=15)
                if ok:
                    assert result.returncode == 0, (args, result.stderr, result.stdout)
                    return json.loads(result.stdout)
                assert result.returncode != 0, (args, result.stdout)
                return result.stderr + result.stdout

            task = run("start", "development", "--label", "Interruption fixture")
            task_id = task["task"]
            record_path = root / "tasks" / task_id / "task.json"
            legacy = json.loads(record_path.read_text())
            legacy.pop("viewports", None)
            legacy["resume_after"] = time.time() + 60
            record_path.write_text(json.dumps(legacy))
            run("action", task_id, action={"type": "evaluate", "expression": "40+2"}, ok=False)
            run("finish", task_id, ok=False)
            run("resume", task_id, ok=False)
            legacy["resume_after"] = None
            record_path.write_text(json.dumps(legacy))
            assert run("info", task_id)["state"] == "active"
            assert run("action", task_id, action={"type": "evaluate", "expression": "40+2"})["value"] == 42

            previous_connections = peer.connections
            client = Client(command, root, state_dir=root / "tasks")
            try:
                assert "result" in client.call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "failure-test", "version": "1"}})
                for _ in range(3):
                    result = client.call("tools/call", {"name": "dev_browser", "arguments": {"task": task_id, "action": {"type": "evaluate", "expression": "40+2"}}})
                    assert not result["result"].get("isError"), result
                assert peer.connections == previous_connections + 1, "Persistent MCP reopened its CDP WebSocket for each action"
                with (record_path.parent / "lock").open("a") as locked:
                    fcntl.flock(locked, fcntl.LOCK_EX)
                    client.send({"jsonrpc": "2.0", "id": 998, "method": "tools/call", "params": {"name": "dev_browser", "arguments": {"task": task_id, "timeout": 10, "action": {"type": "evaluate", "expression": "40+2"}}}})
                    time.sleep(0.1)
                    client.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 998}})
                    cancelled = client.receive(998, timeout=2)
                    assert cancelled["result"]["isError"], cancelled
                peer.stalled.clear()
                client.send({"jsonrpc": "2.0", "id": 999, "method": "tools/call", "params": {"name": "dev_browser", "arguments": {"task": task_id, "timeout": 10, "action": {"type": "evaluate", "expression": "__native_stall__"}}}})
                assert peer.stalled.wait(5)
                assert client.call("ping")["result"] == {}
                run("action", task_id, "--timeout", "1", action={"type": "evaluate", "expression": "40+2"}, ok=False)
                client.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 999}})
            finally:
                client.close()
            run("action", task_id, action={"type": "evaluate", "expression": "40+2"}, ok=False)
            run("resume", task_id)

            for interruption in (signal.SIGTERM, signal.SIGKILL):
                peer.stalled.clear()
                child = subprocess.Popen(command + ["action", task_id, "--timeout", "2"], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                child.stdin.write(json.dumps({"type": "evaluate", "expression": "__native_stall__"}))
                child.stdin.close()
                child.stdin = None
                try:
                    assert peer.stalled.wait(5), "Evaluation did not reach the CDP peer"
                    os.kill(child.pid, interruption)
                    child.communicate(timeout=6)
                    assert child.returncode != 0
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate()
                record = json.loads(record_path.read_text())
                record["resume_after"] = 0
                record_path.write_text(json.dumps(record))
                run("action", task_id, action={"type": "evaluate", "expression": "40+2"}, ok=False)
                run("finish", task_id, ok=False)
                run("resume", task_id)
                assert any(call["method"] == "Runtime.terminateExecution" for call in peer.calls)
                assert run("action", task_id, action={"type": "evaluate", "expression": "40+2"})["value"] == 42

            peer.stalled.clear()
            run("action", task_id, "--timeout", "1", action={"type": "screenshot"}, ok=False)
            assert peer.stalled.is_set(), "Screenshot was rejected before reaching the CDP peer"
            run("resume", task_id)

            peer.stall_navigation = True
            for args in (
                ["open", task_id, "--page", "main", "--url", "https://example.test"],
                ["start", "development", "--label", "Interrupted start", "--url", "https://example.test"],
            ):
                previous = set((root / "tasks").iterdir())
                peer.stalled.clear()
                child = subprocess.Popen(command + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    assert peer.stalled.wait(5), "Lifecycle navigation did not reach CDP"
                    child.terminate()
                    child.communicate(timeout=5)
                    assert child.returncode != 0
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate()
                affected = task_id if args[0] == "open" else next(iter(set((root / "tasks").iterdir()) - previous)).name
                assert run("info", affected)["state"] == "kept"
                run("finish", affected, ok=False)
                run("resume", affected)
                assert any(call["method"] == "Page.stopLoading" for call in peer.calls)
            peer.stall_navigation = False

            closed = task["pages"]["main"]
            del peer.targets[closed]
            run("open", task_id, "--page", "main", ok=False)
            assert closed not in peer.targets
            run("open", task_id, "--page", "replacement")
            done = run("finish", task_id)
            assert run("finish", task_id)["finished_at"] == done["finished_at"]
            expired = json.loads(record_path.read_text())
            expired["finished_at"] = time.time() - 3601
            record_path.write_text(json.dumps(expired))
            with (record_path.parent / "lock").open("a") as locked:
                fcntl.flock(locked, fcntl.LOCK_EX)
                assert task_id in run("cleanup")["busy"]
            run("resume", task_id)
            peer.instance = "fixture-instance-2"
            run("action", task_id, "--page", "replacement", action={"type": "evaluate", "expression": "40+2"}, ok=False)
            record = json.loads(record_path.read_text())
            record["state"] = "finished"
            record["finished_at"] = time.time() - 3601
            record_path.write_text(json.dumps(record))
            before = set(peer.targets)
            result = run("cleanup")
            assert task_id in result["stale"], result
            assert set(peer.targets) == before
            assert "manual" in peer.targets
    finally:
        peer.close()
    print("Native CDP cancellation, crash recovery, screenshot timeout, closed-page and restart ownership passed")


if __name__ == "__main__":
    check(sys.argv[1])
