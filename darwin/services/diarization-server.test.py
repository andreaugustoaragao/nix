"""Isolated HTTP contract tests; no model, microphone, or live service."""
import http.client
from contextlib import closing
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import wave

spec = importlib.util.spec_from_file_location("server", Path(__file__).with_name("diarization-server.py"))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.worker = Path(self.directory.name) / "worker"
        self.worker.write_text(
            f"#!{sys.executable}\nimport json,sys\n"
            "assert len(sys.argv)==3\n"
            "with open(sys.argv[2], 'w') as out: json.dump({'speaker_segments': "
            "[{'start':0.1,'end':0.3,'speaker':'S1'},{'start':0.4,'end':0.7,'speaker':'S2'}]},out)\n")
        self.worker.chmod(0o700)
        self.server = server.Server(("127.0.0.1", 0), str(self.worker))
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        stream = io.BytesIO()
        with wave.open(stream, "wb") as wav:
            wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            wav.writeframes(b"\0\0" * 16000)
        self.audio = stream.getvalue()

    def tearDown(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()
        self.directory.cleanup()

    def request(self, body=None, content_type="audio/wav", path="/v1/audio/diarizations"):
        with closing(http.client.HTTPConnection(*self.server.server_address, timeout=3)) as client:
            client.request("GET" if body is None else "POST", path, body,
                           {"Content-Type": content_type})
            response = client.getresponse()
            return response.status, json.loads(response.read())

    def test_raw_speaker_segments_survive_without_transcription_tokens(self):
        status, result = self.request(self.audio)
        self.assertEqual(status, 200)
        self.assertEqual([s["speaker"] for s in result["speaker_segments"]], ["S1", "S2"])
        self.assertEqual(result["speaker_segments"][0]["end"], 0.3)

    def test_input_rejection_does_not_run_worker_or_hold_lock(self):
        self.assertEqual(self.request(self.audio, "application/json")[0], 415)
        self.assertEqual(self.request(self.audio[:100])[0], 422)
        self.assertEqual(self.request(self.audio, path="/anything")[0], 404)
        self.assertEqual(self.request(self.audio)[0], 200)

    def test_concurrent_request_is_bounded_and_worker_failure_is_reported(self):
        with self.server.inference:
            self.assertEqual(self.request(self.audio), (503, {"error": "worker_busy"}))
        self.worker.write_text(f"#!{sys.executable}\nraise SystemExit(1)\n")
        self.assertEqual(self.request(self.audio), (502, {"error": "diarization_failed"}))
        self.assertFalse(self.server.inference.locked())

    def test_health_requires_worker_and_unknown_path_is_not_health(self):
        self.assertEqual(self.request(path="/health")[0], 200)
        self.assertEqual(self.request(path="/")[0], 404)
        self.worker.unlink()
        self.assertEqual(self.request(path="/health")[0], 503)


if __name__ == "__main__":
    unittest.main()
