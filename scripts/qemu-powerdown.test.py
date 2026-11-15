import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

class ShutdownTests(unittest.TestCase):
    def test_waits_for_guest_disconnect_after_accepting_powerdown(self):
        with tempfile.TemporaryDirectory(dir="/tmp", prefix="qmp-") as temporary:
            path = str(Path(temporary) / "socket")
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(path)
                server.listen()
                process = subprocess.Popen([sys.executable, str(Path(__file__).with_name("qemu-powerdown.py")), path])
                try:
                    connection, _ = server.accept()
                    with connection:
                        stream = connection.makefile("rwb", buffering=0)
                        stream.write(b'{"QMP":{}}\n')
                        for name in ["qmp_capabilities", "system_powerdown"]:
                            request = json.loads(stream.readline())
                            self.assertEqual(request["execute"], name)
                            stream.write((json.dumps({"return": {}, "id": name}) + "\n").encode())
                        with self.assertRaises(subprocess.TimeoutExpired):
                            process.wait(timeout=0.1)
                        stream.close()
                    self.assertEqual(process.wait(timeout=5), 0)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.wait()

if __name__ == "__main__":
    unittest.main()
