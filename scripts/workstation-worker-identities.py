"""Read public worker identities through the host-owned QEMU channel."""

import base64
import json
import os
import socket
import time


def main():
    if os.getuid() != 0 or socket.gethostname() != "workstation":
        raise RuntimeError("Authenticate locally on workstation to read worker identities")
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect("/run/workstation-worker/guest-agent.sock")
        with connection.makefile("rwb", buffering=0) as stream:
            def request(command, arguments=None):
                message = {"execute": command}
                if arguments is not None:
                    message["arguments"] = arguments
                stream.write(json.dumps(message).encode() + b"\n")
                response = json.loads(stream.readline())
                if "error" in response:
                    raise RuntimeError(str(response["error"]))
                return response["return"]
            request("guest-sync", {"id": 7632})
            process = request("guest-exec", {
                "path": "/run/current-system/sw/bin/cat",
                "arg": ["/etc/workstation-worker/public-identities.json"],
                "capture-output": True,
            })
            deadline = time.monotonic() + 30
            while True:
                status = request("guest-exec-status", {"pid": process["pid"]})
                if status["exited"]:
                    if status.get("exitcode") != 0:
                        raise RuntimeError("Guest identity setup has not finished")
                    value = json.loads(base64.b64decode(status["out-data"], validate=True))
                    if set(value) != {"ssh", "age", "cache"} or not all(isinstance(v, str) for v in value.values()):
                        raise ValueError("Invalid public identity response")
                    if not value["ssh"].startswith("ssh-ed25519 ") or not value["age"].startswith("age1") or not value["cache"].startswith("workstation-worker-1:"):
                        raise ValueError("Unexpected worker public key format")
                    print(json.dumps(value, indent=2))
                    return
                if time.monotonic() >= deadline:
                    raise RuntimeError("Guest identity query timed out")
                time.sleep(0.2)


if __name__ == "__main__":
    main()
