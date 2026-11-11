local M = {}

M.groups = {
    { id = "attention", title = "Needs you" },
    { id = "working", title = "Working" },
    { id = "done", title = "Done" },
    { id = "idle", title = "Idle" },
}
M.statuses = {
    error = { group = "attention", rank = 1, label = "Error", glyph = "alert-triangle", color = "error" },
    blocked = { group = "attention", rank = 2, label = "Needs input", glyph = "help-circle", color = "tertiary" },
    working = { group = "working", rank = 3, label = "Working", glyph = "loader", color = "primary" },
    done = { group = "done", rank = 4, label = "Done", glyph = "circle-check", color = "secondary" },
    idle = { group = "idle", rank = 5, label = "Idle", glyph = "circle-dashed", color = "on_surface_variant" },
}

function M.collect(window, core)
    local terminals = {}
    for _, terminal in ipairs(core.terminals) do
        terminals[terminal.address] = terminal
    end
    local snapshot = { phase = "ready", agents = {}, working = 0, attention = 0, errors = 0 }
    local seen = {}
    for _, space in ipairs(window.spaces) do
        for _, tab in ipairs(space.tabs) do
            for _, pane in ipairs(tab.terminals) do
                local address = pane.terminal
                if space.machine and space.machine ~= "" and not string.find(address, "/", 1, true) then
                    address = space.machine .. "/" .. address
                end
                local terminal = terminals[address]
                local status = pane.status
                if terminal then status = terminal.status end
                local spec = M.statuses[status]
                if spec and not seen[address] and (not terminal or terminal.state == "live") then
                    seen[address] = true
                    local title = space.name .. " / " .. tab.name
                    local name = pane.name or (terminal and terminal.name)
                    if name and name ~= "" then title = title .. " / " .. name end
                    table.insert(snapshot.agents, {
                        address = address,
                        title = title,
                        app = pane.app or (terminal and terminal.agent) or "Agent",
                        status = status,
                    })
                    if spec.group == "working" then snapshot.working += 1 end
                    if spec.group == "attention" then snapshot.attention += 1 end
                    if status == "error" then snapshot.errors += 1 end
                end
            end
        end
    end
    table.sort(snapshot.agents, function(a, b)
        local aRank, bRank = M.statuses[a.status].rank, M.statuses[b.status].rank
        if aRank ~= bRank then return aRank < bRank end
        if a.title ~= b.title then return a.title < b.title end
        return a.address < b.address
    end)
    return snapshot
end

return M
