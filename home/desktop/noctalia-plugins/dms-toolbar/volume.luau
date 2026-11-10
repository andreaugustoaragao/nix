local volume = nil
local muted = false
local polling = false
local writing = false
local desired = nil
local failure = nil

local function render()
    local glyph = muted and "volume-off" or "volume"
    barWidget.setTooltip(failure or "Drag or scroll to adjust volume; click the speaker to mute. Right-click opens audio controls.")
    barWidget.render(ui.row({ gap = 5, align = "center" }, {
        ui.button({ glyph = glyph, glyphSize = 14, variant = "ghost", height = 18,
            enabled = volume ~= nil, onClick = "onMute" }),
        ui.slider({ key = "volume", min = 0, max = 100, step = 1,
            value = desired or volume or 0, width = 84, height = 16,
            enabled = volume ~= nil, onChange = "onVolumeChanged" }),
        ui.label({ text = volume and string.format("%.0f%%", desired or volume) or "--",
            width = 32, color = muted and "outline" or "on_surface" }),
    }))
end

local function readVolume()
    if polling or writing or desired ~= nil then return end
    polling = true
    local accepted = noctalia.runAsync({ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }, function(result)
        polling = false
        local value = result.exitCode == 0 and tonumber(string.match(result.stdout, "Volume:%s*([%d.]+)"))
        if value then
            if not writing and desired == nil then
                volume = value * 100
                muted = string.find(result.stdout, "MUTED", 1, true) ~= nil
            end
            failure = nil
        else
            volume = nil
            failure = "Audio volume is unavailable."
        end
        render()
    end)
    if not accepted then
        polling = false
        volume = nil
        failure = "Could not read audio volume."
        render()
    end
end

local function writeVolume()
    if writing or desired == nil then return end
    local target = desired
    desired = nil
    writing = true
    local accepted = noctalia.runAsync({ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", string.format("%.2f", target / 100) }, function(result)
        writing = false
        if result.exitCode == 0 then
            volume = target
            failure = nil
        else
            desired = nil
            failure = "Could not change audio volume."
        end
        render()
        if desired ~= nil then writeVolume() else readVolume() end
    end)
    if not accepted then
        writing = false
        desired = nil
        failure = "Could not change audio volume."
        render()
    end
end

function onVolumeChanged(value)
    local parsed = tonumber(value)
    if not parsed then return end
    desired = math.clamp(parsed, 0, 100)
    render()
    writeVolume()
end

function onMute()
    noctalia.runAsync({ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" }, function(result)
        if result.exitCode ~= 0 then failure = "Could not change mute state." end
        readVolume()
    end)
end

function onRightClick()
    noctalia.runAsync({ "noctalia", "msg", "panel-toggle", "control-center", "audio" })
end

function update() readVolume() end
function onIpc() readVolume() end
noctalia.setUpdateInterval(1000)
render()
readVolume()
