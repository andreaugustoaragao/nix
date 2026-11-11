local model = require("./model.luau")
local opened = false

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

local function render(snapshot)
    if not opened then return end
    local rows = {}
    if not snapshot or snapshot.phase == "loading" then
        table.insert(rows, ui.label({ text = "Reading agent status…", color = "on_surface_variant" }))
    elseif snapshot.phase ~= "ready" then
        table.insert(rows, ui.label({ text = snapshot.message, maxLines = 3, color = "on_surface_variant" }))
    elseif #snapshot.agents == 0 then
        table.insert(rows, ui.label({ text = "No agents are reporting status in Herdr's spaces.", maxLines = 2, color = "on_surface_variant" }))
    else
        for _, group in ipairs(model.groups) do
            local agents = {}
            for _, agent in ipairs(snapshot.agents) do
                if model.statuses[agent.status].group == group.id then table.insert(agents, agent) end
            end
            if #agents > 0 then
                table.insert(rows, ui.label({ text = group.title .. "  " .. #agents,
                    fontWeight = "semibold", color = "on_surface_variant" }))
                for _, agent in ipairs(agents) do
                    local spec = model.statuses[agent.status]
                    table.insert(rows, ui.row({ key = agent.address, gap = 6, align = "center" }, {
                        ui.button({ key = "focus-" .. agent.address,
                            text = agent.title, glyph = spec.glyph, variant = "ghost",
                            contentAlign = "start", flexGrow = 1, controlSize = "sm",
                            tooltip = agent.title .. "\n" .. agent.app .. " · " .. agent.address .. " · " .. spec.label,
                            onClick = function() focus(agent) end }),
                        ui.column({ gap = 1, width = 86, align = "end" }, {
                            ui.label({ text = spec.label, color = spec.color, fontSize = 12 }),
                            ui.label({ text = agent.address, color = "on_surface_variant", fontSize = 10,
                                maxWidth = 86, maxLines = 1 }),
                        }),
                    }))
                end
            end
        end
    end
    panel.render(ui.column({ gap = 12, padding = 12, fill = "surface_container", radius = 10 }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "terminal-2", size = 20, color = "primary" }),
            ui.label({ text = "Herdr", fontSize = 20, fontWeight = "semibold", flexGrow = 1 }),
            ui.button({ text = "Open Herdr", variant = "ghost", controlSize = "sm", onClick = "openHerdr" }),
        }),
        ui.scroll({ key = "agents", gap = 8, flexGrow = 1 }, rows),
    }))
end

function onOpen()
    opened = true
    render(noctalia.state.get("snapshot"))
end
function onClose() opened = false end
noctalia.state.watch("snapshot", render)
