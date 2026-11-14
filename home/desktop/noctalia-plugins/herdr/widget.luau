local function count(value)
    if value == nil then return "–" end
    return value > 99 and "99+" or tostring(value)
end

local function render(snapshot)
    local ready = snapshot ~= nil and snapshot.phase == "ready"
    local hasWorking = ready and (snapshot.working or 0) > 0
    local hasAttention = ready and (snapshot.attention or 0) > 0
    local attentionColor = "on_surface_variant"
    if hasAttention then
        attentionColor = (snapshot.errors or 0) > 0 and "error" or "secondary"
    end
    local workingColor = hasWorking and "primary" or "on_surface_variant/0.60"
    local workingTextColor = hasWorking and "on_surface" or "on_surface_variant/0.60"
    local iconColor = hasAttention and attentionColor or "on_surface"

    local tooltip = "Reading Herdr agent status…"
    if ready then
        tooltip = string.format(
            "%d working · %d need you · %d done · %d agents\nLeft-click opens list · Right-click jumps to attention or Herdr.",
            snapshot.working or 0, snapshot.attention or 0, snapshot.done or 0, #snapshot.agents)
    elseif snapshot and snapshot.message then
        tooltip = snapshot.message
    end
    barWidget.setTooltip(tooltip)

    local children = {
        ui.glyph({ name = "terminal-2", size = 15, color = iconColor }),
        ui.label({ text = "Herdr", baseline = "inkCentered" }),
        ui.row({ gap = 3, align = "center" }, {
            ui.glyph({ name = "loader", size = 13, color = workingColor }),
            ui.label({ text = count(ready and snapshot.working or nil), color = workingTextColor, baseline = "inkCentered" }),
        }),
    }
    if hasAttention then
        local attentionGlyph = (snapshot.errors or 0) > 0 and "alert-triangle" or "alert-circle"
        table.insert(children, ui.row({ gap = 3, align = "center" }, {
            ui.glyph({ name = attentionGlyph, size = 13, color = attentionColor }),
            ui.label({ text = count(snapshot.attention), color = attentionColor, baseline = "inkCentered" }),
        }))
    end

    barWidget.render(ui.row({ gap = 6, align = "center" }, children))
end

function onClick() noctalia.togglePanel("aragao/herdr:agents") end

function onRightClick()
    local snapshot = noctalia.state.get("snapshot")
    if snapshot and snapshot.phase == "ready" and snapshot.agents and #snapshot.agents > 0 then
        local top = snapshot.agents[1]
        if top.status == "error" or top.status == "blocked" then
            local accepted = noctalia.runAsync({ "herdr-app", "do", "agent.focus", "--terminal", top.address }, function(result)
                if result.exitCode == 0 then
                    noctalia.runAsync({ "herdr-app" })
                else
                    noctalia.notifyError("Herdr", "Could not open that terminal. It may have closed; retry from the agent list.")
                end
            end)
            if not accepted then noctalia.notifyError("Herdr", "Could not launch Herdr.") end
            return
        end
    end
    local accepted = noctalia.runAsync({ "herdr-app" })
    if not accepted then noctalia.notifyError("Herdr", "Could not launch Herdr.") end
end

noctalia.state.watch("snapshot", render)
render(noctalia.state.get("snapshot"))
