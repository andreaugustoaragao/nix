"""Generate real producer states and check the Fulcrum consumer contract.

Uses only synthetic PCM/module commands. Requires an explicit Fulcrum checkout;
its pinned Bun executes the real parser and local catalog. Evidence is retained.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from unittest.mock import patch
import uuid

spec = importlib.util.spec_from_file_location("fixtures", Path(__file__).with_name("record-call-session.test.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
recorder = fixtures.recorder


def producer_fixture(name, evidence):
    fixture = fixtures.RecorderTests()
    fixture.setUp()
    timer = None
    try:
        session = fixture.session()
        fixture.synthetic_capture(session, fail_loopback=name == "setup_failure", fail_first_call=name == "capture_gap")
        session.manifest["recordingId"] = str(uuid.uuid4())
        session.manifest["startedAt"] = recorder.utc_now()
        session.persist()
        original = session.launch_capture

        def launch(side):
            if name == "second_launch_failure" and side == "mic":
                raise OSError("synthetic second capture launch failure")
            original(side)

        if name == "asr_failure":
            (fixture.root / "control.json").write_text('{"fail_mic":100}')
        if name in ("capture_gap", "asr_failure"):
            timer = recorder.threading.Timer(1.1 if name == "capture_gap" else 0.65, session.stop_event.set)
            timer.start()
        with patch.object(session, "launch_capture", side_effect=launch), \
             patch.dict(recorder.os.environ, {"INVOCATION_ID": "synthetic-contract-fixture"}):
            assert session.run() == 1
        assert session.manifest["status"] == "incomplete"
        if name in ("setup_failure", "second_launch_failure"):
            assert session.manifest["endedAt"] is None
            assert session.manifest["finalizedAt"] is None
            assert session.manifest["failure"]["retryable"] is False
        if name == "asr_failure":
            assert session.manifest["endedAt"] is not None
            assert session.manifest["failure"]["retryable"] is True
        assert [module["index"] for module in json.loads((fixture.root / "modules.json").read_text())] == [11, 12]
        recorder.atomic_json(evidence / name / "recording.json", session.manifest)
        output = session.manifest["source"]["transcript"]
        if output is not None:
            shutil.copy2(session.directory / output["path"], evidence / name / output["path"])
    finally:
        if timer:
            timer.cancel()
        fixture.tearDown()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", required=True, type=Path)
    arguments = parser.parse_args()
    backend = arguments.backend.resolve()
    evidence = Path(tempfile.mkdtemp(prefix="record-call-contract-", dir=Path.home() / ".cache"))
    initial = recorder.new_manifest(str(uuid.uuid4()), recorder.utc_now(), "UTC")
    recorder.atomic_json(evidence / "initial" / "recording.json", initial)
    for name in ("setup_failure", "second_launch_failure", "capture_gap", "asr_failure"):
        producer_fixture(name, evidence)
    script = evidence / "verify-consumer.ts"
    script.write_text("\n".join([
        "import assert from 'node:assert/strict';",
        "import {readFileSync,readdirSync} from 'node:fs';",
        "import {join} from 'node:path';",
        "import {parseRecordingManifest} from " + json.dumps(str(backend / "src/infrastructure/adapters/recordings/recording-manifest.ts")) + ";",
        "import {LocalRecordingCatalog} from " + json.dumps(str(backend / "src/infrastructure/adapters/recordings/local-recording-catalog.ts")) + ";",
        "const root = process.argv[2];",
        "const directories = readdirSync(root,{withFileTypes:true}).filter(entry=>entry.isDirectory());",
        "for (const entry of directories) {",
        "  const value = JSON.parse(readFileSync(join(root,entry.name,'recording.json'),'utf8'));",
        "  const parsed = parseRecordingManifest(value,entry.name);",
        "  assert.equal(parsed.status,value.status);",
        "}",
        "const catalog = new LocalRecordingCatalog(root);",
        "const result = await catalog.scan();",
        "assert.equal(result.available,true);",
        "if (!result.available) throw Error(result.reason);",
        "assert.deepEqual(result.issues,[]);",
        "assert.equal(result.recordings.length,5);",
        "for (const recording of result.recordings) assert.deepEqual(await catalog.snapshot(recording),{ok:false,code:'not_ready'});",
        "console.log(JSON.stringify({result:'PASS',fixtures:result.recordings.map(recording=>recording.sourceKey),evidence:root}));",
    ]))
    print("Contract evidence: " + str(evidence), flush=True)
    return subprocess.run([str(backend / "node_modules/.bin/bun"), str(script), str(evidence)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
