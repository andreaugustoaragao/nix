local model = require("./model.luau")
local opened = false
local activeOnly = false
local collapsed = { idle = true }
local render

local function command(argv, callback)
    local accepted = noctalia.runAsync(argv, function(result)
        if result.exitCode ~= 0 then
            noctalia.notifyError("Herdr", "Could not open that terminal. It may have closed; retry from the agent list.")
        elseif callback then
            callback()
        end
    end)
    if not accepted then noctalia.notifyError("Herdr", "Could not launch Herdr.") end
end

function openHerdr()
    panel.close()
    command({ "herdr-app" })
end

local function focus(agent)
    panel.close()
    command({ "herdr-app", "do", "agent.focus", "--terminal", agent.address }, function()
        noctalia.runAsync({ "herdr-app" })
    end)
end

local function toggleActiveOnly()
    activeOnly = not activeOnly
    render(noctalia.state.get("snapshot"))
end

local function toggleGroup(groupId)
    collapsed[groupId] = not collapsed[groupId]
    render(noctalia.state.get("snapshot"))
end

local function summaryText(snapshot)
    if not snapshot or snapshot.phase == "loading" then return "Reading…" end
    if snapshot.phase ~= "ready" then return "Offline" end
    local parts = {}
    if (snapshot.attention or 0) > 0 then
        table.insert(parts, tostring(snapshot.attention) .. " need you")
    end
    if (snapshot.working or 0) > 0 then
        table.insert(parts, tostring(snapshot.working) .. " working")
    end
    if #parts == 0 and #snapshot.agents > 0 then
        return tostring(#snapshot.agents) .. " agents"
    end
    return table.concat(parts, " · ")
end

local function formatMeta(agent, nowMs)
    local parts = {}
    if agent.app and agent.app ~= "" and agent.app ~= "Agent" then
        table.insert(parts, agent.app)
    end
    if type(agent.turn) == "number" and agent.turn > 0 then
        table.insert(parts, "t" .. tostring(agent.turn))
    end
    local elapsed = (agent.since and nowMs) and model.formatDuration(nowMs - agent.since) or nil
    if elapsed then
        table.insert(parts, elapsed)
    end
    table.insert(parts, agent.address)
    return table.concat(parts, " · ")
end

local function contextLabel(row)
    local agent = row.agent
    if row.sameSpaceParent then
        if agent.subtitle and string.find(agent.subtitle, " · ", 1, true) then
            return agent.tab
        end
        return nil
    end
    return agent.subtitle
end

render = function(snapshot)
    if not opened then return end
    local nowMs = noctalia.nowMs and noctalia.nowMs() or nil
    local rows = {}
    if not snapshot or snapshot.phase == "loading" then
        table.insert(rows, ui.label({ text = "Reading agent status…", color = "on_surface_variant" }))
    elseif snapshot.phase ~= "ready" then
        table.insert(rows, ui.label({ text = snapshot.message, maxLines = 3, color = "on_surface_variant" }))
    elseif #snapshot.agents == 0 then
        table.insert(rows, ui.label({ text = "No agents are reporting status in Herdr's spaces.", maxLines = 2, color = "on_surface_variant" }))
    else
        local sections, hiddenCount = model.groupAgents(snapshot.agents, activeOnly)
        for _, section in ipairs(sections) do
            local isCollapsed = collapsed[section.id] == true
            local headerKey = "group-" .. section.id
            local countText = isCollapsed
                and string.format("%s  %d  (collapsed)", section.title, section.count)
                or string.format("%s  %d", section.title, section.count)
            local headerChildren = {
                ui.button({
                    key = headerKey,
                    text = countText,
                    glyph = isCollapsed and "chevron-right" or "chevron-down",
                    variant = "ghost",
                    contentAlign = "start",
                    controlSize = "sm",
                    flexGrow = 1,
                    onClick = function() toggleGroup(section.id) end,
                }),
            }
            if section.id == "attention" then
                table.insert(headerChildren, ui.label({
                    text = (snapshot.errors or 0) > 0 and "Action required" or "Waiting on you",
                    color = (snapshot.errors or 0) > 0 and "error" or "secondary",
                    fontSize = 11,
                    fontWeight = "medium",
                }))
            end

            table.insert(rows, ui.row({ key = "header-" .. section.id, gap = 6, align = "center" }, headerChildren))

            if not isCollapsed then
                for _, item in ipairs(section.rows) do
                    local agent = item.agent
                    local spec = model.statuses[agent.status]
                    local rowKey = "focus-" .. agent.address

                    local tooltip = string.format("%s\n%s%s · %s · %s",
                        agent.fullTitle or agent.title,
                        agent.app or "Agent",
                        type(agent.turn) == "number" and agent.turn > 0 and (" · turn " .. tostring(agent.turn)) or "",
                        spec.label,
                        agent.address)

                    local rowChildren = {}
                    if item.depth > 0 then
                        table.insert(rowChildren, ui.row({ width = 16 * item.depth, justify = "end", align = "center" }, {
                            ui.glyph({ name = "corner-down-right", size = 12, color = "on_surface_variant/0.55" }),
                        }))
                    end
                    table.insert(rowChildren, ui.glyph({ name = spec.glyph, size = 14, color = spec.color }))
                    table.insert(rowChildren, ui.button({
                        key = rowKey,
                        text = agent.title,
                        variant = "ghost",
                        contentAlign = "start",
                        flexGrow = 1,
                        controlSize = "sm",
                        tooltip = tooltip,
                        onClick = function() focus(agent) end,
                    }))
                    if agent.active then
                        table.insert(rowChildren, ui.glyph({ name = "point-filled", size = 7, color = "primary" }))
                    end

                    local ctx = contextLabel(item)
                    if ctx and ctx ~= "" and ctx ~= agent.title then
                        table.insert(rowChildren, ui.label({
                            text = ctx,
                            color = "on_surface_variant/0.80",
                            fontSize = 11,
                            maxWidth = 135,
                            maxLines = 1,
                        }))
                    end
                    if spec.badge then
                        local isErr = agent.status == "error"
                        table.insert(rowChildren, ui.row({
                            fill = isErr and "error_container" or "secondary_container",
                            radius = 4,
                            paddingH = 5,
                            paddingV = 1,
                            align = "center",
                        }, {
                            ui.label({
                                text = spec.badge,
                                color = isErr and "on_error_container" or "on_secondary_container",
                                fontSize = 10,
                                fontWeight = "semibold",
                            }),
                        }))
                    end
                    table.insert(rowChildren, ui.label({
                        text = formatMeta(agent, nowMs),
                        color = "on_surface_variant/0.62",
                        fontSize = 11,
                        maxLines = 1,
                        textAlign = "end",
                    }))

                    table.insert(rows, ui.row({
                        key = agent.address,
                        gap = 6,
                        paddingH = 6,
                        paddingV = 2,
                        radius = 6,
                        align = "center",
                        fill = agent.active and "surface_container_low" or "#00000000",
                        border = agent.active and "primary/0.40" or "#00000000",
                        borderWidth = agent.active and 1 or 0,
                        tooltip = tooltip,
                    }, rowChildren))
                end
            end
        end

        if #sections == 0 and hiddenCount > 0 then
            table.insert(rows, ui.label({
                text = "No active agents right now.",
                color = "on_surface_variant/0.80",
            }))
        end
        if hiddenCount > 0 then
            table.insert(rows, ui.button({
                key = "show-all-hidden",
                text = string.format("%d idle/settled hidden · Show all", hiddenCount),
                variant = "ghost",
                controlSize = "sm",
                contentAlign = "center",
                onClick = toggleActiveOnly,
            }))
        end
    end

    panel.render(ui.column({ gap = 10, padding = 0, fill = "surface" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "terminal-2", size = 18, color = "primary" }),
            ui.label({ text = "Herdr", color = "on_surface", fontSize = 18, fontWeight = "semibold" }),
            ui.label({ text = summaryText(snapshot), color = "on_surface_variant/0.75", fontSize = 12, flexGrow = 1 }),
            ui.button({
                key = "toggle-active",
                text = activeOnly and "Active" or "All",
                glyph = "filter",
                variant = activeOnly and "primary" or "outline",
                controlSize = "sm",
                tooltip = activeOnly and "Showing active agents only. Click to show idle and settled." or "Hide idle and settled agents",
                onClick = toggleActiveOnly,
            }),
            ui.button({
                key = "open-herdr",
                text = "Open",
                glyph = "arrow-up-right",
                variant = "outline",
                controlSize = "sm",
                tooltip = "Open Herdr window",
                onClick = "openHerdr",
            }),
        }),
        ui.box({ height = 1, fill = "outline_variant/0.80" }),
        ui.scroll({ key = "agents", gap = 3, flexGrow = 1 }, rows),
    }))
end

function onOpen()
    opened = true
    render(noctalia.state.get("snapshot"))
end
function onClose() opened = false end
noctalia.state.watch("snapshot", render)
