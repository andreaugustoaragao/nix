local recording = require("./recording.luau")
local state = nil
local polling = false
local busy = false
local lastPoll = 0
local commandError = nil
local view = recording.view(nil, 0)

local function render()
    view = recording.view(state, noctalia.nowMs() / 1000)
    barWidget.setGlyph("microphone")
    barWidget.setText(busy and "Updating" or view.label)
    barWidget.setColor(commandError and "error" or view.color)
    barWidget.setGlyphColor(commandError and "error" or view.color)
    barWidget.setTooltip(commandError or view.tooltip)
end

local function poll()
    if polling then return end
    polling = true
    lastPoll = noctalia.nowMs()
    local accepted = noctalia.runAsync({ "noctalia-record-call", "status", "--json" }, function(result)
        polling = false
        state = result.exitCode == 0 and noctalia.json.decode(result.stdout) or nil
        render()
    end)
    if not accepted then polling = false; state = nil; render() end
end

local function execute(action)
    if busy or not action then return end
    local argv = { "noctalia-record-call" }
    for _, value in ipairs(action) do table.insert(argv, value) end
    busy = true
    commandError = nil
    render()
    local accepted = noctalia.runAsync(argv, function(result)
        busy = false
        if result.exitCode ~= 0 then
            commandError = "Recorder command failed: " .. string.sub(result.stderr or "", 1, 250)
        end
        poll()
        render()
    end)
    if not accepted then busy = false; commandError = "Could not run recorder command"; render() end
end

function onClick() execute(view.left) end
function onRightClick() execute(view.right) end
function onIpc(event) if event == "refresh" then poll() end end
function update()
    if noctalia.nowMs() - lastPoll >= 2000 then poll() end
    render()
end

noctalia.setUpdateInterval(1000)
render()
poll()
