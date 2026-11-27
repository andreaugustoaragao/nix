#!/usr/bin/env python3
"""Unit tests for hypr-dropdown.py."""

import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location(
    "hypr_dropdown", pathlib.Path(__file__).with_name("hypr-dropdown.py")
)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

MONITORS = [
    {
        "name": "DP-1",
        "x": 1440,
        "y": 0,
        "width": 3840,
        "height": 2160,
        "scale": 1.25,
        "transform": 0,
        "focused": False,
        "specialWorkspace": {"id": 0, "name": ""},
    },
    {
        "name": "DP-2",
        "x": 0,
        "y": 0,
        "width": 3840,
        "height": 2160,
        "scale": 1.5,
        "transform": 3,
        "focused": True,
        "specialWorkspace": {"id": 0, "name": ""},
    },
]


class HyprDropdownTests(unittest.TestCase):
    def test_toggles_empty_special_when_no_client_exists(self):
        cmds = MOD.plan_dispatches(
            clients=[],
            monitors=MONITORS,
            special_name="bitwarden",
            class_pattern="(?i)^bitwarden$",
            title_pattern=None,
            width_pct=65.0,
            height_pct=65.0,
        )
        self.assertEqual(cmds, ["dispatch togglespecialworkspace bitwarden"])

    def test_adopts_existing_window_from_normal_workspace_into_special(self):
        clients = [
            {
                "address": "0xabc123",
                "class": "bitwarden",
                "title": "Bitwarden",
                "floating": False,
                "workspace": {"id": 1, "name": "1"},
                "focusHistoryID": 2,
            }
        ]
        cmds = MOD.plan_dispatches(
            clients=clients,
            monitors=MONITORS,
            special_name="bitwarden",
            class_pattern="(?i)^bitwarden$",
            title_pattern=None,
            width_pct=65.0,
            height_pct=65.0,
        )
        # Focused monitor DP-2 logical size = 1440 x 2560 -> 65% = 936 x 1664, center = (252, 448)
        self.assertEqual(
            cmds,
            [
                "dispatch setfloating address:0xabc123",
                "dispatch movetoworkspacesilent special:bitwarden,address:0xabc123",
                "dispatch togglespecialworkspace bitwarden",
                "dispatch focuswindow address:0xabc123",
                "dispatch resizewindowpixel exact 936 1664,address:0xabc123",
                "dispatch movewindowpixel exact 252 448,address:0xabc123",
            ],
        )

    def test_hides_when_special_workspace_already_active_on_focused_monitor(self):
        monitors = [
            MONITORS[0],
            {**MONITORS[1], "specialWorkspace": {"id": -98, "name": "special:vitals"}},
        ]
        cmds = MOD.plan_dispatches(
            clients=[],
            monitors=monitors,
            special_name="vitals",
            class_pattern=None,
            title_pattern="^Vitals — System Monitor$",
            width_pct=65.0,
            height_pct=65.0,
        )
        self.assertEqual(cmds, ["dispatch togglespecialworkspace vitals"])

    def test_vereda_regex_ignores_file_picker(self):
        clients = [
            {
                "address": "0xdef456",
                "class": "io.github.andrearagao.vereda.Picker",
                "title": "Open File",
                "floating": True,
                "workspace": {"id": 1, "name": "1"},
                "focusHistoryID": 0,
            }
        ]
        cmds = MOD.plan_dispatches(
            clients=clients,
            monitors=MONITORS,
            special_name="vereda",
            class_pattern=r"^io\.github\.andrearagao\.vereda$",
            title_pattern=None,
            width_pct=65.0,
            height_pct=65.0,
        )
        self.assertEqual(cmds, ["dispatch togglespecialworkspace vereda"])

    def test_uses_global_coordinates_on_nonzero_origin_monitor(self):
        monitors = [
            {**MONITORS[0], "focused": True},
            {**MONITORS[1], "focused": False},
        ]
        clients = [
            {
                "address": "0x999",
                "class": "bitwarden",
                "title": "Bitwarden",
                "floating": True,
                "workspace": {"id": 1, "name": "1"},
                "focusHistoryID": 0,
            }
        ]
        cmds = MOD.plan_dispatches(
            clients=clients,
            monitors=monitors,
            special_name="bitwarden",
            class_pattern="(?i)^bitwarden$",
            title_pattern=None,
            width_pct=65.0,
            height_pct=65.0,
        )
        # DP-1 origin=(1440, 0), logical=3072x1728 -> 65%=1997x1123, center=(1440+538, 302)=(1978, 302)
        self.assertIn("dispatch resizewindowpixel exact 1997 1123,address:0x999", cmds)
        self.assertIn("dispatch movewindowpixel exact 1978 302,address:0x999", cmds)


if __name__ == "__main__":
    unittest.main()
