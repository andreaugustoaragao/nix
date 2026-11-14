local M = {}

M.groups = {
    { id = "attention", title = "Needs you" },
    { id = "working", title = "Working" },
    { id = "done", title = "Done" },
    { id = "idle", title = "Idle" },
}
M.statuses = {
    error = { group = "attention", rank = 1, label = "Error", badge = "Error", glyph = "alert-triangle", color = "error" },
    blocked = { group = "attention", rank = 2, label = "Needs input", badge = "Input", glyph = "help-circle", color = "secondary" },
    working = { group = "working", rank = 3, label = "Working", glyph = "loader", color = "primary" },
    done = { group = "done", rank = 4, label = "Done", glyph = "circle-check", color = "tertiary" },
    idle = { group = "idle", rank = 5, label = "Idle", glyph = "circle-dashed", color = "on_surface_variant/0.55" },
}

local function normalize(value)
    return string.gsub(string.lower(value or ""), "[^%w]+", "")
end

local function isNumeric(value)
    return value ~= nil and value ~= "" and string.match(value, "^%d+$") ~= nil
end

local function isRedundantTab(tabName, paneName)
    local a = normalize(tabName)
    local b = normalize(paneName)
    if a == "" or b == "" then return false end
    return a == b or string.find(a, b, 1, true) == 1 or string.find(b, a, 1, true) == 1
end

local function qualifyAddress(machine, address)
    if not address or address == "" then return nil end
    if machine and machine ~= "" and not string.find(address, "/", 1, true) then
        return machine .. "/" .. address
    end
    return address
end

local function buildDisplay(spaceName, tabName, paneName, app)
    local title, subtitle
    if paneName and paneName ~= "" then
        title = paneName
        if tabName ~= "" and not isNumeric(tabName) and not isRedundantTab(tabName, paneName) then
            subtitle = spaceName .. " · " .. tabName
        else
            subtitle = spaceName
        end
    elseif tabName == "chief-of-staff" then
        title = spaceName
        subtitle = "chief-of-staff"
    elseif tabName ~= "" and not isNumeric(tabName) then
        title = tabName
        subtitle = spaceName
    else
        title = spaceName
        subtitle = app
    end
    local fullTitle = spaceName .. " / " .. tabName
    if paneName and paneName ~= "" then
        fullTitle = fullTitle .. " / " .. paneName
    end
    return title, subtitle, fullTitle
end

function M.formatDuration(ms)
    if type(ms) ~= "number" or ms < 0 then return nil end
    local minutes = math.floor(ms / 60000)
    if minutes < 1 then return "<1m" end
    if minutes < 60 then return tostring(minutes) .. "m" end
    local hours = math.floor(minutes / 60)
    if hours < 24 then return tostring(hours) .. "h" end
    return tostring(math.floor(hours / 24)) .. "d"
end

function M.collect(window, core, nowMs, transitions)
    local terminals = {}
    for _, terminal in ipairs(core.terminals) do
        terminals[terminal.address] = terminal
    end

    local subParents = {}
    for _, space in ipairs(window.spaces) do
        for _, tab in ipairs(space.tabs) do
            for _, pane in ipairs(tab.terminals) do
                local parentAddr = qualifyAddress(space.machine, pane.terminal)
                if parentAddr and type(pane.sub_agents) == "table" then
                    for _, child in ipairs(pane.sub_agents) do
                        local childAddr = qualifyAddress(space.machine, child)
                        if childAddr and not subParents[childAddr] then
                            subParents[childAddr] = parentAddr
                        end
                    end
                end
            end
        end
    end

    local snapshot = {
        phase = "ready",
        agents = {},
        working = 0,
        attention = 0,
        errors = 0,
        done = 0,
        idle = 0,
    }
    local seen = {}
    for _, space in ipairs(window.spaces) do
        for _, tab in ipairs(space.tabs) do
            for _, pane in ipairs(tab.terminals) do
                local address = qualifyAddress(space.machine, pane.terminal)
                local terminal = address and terminals[address] or nil
                local status = pane.status
                if terminal then status = terminal.status end
                local spec = M.statuses[status]
                if address and spec and not seen[address] and (not terminal or terminal.state == "live") then
                    seen[address] = true
                    local name = pane.name or (terminal and terminal.name)
                    local app = pane.app or (terminal and terminal.agent) or "Agent"
                    local title, subtitle, fullTitle = buildDisplay(space.name, tab.name, name, app)
                    local parent = (terminal and qualifyAddress(space.machine, terminal.parent)) or subParents[address]
                    if parent == address then parent = nil end

                    local since = nil
                    if type(transitions) == "table" and type(nowMs) == "number" then
                        local prev = transitions[address]
                        if prev and prev.status == status then
                            since = prev.since
                        else
                            since = nowMs
                            transitions[address] = { status = status, since = nowMs }
                        end
                    end

                    table.insert(snapshot.agents, {
                        address = address,
                        space = space.name,
                        tab = tab.name,
                        name = name,
                        title = title,
                        subtitle = subtitle,
                        fullTitle = fullTitle,
                        app = app,
                        status = status,
                        parent = parent,
                        turn = terminal and terminal.turn or nil,
                        active = space.active == true and tab.active == true,
                        settled = tab.settled == true,
                        since = since,
                    })
                    if spec.group == "working" then snapshot.working += 1 end
                    if spec.group == "attention" then snapshot.attention += 1 end
                    if spec.group == "done" then snapshot.done += 1 end
                    if spec.group == "idle" then snapshot.idle += 1 end
                    if status == "error" then snapshot.errors += 1 end
                end
            end
        end
    end

    if type(transitions) == "table" then
        for addr in pairs(transitions) do
            if not seen[addr] then transitions[addr] = nil end
        end
    end

    table.sort(snapshot.agents, function(a, b)
        local aRank, bRank = M.statuses[a.status].rank, M.statuses[b.status].rank
        if aRank ~= bRank then return aRank < bRank end
        if a.fullTitle ~= b.fullTitle then return a.fullTitle < b.fullTitle end
        return a.address < b.address
    end)
    return snapshot
end

function M.groupAgents(agents, activeOnly)
    local sections = {}
    local hiddenCount = 0

    for _, group in ipairs(M.groups) do
        local members = {}
        local byAddress = {}
        for _, agent in ipairs(agents) do
            if M.statuses[agent.status].group == group.id then
                local hide = activeOnly and (group.id == "idle" or (group.id == "done" and agent.settled == true))
                if hide then
                    hiddenCount += 1
                else
                    table.insert(members, agent)
                    byAddress[agent.address] = agent
                end
            end
        end

        if #members > 0 then
            local childrenOf = {}
            local roots = {}
            for _, agent in ipairs(members) do
                if agent.parent and agent.parent ~= agent.address and byAddress[agent.parent] then
                    childrenOf[agent.parent] = childrenOf[agent.parent] or {}
                    table.insert(childrenOf[agent.parent], agent)
                else
                    table.insert(roots, agent)
                end
            end

            local rows = {}
            local visited = {}
            local function appendNode(agent, depth, parentAgent)
                if visited[agent.address] then return end
                visited[agent.address] = true
                table.insert(rows, {
                    agent = agent,
                    depth = depth,
                    sameSpaceParent = parentAgent ~= nil and parentAgent.space == agent.space,
                })
                for _, child in ipairs(childrenOf[agent.address] or {}) do
                    appendNode(child, math.min(depth + 1, 2), agent)
                end
            end

            for _, root in ipairs(roots) do
                appendNode(root, 0, nil)
            end
            for _, agent in ipairs(members) do
                if not visited[agent.address] then
                    appendNode(agent, 0, nil)
                end
            end

            table.insert(sections, {
                id = group.id,
                title = group.title,
                count = #members,
                rows = rows,
            })
        end
    end

    return sections, hiddenCount
end

return M
