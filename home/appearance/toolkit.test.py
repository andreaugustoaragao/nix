"""Check the rendered GTK/Qt/KDE palettes rather than their Nix generators."""

import configparser
import json
from pathlib import Path
import re
import sys

data = json.loads(Path(sys.argv[1]).read_text())
for mode in ("dark", "light"):
    colors, toolkit = data[mode], data["toolkit"][mode]
    for name in ("gtk3", "gtk4", "qt"):
        values = re.findall(r"#[0-9a-fA-F]{6}", toolkit[name])
        assert values, (mode, name)
        assert set(values).issubset(set(colors.values())), (mode, name, set(values) - set(colors.values()))
        assert "{{" not in toolkit[name], (mode, name)
    for name in ("gtk3", "gtk4"):
        assert f"@define-color window_bg_color {colors['base']};" in toolkit[name]
        assert f"@define-color window_fg_color {colors['text']};" in toolkit[name]
    assert f"--window-bg-color: {colors['base']};" in toolkit["gtk4"]
    assert f"--accent-bg-color: {colors['green']};" in toolkit["gtk4"]
    qt = configparser.ConfigParser()
    qt.read_string(toolkit["qt"])
    for group in ("active_colors", "inactive_colors", "disabled_colors"):
        values = [item.strip() for item in qt["ColorScheme"][group].split(",")]
        assert len(values) == 22, (mode, group, values)
        assert values[9] == colors["base"], (mode, group, "QPalette::Base")
        assert values[10] == colors["base"], (mode, group, "QPalette::Window")
    def rgb(color):
        return ",".join(str(int(color[index:index + 2], 16)) for index in (1, 3, 5))
    assert toolkit["kde"]["Colors:Window"]["BackgroundNormal"] == rgb(colors["base"])
    assert toolkit["kde"]["Colors:Window"]["ForegroundNormal"] == rgb(colors["text"])
print("GTK3/GTK4, Qt5/Qt6 and KDE: consistent Gruvbox dark/light tokens")
