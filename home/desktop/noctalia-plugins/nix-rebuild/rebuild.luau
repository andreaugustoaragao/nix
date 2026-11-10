local state = nil
local polling = false
local launching = false
local commandError = nil

local function render()
    -- Unknown/failed Git reads never masquerade as a dirty checkout.
    barWidget.setVisible(state ~= nil and state.dirty == true)
    barWidget.setGlyph("snowflake")
    local busy = launching or (state ~= nil and state.busy == true)
    local label = "Rebuild"
    if busy then
        label = "Starting"
        if not launching and state ~= nil then
            if state.phase == "building" then label = "Building" end
            if state.phase == "applying" then label = "Applying" end
        end
    end
    barWidget.setText(label)
    local failed = commandError ~= nil or (state ~= nil and (state.error ~= nil or state.phase == "failed" or state.phase == "interrupted"))
    local color = failed and "error" or (busy and "secondary" or "primary")
    barWidget.setColor(color)
    barWidget.setGlyphColor(color)
    local tooltip = commandError or (state ~= nil and (state.error or state.message))
        or "Rebuild the current Nix checkout, then authenticate in the GUI to apply it."
    barWidget.setTooltip(tooltip .. "\nLeft-click rebuilds; right-click opens the log.\nRebuilding does not stage or commit Git changes. Untracked files are excluded until staged.")
end

local function poll()
    if polling then return end
    polling = true
    local accepted = noctalia.runAsync({ "noctalia-nix-rebuild", "status" }, function(result)
        polling = false
        local ok, value = pcall(noctalia.json.decode, result.stdout or "")
        state = result.exitCode == 0 and ok and type(value) == "table" and value or nil
        render()
    end)
    if not accepted then polling = false; state = nil; render() end
end

function onClick()
    if launching or state == nil or state.dirty ~= true or state.busy == true or state.error ~= nil then return end
    launching = true
    commandError = nil
    render()
    local accepted = noctalia.runAsync({ "noctalia-nix-rebuild", "start" }, function(result)
        launching = false
        if result.exitCode ~= 0 then
            commandError = "Could not start the rebuild: " .. string.sub(result.stderr or "", 1, 250)
            noctalia.notifyError("NixOS rebuild", commandError)
        end
        poll()
        render()
    end)
    if not accepted then
        launching = false
        commandError = "Could not launch the NixOS rebuild helper."
        noctalia.notifyError("NixOS rebuild", commandError)
        render()
    end
end

function onRightClick()
    local accepted = noctalia.runAsync({ "noctalia-nix-rebuild", "log" })
    if not accepted then noctalia.notifyError("NixOS rebuild", "Could not open the rebuild log.") end
end

function update() poll() end
function onIpc(event) if event == "refresh" then poll() end end
noctalia.setUpdateInterval(5000)
render()
poll()
