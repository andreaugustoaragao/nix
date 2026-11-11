"""Live handoff verification against the existing managed development browser."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from live import Browser, fixture


def check(command, old_command=None, app=None):
    with tempfile.TemporaryDirectory(prefix="browser-assistance-check-") as root, fixture() as url:
        browser = Browser(command, Path(root))
        task = browser.start("Browser assistance verification", url)
        try:
            browser.value(task, "(() => {const a=document.createElement('a'); a.href='/next'; a.textContent='Next page'; document.body.prepend(a); return true})()")
            point = browser.value(task, "(() => {const r=document.querySelector('#increment').getBoundingClientRect(); return {x:r.left+r.width/2,y:r.top+r.height/2}})()")
            handoff = browser.run("assist-begin", task, "--prompt", "Enter your name")
            token = handoff["token"]
            assert len(token) == 64
            info = browser.run("info", task)
            assert info["state"] == "assisting"
            assert info["assistance"]["prompt"] == "Enter your name"
            assert "token" not in json.dumps(info)
            if old_command:
                old = subprocess.run([old_command, "--state-dir", root, "resume", task], capture_output=True, text=True, timeout=40)
                assert old.returncode != 0, "Older clients must not resume assistance tasks"
                assert browser.run("info", task)["state"] == "assisting"
            for args in [("resume", task), ("finish", task), ("keep", task), ("open", task, "--page", "other")]:
                assert "user controls" in browser.run(*args, ok=False)
            assert "user controls" in browser.action(task, "evaluate", expression="document.title", ok=False)

            def user(action, session=token, ok=True):
                result = subprocess.run(browser.command + ["assist-action", task], input=json.dumps({"token": session, "action": action}), text=True, capture_output=True, timeout=40)
                if not ok:
                    assert result.returncode != 0
                    return result.stderr
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)

            frame = user({"type": "frame"})
            assert frame["png"].startswith("iVBOR")
            assert frame["location"]["origin"] == url
            assert not list(Path(root).rglob("screenshot-*.png"))
            binding = {"document": frame["document"], "origin": url}
            field = next(c for c in frame["controls"] if c["field"] and c["label"] == "Name")
            secret = "private-fixture-value-8921"
            assert "expired" in user({"type": "frame"}, session="wrong", ok=False)
            assert "page changed" in user({"type": "fill", **binding, "document": "stale", "reference": field["reference"], "text": secret}, ok=False)
            assert "page changed" in user({"type": "fill", **binding, "origin": "https://other.invalid", "reference": field["reference"], "text": secret}, ok=False)
            user({"type": "fill", **binding, "reference": field["reference"], "text": secret})
            user({"type": "key", **binding, "key": "End"})
            user({"type": "text", **binding, "text": "-suffix"})
            frame = user({"type": "frame"})
            increment = next(c for c in frame["controls"] if c["label"] == "Increment")
            user({"type": "press", **binding, "reference": increment["reference"]})
            user({"type": "click", **binding, **point})
            for path in Path(root).rglob("*"):
                if path.is_file():
                    assert secret.encode() not in path.read_bytes(), path
            assert not list(Path(root).rglob("screenshot-*.png"))
            result = subprocess.run(browser.command + ["assist-end", task, "--result", "continue"], input=json.dumps(token), text=True, capture_output=True, timeout=40)
            assert result.returncode == 0, result.stderr
            assert "assistance" not in json.loads(result.stdout)
            assert browser.value(task, "document.querySelector('input').value") == secret + "-suffix"
            assert browser.value(task, "document.querySelector('#count').textContent") == "2"
            # Returning control invalidates refs and old handoff capabilities.
            assert "expired" in user({"type": "frame"}, ok=False)
            second = browser.run("assist-begin", task)
            frame = user({"type": "frame"}, session=second["token"])
            next_page = next(c for c in frame["controls"] if c["label"] == "Next page")
            user({"type": "press", "document": frame["document"], "origin": url, "reference": next_page["reference"]}, session=second["token"])
            new_frame = user({"type": "frame"}, session=second["token"])
            assert new_frame["location"]["url"] == url + "/next"
            assert "page changed" in user({"type": "text", **binding, "text": secret}, session=second["token"], ok=False)
            assert not new_frame["controls"]
            browser.run("assist-cancel", task)
            assert browser.run("info", task)["state"] == "kept"
            browser.run("resume", task)
            assert browser.value(task, "document.title") == "Next document"
            if app:
                ui_task = browser.start("Rune private input verification", url)
                ui_secret = "rune-private-fixture-3812"
                tree = Path(root) / "ui-tree.json"
                preview = subprocess.run([app, "--task", ui_task, "--state-dir", root,
                    "--snap", str(Path(root) / "preview.png"), "--tree", str(tree)],
                    capture_output=True, text=True, timeout=90)
                assert preview.returncode == 0, preview.stderr[-2000:]
                def walk(value):
                    if isinstance(value, dict):
                        yield value
                        for child in value.values():
                            yield from walk(child)
                    elif isinstance(value, list):
                        for child in value:
                            yield from walk(child)
                field_key = next(node["key"] for node in walk(json.loads(tree.read_text()))
                    if str(node.get("key", "")).startswith("field-") and (node.get("label") == "Name" or node.get("name") == "Name"))
                browser.run("resume", ui_task)
                script = Path(root) / "ui-script.json"
                script.write_text(json.dumps({"events": [
                    {"t": 0.1, "type": "click", "key": field_key},
                    {"t": 0.2, "type": "type", "text": ui_secret, "every": 0.001},
                    {"t": 0.3, "type": "click", "key": "send-input"},
                ]}))
                tree = Path(root) / "ui-tree.json"
                output = subprocess.run([app, "--task", ui_task, "--state-dir", root,
                    "--script", str(script), "--snap", str(Path(root) / "ui.png"),
                    "--tree", str(tree), "--at", "0.5"], capture_output=True, text=True, timeout=90)
                assert output.returncode == 0, output.stderr[-2000:]
                assert browser.run("info", ui_task)["state"] == "kept"
                assert ui_secret not in tree.read_text()
                browser.run("resume", ui_task)
                actual_input = browser.value(ui_task, "document.querySelector('input').value")
                assert actual_input == ui_secret, f"Fixture field contains {actual_input!r}"
                for path in (Path(root) / ui_task).rglob("*"):
                    if path.is_file():
                        assert ui_secret.encode() not in path.read_bytes(), path
                print("PASS: real Rune controls send private input to the live page; closing the app keeps the task paused")
            print("PASS: handoff isolation, live fields/buttons, memory-only screenshots, private input, document/origin binding, resume and crash recovery")
        finally:
            # Release our own handoffs before the fixture expires its task records.
            # Otherwise an assertion failure could leave an assisting record uncleanable.
            for owned in browser.tasks:
                subprocess.run(browser.command + ["assist-cancel", owned],
                    capture_output=True, timeout=40)
            browser.cleanup()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command")
    parser.add_argument("--old-command")
    parser.add_argument("--app")
    args = parser.parse_args()
    check(args.command, args.old_command, args.app)
