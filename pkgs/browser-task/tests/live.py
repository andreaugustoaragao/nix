"""Exercise the native backend on owned pages in the managed development browser."""

import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
import urllib.request


HTML = b"""<!doctype html><html lang="en"><meta charset="utf-8">
<title>Native CDP fixture</title>
<style>body{font:18px sans-serif;padding:32px}button,input{margin:12px;padding:12px}
#covered{position:relative;width:200px;height:100px}
#cover{position:absolute;inset:0;background:#bbb;z-index:10}</style>
<h1>Native CDP fixture</h1>
<label>Name<input id="name"></label>
<button id="increment">Increment</button><p id="count">0</p>
<button id="replace">Replace control</button>
<button>Duplicate</button><button>Duplicate</button>
<div id="covered"><button>Covered</button><div id="cover"></div></div>
<div style="height:1600px"></div><button id="bottom">Bottom</button>
<script>
window.inputs=[];window.clicks=[];window.keys=[];
document.addEventListener('input',e=>inputs.push({trusted:e.isTrusted,value:e.target.value}));
document.addEventListener('click',e=>clicks.push({trusted:e.isTrusted,id:e.target.id}));
document.addEventListener('keydown',e=>keys.push({trusted:e.isTrusted,key:e.key}));
increment.onclick=()=>count.textContent=String(Number(count.textContent)+1);
replace.onclick=()=>increment.replaceWith(increment.cloneNode(true));
</script></html>"""


@contextmanager
def fixture():
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            content_type = "text/html; charset=utf-8"
            if self.path == "/slow.js":
                time.sleep(0.75)
                body = b"window.deferredReady = true;"
                content_type = "text/javascript"
            elif self.path == "/deferred":
                body = b'<!doctype html><title>Deferred script</title><script defer src="/slow.js"></script><h1>Deferred</h1>'
            elif self.path == "/next":
                body = b"<!doctype html><title>Next document</title><h1>Arrived</h1>"
            else:
                body = HTML
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class Browser:
    def __init__(self, command, root):
        self.command = [command, "--state-dir", str(root)]
        self.root = root
        self.tasks = []

    def run(self, *args, action=None, ok=True, timeout=40):
        result = subprocess.run(
            self.command + list(args), input=json.dumps(action) if action is not None else None,
            text=True, capture_output=True, timeout=timeout,
        )
        if ok:
            assert result.returncode == 0, (args, result.stderr, result.stdout)
            return json.loads(result.stdout)
        assert result.returncode != 0, (args, result.stdout)
        return result.stderr + result.stdout

    def start(self, label, url):
        task = self.run("start", "development", "--label", label, "--url", url)
        self.tasks.append(task["task"])
        return task["task"]

    def action(self, task, kind, page="main", ok=True, **parameters):
        return self.run("action", task, "--page", page, action={"type": kind, **parameters}, ok=ok)

    def value(self, task, expression, page="main"):
        return self.action(task, "evaluate", page=page, expression=expression)["value"]

    def expire(self, task):
        path = self.root / task / "task.json"
        if not path.exists():
            return
        record = json.loads(path.read_text())
        record["state"] = "finished"
        record["finished_at"] = time.time() - 3601
        path.write_text(json.dumps(record))

    def cleanup(self):
        for path in self.root.glob("*/task.json"):
            self.expire(path.parent.name)
        return self.run("cleanup")


def targets(port):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f"http://127.0.0.1:{port}/json/list", timeout=5) as response:
        return {item["id"] for item in json.load(response) if item["type"] == "page"}


def check(command, port, artifacts=None):
    before = targets(port)
    report = {"checks": [], "screenshot": None}
    with tempfile.TemporaryDirectory(prefix="browser-native-live-") as temporary, fixture() as url:
        browser = Browser(command, Path(temporary))
        try:
            first = browser.start("Native CDP verification", url)
            second = browser.start("Native CDP isolation", url + "/next")
            assert browser.value(first, "document.title") == "Native CDP fixture"
            assert browser.value(second, "document.title") == "Next document"
            report["checks"].append("separate task targets and completed navigation")

            snapshot = browser.action(first, "snapshot")
            assert "Increment" in snapshot["text"] and "Name" in snapshot["text"]
            assert "truncated" in snapshot
            def increment_ref(value):
                line = next(line for line in value["text"].splitlines() if 'button "Increment"' in line)
                return re.search(r"\[ref=([^\]]+)\]", line).group(1)

            old_ref = increment_ref(snapshot)
            fresh = browser.action(first, "snapshot")
            assert increment_ref(fresh) != old_ref
            browser.action(first, "click", target={"ref": old_ref}, ok=False)
            stale = increment_ref(fresh)
            browser.value(first, "document.querySelector('#increment').replaceWith(document.querySelector('#increment').cloneNode(true))")
            browser.action(first, "click", target={"ref": stale}, ok=False)
            browser.value(first, "(() => { document.querySelector('#increment').onclick=()=>document.querySelector('#count').textContent=String(Number(document.querySelector('#count').textContent)+1); return true; })()")
            report["checks"].append("old snapshot and detached DOM references cannot retarget")
            browser.action(first, "fill", target={"role": "textbox", "name": "Name"}, text="Native Rust")
            assert browser.value(first, "document.querySelector('#name').value") == "Native Rust"
            assert browser.value(first, "inputs.length > 0 && inputs.every(e => e.trusted)") is True
            browser.action(first, "click", target={"role": "button", "name": "Increment"})
            assert browser.value(first, "document.querySelector('#count').textContent") == "1"
            assert browser.value(first, "clicks.some(e => e.id === 'increment' && e.trusted)") is True
            browser.action(first, "key", key="Tab")
            assert browser.value(first, "keys.some(e => e.key === 'Tab' && e.trusted)") is True
            report["checks"].append("AX role selection, trusted fill/click/keyboard")

            browser.action(first, "click", target={"role": "button", "name": "Duplicate"}, ok=False)
            browser.action(first, "click", target={"role": "button", "name": "Covered"}, ok=False)
            report["checks"].append("ambiguous and obscured target rejection")

            browser.action(first, "wait", target={"role": "button", "name": "Increment"}, state="visible")
            browser.value(first, "(document.querySelector('#increment').hidden=true, true)")
            browser.action(first, "wait", target={"role": "button", "name": "Increment"}, state="hidden")
            browser.value(first, "(document.querySelector('#increment').hidden=false, true)")
            report["checks"].append("wait resolves changing visibility")

            browser.value(first, "(() => { const d=document.createElement('div'); d.id='many'; for(let i=0;i<1000;i++) { const b=document.createElement('button'); b.textContent='Extra '+i; d.append(b); } document.body.append(d); return true; })()")
            bounded = browser.action(first, "snapshot", max_nodes=25, max_chars=1000)
            assert bounded["truncated"] is True and len(bounded["text"].encode()) <= 1000
            browser.value(first, "document.querySelector('#many').remove()")
            report["checks"].append("large snapshot has explicit output bounds")

            browser.action(first, "viewport", width=800, height=600)
            assert browser.value(first, "({width:innerWidth,height:innerHeight})") == {"width": 800, "height": 600}
            browser.action(first, "click", target={"role": "button", "name": "Bottom"})
            assert browser.value(first, "clicks.some(e => e.id === 'bottom' && e.trusted)") is True
            previous_scroll = browser.value(first, "scrollY")
            assert previous_scroll > 0
            browser.action(first, "scroll", x=0, y=-2000)
            for _ in range(20):
                if browser.value(first, "scrollY") < previous_scroll:
                    break
                time.sleep(0.05)
            else:
                raise AssertionError("Scroll action did not move the document")
            report["checks"].append("viewport persistence, offscreen click and scrolling")

            browser.run("open", first, "--page", "other", "--url", url + "/next")
            assert browser.value(first, "document.title", page="other") == "Next document"
            assert browser.value(first, "document.title") == "Native CDP fixture"
            browser.action(first, "navigate", url=url + "/deferred")
            assert browser.value(first, "window.deferredReady") is True, "Navigate returned before DOMContentLoaded"
            browser.action(first, "navigate", url=url + "/deferred#anchor")
            assert browser.value(first, "window.deferredReady") is True
            browser.action(first, "navigate", url=url + "/next")
            assert browser.value(first, "document.title") == "Next document"
            report["checks"].append("named page isolation and document replacement")

            browser.run("keep", first)
            browser.action(first, "evaluate", expression="document.title", ok=False)
            browser.run("finish", first, ok=False)
            browser.run("resume", first)
            finished = browser.run("finish", first)
            assert browser.run("finish", first)["finished_at"] == finished["finished_at"]
            browser.action(first, "snapshot", ok=False)
            browser.run("resume", first)
            report["checks"].append("keep/resume/finish state rules and idempotent retention")

            browser.action(first, "viewport", width=1024, height=720)
            value = browser.action(first, "screenshot", full_page=True)
            path = Path(value["path"])
            png = path.read_bytes()
            assert png.startswith(b"\x89PNG\r\n\x1a\n")
            assert len(png) == value["bytes"]
            assert int.from_bytes(png[16:20], "big") == value["width"] == 1024
            assert int.from_bytes(png[20:24], "big") == value["height"] >= 720
            assert path.stat().st_mode & 0o077 == 0
            report["screenshot"] = "Full-page PNG captured privately in background"
            if artifacts:
                artifacts.mkdir(parents=True, exist_ok=True)
                saved = artifacts / "background-screenshot.png"
                saved.write_bytes(png)
                saved.chmod(0o600)
                report["screenshot_artifact"] = str(saved)

            browser.run("finish", first)
            browser.expire(first)
            cleaned = browser.run("cleanup")
            assert not cleaned.get("retry"), cleaned
            assert browser.value(second, "document.title") == "Next document"
            assert before <= targets(port), "Cleanup closed a preexisting tab"
            report["checks"].append("expired cleanup preserves other tasks and preexisting tabs")
        finally:
            cleanup = browser.cleanup()
            assert not cleanup.get("retry"), cleanup
    assert targets(port) == before, "Verification left owned tabs or closed preexisting tabs"
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("launcher")
    parser.add_argument("--port", type=int, default=9332)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    print(json.dumps(check(args.launcher, args.port, args.artifacts), indent=2))
