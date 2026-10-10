import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property string phase: "idle"
    readonly property bool recording: phase === "recording"
    readonly property bool finalizing: phase === "finalizing" || phase === "starting" || phase === "diarizing"
    property string failureCode: ""
    property string captureIssueSides: ""
    property string routingWarning: ""
    property string micSourceWarning: ""
    property string coverageDetail: ""
    readonly property bool activeWarning: captureIssueSides !== "" || routingWarning !== "" || micSourceWarning !== ""
    property bool retryable: false
    property bool salvageable: false
    property bool hasPartialTranscript: false
    property string diarizationStatus: "pending"
    property string diarizationFailureCode: ""
    property int diarizedSpeakers: 0
    property bool toggleBusy: false
    property int startedAt: 0
    property string outputDir: ""
    property int completedWindows: 0
    property int totalWindows: 0
    property int finalizationPercent: 0
    property int now: Math.floor(Date.now() / 1000)

    function pad(n) { return n < 10 ? "0" + n : "" + n; }
    function elapsedText() {
        if (!recording || startedAt <= 0) return "";
        var s = Math.max(0, now - startedAt);
        var h = Math.floor(s / 3600);
        var m = Math.floor((s % 3600) / 60);
        var sec = s % 60;
        return h > 0 ? (h + ":" + pad(m) + ":" + pad(sec)) : (pad(m) + ":" + pad(sec));
    }
    function statusText() {
        if (root.phase === "starting") return "Starting";
        if (root.phase === "diarizing") return "Diarizing";
        if (root.phase === "finalizing")
            return root.totalWindows > 0 ? "Finalizing " + root.finalizationPercent + "%" : "Finalizing";
        return root.elapsedText();
    }
    function tooltipText() {
        if (root.toggleBusy) return "Updating recording...";
        if (root.phase === "starting") return "Starting recording...";
        if (root.phase === "diarizing") return "Identifying call participants...";
        if (root.phase === "finalizing") {
            return root.totalWindows > 0
                ? "Finalizing transcript — " + root.completedWindows + " of " + root.totalWindows +
                    " windows (" + root.finalizationPercent + "%)"
                : "Finalizing transcript...";
        }
        if (root.phase === "incomplete") {
            if (root.failureCode === "status_unavailable") return "Recorder status is unavailable";
            if (root.failureCode === "legacy_recording_state") return "An older recording needs review before a new one can start";
            return root.failureText() + root.coverageDetail +
                (root.salvageable ? " — click to verify and transcribe retained audio as a partial transcript; right-click to start another recording" :
                 root.hasPartialTranscript ? " — partial transcript available; click to start another recording" :
                 root.retryable ? " — click to retry transcription; right-click to start another recording" :
                 " — click to start another recording");
        }
        if (root.phase === "ready") {
            if (root.diarizationStatus === "failed")
                return "Transcript ready; participant labeling failed — click to retry diarization; right-click to start another recording";
            if (root.diarizationStatus === "ready")
                return "Speaker-labeled transcript ready — click to start recording";
            return "Transcript ready — click to start recording";
        }
        return root.recording
            ? "Recording " + root.elapsedText() +
                (root.captureIssueSides ? " — audio capture was interrupted on " + root.captureIssueSides + "; this transcript will need review" :
                 root.routingWarning === "browser_stream_missing" ? " — no browser audio stream detected; call audio may be missing" :
                 root.routingWarning ? " — browser audio routing is temporarily unavailable" : "") +
                (root.micSourceWarning ? " — microphone source is temporarily unavailable" : "") +
                " — click to stop"
            : "Start recording";
    }

    function failureText() {
        switch (root.failureCode) {
        case "asr_exit": return "Speech recognition failed";
        case "asr_timeout": return "Speech recognition timed out";
        case "invalid_asr_output": return "Speech recognition returned an unusable result";
        case "incomplete_audio_coverage": return "Recording has missing audio";
        case "recording_owner_lost": return "Recorder stopped before completion";
        case "capture_end_unknown": return "Recording ended unexpectedly";
        case "turns_failed": return "Transcript formatting failed";
        case "legacy_recording_state": return "An older recording needs attention";
        default: return "Recording could not be completed";
        }
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.now = Math.floor(Date.now() / 1000)
    }

    // The CLI verifies durable state and the owning unit. A stale file must
    // never look like active capture, and finalization is a separate state.
    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: { if (!pollProc.running) pollProc.running = true; }
    }

    property string _pollOut: ""

    Process {
        id: pollProc
        command: ["record-call", "status", "--json"]
        running: false
        stdout: SplitParser {
            onRead: data => { root._pollOut += data + "\n"; }
        }
        onStarted: root._pollOut = ""
        onExited: (exitCode, exitStatus) => {
            try {
                if (exitCode !== 0) throw new Error("status_unavailable");
                var state = JSON.parse(root._pollOut);
                if (["idle", "starting", "recording", "finalizing", "diarizing", "ready", "incomplete"].indexOf(state.status) < 0)
                    throw new Error("invalid_status");
                var progress = state.finalization || {};
                root.phase = state.status === "finalizing" && progress.stage === "diarizing"
                    ? "diarizing"
                    : state.status;
                root.startedAt = state.startedAt ? Math.floor(Date.parse(state.startedAt) / 1000) : 0;
                root.outputDir = state.outputDir || "";
                root.failureCode = state.failure ? state.failure.code : "";
                root.retryable = !!(state.failure && state.failure.retryable && root.outputDir);
                root.salvageable = !!(state.salvageable && root.outputDir);
                root.hasPartialTranscript = !!(state.status === "incomplete" && state.source && state.source.transcript);
                var issues = Array.isArray(state.captureIssues) ? state.captureIssues : [];
                var affected = [];
                for (var issue of issues) {
                    if ((issue.side === "call" || issue.side === "mic") && affected.indexOf(issue.side) < 0)
                        affected.push(issue.side);
                }
                root.captureIssueSides = affected.join(" and ");
                root.routingWarning = state.routingWarning || "";
                root.micSourceWarning = state.micSourceWarning || "";
                var coverage = state.coverage || {};
                var sides = coverage.sides || {};
                var shortfalls = [];
                for (var side of ["call", "mic"]) {
                    var shortfall = Number((sides[side] || {}).sampleClockShortfallMs);
                    if (Number.isFinite(shortfall) && shortfall > 0)
                        shortfalls.push(side + " " + (shortfall / 1000).toFixed(1) + " s");
                }
                root.coverageDetail = shortfalls.length
                    ? " — unverified audio time: " + shortfalls.join(", ") + "; its position in the call is unknown"
                    : "";
                var diarization = state.diarization || {};
                root.diarizationStatus = diarization.status || "pending";
                root.diarizationFailureCode = diarization.failure ? diarization.failure.code : "";
                root.diarizedSpeakers = Math.max(0, Number(diarization.speakers) || 0);
                root.completedWindows = Math.max(0, Number(progress.completedWindows) || 0);
                root.totalWindows = Math.max(0, Number(progress.totalWindows) || 0);
                root.finalizationPercent = root.totalWindows > 0
                    ? Math.min(100, Math.floor(root.completedWindows * 100 / root.totalWindows))
                    : 0;
            } catch (error) {
                root.phase = "incomplete";
                root.failureCode = "status_unavailable";
                root.captureIssueSides = "";
                root.routingWarning = "";
                root.micSourceWarning = "";
                root.coverageDetail = "";
                root.retryable = false;
                root.salvageable = false;
                root.hasPartialTranscript = false;
                root.diarizationStatus = "pending";
                root.diarizationFailureCode = "";
                root.diarizedSpeakers = 0;
                root.startedAt = 0;
                root.completedWindows = 0;
                root.totalWindows = 0;
                root.finalizationPercent = 0;
            }
        }
    }

    Process {
        id: toggleProc
        command: ["true"]
        running: false
        onStarted: {
            root.toggleBusy = true;
        }
        onExited: (exitCode, exitStatus) => {
            root.toggleBusy = false;
            if (exitCode !== 0) {
                console.warn("[record-call] command failed rc=" + exitCode);
            }
            kickPoll.start();
        }
    }

    // The owner continues finalization after stop returns. Do not start a
    // competing command while capture startup or transcript finalization runs.
    function toggle() {
        if (root.toggleBusy || root.finalizing || root.failureCode === "status_unavailable" || root.failureCode === "legacy_recording_state") return;
        if (root.phase === "ready" && root.diarizationStatus === "failed" && root.outputDir) {
            toggleProc.command = ["record-call", "retry-diarization", root.outputDir];
        } else if (root.phase === "incomplete" && root.salvageable) {
            toggleProc.command = ["record-call", "salvage", root.outputDir];
        } else if (root.phase === "incomplete" && root.retryable) {
            toggleProc.command = ["record-call", "retry", root.outputDir];
        } else {
            toggleProc.command = ["record-call", root.recording ? "stop" : "start"];
        }
        toggleProc.running = true;
    }

    // A failed transcription must not prevent recording the next meeting.
    // Starting a new session leaves the previous audio and retry receipts intact.
    function startNew() {
        if (root.toggleBusy || root.recording || root.finalizing || root.failureCode === "status_unavailable" || root.failureCode === "legacy_recording_state") return;
        toggleProc.command = ["record-call", "start"];
        toggleProc.running = true;
    }

    Timer {
        id: kickPoll
        interval: 400
        running: false
        repeat: false
        onTriggered: { if (!pollProc.running) pollProc.running = true; }
    }

    pillClickAction: () => root.toggle()
    pillRightClickAction: () => root.startNew()

    // Layer-shell tooltip window (renders above the bar). Activated lazily on
    // hover so the layer surface only exists while the pill is hovered.
    Loader {
        id: tooltipLoader
        active: false
        sourceComponent: DankTooltip {}
    }

    function _showTooltip(item) {
        if (!root.parentScreen) return;
        tooltipLoader.active = true;
        if (!tooltipLoader.item) return;
        var screen = root.parentScreen || Screen;
        if (root.isVertical) {
            var globalPos = item.mapToGlobal(item.width / 2, item.height / 2);
            var screenY = screen ? screen.y : 0;
            var relativeY = globalPos.y - screenY;
            var isLeft = root.axis?.edge === "left";
            var tooltipX = isLeft
                ? (root.barThickness + root.barSpacing + Theme.spacingXS)
                : (screen.width - root.barThickness - root.barSpacing - Theme.spacingXS);
            var screenX = screen ? screen.x : 0;
            tooltipLoader.item.show(root.tooltipText(), screenX + tooltipX, relativeY, screen, isLeft, !isLeft);
        } else {
            var isBottom = root.axis?.edge === "bottom";
            var hpos = item.mapToGlobal(item.width / 2, 0);
            var tooltipY;
            if (isBottom) {
                var tooltipHeight = Theme.fontSizeSmall * 1.5 + Theme.spacingS * 2;
                tooltipY = screen.height - root.barThickness - root.barSpacing - Theme.spacingXS - tooltipHeight;
            } else {
                tooltipY = root.barThickness + root.barSpacing + Theme.spacingXS;
            }
            tooltipLoader.item.show(root.tooltipText(), hpos.x, tooltipY, screen, false, false);
        }
    }

    function _hideTooltip() {
        if (tooltipLoader.item) tooltipLoader.item.hide();
        tooltipLoader.active = false;
    }

    horizontalBarPill: Component {
        Row {
            id: hPillRow
            spacing: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter

            HoverHandler {
                onHoveredChanged: hovered ? root._showTooltip(hPillRow) : root._hideTooltip()
            }

            DankIcon {
                name: root.recording ? (root.activeWarning ? "error_outline" : "fiber_manual_record") : root.finalizing ? "hourglass_top" : root.phase === "incomplete" || (root.phase === "ready" && root.diarizationStatus === "failed") ? "error_outline" : "mic"
                size: Theme.iconSize
                color: root.recording ? (root.activeWarning ? "#e6a23c" : "#e74c3c") : root.phase === "incomplete" || (root.phase === "ready" && root.diarizationStatus === "failed") ? "#e6a23c" : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter

                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    running: root.recording
                    NumberAnimation { from: 1.0; to: 0.4; duration: 700 }
                    NumberAnimation { from: 0.4; to: 1.0; duration: 700 }
                }
            }

            StyledText {
                text: root.statusText()
                visible: root.recording || root.finalizing
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            id: vPillCol
            spacing: 1
            anchors.horizontalCenter: parent.horizontalCenter

            HoverHandler {
                onHoveredChanged: hovered ? root._showTooltip(vPillCol) : root._hideTooltip()
            }

            DankIcon {
                name: root.recording ? (root.activeWarning ? "error_outline" : "fiber_manual_record") : root.finalizing ? "hourglass_top" : root.phase === "incomplete" || (root.phase === "ready" && root.diarizationStatus === "failed") ? "error_outline" : "mic"
                size: Theme.iconSize
                color: root.recording ? (root.activeWarning ? "#e6a23c" : "#e74c3c") : root.phase === "incomplete" || (root.phase === "ready" && root.diarizationStatus === "failed") ? "#e6a23c" : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter

                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    running: root.recording
                    NumberAnimation { from: 1.0; to: 0.4; duration: 700 }
                    NumberAnimation { from: 0.4; to: 1.0; duration: 700 }
                }
            }

            StyledText {
                text: root.statusText()
                visible: root.recording || root.finalizing
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }
}
