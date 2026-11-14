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
local nowMs = 1000000
ui = {}
for _, kind in ipairs({"row", "column", "box", "scroll", "glyph", "label", "button", "separator", "spacer"}) do
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
    nowMs = function() return nowMs end,
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
local function findNode(node, key)
    if node.props and node.props.key == key then return node.props end
    for _, child in ipairs(node.children) do
        local found = findNode(child, key)
        if found then return found end
    end
    return nil
end
local function findLabels(node, result)
    result = result or {}
    if node.kind == "label" then table.insert(result, node.props) end
    for _, child in ipairs(node.children) do findLabels(child, result) end
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
local window = {spaces = {{name = "nix", active = true, tabs = {{name = "widget", active = true, terminals = panes},
    {name = "duplicate", terminals = {{terminal = "working", status = "working"}}}}},
    {name = "remote", machine = "vps", tabs = {{name = "api", terminals = {
        {terminal = "t1", status = "blocked", name = "review"}}}}}}}
local core = {terminals = {}}
for _, pane in ipairs(panes) do
    table.insert(core.terminals, {address = pane.terminal, status = pane.terminal ~= "cleared" and pane.terminal or nil,
        state = pane.terminal == "finished" and "finished" or "live"})
end
table.insert(core.terminals, {address = "hidden", status = "error", state = "live"})
table.insert(core.terminals, {address = "vps/t1", status = "working", state = "live", turn = 12})
local snapshot = model.collect(window, core)
assert(#snapshot.agents == 6, "shells, hidden agents, finished programs and duplicate panes must not count")
assert(snapshot.working == 2 and snapshot.attention == 2 and snapshot.errors == 1 and snapshot.done == 1 and snapshot.idle == 1)
assert(snapshot.agents[1].status == "error" and snapshot.agents[2].status == "blocked")
assert(snapshot.agents[5].status == "done", "core done must override window idle")
assert(snapshot.agents[6].status == "idle")
assert(model.statuses.blocked.color == "secondary", "blocked attention must use warning amber secondary")
assert(model.statuses.done.color == "tertiary", "done must use calm tertiary")
assert(snapshot.agents[4].address == "vps/t1", "remote targets must keep their machine")
assert(snapshot.agents[4].title == "review" and snapshot.agents[4].subtitle == "remote · api")
assert(snapshot.agents[4].fullTitle == "remote / api / review")
assert(snapshot.agents[4].turn == 12)
assert(snapshot.agents[1].active == true)
assert(#model.collect({spaces = {}}, {terminals = {}}).agents == 0)
''')

    def test_display_disambiguation_nesting_and_transitions(self):
        run_luau(r'''
local model = require("./model.luau")
local window = {spaces = {
    {name = "system", active = true, tabs = {
        {name = "chief-of-staff", active = true, terminals = {
            {terminal = "t1", status = "working", app = "codex", sub_agents = {"t2", "t3"}},
        }},
        {name = "Runtime adapters", terminals = {
            {terminal = "t2", status = "working", app = "codex", name = "t014-impl"},
            {terminal = "t3", status = "blocked", app = "codex", name = "t001-urgent"},
        }},
    }},
    {name = "fulcrum", tabs = {
        {name = "t001-query-fixture-fix", terminals = {
            {terminal = "t4", status = "done", app = "codex", name = "t001-query-fixture-fix"},
        }},
        {name = "settled-tab", settled = true, terminals = {
            {terminal = "t5", status = "idle", app = "codex"},
        }},
    }},
}}
local core = {terminals = {
    {address = "t1", status = "working", state = "live", turn = 41},
    {address = "t2", status = "working", state = "live", parent = "t1", turn = 2},
    {address = "t3", status = "blocked", state = "live", parent = "t1", turn = 1},
    {address = "t4", status = "done", state = "live", turn = 3},
    {address = "t5", status = "idle", state = "live", turn = 9},
}}
local transitions = {}
local snap1 = model.collect(window, core, 100000, transitions)
local byAddr = {}
for _, a in ipairs(snap1.agents) do byAddr[a.address] = a end
assert(byAddr.t1.title == "system" and byAddr.t1.subtitle == "chief-of-staff")
assert(byAddr.t2.title == "t014-impl" and byAddr.t2.subtitle == "system · Runtime adapters")
assert(byAddr.t4.title == "t001-query-fixture-fix" and byAddr.t4.subtitle == "fulcrum", "redundant tab name must not duplicate")
assert(byAddr.t1.since == 100000)

-- Transition t4 from done -> working; t1 keeps original since while t4 updates.
core.terminals[4].status = "working"
local snap2 = model.collect(window, core, 460000, transitions)
local byAddr2 = {}
for _, a in ipairs(snap2.agents) do byAddr2[a.address] = a end
assert(byAddr2.t1.since == 100000, "unchanged status must preserve transition timestamp")
assert(byAddr2.t4.since == 460000, "changed status must update transition timestamp")
assert(model.formatDuration(460000 - byAddr2.t1.since) == "6m")
assert(model.formatDuration(30000) == "<1m")
assert(model.formatDuration(7200000) == "2h")

-- Grouping: t2 nests under working parent t1, while blocked child t3 stays root in attention.
local sections, hidden = model.groupAgents(snap1.agents, false)
assert(hidden == 0)
assert(sections[1].id == "attention" and sections[1].rows[1].agent.address == "t3" and sections[1].rows[1].depth == 0)
assert(sections[2].id == "working" and #sections[2].rows == 2)
assert(sections[2].rows[1].agent.address == "t1" and sections[2].rows[1].depth == 0)
assert(sections[2].rows[2].agent.address == "t2" and sections[2].rows[2].depth == 1)
assert(sections[2].rows[2].sameSpaceParent == true)

local _, activeHidden = model.groupAgents(snap1.agents, true)
assert(activeHidden == 1, "activeOnly must hide idle agents")
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
assert(values.snapshot.agents[1].since == 1000000)
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
nowMs = 1120000
update(); reply({exitCode = 0, stdout = "window"}); reply({exitCode = 0, stdout = "core"})
assert(values.snapshot.phase == "ready", "a failed read must not stop future polls")
assert(values.snapshot.agents[1].since == 1000000, "transient failure must preserve transition timestamp")
''')

    def test_bar_hides_zero_attention_and_right_click_jumps_to_attention(self):
        run_luau(HOST + (PLUGINS / "widget.luau").read_text() + r'''
assert(bar.children[3].children[2].props.text == "–")
assert(#bar.children == 3, "loading bar must not reserve an empty attention slot")

noctalia.state.set("snapshot", {phase = "ready", agents = {}, working = 0, attention = 0, errors = 0, done = 0})
assert(bar.children[3].children[2].props.text == "0")
assert(bar.children[1].props.color == "on_surface")
assert(bar.children[3].children[1].props.color == "on_surface_variant/0.60")
assert(bar.children[3].children[2].props.color == "on_surface_variant/0.60")
assert(#bar.children == 3, "zero attention must stay hidden from the bar pill")

noctalia.state.set("snapshot", {
    phase = "ready",
    agents = {{address = "t9", status = "blocked"}},
    working = 100, attention = 1, errors = 0, done = 0,
})
assert(#bar.children == 4, "non-zero attention must appear in the bar pill")
assert(bar.children[3].children[2].props.text == "99+")
assert(bar.children[3].children[1].props.color == "primary")
assert(bar.children[3].children[2].props.color == "on_surface")
assert(bar.children[4].children[1].props.color == "secondary")
assert(bar.children[4].children[2].props.color == "secondary")

onRightClick()
assert(calls[1][3] == "agent.focus" and calls[1][5] == "t9", "right-click must focus top attention agent")
reply({exitCode = 0})
assert(#calls == 2 and calls[2][1] == "herdr-app")

noctalia.state.set("snapshot", {phase = "ready", agents = {{address = "t1", status = "working"}}, working = 1, attention = 1, errors = 1, done = 0})
assert(bar.children[4].children[1].props.color == "error")
assert(bar.children[4].children[2].props.color == "error")

noctalia.state.set("snapshot", {phase = "unavailable", message = "Open Herdr, then retry."})
assert(tooltip == "Open Herdr, then retry.")
assert(bar.children[3].children[2].props.text == "–")
onClick()
assert(toggled == "aragao/herdr:agents")
''')

    def test_panel_targets_agent_supports_hover_collapse_filter_and_unavailable(self):
        run_luau(HOST + (PLUGINS / "panel.luau").read_text() + r'''
local a = {address = "t1", title = "widget", subtitle = "nix", fullTitle = "nix / widget", app = "codex", status = "working", turn = 15, since = 700000, active = true}
local b = {address = "vps/t2", title = "review", subtitle = "remote · api", fullTitle = "remote / api / review", app = "pi", status = "blocked", turn = 4, since = 940000}
local c = {address = "t3", title = "idle-space", subtitle = "chief-of-staff", fullTitle = "idle-space / chief-of-staff", app = "codex", status = "idle", since = 400000}
noctalia.state.set("snapshot", {phase = "ready", agents = {b, a, c}, working = 1, attention = 1, errors = 0, done = 0, idle = 1})
assert(panelTree == nil, "closed panels must not redraw")
onOpen()

-- Idle starts collapsed, so t3 focus button is not rendered until expanded.
assert(panelTree.props.fill == "surface" and panelTree.props.radius == nil)
local rowA = findNode(panelTree, "t1")
local rowB = findNode(panelTree, "vps/t2")
local btnA = findNode(panelTree, "focus-t1")
local btnB = findNode(panelTree, "focus-vps/t2")
assert(rowA ~= nil and rowB ~= nil and btnA ~= nil and btnB ~= nil)
assert(findNode(panelTree, "focus-t3") == nil, "idle group should start collapsed")

-- Active row highlights with surface_container_low + primary/0.40 border; non-active row uses transparent fill.
assert(rowA.fill == "surface_container_low" and rowA.border == "primary/0.40" and rowA.borderWidth == 1)
assert(rowB.fill == "#00000000" and rowB.border == "#00000000")

-- Section header does not repeat "Working" on rows; urgent badge appears on blocked rows.
local labels = findLabels(panelTree)
local sawWorkingLabel, sawInputBadge, sawMeta = false, false, false
for _, lbl in ipairs(labels) do
    if lbl.text == "Working" then sawWorkingLabel = true end
    if lbl.text == "Input" then sawInputBadge = true end
    if lbl.text and string.find(lbl.text, "codex · t15 · 5m · t1", 1, true) then sawMeta = true end
end
assert(not sawWorkingLabel, "rows must not repeat Working")
assert(sawInputBadge, "attention row must display Input badge")
assert(sawMeta, "row metadata must include app, turn, elapsed and address")

-- Expanding idle reveals t3.
findNode(panelTree, "group-idle").onClick()
assert(findNode(panelTree, "focus-t3") ~= nil)

-- Active-only filter hides idle group and shows the unhide button.
findNode(panelTree, "toggle-active").onClick()
assert(findNode(panelTree, "group-idle") == nil)
assert(findNode(panelTree, "show-all-hidden") ~= nil)
findNode(panelTree, "show-all-hidden").onClick()
assert(findNode(panelTree, "group-idle") ~= nil)

-- Focusing an agent closes panel, focuses terminal, and raises Herdr.
findNode(panelTree, "focus-vps/t2").onClick()
assert(closed)
assert(calls[1][3] == "agent.focus" and calls[1][4] == "--terminal" and calls[1][5] == "vps/t2")
reply({exitCode = 0})
assert(#calls == 2 and #calls[2] == 1 and calls[2][1] == "herdr-app", "focus must raise Herdr")
table.remove(pending, 1)

findNode(panelTree, "focus-t1").onClick()
assert(calls[3][5] == "t1", "each handler must keep its own terminal")
reply({exitCode = 1})
assert(#notifications == 1 and #calls == 3, "failed focus must not launch another window")

noctalia.state.set("snapshot", {phase = "unavailable", message = "Open Herdr, then retry."})
assert(findNode(panelTree, "focus-t1") == nil, "failed snapshots must clear stale agent targets")
onClose()
noctalia.state.set("snapshot", {phase = "ready", agents = {}, working = 0, attention = 0, errors = 0, done = 0, idle = 0})
onOpen()
assert(findNode(panelTree, "open-herdr") ~= nil)
''')


def verify_live():
    window = json.loads(subprocess.check_output(["herdr-app", "ls"], timeout=10))
    core = json.loads(subprocess.check_output(["hc", "ls", "--json"], timeout=10))
    run_luau("local model = require('./model.luau')\n"
             f"local snapshot = model.collect({literal(window)}, {literal(core)})\n"
             "assert(snapshot.phase == 'ready')\n"
             "local sections = model.groupAgents(snapshot.agents, false)\n"
             "for _, section in ipairs(sections) do\n"
             "  print('[' .. section.title .. ' ' .. section.count .. ']')\n"
             "  for _, row in ipairs(section.rows) do\n"
             "    local a = row.agent\n"
             "    local indent = string.rep('  ', row.depth)\n"
             "    print(string.format('%s%s | %s | %s | %s', indent, a.title, a.subtitle or '', a.app, a.address))\n"
             "  end\n"
             "end\n"
             "print(string.format('%d working, %d need you, %d done, %d idle (%d total)', snapshot.working, snapshot.attention, snapshot.done, snapshot.idle, #snapshot.agents))\n")


if __name__ == "__main__":
    if "--live" in sys.argv:
        verify_live()
    else:
        unittest.main()
