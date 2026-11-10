"""Load both palettes through the actual qtct platform plugin, without a display."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if sys.argv[1] == "child":
    version, background, foreground = sys.argv[2:]
    if version == "6":
        from PyQt6.QtGui import QPalette
        from PyQt6.QtWidgets import QApplication
    else:
        from PyQt5.QtGui import QPalette
        from PyQt5.QtWidgets import QApplication
    app = QApplication([])
    palette = app.palette()
    assert palette.color(QPalette.ColorRole.Window).name() == background
    assert palette.color(QPalette.ColorRole.WindowText).name() == foreground
    print(f"Qt{version}: {background} / {foreground}")
else:
    data = json.loads(Path(sys.argv[1]).read_text())
    version, plugins = sys.argv[2:]
    with tempfile.TemporaryDirectory() as directory:
        config = Path(directory) / f"qt{version}ct"
        config.mkdir()
        palette = config / "gruvbox.conf"
        (config / f"qt{version}ct.conf").write_text(
            f"[Appearance]\ncustom_palette=true\nstyle=Fusion\ncolor_scheme_path={palette}\n"
            '[Fonts]\ngeneral="DejaVu Sans,10,-1,5,50,0,0,0,0,0"\n'
            'fixed="DejaVu Sans Mono,10,-1,5,50,0,0,0,0,0"\n')
        fonts = Path(directory) / "fonts.conf"
        fonts.write_text(f"<fontconfig><cachedir>{directory}/cache</cachedir></fontconfig>")
        env = dict(os.environ, XDG_CONFIG_HOME=directory,
                   XDG_RUNTIME_DIR=directory, XDG_CACHE_HOME=directory + "/cache",
                   FONTCONFIG_FILE=str(fonts), HOME=directory,
                   QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="qt5ct",
                   QT_PLUGIN_PATH=plugins)
        env.pop("QT_STYLE_OVERRIDE", None)
        for mode in ("dark", "light"):
            palette.write_text(data["toolkit"][mode]["qt"])
            subprocess.run([sys.executable, __file__, "child", version,
                            data[mode]["base"], data[mode]["text"]], env=env, check=True)
