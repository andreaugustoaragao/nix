import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("retirement", Path(__file__).with_name("workstation-k3s-retire.py"))
retirement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retirement)


class RetirementTests(unittest.TestCase):
    def test_orphaned_scope_is_killed_even_without_a_k3s_process(self):
        unit = "cri-containerd-" + "a" * 64 + ".scope"
        with patch.object(retirement, "host_container_scopes", side_effect=[[unit], []]), patch.object(retirement.subprocess, "run") as command:
            command.return_value = subprocess.CompletedProcess([], 5)
            retirement.retire_host_containers()
        self.assertEqual(command.call_args_list[0].args[0], ["systemctl", "kill", "--kill-whom=all", "--signal=KILL", unit])
        self.assertEqual(command.call_args_list[1].args[0], ["systemctl", "stop", unit])

    def test_remaining_scope_fails_retirement(self):
        unit = "cri-containerd-" + "b" * 64 + ".scope"
        with patch.object(retirement, "host_container_scopes", return_value=[unit]), patch.object(retirement.subprocess, "run"):
            with self.assertRaisesRegex(RuntimeError, "remain running"):
                retirement.retire_host_containers()

    def test_repeat_with_no_scopes_does_not_stop_anything(self):
        with patch.object(retirement, "host_container_scopes", return_value=[]), patch.object(retirement.subprocess, "run") as command:
            retirement.retire_host_containers()
            command.assert_not_called()

    def test_unrelated_scope_cannot_enter_retirement_set(self):
        with patch.object(retirement, "run", return_value="docker-" + "c" * 64 + ".scope loaded active running"):
            with self.assertRaisesRegex(RuntimeError, "Unexpected container"):
                retirement.host_container_scopes()


if __name__ == "__main__":
    unittest.main()
