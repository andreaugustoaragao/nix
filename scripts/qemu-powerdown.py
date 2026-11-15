"""Power down a QEMU guest and wait until it has flushed its disks."""
import json
import socket
import sys
import time

deadline = time.monotonic() + 120
with socket.socket(socket.AF_UNIX) as connection:
    connection.settimeout(120)
    connection.connect(sys.argv[1])
    with connection.makefile("rwb", buffering=0) as stream:
        def receive():
            connection.settimeout(max(0.1, deadline - time.monotonic()))
            line = stream.readline()
            return json.loads(line) if line else None

        def command(name):
            stream.write((json.dumps({"execute": name, "id": name}) + "\n").encode())
            while True:
                reply = receive()
                if reply is None:
                    raise RuntimeError("QEMU disconnected before accepting shutdown")
                if reply.get("id") == name:
                    if "error" in reply:
                        raise RuntimeError(reply["error"])
                    return

        receive()
        command("qmp_capabilities")
        command("system_powerdown")
        while receive() is not None:
            pass
