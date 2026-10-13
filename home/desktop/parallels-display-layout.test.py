import importlib.util
import unittest
from pathlib import Path


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

    def test_positions_follow_live_logical_widths(self):
        outputs = {
            name: {"logical": {"width": width}}
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


if __name__ == "__main__":
    unittest.main()
