import importlib.util
import json
import unittest
from pathlib import Path
from unittest import mock


source = Path(__file__).with_name("parallels-display-layout.py")
spec = importlib.util.spec_from_file_location("parallels_display_layout", source)
layout_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout_module)


def config(count):
    return f"Dynamic Resolution: new heads config (id=12(C), heads_count={count}, ext_width=13488)"


def head(index, x):
    return f"Dynamic Resolution:  head {index}) width=3384, height=6016, x={x}, y=0"


class HeadLayoutTests(unittest.TestCase):
    def test_parallels_can_reverse_the_portrait_display_indices(self):
        layout = layout_module.HeadLayout()
        for line in (config(3), head(0, 0), head(1, 6720), head(2, -3384)):
            layout.feed(line)
        self.assertEqual(layout.latest, ("Virtual-3", "Virtual-2"))

        for line in (config(3), head(0, 0), head(1, -3384), head(2, 6720)):
            layout.feed(line)
        self.assertEqual(layout.latest, ("Virtual-2", "Virtual-3"))

    def test_windowed_layout_clears_the_previous_three_display_mapping(self):
        layout = layout_module.HeadLayout()
        for line in (config(3), head(0, 0), head(1, -3384), head(2, 6720)):
            layout.feed(line)
        layout.feed(config(1))
        self.assertIsNone(layout.latest)

    def test_positions_follow_live_output_sizes(self):
        outputs = {
            name: {
                "logical": {"width": width, "scale": 2.0},
                "current_mode": 0,
                "modes": [{"width": width * 2}],
            }
            for name, width in (
                ("Virtual-1", 3360),
                ("Virtual-2", 1692),
                ("Virtual-3", 1692),
            )
        }
        self.assertEqual(
            layout_module.desired_positions(("Virtual-2", "Virtual-3"), outputs),
            {"Virtual-2": 0, "Virtual-1": 1692, "Virtual-3": 5052},
        )

    def test_fractional_scale_does_not_overlap_the_next_display(self):
        outputs = {
            "Virtual-3": {
                "logical": {"width": 1353, "scale": 2.5},
                "current_mode": 0,
                "modes": [{"width": 3384}],
            },
            "Virtual-1": {
                "logical": {"width": 2688, "scale": 2.5},
                "current_mode": 0,
                "modes": [{"width": 6720}],
            },
            "Virtual-2": {"logical": {"width": 1353, "scale": 2.5}},
        }
        self.assertEqual(
            layout_module.desired_positions(("Virtual-3", "Virtual-2"), outputs),
            {"Virtual-3": 0, "Virtual-1": 1354, "Virtual-2": 4042},
        )

    def test_hyprland_positions_follow_live_monitor_sizes_and_transforms(self):
        monitors = [
            {"name": "Virtual-3", "width": 6016, "height": 3384, "scale": 1.5, "transform": 1},
            {"name": "Virtual-1", "width": 2057, "height": 1290, "scale": 1.5, "transform": 0},
            {"name": "Virtual-2", "width": 3384, "height": 6016, "scale": 1.5, "transform": 0},
        ]
        # Virtual-3 rotated 90deg -> 3384 / 1.5 = 2256
        # Virtual-1 -> 2057 / 1.5 = 1371.333... -> std::round = 1371 (no 1px gap)
        self.assertEqual(
            layout_module.hyprland_desired_positions(("Virtual-3", "Virtual-2"), monitors),
            {"Virtual-3": 0, "Virtual-1": 2256, "Virtual-2": 3627},
        )

    def test_desired_scale_distinguishes_laptop_from_larger_display(self):
        def outputs_for(width, scale=1.5):
            return {
                "Virtual-1": {
                    "logical": {"width": int(width / scale), "scale": scale},
                    "current_mode": 0,
                    "modes": [{"width": width}],
                }
            }

        self.assertEqual(layout_module.desired_scale(outputs_for(2056)), 1.25)
        self.assertEqual(layout_module.desired_scale(outputs_for(2560)), 1.25)
        self.assertEqual(layout_module.desired_scale(outputs_for(3360)), 1.5)
        self.assertEqual(layout_module.desired_scale(outputs_for(3840)), 1.5)
        self.assertIsNone(layout_module.desired_scale({}))

    def test_hyprland_desired_scale_distinguishes_laptop_from_larger_display(self):
        self.assertEqual(
            layout_module.hyprland_desired_scale(
                [{"name": "Virtual-1", "width": 2056, "height": 1290, "scale": 1.5, "transform": 0}]
            ),
            1.25,
        )
        self.assertEqual(
            layout_module.hyprland_desired_scale(
                [{"name": "Virtual-1", "width": 3840, "height": 2160, "scale": 1.25, "transform": 0}]
            ),
            1.5,
        )

    def test_docked_portrait_outputs_force_large_scale_even_at_1920_width(self):
        self.assertEqual(
            layout_module.desired_scale(
                {
                    "Virtual-1": {
                        "logical": {"width": 1536, "scale": 1.25},
                        "current_mode": 0,
                        "modes": [{"width": 1920}],
                    },
                    "Virtual-2": {"logical": {"width": 1440, "scale": 1.5}},
                    "Virtual-3": {"logical": {"width": 1440, "scale": 1.5}},
                }
            ),
            1.5,
        )
        self.assertEqual(
            layout_module.hyprland_desired_scale(
                [
                    {"name": "Virtual-1", "width": 1920, "height": 1080, "scale": 1.25, "transform": 0},
                    {"name": "Virtual-2", "width": 2160, "height": 3840, "scale": 1.5, "transform": 0},
                    {"name": "Virtual-3", "width": 2160, "height": 3840, "scale": 1.5, "transform": 0},
                ]
            ),
            1.5,
        )

    def test_apply_niri_layout_scales_single_laptop_display_without_three_heads(self):
        calls = []
        state = {
            "Virtual-1": {
                "logical": {"x": 0, "y": 0, "width": 1370, "scale": 1.5},
                "current_mode": 0,
                "modes": [{"width": 2056}],
            }
        }

        def fake_run(argv, **_kwargs):
            calls.append(argv)
            if argv[1:] == ["msg", "--json", "outputs"]:
                return mock.Mock(stdout=json.dumps(state))
            if argv[1:5] == ["msg", "output", "Virtual-1", "scale"]:
                state["Virtual-1"]["logical"]["scale"] = float(argv[5])
            return mock.Mock(stdout="")

        with mock.patch.object(layout_module.subprocess, "run", side_effect=fake_run):
            self.assertTrue(layout_module.apply_niri_layout(None, "niri"))
        self.assertIn(["niri", "msg", "output", "Virtual-1", "scale", "1.25"], calls)

    def test_apply_niri_layout_updates_scale_before_computing_three_head_positions(self):
        calls = []
        state = {
            "Virtual-2": {
                "logical": {"x": 0, "y": 0, "width": 1440, "scale": 1.5},
                "current_mode": 0,
                "modes": [{"width": 2160}],
            },
            "Virtual-1": {
                "logical": {"x": 1440, "y": 0, "width": 3072, "scale": 1.25},
                "current_mode": 0,
                "modes": [{"width": 3840}],
            },
            "Virtual-3": {
                "logical": {"x": 4512, "y": 0, "width": 1440, "scale": 1.5},
                "current_mode": 0,
                "modes": [{"width": 2160}],
            },
        }

        def fake_run(argv, **_kwargs):
            calls.append(argv)
            if argv[1:] == ["msg", "--json", "outputs"]:
                return mock.Mock(stdout=json.dumps(state))
            if argv[1:5] == ["msg", "output", "Virtual-1", "scale"]:
                state["Virtual-1"]["logical"]["scale"] = float(argv[5])
            return mock.Mock(stdout="")

        with mock.patch.object(layout_module.subprocess, "run", side_effect=fake_run):
            self.assertTrue(layout_module.apply_niri_layout(("Virtual-2", "Virtual-3"), "niri"))
        self.assertEqual(
            calls,
            [
                ["niri", "msg", "--json", "outputs"],
                ["niri", "msg", "output", "Virtual-1", "scale", "1.5"],
                ["niri", "msg", "--json", "outputs"],
                ["niri", "msg", "output", "Virtual-2", "position", "set", "0", "0"],
                ["niri", "msg", "output", "Virtual-1", "position", "set", "1440", "0"],
                ["niri", "msg", "output", "Virtual-3", "position", "set", "4000", "0"],
            ],
        )


if __name__ == "__main__":
    unittest.main()
