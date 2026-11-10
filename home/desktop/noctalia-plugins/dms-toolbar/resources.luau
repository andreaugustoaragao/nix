local resource = noctalia.getConfig("resource")

function update()
    local used, total, percent, tooltip
    if resource == "ram" then
        local stats = noctalia.systemStats()
        if stats then
            used, total = stats.ram.usedMb / 1024, stats.ram.totalMb / 1024
            percent = stats.ram.usagePercent
            tooltip = string.format("RAM: %.1f / %.1f GiB\nSwap: %.1f / %.1f GiB", used, total,
                stats.swap.usedMb / 1024, stats.swap.totalMb / 1024)
        end
    else
        local disk = noctalia.diskStats("/")
        if disk then
            used, total = (disk.totalBytes - disk.freeBytes) / 1073741824, disk.totalBytes / 1073741824
            percent = disk.usagePercent
            tooltip = string.format("Root filesystem: %.1f / %.1f GiB\nAvailable: %.1f GiB", used, total, disk.availableBytes / 1073741824)
        end
    end
    local color = percent and percent >= 90 and "error" or "primary"
    barWidget.setTooltip(tooltip or "System statistics are not available yet.")
    barWidget.render(ui.row({ gap = 4, align = "center" }, {
        ui.glyph({ name = resource == "ram" and "memory" or "storage", size = 13 }),
        ui.progress({ progress = math.clamp((percent or 0) / 100, 0, 1), fill = color,
            track = "surface_container_highest", width = 30, height = 5, radius = 2 }),
        ui.label({ text = used and string.format("%.1f/%.1fG", used, total) or "--" }),
    }))
end

function onClick()
    noctalia.runAsync({ "noctalia", "msg", "panel-toggle", "control-center", "system" })
end

noctalia.setUpdateInterval(2000)
update()
