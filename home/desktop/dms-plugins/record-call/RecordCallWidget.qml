import QtQuick
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property bool recording: false
    property int startedAt: 0
    property string outputDir: ""
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
    function tooltipText() {
        return root.recording
            ? "Recording " + root.elapsedText() + " — click to stop"
            : "Start recording";
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.now = Math.floor(Date.now() / 1000)
    }

    // Poll the state file every 2s so CLI-driven start/stop is mirrored
    // in the pill. record-call has no IPC of its own.
    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: pollProc.running = true
    }

    property string _pollOut: ""

    Process {
        id: pollProc
        command: ["sh", "-c", "cat \"${XDG_RUNTIME_DIR:-/tmp}/record-call/session.env\" 2>/dev/null || true"]
        running: false
        stdout: SplitParser {
            onRead: data => { root._pollOut += data + "\n"; }
        }
        onStarted: root._pollOut = ""
        onExited: (exitCode, exitStatus) => {
            var txt = root._pollOut;
            if (!txt || txt.indexOf("STARTED_AT=") < 0) {
                root.recording = false;
                root.startedAt = 0;
                root.outputDir = "";
                return;
            }
            var lines = txt.split("\n");
            var started = 0;
            var out = "";
            for (var i = 0; i < lines.length; i++) {
                var ln = lines[i];
                if (ln.indexOf("STARTED_AT=") === 0) {
                    started = parseInt(ln.substring("STARTED_AT=".length), 10) || 0;
                } else if (ln.indexOf("OUTPUT_DIR=") === 0) {
                    out = ln.substring("OUTPUT_DIR=".length);
                }
            }
            root.recording = started > 0;
            root.startedAt = started;
            root.outputDir = out;
        }
    }

    Process {
        id: toggleProc
        command: ["true"]
        running: false
        onExited: (exitCode, exitStatus) => {
            kickPoll.start();
        }
    }

    function toggle() {
        var sub = root.recording ? "stop" : "start";
        toggleProc.command = ["sh", "-c", "record-call " + sub];
        toggleProc.running = true;
    }

    Timer {
        id: kickPoll
        interval: 400
        running: false
        repeat: false
        onTriggered: pollProc.running = true
    }

    pillClickAction: () => root.toggle()

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
                name: root.recording ? "fiber_manual_record" : "mic"
                size: Theme.iconSize
                color: root.recording ? "#e74c3c" : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter

                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    running: root.recording
                    NumberAnimation { from: 1.0; to: 0.4; duration: 700 }
                    NumberAnimation { from: 0.4; to: 1.0; duration: 700 }
                }
            }

            StyledText {
                text: root.elapsedText()
                visible: root.recording
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
                name: root.recording ? "fiber_manual_record" : "mic"
                size: Theme.iconSize
                color: root.recording ? "#e74c3c" : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter

                SequentialAnimation on opacity {
                    loops: Animation.Infinite
                    running: root.recording
                    NumberAnimation { from: 1.0; to: 0.4; duration: 700 }
                    NumberAnimation { from: 0.4; to: 1.0; duration: 700 }
                }
            }

            StyledText {
                text: root.elapsedText()
                visible: root.recording
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }
}
