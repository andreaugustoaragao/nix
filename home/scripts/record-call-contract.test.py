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


def ready_cleanup_fixture(backend, evidence):
    fixture = fixtures.RecorderTests()
    fixture.setUp()
    timer = None
    try:
        session = fixture.session()
        fixture.synthetic_capture(session)
        session.manifest["recordingId"] = str(uuid.uuid4())
        session.state["unit"] = "record-call-synthetic-contract.service"
        session.persist()
        timer = recorder.threading.Timer(0.65, session.stop_event.set)
        timer.start()
        invocation = "synthetic-ready-cleanup"
        with patch.dict(recorder.os.environ, {"INVOCATION_ID": invocation}):
            assert session.run() == 0
        target = evidence / "ready_cleanup"
        shutil.copytree(session.directory, target)
        before = {path.name: path.read_bytes() for path in target.iterdir()
                  if path.name == "recording.json" or path.name.startswith("transcript")}
        script = evidence / "verify-cleanup.ts"
        script.write_text("\n".join([
            "import assert from 'node:assert/strict';",
            "import {readFileSync,writeFileSync} from 'node:fs';",
            "import {join} from 'node:path';",
            "import {LocalRecordingCatalog} from " + json.dumps(str(backend / "src/infrastructure/adapters/recordings/local-recording-catalog.ts")) + ";",
            "const [root,phase] = process.argv.slice(2);",
            "const catalog = new LocalRecordingCatalog(root);",
            "const scan = await catalog.scan();",
            "assert.equal(scan.available,true); if (!scan.available) throw Error(scan.reason);",
            "const current = scan.recordings.find(recording=>recording.sourceKey==='ready_cleanup');",
            "assert.ok(current); assert.equal(current.status,'ready');",
            "const path = join(root,'reserved-descriptor.json');",
            "if (phase==='before') writeFileSync(path,JSON.stringify(current));",
            "const expected = JSON.parse(readFileSync(path,'utf8'));",
            "const snapshot = await catalog.snapshot(expected);",
            "assert.equal(snapshot.ok,true,JSON.stringify(snapshot));",
            "assert.deepEqual(current,expected,'cleanup changed the next scan descriptor');",
            "console.log(JSON.stringify({result:'PASS',fixture:'ready_cleanup',phase,revision:current.revision}));",
        ]))
        command = [str(backend / "node_modules/.bin/bun"), str(script), str(evidence)]
        subprocess.run([*command, "before"], check=True)
        owner = {"ActiveState": "deactivating", "InvocationID": invocation}
        with patch.object(recorder, "owner_properties", return_value=owner), \
             patch.dict(recorder.os.environ, {"INVOCATION_ID": invocation}):
            for phase in ("after", "repeated"):
                recorder.cleanup_after_owner(target, session.config)
                subprocess.run([*command, phase], check=True)
                assert {name: (target / name).read_bytes() for name in before} == before
                state = recorder.read_json(target / ".record-call/state.json")
                assert state["cleanupCompletedInvocationId"] == invocation
        assert [module["index"] for module in json.loads((fixture.root / "modules.json").read_text())] == [11, 12]
    finally:
        if timer:
            timer.cancel()
        fixture.tearDown()


def diarized_ready_fixture(evidence):
    fixture = fixtures.RecorderTests()
    fixture.setUp()
    timer = None
    try:
        session = fixture.session()
        fixture.synthetic_capture(session)
        session.manifest["recordingId"] = str(uuid.uuid4())
        session.persist()
        (fixture.root / "control.json").write_text('{"diarization_success":true}')
        timer = recorder.threading.Timer(0.65, session.stop_event.set)
        timer.start()
        with patch.dict(recorder.os.environ, {"INVOCATION_ID": "synthetic-diarized-ready"}):
            assert session.run() == 0
        assert session.manifest["status"] == "ready"
        assert session.manifest["source"]["transcript"]["path"] == "transcript.diarized.turns.txt"
        assert session.state["diarization"]["status"] == "ready"
        shutil.copytree(session.directory, evidence / "diarized_ready")
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
    ready_cleanup_fixture(backend, evidence)
    diarized_ready_fixture(evidence)
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
        "assert.equal(result.recordings.length,7);",
        "for (const recording of result.recordings) {",
        "  const snapshot = await catalog.snapshot(recording);",
        "  if (recording.status==='ready') assert.equal(snapshot.ok,true);",
        "  else assert.deepEqual(snapshot,{ok:false,code:'not_ready'});",
        "}",
        "console.log(JSON.stringify({result:'PASS',fixtures:result.recordings.map(recording=>recording.sourceKey),evidence:root}));",
    ]))
    print("Contract evidence: " + str(evidence), flush=True)
    return subprocess.run([str(backend / "node_modules/.bin/bun"), str(script), str(evidence)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
