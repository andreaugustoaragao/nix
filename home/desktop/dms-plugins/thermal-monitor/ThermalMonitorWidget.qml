import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

PluginComponent {
    id: root

    property string sensorOutput: ""
    property real cpuTempC: -1
    property var cpuRows: []
    property var fanRows: []
    property var boardRows: []
    property var gpuRows: []
    property var memoryRows: []
    property var nvmeRows: []
    property string lastUpdated: "--"

    popoutWidth: 560

    readonly property color tempColor: {
        if (cpuTempC >= 85) return Theme.tempDanger;
        if (cpuTempC >= 70) return Theme.tempWarning;
        return Theme.surfaceText;
    }

    function displayTemp(celsius, withUnit) {
        if (celsius === undefined || celsius === null || celsius < -100) return "--";
        const value = SettingsData.useFahrenheit ? (celsius * 9 / 5 + 32) : celsius;
        return Math.round(value).toString() + (withUnit ? (SettingsData.useFahrenheit ? "°F" : "°C") : "°");
    }

    function parseTemp(line) {
        const match = line.match(/^\s*([^:]+):\s+\+?(-?\d+(?:\.\d+)?)°C/);
        if (!match) return null;
        return {
            "name": match[1].trim(),
            "value": parseFloat(match[2]),
            "text": displayTemp(parseFloat(match[2]), true)
        };
    }

    function parseSensors(text) {
        const lines = text.split("\n");
        let block = "";
        let cpu = [];
        let fans = [];
        let board = [];
        let gpu = [];
        let memory = [];
        let nvme = [];

        for (let i = 0; i < lines.length; i++) {
            const raw = lines[i];
            const line = raw.trim();
            if (line.length === 0) continue;
            if (raw[0] !== " " && raw[0] !== "\t" && line.indexOf(":") < 0 && line.indexOf("Adapter") !== 0) {
                block = line;
                continue;
            }

            if (block.indexOf("k10temp") === 0) {
                const temp = parseTemp(raw);
                if (temp && (temp.name === "Tctl" || temp.name.indexOf("Tccd") === 0)) {
                    cpu.push(temp);
                    if (temp.name === "Tctl") root.cpuTempC = temp.value;
                }
            } else if (block.indexOf("nct6799") === 0) {
                const fan = line.match(/^(fan\d+):\s+(\d+)\s+RPM/);
                if (fan) {
                    fans.push({ "name": fan[1], "text": fan[2] + " RPM" });
                    continue;
                }
                const temp = parseTemp(raw);
                if (temp && ["SYSTIN", "CPUTIN", "AUXTIN0", "SMBUSMASTER 0"].indexOf(temp.name) >= 0) {
                    board.push(temp);
                }
            } else if (block.indexOf("amdgpu") === 0) {
                const fan = line.match(/^(fan\d+):\s+(\d+)\s+RPM/);
                if (fan) {
                    gpu.push({ "name": block + " " + fan[1], "text": fan[2] + " RPM" });
                    continue;
                }
                const temp = parseTemp(raw);
                if (temp && ["edge", "junction", "mem"].indexOf(temp.name) >= 0) {
                    gpu.push({ "name": block + " " + temp.name, "text": temp.text, "value": temp.value });
                    continue;
                }
                const power = line.match(/^(PPT):\s+([0-9.]+\s+[m]?W)/);
                if (power) gpu.push({ "name": block + " " + power[1], "text": power[2] });
            } else if (block.indexOf("spd5118") === 0) {
                const temp = parseTemp(raw);
                if (temp) memory.push({ "name": block, "text": temp.text, "value": temp.value });
            } else if (block.indexOf("nvme") === 0) {
                const temp = parseTemp(raw);
                if (temp && (temp.name === "Composite" || temp.name.indexOf("Sensor") === 0)) {
                    nvme.push({ "name": block + " " + temp.name, "text": temp.text, "value": temp.value });
                }
            }
        }

        root.cpuRows = cpu;
        root.fanRows = fans;
        root.boardRows = board;
        root.gpuRows = gpu;
        root.memoryRows = memory;
        root.nvmeRows = nvme;
        root.lastUpdated = Qt.formatDateTime(new Date(), "h:mm:ss AP");
    }

    Component.onCompleted: sensorTimer.start()

    Timer {
        id: sensorTimer
        interval: 2000
        repeat: true
        triggeredOnStart: true
        onTriggered: sensorsProcess.running = true
    }

    Process {
        id: sensorsProcess
        command: ["sh", "-c", "sensors 2>/dev/null || true"]
        running: false
        stdout: SplitParser {
            onRead: data => root.sensorOutput += data + "\n"
        }
        onStarted: root.sensorOutput = ""
        onExited: (exitCode, exitStatus) => root.parseSensors(root.sensorOutput)
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter

            DankIcon {
                name: "device_thermostat"
                size: root.iconSizeLarge
                color: root.tempColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.displayTemp(root.cpuTempC, false)
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: root.tempColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 1
            anchors.horizontalCenter: parent.horizontalCenter

            DankIcon {
                name: "device_thermostat"
                size: root.iconSizeLarge
                color: root.tempColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.displayTemp(root.cpuTempC, false)
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: root.tempColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutContent: Component {
        Column {
            width: parent ? parent.width : root.popoutWidth
            spacing: Theme.spacingM

            RowLayout {
                width: parent.width
                spacing: Theme.spacingM

                DankIcon {
                    name: "device_thermostat"
                    size: Theme.fontSizeXLarge
                    color: root.tempColor
                    Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1

                    StyledText {
                        text: "Thermals"
                        font.pixelSize: Theme.fontSizeLarge
                        color: Theme.surfaceText
                    }

                    StyledText {
                        text: "Updated " + root.lastUpdated
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }

                StyledText {
                    text: root.displayTemp(root.cpuTempC, true)
                    font.pixelSize: Theme.fontSizeXLarge
                    color: root.tempColor
                    Layout.alignment: Qt.AlignVCenter
                }
            }

            SensorCard {
                title: "CPU Package"
                iconName: "memory"
                rows: root.cpuRows
            }

            SensorCard {
                title: "Motherboard Fans"
                iconName: "air"
                rows: root.fanRows
            }

            SensorCard {
                title: "Board Thermistors"
                iconName: "thermostat"
                rows: root.boardRows
            }

            SensorCard {
                title: "GPU"
                iconName: "developer_board"
                rows: root.gpuRows
            }

            SensorCard {
                title: "Memory and NVMe"
                iconName: "storage"
                rows: root.memoryRows.concat(root.nvmeRows)
            }
        }
    }

    component SensorCard: Rectangle {
        required property string title
        required property string iconName
        required property var rows

        width: parent ? parent.width : root.popoutWidth
        implicitHeight: cardColumn.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.72)
        border.color: Theme.withAlpha(Theme.surfaceText, 0.08)
        border.width: 1

        Column {
            id: cardColumn
            width: parent.width - Theme.spacingM * 2
            x: Theme.spacingM
            y: Theme.spacingM
            spacing: Theme.spacingS

            Row {
                spacing: Theme.spacingS

                DankIcon {
                    name: iconName
                    size: Theme.fontSizeLarge
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: title
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                visible: rows.length === 0
                text: "No readings"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Repeater {
                model: rows
                delegate: RowLayout {
                    width: cardColumn.width
                    spacing: Theme.spacingM

                    StyledText {
                        text: modelData.name
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    StyledText {
                        text: modelData.text
                        font.pixelSize: Theme.fontSizeSmall
                        color: {
                            if (modelData.value >= 85) return Theme.tempDanger;
                            if (modelData.value >= 70) return Theme.tempWarning;
                            return Theme.surfaceText;
                        }
                    }
                }
            }
        }
    }
}
