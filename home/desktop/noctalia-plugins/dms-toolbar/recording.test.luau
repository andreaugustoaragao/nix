local recording = require("./recording")
local epoch = 1794189600 -- 2026-11-09T02:00:00Z
local function view(state, seconds)
    return recording.view(state, epoch + (seconds or 0))
end
local function state(phase)
    return { status = phase, canStartRecording = true, startedAt = "2026-11-09T02:00:00.000Z" }
end

assert(view(nil).left == nil)
assert(view({ status = "unknown", canStartRecording = true }).left == nil)
assert(view(state("idle")).left[1] == "start")
local active = view(state("recording"), 3661)
assert(active.label == "1:01:01", active.label)
assert(active.left[1] == "stop" and active.right == nil)
assert(view(state("recording"), -1).label == "00:00")
local starting = state("starting")
starting.canStartRecording = false
assert(view(starting).left == nil)
local finalizing = state("finalizing")
finalizing.canStartRecording = false
finalizing.finalization = { completedWindows = 2, totalWindows = 5 }
assert(view(finalizing).label == "Finalizing 40%")
assert(view(finalizing).left == nil)
finalizing.finalization.stage = "diarizing"
finalizing.canStartRecording = true
assert(view(finalizing).phase == "diarizing" and view(finalizing).left[1] == "start")
local failed = state("incomplete")
failed.outputDir = "/tmp/meeting with 'quotes' and $(literal)"
failed.failure = { code = "asr_exit", retryable = true }
assert(view(failed).left[1] == "retry")
assert(view(failed).left[2] == failed.outputDir)
assert(view(failed).right[1] == "start")
failed.salvageable = true
assert(view(failed).left[1] == "salvage")
failed.failure.code = "legacy_recording_state"
assert(view(failed).left == nil and view(failed).right == nil)
failed.failure.code = "status_unavailable"
assert(view(failed).left == nil)
failed.failure.code = "incomplete_audio_coverage"
failed.transcriptReadyWithoutCoverageWarning = true
assert(view(failed).phase == "ready" and view(failed).left[1] == "start")
local warning = state("recording")
warning.captureIssues = { { side = "call" } }
warning.routingWarning = "browser_stream_missing"
warning.micSourceWarning = "source_missing"
warning.coverage = { sides = { call = { sampleClockShortfallMs = 1500 } } }
local warned = view(warning, 12)
assert(warned.label == "00:12 !")
assert(string.find(warned.tooltip, "No browser audio", 1, true))
assert(string.find(warned.tooltip, "1.5 s unverified", 1, true))
assert(string.find(warned.tooltip, "Microphone source warning", 1, true))
print("Recorder controls passed: timing, start/stop, finalization, recovery, warnings, and blocked states.")
