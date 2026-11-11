local function count(value)
    if value == nil then return "–" end
    return value > 99 and "99+" or tostring(value)
end

local function render(snapshot)
    local ready = snapshot ~= nil and snapshot.phase == "ready"
    local attentionColor = "outline"
    if ready and snapshot.attention > 0 then
        attentionColor = snapshot.errors > 0 and "error" or "tertiary"
    end
    local tooltip = "Reading Herdr agent status…"
    if ready then
        tooltip = string.format("%d working · %d need you · %d agents in Herdr\nClick to switch to an agent.",
            snapshot.working, snapshot.attention, #snapshot.agents)
    elseif snapshot and snapshot.message then
        tooltip = snapshot.message
    end
    barWidget.setTooltip(tooltip)
    barWidget.render(ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = "terminal-2", size = 15, color = attentionColor }),
        ui.label({ text = "Herdr" }),
        ui.row({ gap = 3, align = "center", width = 39 }, {
            ui.glyph({ name = "loader", size = 13, color = ready and snapshot.working > 0 and "primary" or "outline" }),
            ui.label({ text = count(ready and snapshot.working or nil), width = 23 }),
        }),
        ui.row({ gap = 3, align = "center", width = 39 }, {
            ui.glyph({ name = "alert-circle", size = 13, color = attentionColor }),
            ui.label({ text = count(ready and snapshot.attention or nil), width = 23, color = attentionColor }),
        }),
    }))
end

function onClick() noctalia.togglePanel("aragao/herdr:agents") end
noctalia.state.watch("snapshot", render)
render(noctalia.state.get("snapshot"))
