"""Exercise the real Luau adapters without changing host audio or recording."""

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


LUAU = "luau"
PLUGINS = pathlib.Path(__file__).with_name("noctalia-plugins") / "dms-toolbar"


class ToolbarTests(unittest.TestCase):
    def test_recorder_states(self):
        subprocess.run([LUAU, str(PLUGINS / "recording.test.luau")], check=True)

    def test_volume_controls_and_queued_drag_updates(self):
        host = r'''
local current = 0.84
local isMuted = false
local pending = {}
local writes = {}
local tree
ui = {}
for _, name in ipairs({"row", "button", "slider", "label"}) do
    ui[name] = function(props, children) return { props = props, children = children } end
end
barWidget = {
    setTooltip = function(_) end,
    render = function(value) tree = value end,
}
noctalia = {
    setUpdateInterval = function(_) end,
    runAsync = function(argv, callback)
        if argv[2] == "get-volume" then
            callback({exitCode = 0, stdout = "Volume: " .. current .. (isMuted and " [MUTED]" or "")})
        elseif argv[2] == "set-volume" then
            table.insert(writes, argv)
            table.insert(pending, function()
                current = tonumber(argv[4])
                callback({exitCode = 0})
            end)
        elseif argv[2] == "set-mute" then
            isMuted = not isMuted
            callback({exitCode = 0})
        end
        return true
    end,
}
'''
        assertions = r'''
assert(tree.children[3].props.text == "84%")
onVolumeChanged("60")
onVolumeChanged("70")
assert(#writes == 1, "drag writes must be serialized")
table.remove(pending, 1)()
assert(#writes == 2 and writes[2][4] == "0.70", "latest drag value must win")
table.remove(pending, 1)()
assert(tree.children[3].props.text == "70%")
assert(tree.children[2].props.value == 70)
onVolumeChanged("0")
table.remove(pending, 1)()
assert(tree.children[3].props.text == "0%", "zero volume must be usable")
onVolumeChanged("invalid")
assert(#writes == 3, "invalid callback must not reach wpctl")
onMute()
assert(tree.children[1].props.glyph == "volume-off")
onMute()
assert(tree.children[1].props.glyph == "volume")
print("Volume controls passed: slider values, queued drags, mute, and invalid input.")
'''
        with tempfile.TemporaryDirectory(prefix="noctalia-toolbar-") as directory:
            script = pathlib.Path(directory) / "volume.test.luau"
            script.write_text(host + (PLUGINS / "volume.luau").read_text() + assertions)
            subprocess.run([LUAU, str(script)], check=True)

    def test_resource_numbers_without_progress_bars(self):
        self._run_resources(
            "ram",
            r'''
ramStats = {
    ram = { usedMb = 1536, totalMb = 8192, usagePercent = 95 },
    swap = { usedMb = 512, totalMb = 2048 },
}
noctalia.diskStats = function()
    error("ram widget must not query disk")
end
''',
            r'''
assertNumbers("memory", "1.5/8.0G", "RAM: 1.5 / 8.0 GiB\nSwap: 0.5 / 2.0 GiB")
assertControlCenter()
ramStats = nil
update()
assertNumbers("memory", "--", "System statistics are not available yet.")
assertControlCenter()
print("RAM numbers passed: label, tooltip, unavailable stats, and control center.")
''',
        )
        self._run_resources(
            "disk",
            r'''
diskStatsValue = {
    totalBytes = 10737418240,
    freeBytes = 6442450944,
    availableBytes = 5905580032,
    usagePercent = 40,
}
noctalia.systemStats = function()
    error("disk widget must not query memory")
end
''',
            r'''
assertNumbers("storage", "4.0/10.0G", "Root filesystem: 4.0 / 10.0 GiB\nAvailable: 5.5 GiB")
assertControlCenter()
diskStatsValue = nil
update()
assertNumbers("storage", "--", "System statistics are not available yet.")
assertControlCenter()
print("Disk numbers passed: label, tooltip, unavailable stats, and control center.")
''',
        )

    def _run_resources(self, resource, prelude, assertions):
        host = r'''
local tree
local tooltip
local interval
local clicks = {}
local progressCalls = 0
ui = {}
for _, name in ipairs({"row", "glyph", "label"}) do
    ui[name] = function(props, children)
        return { kind = name, props = props, children = children }
    end
end
ui.progress = function(props, children)
    progressCalls = progressCalls + 1
    return { kind = "progress", props = props, children = children }
end
barWidget = {
    setTooltip = function(text) tooltip = text end,
    render = function(value) tree = value end,
}
noctalia = {
    getConfig = function(key)
        assert(key == "resource", key)
        return "RESOURCE"
    end,
    setUpdateInterval = function(ms) interval = ms end,
    systemStats = function()
        return ramStats
    end,
    diskStats = function(path)
        assert(path == "/", path)
        return diskStatsValue
    end,
    runAsync = function(argv)
        table.insert(clicks, argv)
        return true
    end,
}
'''.replace("RESOURCE", resource)
        shared = r'''
local function assertNumbers(glyph, text, tip)
    assert(interval == 2000, "resource widgets must keep polling")
    assert(progressCalls == 0, "resource widgets must not draw progress bars")
    assert(tree.kind == "row" and tree.props.gap == 4 and tree.props.align == "center")
    assert(#tree.children == 2, "row should be glyph plus numeric label")
    assert(tree.children[1].kind == "glyph" and tree.children[1].props.name == glyph)
    assert(tree.children[1].props.size == 13)
    assert(tree.children[2].kind == "label" and tree.children[2].props.text == text, tree.children[2].props.text)
    assert(tooltip == tip, tooltip)
end
local function assertControlCenter()
    onClick()
    local argv = clicks[#clicks]
    assert(#argv == 5)
    assert(argv[1] == "noctalia" and argv[2] == "msg" and argv[3] == "panel-toggle")
    assert(argv[4] == "control-center" and argv[5] == "system")
end
'''
        with tempfile.TemporaryDirectory(prefix="noctalia-toolbar-") as directory:
            script = pathlib.Path(directory) / "resources.test.luau"
            script.write_text(host + prelude + (PLUGINS / "resources.luau").read_text() + shared + assertions)
            subprocess.run([LUAU, str(script)], check=True)

    def test_rendered_toolbar_lists_drop_network_and_gauges(self):
        toolbar = pathlib.Path(__file__).with_name("noctalia-toolbar.nix")
        expression = r'''
let
  lib = {
    optional = cond: elem: if cond then [ elem ] else [ ];
    splitString = sep: s: builtins.throw "splitString should stay lazy";
  };
  load = personalOnly:
    import __TOOLBAR__ {
      inherit lib personalOnly;
      displays = { dp2 = "DP-2"; };
    };
  lists = cfg: {
    start = cfg.bar.main.start;
    center = cfg.bar.main.center;
    end = cfg.bar.main.end;
    portrait = cfg.bar.main.monitor.portrait;
    third = cfg.bar.main.monitor.third;
    cpu = cfg.widget.cpu;
    ram = cfg.widget.ram.type;
    disk = cfg.widget.disk.type;
    download = cfg.widget.download;
    upload = cfg.widget.upload;
    network = cfg.widget.network;
    inlineVolume = cfg.widget."inline-volume".type;
    recorder = cfg.widget.recorder.type;
    rebuild = cfg.widget."nix-rebuild".type;
    herdr = cfg.widget.herdr.type;
    plugins = cfg.plugins.enabled;
    bluetooth = cfg.widget.bluetooth;
    privacy = cfg.widget.privacy;
    launcher = cfg.shell.panel.launcher_placement;
    notification = cfg.notification.position;
  };
in {
  shared = lists (load false);
  personal = lists (load true);
}
'''.replace("__TOOLBAR__", json.dumps(str(toolbar)))
        result = subprocess.run(
            [
                "nix",
                "eval",
                "--offline",
                "--impure",
                "--option",
                "allow-import-from-derivation",
                "false",
                "--json",
                "--expr",
                expression,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        rendered = json.loads(result.stdout)
        primary = [
            "herdr",
            "clipboard",
            "cpu",
            "ram",
            "disk",
            "notifications",
            "battery",
            "inline-volume",
            "control-center",
            "nix-rebuild",
            "bluetooth",
            "caffeine",
            "recorder",
            "download",
            "upload",
            "privacy",
            "tray",
        ]
        secondary = [
            "herdr",
            "clipboard",
            "notifications",
            "control-center",
            "nix-rebuild",
            "download",
            "upload",
            "bluetooth",
            "privacy",
            "tray",
        ]
        shared = rendered["shared"]
        personal = rendered["personal"]
        self.assertEqual(shared["end"], primary)
        self.assertEqual(personal["end"], [item for item in primary if item != "recorder"])
        for output in (shared, personal):
            self.assertEqual(output["start"], ["clock", "weather", "workspaces", "active_window", "media"])
            self.assertEqual(output["center"], [])
            self.assertNotIn("network", output["end"])
            for monitor in ("portrait", "third"):
                self.assertEqual(output[monitor]["end"], secondary)
                self.assertNotIn("network", output[monitor]["end"])
                self.assertEqual(output[monitor]["start"], ["clock", "workspaces", "active_window"])
                self.assertEqual(output[monitor]["center"], [])
            self.assertEqual(output["portrait"]["match"], "DP-2")
            self.assertEqual(output["third"]["match"], "Virtual-3")
            self.assertEqual(
                output["cpu"],
                {
                    "type": "sysmon",
                    "stat": "cpu_usage",
                    "visualization": "none",
                    "label_min_width": 28,
                },
            )
            self.assertEqual(output["ram"], "aragao/dms-toolbar:ram")
            self.assertEqual(output["disk"], "aragao/dms-toolbar:disk")
            self.assertEqual(output["download"]["visualization"], "none")
            self.assertEqual(output["download"]["stat"], "net_rx")
            self.assertEqual(output["upload"]["visualization"], "none")
            self.assertEqual(output["upload"]["stat"], "net_tx")
            self.assertEqual(output["network"], {"show_label": False, "vpn_status": "both"})
            self.assertEqual(output["inlineVolume"], "aragao/dms-toolbar:volume")
            self.assertEqual(output["recorder"], "aragao/dms-toolbar:recorder")
            self.assertEqual(output["rebuild"], "aragao/nix-rebuild:rebuild")
            self.assertEqual(output["herdr"], "aragao/herdr:radar")
            self.assertEqual(output["plugins"], ["aragao/dms-toolbar", "aragao/nix-rebuild", "aragao/herdr"])
            self.assertEqual(output["bluetooth"], {"hide_when_adapter_off": True})
            self.assertEqual(output["privacy"], {"hide_inactive": True})
            self.assertEqual(output["launcher"], "floating")
            self.assertEqual(output["notification"], "top_center")

    def test_bar_font_is_noto_sans_medium(self):
        settings = pathlib.Path(__file__).with_name("noctalia-settings.nix")
        lock = json.loads(settings.parents[2].joinpath("flake.lock").read_text())
        locked = lock["nodes"][lock["nodes"]["root"]["inputs"]["nixpkgs"]]["locked"]
        nixpkgs = f"github:{locked['owner']}/{locked['repo']}/{locked['rev']}"
        expression = r'''
let
  lib = (builtins.getFlake __NIXPKGS__).lib;
  cfg = import __SETTINGS__ {
    inherit lib;
    pkgs = { };
    wallpapers = "/unused";
    displays = { dp2 = "DP-2"; };
    personalOnly = false;
    lockScreen = false;
    preview = true;
  };
  planeKeys = [
    "background_opacity"
    "border"
    "border_width"
    "margin_edge"
    "capsule"
    "capsule_fill"
    "capsule_opacity"
    "capsule_radius"
    "capsule_border"
    "capsule_thickness"
    "compositor_blur"
  ];
  monitor = name: cfg.bar.main.monitor.${name};
in {
  fontFamily = cfg.bar.main.font_family;
  fontWeight = cfg.bar.main.font_weight;
  fontScale = cfg.bar.main.font_scale;
  shellFont = cfg.shell.font_family;
  thickness = cfg.bar.main.thickness;
  radius = cfg.bar.main.radius;
  scale = cfg.bar.main.scale;
  widgetSpacing = cfg.bar.main.widget_spacing;
  capsulePadding = cfg.bar.main.capsule_padding;
  position = cfg.bar.main.position;
  backgroundOpacity = cfg.bar.main.background_opacity;
  borderWidth = cfg.bar.main.border_width;
  borderSet = cfg.bar.main ? border;
  marginEdge = cfg.bar.main.margin_edge;
  compositorBlur = cfg.bar.main.compositor_blur;
  shadow = cfg.bar.main.shadow;
  capsule = cfg.bar.main.capsule;
  capsuleFill = cfg.bar.main.capsule_fill;
  capsuleOpacity = cfg.bar.main.capsule_opacity;
  capsuleRadiusSet = cfg.bar.main ? capsule_radius;
  capsuleBorderSet = cfg.bar.main ? capsule_border;
  capsuleThicknessSet = cfg.bar.main ? capsule_thickness;
  start = cfg.bar.main.start;
  center = cfg.bar.main.center;
  end = cfg.bar.main.end;
  portrait = {
    match = (monitor "portrait").match;
    start = (monitor "portrait").start;
    center = (monitor "portrait").center;
    end = (monitor "portrait").end;
    overridesPlane = builtins.any (name: builtins.hasAttr name (monitor "portrait")) planeKeys;
  };
  third = {
    match = (monitor "third").match;
    start = (monitor "third").start;
    center = (monitor "third").center;
    end = (monitor "third").end;
    overridesPlane = builtins.any (name: builtins.hasAttr name (monitor "third")) planeKeys;
  };
  cpu = cfg.widget.cpu;
  ram = cfg.widget.ram.type;
  disk = cfg.widget.disk.type;
  download = cfg.widget.download;
  upload = cfg.widget.upload;
  rebuild = cfg.widget."nix-rebuild".type;
}
'''.replace("__NIXPKGS__", json.dumps(nixpkgs)).replace("__SETTINGS__", json.dumps(str(settings)))
        result = subprocess.run(
            [
                "nix",
                "eval",
                "--offline",
                "--impure",
                "--option",
                "allow-import-from-derivation",
                "false",
                "--json",
                "--expr",
                expression,
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        rendered = json.loads(result.stdout)
        primary = [
            "herdr",
            "clipboard",
            "cpu",
            "ram",
            "disk",
            "notifications",
            "battery",
            "inline-volume",
            "control-center",
            "nix-rebuild",
            "bluetooth",
            "caffeine",
            "recorder",
            "download",
            "upload",
            "privacy",
            "tray",
        ]
        secondary = [
            "herdr",
            "clipboard",
            "notifications",
            "control-center",
            "nix-rebuild",
            "download",
            "upload",
            "bluetooth",
            "privacy",
            "tray",
        ]
        self.assertEqual(
            {
                key: rendered[key]
                for key in (
                    "fontFamily",
                    "fontWeight",
                    "fontScale",
                    "shellFont",
                    "thickness",
                    "radius",
                    "scale",
                    "widgetSpacing",
                    "capsulePadding",
                )
            },
            {
                "fontFamily": "Noto Sans",
                "fontWeight": 500,
                "fontScale": 1,
                "shellFont": "Cantarell",
                "thickness": 32,
                "radius": 16,
                "scale": 0.825,
                "widgetSpacing": 5,
                "capsulePadding": 4.5,
            },
        )
        self.assertEqual(
            {
                key: rendered[key]
                for key in (
                    "position",
                    "backgroundOpacity",
                    "borderWidth",
                    "borderSet",
                    "marginEdge",
                    "compositorBlur",
                    "shadow",
                    "capsule",
                    "capsuleFill",
                    "capsuleOpacity",
                    "capsuleRadiusSet",
                    "capsuleBorderSet",
                    "capsuleThicknessSet",
                )
            },
            {
                "position": "top",
                "backgroundOpacity": 0,
                "borderWidth": 0,
                "borderSet": False,
                "marginEdge": 10,
                "compositorBlur": False,
                "shadow": False,
                "capsule": True,
                "capsuleFill": "surface_container",
                "capsuleOpacity": 1,
                "capsuleRadiusSet": False,
                "capsuleBorderSet": False,
                "capsuleThicknessSet": False,
            },
        )
        self.assertEqual(rendered["start"], ["clock", "weather", "workspaces", "active_window", "media"])
        self.assertEqual(rendered["center"], [])
        self.assertEqual(rendered["end"], primary)
        self.assertNotIn("network", rendered["end"])
        for output in (rendered["portrait"], rendered["third"]):
            self.assertFalse(output["overridesPlane"])
            self.assertEqual(output["start"], ["clock", "workspaces", "active_window"])
            self.assertEqual(output["center"], [])
            self.assertEqual(output["end"], secondary)
            self.assertNotIn("network", output["end"])
        self.assertEqual(rendered["portrait"]["match"], "DP-2")
        self.assertEqual(rendered["third"]["match"], "Virtual-3")
        self.assertEqual(
            rendered["cpu"],
            {
                "type": "sysmon",
                "stat": "cpu_usage",
                "visualization": "none",
                "label_min_width": 28,
            },
        )
        self.assertEqual(rendered["ram"], "aragao/dms-toolbar:ram")
        self.assertEqual(rendered["disk"], "aragao/dms-toolbar:disk")
        self.assertEqual(rendered["download"]["visualization"], "none")
        self.assertEqual(rendered["download"]["stat"], "net_rx")
        self.assertEqual(rendered["upload"]["visualization"], "none")
        self.assertEqual(rendered["upload"]["stat"], "net_tx")
        self.assertEqual(rendered["rebuild"], "aragao/nix-rebuild:rebuild")


if __name__ == "__main__":
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        LUAU = sys.argv.pop(1)
    unittest.main()
