"""Explicit live PipeWire regression using only private generated tone sources.

Run manually with access to the user audio server. The default tests the installed
recorder; --source tests a candidate Python file against the installed tool config.
No real microphone, browser routing, external ASR, or current-session pointer is
used. Evidence is retained in ~/.cache/record-call-live-*.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import tempfile
import threading
import time
import uuid
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path)
parser.add_argument('--baseline-seconds', type=int, default=60)
parser.add_argument('--fragment-seconds', type=int, default=5)
args = parser.parse_args()
if not 35 <= args.baseline_seconds <= 1800:
    parser.error('--baseline-seconds must be between 35 and 1800')
if not 1 <= args.fragment_seconds <= 300:
    parser.error('--fragment-seconds must be between 1 and 300')
executable = Path(shutil.which('record-call')).resolve()
launcher = executable.read_text()
source_path = re.search(r'/nix/store/[a-z0-9]+-record-call-session\.py', launcher).group()
config_path = re.search(r'/nix/store/[a-z0-9]+-record-call-session-config\.json', launcher).group()
if args.source:
    source_path = str(args.source.resolve())
spec = importlib.util.spec_from_file_location('installed_recorder', source_path)
recorder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recorder)
config = json.loads(Path(config_path).read_text())
evidence = Path(tempfile.mkdtemp(prefix='record-call-live-', dir=Path.home() / '.cache'))
evidence.chmod(0o700)
fake_asr = evidence / 'tone-asr'
fake_asr.write_text('#!' + shutil.which('python3') + '\nprint(\'{"segments": []}\')\n')
fake_asr.chmod(0o700)
config['curl'] = str(fake_asr)
config['diarize'] = shutil.which('false')
token = uuid.uuid4().hex[:12]
modules = []
players = []
results = []
active_session = None
cleanup_session = None

def pactl(*args):
    return subprocess.run([config['pactl'], *map(str, args)], check=True,
                          capture_output=True, text=True, timeout=10).stdout

def module_listing():
    modules = []
    for line in pactl('list', 'short', 'modules').splitlines():
        fields = line.split('\t', 3)
        if len(fields) >= 3 and fields[0].isascii() and fields[0].isdigit():
            modules.append({'index': int(fields[0]), 'name': fields[1], 'argument': fields[2]})
    return modules


def interrupted(*_):
    raise KeyboardInterrupt('Probe interrupted; cleaning up owned resources')


signal.signal(signal.SIGTERM, interrupted)


def sample_summary(session):
    result = {}
    for side in recorder.SIDES:
        files = list((session.directory / 'chunks').glob(side + '_*.wav'))
        peak, nonzero, count = 0, 0, 0
        for path in files:
            with wave.open(str(path), 'rb') as stream:
                assert stream.getnchannels() == 1 and stream.getframerate() == 16000
                data = stream.readframes(stream.getnframes())
            for (sample,) in struct.iter_unpack('<h', data):
                peak = max(peak, abs(sample))
                nonzero += sample != 0
                count += 1
        result[side] = {'samples': count, 'nonzeroSamples': nonzero, 'peak': peak,
                        'fragmentCount': len(files)}
    return result

try:
    sources = {}
    tone = evidence / 'tone.wav'
    block = b''.join(struct.pack('<h', round(7000 * math.sin(2 * math.pi * 440 * n / 48000)))
                     for n in range(48000))
    with wave.open(str(tone), 'wb') as stream:
        stream.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        for _ in range(args.baseline_seconds + 100):
            stream.writeframesraw(block)
    for side in recorder.SIDES:
        name = f'record-call-probe-{token}-{side}'
        module = int(pactl('load-module', 'module-null-sink', 'sink_name=' + name,
                           'rate=48000', 'channels=1',
                           'sink_properties=device.description=RecordingProbe'))
        modules.append((module, name))
        current = json.loads(pactl('-f', 'json', 'list', 'sources'))
        sources[side] = next(item['index'] for item in current if item['name'] == name + '.monitor')
        log = (evidence / (side + '-player.log')).open('wb')
        players.append((subprocess.Popen([str(Path(config['pactl']).with_name('paplay')),
                                         '--device=' + name, str(tone)], stdin=subprocess.DEVNULL,
                                        stdout=log, stderr=log), log))

    for scenario in ('baseline', 'stalled-reader'):
        directory = evidence / scenario
        private = directory / '.record-call'
        private.mkdir(parents=True)
        (directory / 'chunks').mkdir()
        state = {'fragments': {side: [] for side in recorder.SIDES}, 'gaps': [],
                 'advanceMs': 30000, 'windowMs': max(45000, args.fragment_seconds * 2000),
                 'fragmentMs': args.fragment_seconds * 1000, 'turnGap': 8,
                 'whisperServerUrl': 'http://synthetic.invalid',
                 'diarizationServerUrl': 'http://synthetic.invalid',
                 'diarizationModel': 'synthetic-tone', 'model': 'unused', 'vadModel': 'unused',
                 'finalizationStage': 'capturing', 'diarization': {'status': 'pending', 'attempts': 0, 'failure': None},
                 'runs': {side: [] for side in recorder.SIDES}, 'sink': modules[0][1], 'modules': {}}
        recorder.atomic_json(private / 'state.json', state)
        recorder.atomic_json(directory / 'recording.json', recorder.new_manifest(str(uuid.uuid4()), recorder.utc_now(), 'UTC'))
        session = recorder.Session(directory, config)
        active_session = session
        cleanup_session = session
        reader_exits = []
        stop_capture = session.stop_capture

        def observe_stop(side, **kwargs):
            reader = session.captures[side][0]
            stop_capture(side, **kwargs)
            reader_exits.append({"side": side, "returncode": reader.returncode})

        session.stop_capture = observe_stop
        # Route only generated tone nodes; all capture and restart code is the
        # installed Session implementation, with its production thresholds.
        session.setup_audio = lambda: session.state.update(sources=sources)
        session.default_mic_source = lambda: sources['mic']
        session.route = lambda: 1
        session.cleanup_modules = lambda: None
        injection = {}
        controller_errors = []

        def control():
            try:
                deadline = time.monotonic() + max(80, args.baseline_seconds + 10)
                while time.monotonic() < deadline and not session.stop_event.is_set():
                    elapsed = session.elapsed()
                    if scenario == 'baseline' and elapsed >= args.baseline_seconds * 1000:
                        session.stop_event.set()
                        return
                    if scenario == 'stalled-reader':
                        if not injection and elapsed >= 12000 and session.captures.get('call'):
                            reader = session.captures['call'][0]
                            os.kill(reader.pid, signal.SIGSTOP)
                            injection.update(pid=reader.pid, atMs=elapsed)
                        runs = session.state['runs']['call']
                        if len(runs) >= 2 and elapsed >= runs[-1]['offsetMs'] + 12000:
                            session.stop_event.set()
                            return
                    time.sleep(0.05)
                session.stop_event.set()
            except BaseException as error:
                controller_errors.append(type(error).__name__ + ': ' + str(error))
                session.stop_event.set()

        thread = threading.Thread(target=control, daemon=True)
        thread.start()
        failure = None
        try:
            session.capture()
            session.finalize()
        except BaseException as error:
            failure = error.code if isinstance(error, recorder.Failure) else type(error).__name__ + ': ' + str(error)
            session.manifest['status'] = 'incomplete'
            session.manifest['failure'] = error.public() if isinstance(error, recorder.Failure) else {'code': failure}
            session.persist()
        finally:
            session.stop_event.set()
            thread.join(timeout=2)
            for side in list(session.captures):
                session.stop_capture(side)
        result = {'scenario': scenario, 'status': session.manifest['status'], 'failure': failure,
                  'coverage': session.manifest['coverage'], 'issues': session.state.get('captureIssues', []),
                  'gaps': session.state['gaps'], 'runs': {side: len(session.state['runs'][side]) for side in recorder.SIDES},
                  'readerExits': reader_exits, 'injection': injection, 'samples': sample_summary(session), 'controllerErrors': controller_errors}
        results.append(result)
        recorder.atomic_json(evidence / 'results.json', results)
        print(json.dumps(result), flush=True)
        active_session = None
finally:
    if active_session is not None:
        active_session.stop_event.set()
        for side in list(active_session.captures):
            active_session.stop_capture(side)
    for child, log in players:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        log.close()
    # Exercise production cleanup, including recovery when an ID was not saved.
    cleanup_ok = False
    if cleanup_session is not None:
        saved_state = cleanup_session.state
        try:
            for position, (module, name) in enumerate(reversed(modules)):
                cleanup_session.state = {'sink': name, 'modules': {'sink': module} if position == 0 else {}}
                recorder.Session.cleanup_modules(cleanup_session)
            cleanup_ok = not any('record-call-probe-' + token in item['argument'] for item in module_listing())
        finally:
            cleanup_session.state = saved_state
    # If production cleanup fails, still leave no diagnostic resources behind.
    for module, name in reversed(modules):
        if any(item['index'] == module and item['name'] == 'module-null-sink'
               and 'sink_name=' + name in item['argument'].split() for item in module_listing()):
            pactl('unload-module', module)
    remaining = module_listing()
    fallback_ok = not any('record-call-probe-' + token in item['argument'] for item in remaining)
    report = {'source': source_path, 'sourceSha256': hashlib.sha256(Path(source_path).read_bytes()).hexdigest(),
              'evidence': str(evidence), 'fallbackCleanupComplete': fallback_ok, 'cleanupComplete': cleanup_ok, 'scenarios': results}
    recorder.atomic_json(evidence / 'report.json', report)
    print(json.dumps({'evidence': str(evidence), 'fallbackCleanupComplete': fallback_ok, 'cleanupComplete': cleanup_ok}), flush=True)

assert len(results) == 2
assert all(not row['controllerErrors'] and all(side['nonzeroSamples'] > 16000 for side in row['samples'].values()) for row in results)
assert not results[0]['gaps'] and not results[0]['issues'], results[0]
assert results[0]['status'] == 'ready' and results[0]['runs'] == {'call': 1, 'mic': 1}, results[0]
assert results[1]['status'] == 'incomplete' and results[1]['runs']['call'] == 2, results[1]
assert any(issue['code'] == 'capture_stalled' for issue in results[1]['issues']), results[1]
assert not any(gap['reason'] == 'reader_failed' for row in results for gap in row['gaps'])
assert results[1]['coverage']['sides']['mic']['missing'] == []
assert results[1]['coverage']['sides']['call']['missing']
assert results[1]['coverage']['sides']['call']['captureEndMs'] >= results[1]['injection']['atMs'] + 12000
assert cleanup_ok and fallback_ok
