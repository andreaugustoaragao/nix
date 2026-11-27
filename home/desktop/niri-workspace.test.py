#!/usr/bin/env python3
"""Unit tests for niri-workspace.py."""

import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location(
    "niri_workspace", pathlib.Path(__file__).with_name("niri-workspace.py")
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class NiriWorkspaceTests(unittest.TestCase):
    def test_focuses_named_workspace_id_even_when_scratch_is_idx_1(self):
        workspaces = [
            {"id": 21, "idx": 1, "name": "scratch", "output": "DP-1", "is_active": False, "is_focused": False},
            {"id": 1, "idx": 2, "name": "1", "output": "DP-1", "is_active": False, "is_focused": False},
            {"id": 2, "idx": 3, "name": "2", "output": "DP-1", "is_active": True, "is_focused": True},
            {"id": 10, "idx": 1, "name": "p1", "output": "DP-2", "is_active": True, "is_focused": False},
        ]
        actions = MOD.plan_actions(workspaces=workspaces, mode="focus", slot=1)
        self.assertEqual(
            actions,
            [
                {
                    "Action": {
                        "MoveWorkspaceToIndex": {
                            "index": 4,
                            "reference": {"Name": "scratch"},
                        }
                    }
                },
                {"Action": {"FocusWorkspace": {"reference": {"Id": 1}}}},
            ],
        )

    def test_focuses_portrait_named_workspace_id_on_dp2(self):
        workspaces = [
            {"id": 21, "idx": 10, "name": "scratch", "output": "DP-1", "is_active": False, "is_focused": False},
            {"id": 1, "idx": 1, "name": "1", "output": "DP-1", "is_active": True, "is_focused": False},
            {"id": 10, "idx": 1, "name": "p1", "output": "DP-2", "is_active": False, "is_focused": False},
            {"id": 11, "idx": 2, "name": "p2", "output": "DP-2", "is_active": True, "is_focused": True},
        ]
        actions = MOD.plan_actions(workspaces=workspaces, mode="focus", slot=1)
        self.assertEqual(
            actions,
            [{"Action": {"FocusWorkspace": {"reference": {"Id": 10}}}}],
        )

    def test_move_column_targets_named_workspace_id(self):
        workspaces = [
            {"id": 21, "idx": 1, "name": "scratch", "output": "DP-1", "is_active": True, "is_focused": True},
            {"id": 1, "idx": 2, "name": "1", "output": "DP-1", "is_active": False, "is_focused": False},
        ]
        actions = MOD.plan_actions(workspaces=workspaces, mode="move", slot=1)
        self.assertEqual(
            actions,
            [
                {
                    "Action": {
                        "MoveWorkspaceToIndex": {
                            "index": 3,
                            "reference": {"Name": "scratch"},
                        }
                    }
                },
                {
                    "Action": {
                        "MoveColumnToWorkspace": {
                            "reference": {"Id": 1},
                            "focus": True,
                        }
                    }
                },
            ],
        )

    def test_falls_back_to_index_for_unnamed_dynamic_workspaces(self):
        workspaces = [
            {"id": 5, "idx": 1, "name": None, "output": "eDP-1", "is_active": True, "is_focused": True},
        ]
        actions = MOD.plan_actions(workspaces=workspaces, mode="focus", slot=2)
        self.assertEqual(
            actions,
            [{"Action": {"FocusWorkspace": {"reference": {"Index": 2}}}}],
        )


if __name__ == "__main__":
    unittest.main()
