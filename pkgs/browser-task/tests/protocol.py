import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time


class Client:
    def __init__(self, command, directory, state_dir=None):
        self.stderr = (directory / "stderr.log").open("w+")
        command = [command] if isinstance(command, str) else command
        self.process = subprocess.Popen(
            command + ["--state-dir", str(state_dir or directory / "state"), "mcp"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.counter = 0

    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def call(self, method, params=None):
        self.counter += 1
        self.send({"jsonrpc": "2.0", "id": self.counter, "method": method, "params": params or {}})
        return self.receive(self.counter)

    def receive(self, request_id, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if b"\n" not in self.buffer:
                if not self.selector.select(max(0, deadline - time.monotonic())):
                    break
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    self.stderr.flush()
                    self.stderr.seek(0)
                    raise AssertionError("MCP exited: " + self.stderr.read())
                self.buffer += chunk
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                response = json.loads(line)
                assert response["jsonrpc"] == "2.0", response
                if response.get("id") == request_id:
                    return response
        raise AssertionError(f"MCP did not answer request {request_id}")

    def close(self):
        self.process.stdin.close()
        try:
            assert self.process.wait(timeout=5) == 0
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            self.selector.close()
            self.stderr.close()


def check(command):
    with tempfile.TemporaryDirectory(prefix="browser-protocol-") as temporary:
        root = Path(temporary)
        schema = json.loads(subprocess.check_output([command, "schema"], timeout=10))
        client = Client(command, root)
        try:
            initialized = client.call("initialize", {
                "protocolVersion": "2024-11-05", "capabilities": {},
                "clientInfo": {"name": "browser-task-protocol-check", "version": "1"},
            })
            assert "result" in initialized, initialized
            assert initialized["result"]["capabilities"].get("tools") is not None
            client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            listed = client.call("tools/list")["result"]["tools"]
            assert [tool["name"] for tool in listed] == ["dev_browser"], listed
            tool = listed[0]
            assert tool["inputSchema"] == schema
            assert set(schema["required"]) == {"task", "action"}, schema
            assert set(schema["properties"]) == {"task", "page", "timeout", "action"}, schema
            assert schema["properties"]["timeout"]["minimum"] == 1
            assert schema["properties"]["timeout"]["maximum"] == 300
            assert tool["annotations"]["readOnlyHint"] is False
            assert client.call("ping")["result"] == {}
            assert client.call("unknown/method")["error"]["code"] == -32601

            task = "b549bb92-25e7-4e76-b781-9cc6d3910b70"
            invalid = [
                {}, {"task": task, "script": "document.title"},
                {"task": "../../escape", "action": {"type": "snapshot"}},
                {"task": task, "page": "../main", "action": {"type": "snapshot"}},
                {"task": task, "timeout": 0, "action": {"type": "snapshot"}},
                {"task": task, "timeout": 301, "action": {"type": "snapshot"}},
                {"task": task, "action": {"type": "raw_cdp", "method": "Target.getTargets"}},
            ]
            for arguments in invalid:
                response = client.call("tools/call", {"name": "dev_browser", "arguments": arguments})
                assert "error" in response or response["result"].get("isError"), response
            missing = client.call("tools/call", {
                "name": "dev_browser", "arguments": {"task": task, "action": {"type": "snapshot"}},
            })
            assert missing["result"]["isError"], missing
            assert "content" in missing["result"], missing
            assert client.call("ping")["result"] == {}
            assert not (root / "escape").exists()
            client.process.stdin.write(b"{")
            client.process.stdin.flush()
            time.sleep(0.1)
            client.process.terminate()
            client.process.wait(timeout=3)
        finally:
            client.close()
    print("Native MCP discovery, shared schema, validation, errors, and EOF shutdown passed")


if __name__ == "__main__":
    check(sys.argv[1])
