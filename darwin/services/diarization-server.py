"""Bounded WAV-only HTTP adapter for the offline speaker worker."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import wave


MAX_AUDIO_BYTES = 512 * 1024 * 1024


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, worker):
        super().__init__(address, Handler)
        self.worker = worker
        self.inference = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def respond(self, status, value):
        body = json.dumps(value, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/health":
            self.respond(404, {"error": "not_found"})
        elif not os.access(self.server.worker, os.X_OK):
            self.respond(503, {"error": "worker_unavailable"})
        else:
            self.respond(200, {"backend": "fluidaudio-offline-vbx-0.15.5"})

    def do_POST(self):
        if self.path != "/v1/audio/diarizations":
            self.respond(404, {"error": "not_found"})
            return
        if self.headers.get("Content-Type", "").split(";", 1)[0] != "audio/wav":
            self.respond(415, {"error": "wav_required"})
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            size = 0
        if not 44 <= size <= MAX_AUDIO_BYTES or self.headers.get("Transfer-Encoding"):
            self.respond(413, {"error": "invalid_audio_size"})
            return
        if not self.server.inference.acquire(blocking=False):
            self.respond(503, {"error": "worker_busy"})
            return
        try:
            # The upload and model result never share paths with a recording
            # or another request. Read bounded chunks, rather than buffering a
            # multi-hour WAV in the HTTP server's memory.
            with tempfile.TemporaryDirectory(prefix="record-call-diarize-") as directory:
                audio, output = Path(directory) / "audio.wav", Path(directory) / "result.json"
                self.connection.settimeout(30)
                with audio.open("wb") as handle:
                    remaining = size
                    while remaining:
                        data = self.rfile.read(min(1024 * 1024, remaining))
                        if not data:
                            raise ValueError("truncated upload")
                        handle.write(data)
                        remaining -= len(data)
                with wave.open(str(audio)) as wav:
                    if wav.getparams()[:3] != (1, 2, 16000) or wav.getnframes() == 0:
                        raise ValueError("invalid WAV format")
                    remaining_frames = wav.getnframes()
                    while remaining_frames:
                        count = min(remaining_frames, 16000 * 10)
                        if len(wav.readframes(count)) != count * 2:
                            raise ValueError("truncated WAV")
                        remaining_frames -= count
                subprocess.run([self.server.worker, str(audio), str(output)], check=True,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, timeout=7200)
                if output.stat().st_size > 16 * 1024 * 1024:
                    raise ValueError("oversized result")
                result = json.loads(output.read_bytes())
                if not isinstance(result, dict) or not isinstance(result.get("speaker_segments"), list):
                    raise ValueError("invalid worker result")
                self.respond(200, result)
        except (ValueError, wave.Error, EOFError):
            self.respond(422, {"error": "invalid_audio_or_result"})
        except subprocess.TimeoutExpired:
            self.respond(504, {"error": "diarization_timeout"})
        except (OSError, subprocess.CalledProcessError):
            self.respond(502, {"error": "diarization_failed"})
        finally:
            self.server.inference.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=12018)
    args = parser.parse_args()
    with Server((args.host, args.port), args.worker) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
