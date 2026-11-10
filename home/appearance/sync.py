"""Reconcile the Nix appearance policy at activation, shell startup and mode changes."""

import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import tomlkit

from configure import merge_file


def link(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() and os.readlink(path) == source:
        return
    with tempfile.TemporaryDirectory(dir=path.parent, prefix=".appearance-") as directory:
        temporary = Path(directory) / "link"
        temporary.symlink_to(source)
        os.replace(temporary, path)


def main():
    settings = json.loads(Path(sys.argv[1]).read_text())
    action = sys.argv[2]
    config, state = Path(settings["config"]), Path(settings["state"])

    def merge_manifest(name):
        for target, entry in json.loads(Path(name).read_text()).items():
            merge_file(Path(target.replace("@CONFIG@", str(config)).replace("@STATE@", str(state))), entry)

    def msg(*arguments, check=True):
        result = subprocess.run([settings["noctalia"], "msg", *arguments],
                              capture_output=True, text=True, check=check, timeout=15)
        if check and result.stdout.startswith("error:"):
            raise RuntimeError(result.stdout.strip())
        return result

    def online():
        result = msg("config-get", "theme.mode", check=False)
        return result.returncode == 0 and not result.stdout.startswith("error:")

    policy = {"source": "builtin", "builtin": "Gruvbox", "mode": "dark",
              "shell_mode": "follow", "sync_color_scheme": True,
              "templates": {"enable_builtin_templates": False, "enable_community_templates": False}}
    if action == "prepare":
        merge_manifest(settings["baseManifest"])
        saved = state / "noctalia/settings.toml"
        previous = tomlkit.parse(saved.read_text()).get("theme", {}).get("mode", "dark") if saved.exists() else "dark"
        policy["mode"] = previous if previous in ("dark", "light") else "dark"
        # ExecStartPre runs before the shell opens its override file.
        merge_file(state / "noctalia/settings.toml", {
            "format": "toml", "set": {
                "theme": policy,
                "wallpaper": {"automation": {"enabled": False}},
            },
        })
        mode = policy["mode"]
    elif action == "activate":
        merge_manifest(settings["baseManifest"])
        if online():
            def configure(prefix, values):
                for name, value in values.items():
                    if isinstance(value, dict):
                        configure(prefix + name + ".", value)
                    else:
                        msg("config-set", prefix + name, json.dumps(value))
            configure("theme.", policy)
            msg("config-set", "wallpaper.automation.enabled", "false")
        else:
            merge_file(state / "noctalia/settings.toml", {
                "format": "toml", "set": {"theme": policy, "wallpaper": {"automation": {"enabled": False}}},
            })
        mode = "dark"
    elif action == "sync":
        result = msg("config-get", "theme.mode")
        value = tomlkit.parse("value = " + result.stdout)
        mode = value.get("value", "dark")
    elif action in ("dark", "light"):
        mode = action
    else:
        raise ValueError(f"Unknown desktop-colors action: {action}")
    if mode not in ("dark", "light"):
        raise ValueError(f"Unexpected Noctalia mode: {mode}")

    state.mkdir(parents=True, exist_ok=True)
    with (state / "gruvbox.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        files = settings["paletteFiles"][mode]
        for target, source in {
            "gtk-2.0/gruvbox.rc": files["gtk2"],
            "gtk-3.0/gruvbox.css": files["gtk3"],
            "gtk-4.0/gruvbox.css": files["gtk4"],
            "qt5ct/colors/gruvbox.conf": files["qt"],
            "qt6ct/colors/gruvbox.conf": files["qt"],
        }.items():
            link(config / target, source)
        merge_manifest(settings["modeManifests"][mode])
        for version in ("qt5ct", "qt6ct"):
            path = config / version / (version + ".conf")
            if path.exists():
                path.touch()
        (state / "gruvbox-mode").write_text(mode + "\n")

    if os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        # System activation does not inherit the desktop's schema search path.
        gsettings_env = dict(os.environ, GSETTINGS_SCHEMA_DIR=settings["gsettingsSchemaDir"])
        for name, value in {
            "gtk-theme": "adw-gtk3-dark" if mode == "dark" else "adw-gtk3",
            "icon-theme": "Papirus-Dark" if mode == "dark" else "Papirus-Light",
            "color-scheme": "prefer-" + mode,
        }.items():
            subprocess.run([settings["gsettings"], "set", "org.gnome.desktop.interface", name, value],
                           env=gsettings_env, check=True)

    wallpapers = settings["wallpaperModes"][mode]
    if action == "prepare" or not online():
        merge_file(state / "noctalia/settings.toml", {
            "format": "toml", "set": {"wallpaper": {
                "default": {"path": wallpapers["default"]},
                "monitors": {name: {"path": path} for name, path in wallpapers["monitors"].items()},
            }},
        })
    else:
        msg("wallpaper-set", wallpapers["default"])
        for connector, path in wallpapers["monitors"].items():
            if msg("wallpaper-get", connector, check=False).stdout.startswith("error: unknown output"):
                continue
            msg("wallpaper-set", connector, path)


if __name__ == "__main__":
    main()
