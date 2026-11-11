local model = require("./model.luau")
local polling = false

local function publish(snapshot)
    polling = false
    noctalia.state.set("snapshot", snapshot)
end

local function unavailable(message)
    publish({ phase = "unavailable", message = message })
end

local function decode(result, key)
    if result.exitCode ~= 0 or result.timedOut or result.stdoutTruncated then return nil end
    local ok, value = pcall(noctalia.json.decode, result.stdout or "")
    if ok and type(value) == "table" and type(value[key]) == "table" then return value end
    return nil
end

local function poll()
    if polling then return end
    polling = true
    local accepted = noctalia.runAsync({ "herdr-app", "ls" }, function(result)
        local window = decode(result, "spaces")
        if not window then
            unavailable("Could not read Herdr's window. Open Herdr, then retry.")
            return
        end
        local coreAccepted = noctalia.runAsync({ "hc", "ls", "--json" }, function(coreResult)
            local core = decode(coreResult, "terminals")
            if not core then
                unavailable("Could not read agent status from Herdr core. Retry in a moment.")
                return
            end
            local ok, snapshot = pcall(model.collect, window, core)
            if ok then publish(snapshot) else unavailable("Herdr returned an unreadable agent list.") end
        end)
        if not coreAccepted then unavailable("Could not query Herdr core.") end
    end)
    if not accepted then unavailable("Could not query Herdr. Check that it is installed.") end
end

function update() poll() end
function onIpc(event) if event == "refresh" then poll() end end

noctalia.setUpdateInterval(2000)
noctalia.state.set("snapshot", { phase = "loading" })
poll()
