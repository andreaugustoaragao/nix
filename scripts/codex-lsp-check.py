#!/usr/bin/env python3
"""Exercise real language servers through the packaged MCP launcher."""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import shutil
import subprocess
import threading
import time


class Client:
    def __init__(self, command, cwd, log):
        self.events = []
        self.responses = queue.Queue()
        self.stderr = open(log, "w")
        self.proc = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=self.stderr,
                                     text=True, start_new_session=True)
        self.counter = 0
        threading.Thread(target=self.read, daemon=True).start()
        self.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                    "clientInfo": {"name": "codex-lsp-check", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def read(self):
        for line in self.proc.stdout:
            try:
                self.responses.put(json.loads(line))
            except json.JSONDecodeError:
                self.responses.put({"reader_error": line})
        self.responses.put({"reader_error": "server closed stdout"})

    def send(self, value):
        self.proc.stdin.write(json.dumps(value) + "\n")
        self.proc.stdin.flush()

    def request(self, method, params=None, timeout=60):
        self.counter += 1
        ident = self.counter
        start = time.monotonic()
        self.send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params or {}})
        while True:
            remaining = timeout - (time.monotonic() - start)
            if remaining <= 0:
                raise TimeoutError(method)
            try:
                message = self.responses.get(timeout=remaining)
            except queue.Empty as error:
                raise TimeoutError(method) from error
            if "reader_error" in message:
                raise RuntimeError(message["reader_error"])
            if "method" in message and "id" in message:
                result = {"roots": []} if message["method"] == "roots/list" else {}
                self.send({"jsonrpc": "2.0", "id": message["id"], "result": result})
                continue
            if message.get("id") != ident:
                continue
            self.events.append({"method": method, "params": params,
                                "seconds": time.monotonic() - start, "response": message})
            if "error" in message:
                raise RuntimeError(json.dumps(message["error"]))
            return message["result"]

    def call(self, name, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            raise RuntimeError(json.dumps(result))
        return result

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGTERM)
            self.proc.wait(timeout=5)
            raise RuntimeError("MCP did not exit after stdin EOF")
        finally:
            self.stderr.close()


FIXTURES = {
    "go": {
        "files": {"go.mod": "module example.com/lspcheck\n\ngo 1.24\n",
                  "math.go": "package sample\n\nfunc Double(v int) int { return v * 2 }\n",
                  "use.go": "package sample\n\nvar Answer = Double(21)\n"},
        "source": "use.go", "definition": "math.go", "symbol": "Double",
        "error": ("21", '"bad"'), "error_marker": "string",
    },
    "rust": {
        "files": {"Cargo.toml": '[package]\nname="lspcheck"\nversion="0.1.0"\nedition="2021"\n',
                  "src/math.rs": "pub fn double(v: i32) -> i32 { v * 2 }\n",
                  "src/lib.rs": "pub mod math;\npub fn answer() -> i32 { math::double(21) }\n"},
        "source": "src/lib.rs", "definition": "src/math.rs", "symbol": "double",
        "error": ("21", '"bad"'), "error_marker": "E0308",
    },
    "typescript": {
        "files": {"tsconfig.json": '{"compilerOptions":{"strict":true,"target":"ES2022","module":"commonjs"}}\n',
                  "math.ts": "export function double(v: number): number { return v * 2; }\n",
                  "use.ts": 'import { double } from "./math";\nexport const answer = double(21);\n'},
        "source": "use.ts", "definition": "math.ts", "symbol": "double",
        "error": ("21", '"bad"'), "error_marker": "string",
    },
    "nix": {
        "files": {"flake.nix": '{ outputs = { self }: {}; }\n',
                  "default.nix": "let\n  double = n: n * 2;\n  answer = double 21;\nin answer\n"},
        "source": "default.nix", "definition": "default.nix", "symbol": "double",
        "error": ("in answer", "in missingName"), "error_marker": "undefined_name",
    },
}


FIXTURES["tsx"] = {
    "files": {
        "tsconfig.json": '{"compilerOptions":{"strict":true,"jsx":"preserve"}}\n',
        "view.tsx": "export function Label(props: { text: string }) { return props.text; }\n",
        "use.tsx": 'import { Label } from "./view";\nexport const view = <Label text="ok" />;\n',
    },
    "source": "use.tsx", "definition": "view.tsx", "symbol": "Label",
    "error": ('text="ok"', "text={123}"), "error_marker": "2322",
}


def position(path, token, last=True):
    text = path.read_text()
    offset = text.rfind(token) if last else text.find(token)
    assert offset >= 0
    return {"file_path": str(path), "line": text[:offset].count("\n") + 1,
            "character": offset - text.rfind("\n", 0, offset)}


def data(result):
    if "structuredContent" in result:
        return result["structuredContent"]
    return result


def check(language, binary, work):
    fixture = FIXTURES[language]
    root = work / language
    root.mkdir()
    for rel, text in fixture["files"].items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    source, definition = root / fixture["source"], root / fixture["definition"]
    # Starting below the root exercises automatic ancestor discovery.
    launch = root / "nested" / "launch"
    launch.mkdir(parents=True)
    client = Client([binary], launch, work / (language + ".stderr.log"))
    report = {"language": language, "root": str(root), "checks": {}}
    try:
        tools = client.request("tools/list")["tools"]
        report["tools"] = [t["name"] for t in tools]
        report["initial_status"] = data(client.call("get_server_status"))
        assert all(not s["running"] for s in report["initial_status"]["statuses"])
        report["checks"]["lazy_startup"] = True
        symbols = data(client.call("get_document_symbols", file_path=str(definition)))
        assert fixture["symbol"] in {s["name"] for s in symbols["symbols"]}, symbols
        report["checks"]["symbols"] = True
        target = data(client.call("find_definition_at", **position(source, fixture["symbol"])))
        report["definition"] = target
        assert str(definition) in {d["file_path"] for d in target["definitions"]}, target
        report["checks"]["definition"] = True
        refs = data(client.call("find_references_at", **position(definition, fixture["symbol"], False)))
        report["references"] = refs
        assert str(source) in {r["file_path"] for r in refs["references"]}, refs
        report["checks"]["references"] = True
        report["hover"] = data(client.call("hover_at", **position(definition, fixture["symbol"], False)))
        assert report["hover"].get("hover"), report["hover"]
        report["checks"]["hover"] = True
        before = {rel: (root / rel).read_text() for rel in fixture["files"]}
        rename = data(client.call("rename_symbol", file_path=str(definition),
                                  symbol_name=fixture["symbol"], new_name="renamedDouble"))
        report["rename"] = rename
        assert rename.get("dry_run") is True, rename
        edits = rename.get("edit", {}).get("files", [])
        assert {str(source), str(definition)} <= {f["file_path"] for f in edits}, rename
        assert all(e["newText"] == "renamedDouble" for f in edits for e in f["edits"]), rename
        assert before == {rel: (root / rel).read_text() for rel in fixture["files"]}
        assert not list(root.rglob("*.bak"))
        report["checks"]["rename_preview_without_writes"] = True
        good = source.read_text()
        source.write_text(good.replace(*fixture["error"]))
        for _ in range(15):
            errors = data(client.call("get_diagnostics", file_path=str(source)))
            if fixture["error_marker"].lower() in json.dumps(errors["diagnostics"]).lower():
                break
            time.sleep(0.2)
        else:
            raise AssertionError({"missing_expected_diagnostic": errors})
        report["error_diagnostics"] = errors
        report["checks"]["diagnostics_after_external_edit"] = True
        source.write_text(good)
        for _ in range(15):
            clean = data(client.call("get_diagnostics", file_path=str(source)))
            if not any(d.get("severity") == 1 for d in clean["diagnostics"]):
                break
            time.sleep(0.2)
        else:
            raise AssertionError({"stale_diagnostic_after_fix": clean})
        report["checks"]["diagnostics_after_fix"] = True
        report["final_status"] = data(client.call("get_server_status"))
        running = {s["server_id"] for s in report["final_status"]["statuses"] if s["running"]}
        assert running == {language}, running
        report["checks"]["only_requested_server_started"] = True
        report["passed"] = True
    except Exception as error:
        report["passed"] = False
        report["error"] = str(error)
    finally:
        report["events"] = client.events
        try:
            client.close()
        except Exception as error:
            report["passed"] = False
            report["shutdown_error"] = str(error)
    (work / (language + ".json")).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k in ("language", "passed", "checks", "error", "shutdown_error")}), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("--language", choices=list(FIXTURES), action="append")
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    args.binary = shutil.which(args.binary) or str(Path(args.binary).resolve())
    args.work = args.work.resolve()
    args.work.mkdir(parents=True, exist_ok=True)
    results = [check(lang, args.binary, args.work) for lang in (args.language or FIXTURES)]
    (args.work / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    raise SystemExit(0 if all(r["passed"] for r in results) else 1)


if __name__ == "__main__":
    main()
