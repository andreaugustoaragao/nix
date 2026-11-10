"""Exercise the real Luau adapters without changing host audio or recording."""

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


if __name__ == "__main__":
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        LUAU = sys.argv.pop(1)
    unittest.main()
