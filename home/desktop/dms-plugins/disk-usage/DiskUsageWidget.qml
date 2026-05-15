import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

PluginComponent {
    id: root

    property string mountPath: (pluginData && pluginData.mountPath) ? pluginData.mountPath : "/"

    readonly property var selectedMount: {
        if (!DgopService.diskMounts || DgopService.diskMounts.length === 0) return null;
        const wanted = root.mountPath || "/";
        for (let i = 0; i < DgopService.diskMounts.length; i++) {
            if (DgopService.diskMounts[i].mount === wanted) return DgopService.diskMounts[i];
        }
        for (let i = 0; i < DgopService.diskMounts.length; i++) {
            if (DgopService.diskMounts[i].mount === "/") return DgopService.diskMounts[i];
        }
        return DgopService.diskMounts[0] || null;
    }

    readonly property real diskUsagePercent: {
        if (!selectedMount || !selectedMount.percent) return 0;
        return parseFloat(selectedMount.percent.replace("%", "")) || 0;
    }

    readonly property color usageColor: {
        if (diskUsagePercent > 90) return Theme.tempDanger;
        if (diskUsagePercent > 75) return Theme.tempWarning;
        return Theme.surfaceText;
    }

    Component.onCompleted: DgopService.addRef(["diskmounts"])
    Component.onDestruction: DgopService.removeRef(["diskmounts"])

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter

            DankIcon {
                name: "storage"
                size: root.iconSizeLarge
                color: root.usageColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: {
                    if (!root.selectedMount) return "--";
                    return root.selectedMount.used + " / " + root.selectedMount.size
                        + " (" + root.selectedMount.percent + ")";
                }
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 1
            anchors.horizontalCenter: parent.horizontalCenter

            DankIcon {
                name: "storage"
                size: root.iconSizeLarge
                color: root.usageColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.selectedMount ? (root.selectedMount.used + " / " + root.selectedMount.size) : "--"
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: root.selectedMount !== null
                text: root.diskUsagePercent.toFixed(0) + "%"
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: root.usageColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }
}
