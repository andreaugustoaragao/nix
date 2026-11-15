"""Review the private worker desktop over an authenticated SSH tunnel."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--view-only", action="store_true")
    args = parser.parse_args()
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime:
        parser.error("Run this command in your local desktop session")
    subprocess.run(["ssh", "-o", "BatchMode=yes", "workstation-worker",
                    "systemctl --user is-active --quiet worker-desktop-view.service"], check=True)
    with tempfile.TemporaryDirectory(prefix="worker-desktop-", dir=runtime) as temporary:
        socket = Path(temporary) / "view.sock"
        tunnel = subprocess.Popen([
            "ssh", "-T", "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-L",
            str(socket) + ":127.0.0.1:5900", "workstation-worker",
        ])
        try:
            deadline = time.monotonic() + 20
            while not socket.exists():
                if tunnel.poll() is not None:
                    raise RuntimeError("The SSH desktop tunnel failed")
                if time.monotonic() >= deadline:
                    raise RuntimeError("The SSH desktop tunnel did not become ready")
                time.sleep(0.1)
            return subprocess.call([
                "vncviewer", "-AcceptClipboard=0", "-SendClipboard=0", "-SendPrimary=0",
                "-SetPrimary=0", "-ViewOnly=" + str(int(args.view_only)), str(socket),
            ])
        finally:
            tunnel.terminate()
            try:
                tunnel.wait(timeout=5)
            except subprocess.TimeoutExpired:
                tunnel.kill()
                tunnel.wait()


if __name__ == "__main__":
    raise SystemExit(main())
