import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

PluginComponent {
    id: root

    property bool showSwap: (pluginData && pluginData.showSwap !== undefined) ? pluginData.showSwap : false
    readonly property real swapUsage: DgopService.totalSwapKB > 0 ? (DgopService.usedSwapKB / DgopService.totalSwapKB) * 100 : 0
    readonly property color usageColor: {
        if (DgopService.memoryUsage > 90) return Theme.tempDanger;
        if (DgopService.memoryUsage > 75) return Theme.tempWarning;
        return Theme.surfaceText;
    }

    function formatMemoryMB(mb) {
        if (mb >= 1024) return (mb / 1024).toFixed(1) + "G";
        return Math.round(mb).toString() + "M";
    }

    Component.onCompleted: DgopService.addRef(["memory"])
    Component.onDestruction: DgopService.removeRef(["memory"])

    pillClickAction: () => DgopService.setSortBy("memory")

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            anchors.verticalCenter: parent.verticalCenter

            DankIcon {
                name: "memory"
                size: root.iconSizeLarge
                color: root.usageColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: {
                    if (!DgopService.usedMemoryMB || DgopService.usedMemoryMB === 0) return "--";
                    return root.formatMemoryMB(DgopService.usedMemoryMB)
                        + " / " + root.formatMemoryMB(DgopService.totalMemoryMB)
                        + " (" + DgopService.memoryUsage.toFixed(0) + "%)";
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
                name: "memory"
                size: root.iconSizeLarge
                color: root.usageColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: {
                    if (!DgopService.usedMemoryMB || DgopService.usedMemoryMB === 0) return "--";
                    return root.formatMemoryMB(DgopService.usedMemoryMB)
                        + " / " + root.formatMemoryMB(DgopService.totalMemoryMB);
                }
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: root.showSwap && root.swapUsage > 0
                text: "SWAP " + root.swapUsage.toFixed(0) + "%"
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                color: Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }
}
