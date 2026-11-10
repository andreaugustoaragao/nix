local M = {}
local phases = { idle = true, starting = true, recording = true, finalizing = true,
    diarizing = true, ready = true, incomplete = true }
local failures = {
    asr_exit = "Speech recognition failed", asr_timeout = "Speech recognition timed out",
    invalid_asr_output = "Speech recognition returned an unusable result",
    incomplete_audio_coverage = "Recording has missing audio",
    recording_owner_lost = "Recorder stopped before completion",
    capture_end_unknown = "Recording ended unexpectedly", turns_failed = "Transcript formatting failed",
    legacy_recording_state = "An older recording needs attention",
}

local function epoch(value)
    if type(value) ~= "string" or string.sub(value, -1) ~= "Z" then return nil end
    local year, month, day, hour, minute, second = string.match(value, "^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
    if not year then return nil end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    year -= month <= 2 and 1 or 0
    local era = math.floor(year / 400)
    local y = year - era * 400
    local m = month + (month > 2 and -3 or 9)
    local days = era * 146097 + y * 365 + math.floor(y / 4) - math.floor(y / 100)
        + math.floor((153 * m + 2) / 5) + day - 1 - 719468
    return days * 86400 + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)
end

local function elapsed(startedAt, now)
    local started = epoch(startedAt)
    if not started then return "Recording" end
    local seconds = math.max(0, math.floor(now - started))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds / 60) % 60
    if hours > 0 then return string.format("%d:%02d:%02d", hours, minutes, seconds % 60) end
    return string.format("%02d:%02d", minutes, seconds % 60)
end

function M.view(state, now)
    if type(state) ~= "table" or not phases[state.status] then
        return { label = "Rec!", tooltip = "Recorder status is unavailable", color = "error" }
    end
    local phase = state.status
    local finalization = type(state.finalization) == "table" and state.finalization or {}
    local failure = type(state.failure) == "table" and state.failure or {}
    local output = type(state.outputDir) == "string" and string.sub(state.outputDir, 1, 1) == "/" and state.outputDir or nil
    if phase == "incomplete" and state.transcriptReadyWithoutCoverageWarning == true then phase = "ready" end
    if phase == "finalizing" and finalization.stage == "diarizing" then phase = "diarizing" end
    local recording = phase == "recording"
    local canStart = state.canStartRecording == true
    local result = { label = "Rec", tooltip = "Start call recording", color = "on_surface", phase = phase }
    if failure.code ~= "legacy_recording_state" and failure.code ~= "status_unavailable" and (recording or canStart) then
        if phase == "incomplete" and state.salvageable == true and output then
            result.left = { "salvage", output }
        elseif phase == "incomplete" and failure.retryable == true and output then
            result.left = { "retry", output }
        else
            result.left = { recording and "stop" or "start" }
        end
        if not recording then result.right = { "start" } end
    end
    if recording then
        result.label = elapsed(state.startedAt, now)
        result.tooltip = "Recording " .. result.label .. " — click to stop"
        result.color = "error"
    elseif phase == "starting" then
        result.label, result.tooltip = "Starting", "Starting call recording"
    elseif phase == "finalizing" then
        local total = tonumber(finalization.totalWindows) or 0
        local done = tonumber(finalization.completedWindows) or 0
        local progress = total > 0 and string.format(" %d%%", math.clamp(math.floor(done * 100 / total), 0, 100)) or ""
        result.label, result.tooltip = "Finalizing" .. progress, "Finalizing transcript" .. progress
    elseif phase == "diarizing" then
        result.label, result.tooltip = "Speakers", "Identifying call participants"
    elseif phase == "ready" then
        local diarization = type(state.diarization) == "table" and state.diarization or {}
        result.tooltip = diarization.status == "ready" and "Speaker-labeled transcript ready" or "Transcript ready"
        if diarization.status == "partial" then result.tooltip ..= "; uncertain speakers are marked Unknown speaker" end
    elseif phase == "incomplete" then
        result.label = "Rec!"
        result.color = "error"
        result.tooltip = failures[failure.code] or "Recording could not be completed"
    end
    local warnings = {}
    for _, issue in ipairs(type(state.captureIssues) == "table" and state.captureIssues or {}) do
        if issue.side == "call" or issue.side == "mic" then table.insert(warnings, issue.side .. " capture interrupted") end
    end
    if type(state.routingWarning) == "string" and state.routingWarning ~= "" then
        table.insert(warnings, state.routingWarning == "browser_stream_missing" and "No browser audio stream detected" or "Browser audio routing warning")
    end
    if type(state.micSourceWarning) == "string" and state.micSourceWarning ~= "" then table.insert(warnings, "Microphone source warning") end
    local coverage = type(state.coverage) == "table" and state.coverage or {}
    if coverage.acceptedMinorGaps and not state.transcriptReadyWithoutCoverageWarning then table.insert(warnings, "Brief audio gaps; some speech may be missing") end
    for side, info in pairs(type(coverage.sides) == "table" and coverage.sides or {}) do
        local shortfall = type(info) == "table" and tonumber(info.sampleClockShortfallMs) or nil
        if shortfall and shortfall > 0 then table.insert(warnings, string.format("%s: %.1f s unverified audio time; position unknown", side, shortfall / 1000)) end
    end
    if #warnings > 0 then
        result.tooltip ..= "\n" .. table.concat(warnings, "\n")
        if recording then result.label ..= " !" end
    end
    if result.left then
        local action = result.left[1]
        if action == "salvage" then result.tooltip ..= "\nClick to recover retained audio as a partial transcript"
        elseif action == "retry" then result.tooltip ..= "\nClick to retry transcription"
        elseif action == "start" then result.tooltip ..= "\nClick to start another recording" end
    end
    if result.right then result.tooltip ..= "\nRight-click to start a new recording" end
    if phase == "incomplete" and type(state.source) == "table" and state.source.transcript then
        result.tooltip ..= "\nA partial transcript is available"
    end
    if failure.code == "legacy_recording_state" then result.left, result.right = nil, nil end
    return result
end

return M
