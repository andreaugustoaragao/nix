#!/usr/bin/env python3
"""Unit tests for niri-dropdown.py."""

import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location(
    "niri_dropdown", pathlib.Path(__file__).with_name("niri-dropdown.py")
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

WORKSPACES = [
    {"id": 1, "idx": 1, "name": "1", "output": "DP-1", "is_active": True, "is_focused": False},
    {"id": 10, "idx": 1, "name": "p1", "output": "DP-2", "is_active": True, "is_focused": True},
    {"id": 21, "idx": 10, "name": "scratch", "output": "DP-1", "is_active": False, "is_focused": False},
]


class NiriDropdownTests(unittest.TestCase):
    def test_spawns_when_no_matching_window(self):
        actions = MOD.plan_actions(
            windows=[],
            workspaces=WORKSPACES,
            app_id_pattern="(?i)^bitwarden$",
            title_pattern=None,
            command=["bitwarden"],
            scratch_workspace="scratch",
            width_pct=65.0,
            height_pct=65.0,
        )
        self.assertEqual(actions, [{"Action": {"Spawn": {"command": ["bitwarden"]}}}])

    def test_hides_focused_window_to_scratch_without_moving_focus(self):
        windows = [
            {
                "id": 59,
                "app_id": "bitwarden",
                "title": "Bitwarden",
                "workspace_id": 10,
                "is_focused": True,
                "is_floating": True,
            }
        ]
        actions = MOD.plan_actions(
            windows=windows,
            workspaces=WORKSPACES,
            app_id_pattern="(?i)^bitwarden$",
            title_pattern=None,
            command=["bitwarden"],
            scratch_workspace="scratch",
            width_pct=65.0,
            height_pct=65.0,
        )
        self.assertEqual(
            actions,
            [
                {
                    "Action": {
                        "MoveWindowToWorkspace": {
                            "window_id": 59,
                            "reference": {"Name": "scratch"},
                            "focus": False,
                        }
                    }
                }
            ],
        )

    def test_summons_cross_monitor_using_workspace_id_and_centers_on_display(self):
        # Vitals has app_id=None on DP-1 ws 1; focused workspace is DP-2 ws id=10.
        windows = [
            {
                "id": 29,
                "app_id": None,
                "title": "Vitals — System Monitor",
                "workspace_id": 1,
                "is_focused": False,
                "is_floating": False,
            }
        ]
        actions = MOD.plan_actions(
            windows=windows,
            workspaces=WORKSPACES,
            app_id_pattern=None,
            title_pattern="^Vitals — System Monitor$",
            command=["vitals"],
            scratch_workspace="scratch",
            width_pct=65.0,
            height_pct=65.0,
        )
        self.assertEqual(
            actions,
            [
                {
                    "Action": {
                        "MoveWindowToWorkspace": {
                            "window_id": 29,
                            "reference": {"Id": 10},
                            "focus": False,
                        }
                    }
                },
                {"Action": {"MoveWindowToFloating": {"id": 29}}},
                {"Action": {"SetWindowWidth": {"id": 29, "change": {"SetProportion": 65.0}}}},
                {"Action": {"SetWindowHeight": {"id": 29, "change": {"SetProportion": 65.0}}}},
                {"Action": {"CenterWindow": {"id": 29}}},
                {"Action": {"FocusWindow": {"id": 29}}},
            ],
        )

    def test_vereda_regex_excludes_file_picker(self):
        windows = [
            {
                "id": 77,
                "app_id": "io.github.andrearagao.vereda.Picker",
                "title": "Open File",
                "workspace_id": 10,
                "is_focused": False,
                "is_floating": True,
            }
        ]
        actions = MOD.plan_actions(
            windows=windows,
            workspaces=WORKSPACES,
            app_id_pattern=r"^io\.github\.andrearagao\.vereda$",
            title_pattern=None,
            command=["vereda"],
            scratch_workspace="scratch",
            width_pct=65.0,
            height_pct=65.0,
        )
        self.assertEqual(actions, [{"Action": {"Spawn": {"command": ["vereda"]}}}])


if __name__ == "__main__":
    unittest.main()
