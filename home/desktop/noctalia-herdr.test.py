"""Run the Herdr plugin in Luau with controlled snapshots and a Noctalia host."""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


PLUGINS = pathlib.Path(__file__).with_name("noctalia-plugins") / "herdr"
LUAU = "luau"


def literal(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "{" + ",".join(map(literal, value)) + "}"
    return "{" + ",".join(f"[{literal(k)}]={literal(v)}" for k, v in value.items()) + "}"


def run_luau(source):
    with tempfile.TemporaryDirectory(prefix="noctalia-herdr-") as directory:
        root = pathlib.Path(directory)
        shutil.copy(PLUGINS / "model.luau", root)
        script = root / "test.luau"
        # Noctalia requires an explicit extension; the standalone CLI appends it.
        script.write_text(source.replace("./model.luau", "./model"))
        subprocess.run([LUAU, str(script)], check=True)


HOST = r'''
local values, watchers, pending, calls, notifications = {}, {}, {}, {}, {}
local bar, panelTree, tooltip, closed, toggled
ui = {}
for _, kind in ipairs({"row", "column", "scroll", "glyph", "label", "button"}) do
    ui[kind] = function(props, children) return {kind = kind, props = props, children = children or {}} end
end
barWidget = {
    setTooltip = function(value) tooltip = value end,
    render = function(value) bar = value end,
}
panel = {
    render = function(value) panelTree = value end,
    close = function() closed = true end,
}
local reject = nil
noctalia = {
    state = {
        get = function(key) return values[key] end,
        set = function(key, value)
            values[key] = value
            for _, callback in ipairs(watchers[key] or {}) do callback(value) end
        end,
        watch = function(key, callback)
            watchers[key] = watchers[key] or {}
            table.insert(watchers[key], callback)
        end,
    },
    runAsync = function(argv, callback)
        table.insert(calls, argv)
        if reject == argv[1] then return false end
        table.insert(pending, {argv = argv, callback = callback})
        return true
    end,
    setUpdateInterval = function(ms) assert(ms == 2000) end,
    togglePanel = function(id) toggled = id end,
    notifyError = function(title, message) table.insert(notifications, {title, message}) end,
    json = {decode = function(value)
        if value == "bad-json" then error("invalid JSON") end
        return decoded[value]
    end},
}
local function reply(result)
    local request = table.remove(pending, 1)
    assert(request and request.callback, "missing subprocess callback")
    request.callback(result)
end
local function findButtons(node, result)
    result = result or {}
    if node.kind == "button" then table.insert(result, node.props) end
    for _, child in ipairs(node.children) do findButtons(child, result) end
    return result
end
'''


class HerdrTests(unittest.TestCase):
    def test_visible_agents_use_core_status_and_sort_attention_first(self):
        run_luau(r'''
local model = require("./model.luau")
local panes = {
    {terminal = "done", status = "idle", app = "codex"},
    {terminal = "idle", status = "idle", app = "codex"},
    {terminal = "working", status = "working", app = "pi"},
    {terminal = "blocked", status = "blocked", app = "codex"},
    {terminal = "error", status = "error", app = "codex"},
    {terminal = "shell"},
    {terminal = "cleared", status = "blocked", app = "codex"},
    {terminal = "finished", status = "working"},
}
local window = {spaces = {{name = "nix", tabs = {{name = "widget", terminals = panes},
    {name = "duplicate", terminals = {{terminal = "working", status = "working"}}}}},
    {name = "remote", machine = "vps", tabs = {{name = "api", terminals = {
        {terminal = "t1", status = "blocked", name = "review"}}}}}}}
local core = {terminals = {}}
for _, pane in ipairs(panes) do
    table.insert(core.terminals, {address = pane.terminal, status = pane.terminal ~= "cleared" and pane.terminal or nil,
        state = pane.terminal == "finished" and "finished" or "live"})
end
table.insert(core.terminals, {address = "hidden", status = "error", state = "live"})
table.insert(core.terminals, {address = "vps/t1", status = "working", state = "live"})
local snapshot = model.collect(window, core)
assert(#snapshot.agents == 6, "shells, hidden agents, finished programs and duplicate panes must not count")
assert(snapshot.working == 2 and snapshot.attention == 2 and snapshot.errors == 1)
assert(snapshot.agents[1].status == "error" and snapshot.agents[2].status == "blocked")
assert(snapshot.agents[5].status == "done", "core done must override window idle")
assert(snapshot.agents[6].status == "idle")
assert(snapshot.agents[4].address == "vps/t1", "remote targets must keep their machine")
assert(snapshot.agents[4].title == "remote / api / review")
assert(#model.collect({spaces = {}}, {terminals = {}}).agents == 0)
''')

    def test_polling_recovers_and_never_reports_failed_reads_as_zero_agents(self):
        run_luau(HOST + r'''
decoded = {
    window = {spaces = {{name = "nix", tabs = {{name = "widget", terminals = {
        {terminal = "t1", status = "idle", app = "codex"}}}}}}},
    core = {terminals = {{address = "t1", status = "done", state = "live"}}},
    wrong = {spaces = "invalid"},
    malformed = {spaces = {{}}},
}
''' + (PLUGINS / "service.luau").read_text() + r'''
assert(values.snapshot.phase == "loading" and #pending == 1)
update(); update()
assert(#pending == 1, "polls must not overlap")
reply({exitCode = 0, stdout = "window"})
assert(pending[1].argv[1] == "hc" and pending[1].argv[3] == "--json")
update()
assert(#pending == 1)
reply({exitCode = 0, stdout = "core"})
assert(values.snapshot.phase == "ready" and values.snapshot.agents[1].status == "done")
for _, result in ipairs({
    {exitCode = 1}, {exitCode = 0, stdout = "bad-json"},
    {exitCode = 0, stdout = "wrong"}, {exitCode = 0, stdout = "window", timedOut = true},
    {exitCode = 0, stdout = "window", stdoutTruncated = true},
}) do
    update(); reply(result)
    assert(values.snapshot.phase == "unavailable" and values.snapshot.agents == nil)
end
update(); reply({exitCode = 0, stdout = "malformed"}); reply({exitCode = 0, stdout = "core"})
assert(values.snapshot.phase == "unavailable")
update(); reply({exitCode = 0, stdout = "window"}); reply({exitCode = 1})
assert(values.snapshot.phase == "unavailable")
reject = "hc"
update(); reply({exitCode = 0, stdout = "window"})
assert(values.snapshot.phase == "unavailable")
reject = "herdr-app"
update()
assert(values.snapshot.phase == "unavailable")
reject = nil
update(); reply({exitCode = 0, stdout = "window"}); reply({exitCode = 0, stdout = "core"})
assert(values.snapshot.phase == "ready", "a failed read must not stop future polls")
''')

    def test_bar_has_stable_slots_and_distinguishes_unknown_from_zero(self):
        run_luau(HOST + (PLUGINS / "widget.luau").read_text() + r'''
assert(bar.children[3].children[2].props.text == "–")
noctalia.state.set("snapshot", {phase = "ready", agents = {}, working = 0, attention = 0, errors = 0})
assert(bar.children[3].children[2].props.text == "0")
assert(bar.children[4].children[2].props.color == "outline")
noctalia.state.set("snapshot", {phase = "ready", agents = {}, working = 100, attention = 1, errors = 0})
assert(bar.children[3].children[2].props.text == "99+")
assert(bar.children[4].children[2].props.color == "tertiary")
assert(bar.children[3].props.width == 39 and bar.children[4].props.width == 39)
noctalia.state.set("snapshot", {phase = "ready", agents = {}, working = 1, attention = 1, errors = 1})
assert(bar.children[4].children[2].props.color == "error")
noctalia.state.set("snapshot", {phase = "unavailable", message = "Open Herdr, then retry."})
assert(tooltip == "Open Herdr, then retry.")
assert(bar.children[3].children[2].props.text == "–")
onClick()
assert(toggled == "aragao/herdr:agents")
''')

    def test_panel_targets_the_clicked_agent_and_reports_focus_failure(self):
        run_luau(HOST + (PLUGINS / "panel.luau").read_text() + r'''
local a = {address = "t1", title = "nix / widget", app = "codex", status = "working"}
local b = {address = "vps/t2", title = "api / review", app = "pi", status = "blocked"}
noctalia.state.set("snapshot", {phase = "ready", agents = {a, b}})
assert(panelTree == nil, "closed panels must not redraw")
onOpen()
local buttons = findButtons(panelTree)
assert(#buttons == 3 and buttons[2].text == b.title, "needs-you rows must come first")
buttons[2].onClick()
assert(closed)
assert(calls[1][3] == "agent.focus" and calls[1][4] == "--terminal" and calls[1][5] == "vps/t2")
reply({exitCode = 0})
assert(#calls == 2 and #calls[2] == 1 and calls[2][1] == "herdr-app", "focus must raise Herdr")
table.remove(pending, 1)
buttons[3].onClick()
assert(calls[3][5] == "t1", "each handler must keep its own terminal")
reply({exitCode = 1})
assert(#notifications == 1 and #calls == 3, "failed focus must not launch another window")
noctalia.state.set("snapshot", {phase = "unavailable", message = "Open Herdr, then retry."})
assert(#findButtons(panelTree) == 1, "failed snapshots must clear stale agent targets")
onClose()
noctalia.state.set("snapshot", {phase = "ready", agents = {}})
onOpen()
assert(#findButtons(panelTree) == 1)
''')


def verify_live():
    window = json.loads(subprocess.check_output(["herdr-app", "ls"], timeout=10))
    core = json.loads(subprocess.check_output(["hc", "ls", "--json"], timeout=10))
    run_luau("local model = require('./model.luau')\n"
             f"local snapshot = model.collect({literal(window)}, {literal(core)})\n"
             "assert(snapshot.phase == 'ready')\n"
             "for _, agent in ipairs(snapshot.agents) do\n"
             " print(agent.status .. '\\t' .. agent.address .. '\\t' .. agent.title)\nend\n"
             "print(string.format('%d working, %d need you, %d agents', snapshot.working, snapshot.attention, #snapshot.agents))\n")


if __name__ == "__main__":
    if "--live" in sys.argv:
        verify_live()
    else:
        unittest.main()
