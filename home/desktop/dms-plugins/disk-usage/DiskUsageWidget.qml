pragma Singleton

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

BasePill {
    id: root

    property var widgetData: null
    property string mountPath: (widgetData && widgetData.mountPath !== undefined) ? widgetData.mountPath : "/"
    property bool isHovered: mouseArea.containsMouse

    // Find the selected mount from DgopService
    readonly property var selectedMount: {
        if (!DgopService.diskMounts || DgopService.diskMounts.length === 0) {
            return null;
        }
        const currentMountPath = root.mountPath || "/";
        for (let i = 0; i < DgopService.diskMounts.length; i++) {
            if (DgopService.diskMounts[i].mount === currentMountPath) {
                return DgopService.diskMounts[i];
            }
        }
        for (let i = 0; i < DgopService.diskMounts.length; i++) {
            if (DgopService.diskMounts[i].mount === "/") {
                return DgopService.diskMounts[i];
            }
        }
        return DgopService.diskMounts[0] || null;
    }

    readonly property real diskUsagePercent: {
        if (!selectedMount || !selectedMount.percent) {
            return 0;
        }
        const percentStr = selectedMount.percent.replace("%", "");
        return parseFloat(percentStr) || 0;
    }

    Component.onCompleted: {
        DgopService.addRef(["diskmounts"]);
    }
    Component.onDestruction: {
        DgopService.removeRef(["diskmounts"]);
    }

    content: Component {
        Item {
            implicitWidth: root.isVerticalOrientation ? (root.widgetThickness - root.horizontalPadding * 2) : diskContent.implicitWidth
            implicitHeight: root.isVerticalOrientation ? diskColumn.implicitHeight : diskContent.implicitHeight

            Column {
                id: diskColumn
                visible: root.isVerticalOrientation
                anchors.centerIn: parent
                spacing: 1

                DankIcon {
                    name: "storage"
                    size: Theme.barIconSize(root.barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                    color: {
                        if (root.diskUsagePercent > 90) {
                            return Theme.tempDanger;
                        }
                        if (root.diskUsagePercent > 75) {
                            return Theme.tempWarning;
                        }
                        return Theme.surfaceText;
                    }
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: {
                        if (!root.selectedMount) {
                            return "--";
                        }
                        return root.selectedMount.used + " / " + root.selectedMount.size;
                    }
                    font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                    color: Theme.widgetTextColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: root.diskUsagePercent.toFixed(0) + "%"
                    font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                    color: {
                        if (root.diskUsagePercent > 90) {
                            return Theme.tempDanger;
                        }
                        if (root.diskUsagePercent > 75) {
                            return Theme.tempWarning;
                        }
                        return Theme.surfaceVariantText;
                    }
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            Row {
                id: diskContent
                visible: !root.isVerticalOrientation
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    name: "storage"
                    size: Theme.barIconSize(root.barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                    color: {
                        if (root.diskUsagePercent > 90) {
                            return Theme.tempDanger;
                        }
                        if (root.diskUsagePercent > 75) {
                            return Theme.tempWarning;
                        }
                        return Theme.surfaceText;
                    }
                    anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                    id: textBox
                    anchors.verticalCenter: parent.verticalCenter

                    implicitWidth: Math.max(diskBaseline.width, diskText.paintedWidth)
                    implicitHeight: diskText.implicitHeight
                    width: implicitWidth
                    height: implicitHeight

                    StyledTextMetrics {
                        id: diskBaseline
                        font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                        text: "868.9G / 3.4T"
                    }

                    StyledText {
                        id: diskText
                        text: {
                            if (!root.selectedMount) {
                                return "--";
                            }
                            return root.selectedMount.used + " / " + root.selectedMount.size + " (" + root.selectedMount.percent + ")";
                        }
                        font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                        color: Theme.widgetTextColor

                        anchors.fill: parent
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideNone
                        wrapMode: Text.NoWrap
                    }
                }
            }
        }
    }

    Loader {
        id: tooltipLoader
        active: false
        sourceComponent: DankTooltip {}
    }

    MouseArea {
        id: mouseArea
        z: 1
        anchors.fill: parent
        hoverEnabled: root.isVerticalOrientation
        onEntered: {
            if (root.isVerticalOrientation && root.selectedMount) {
                tooltipLoader.active = true;
                if (tooltipLoader.item) {
                    const globalPos = mapToGlobal(width / 2, height / 2);
                    const currentScreen = root.parentScreen || Screen;
                    const screenX = currentScreen ? currentScreen.x : 0;
                    const screenY = currentScreen ? currentScreen.y : 0;
                    const relativeY = globalPos.y - screenY;
                    const adjustedY = relativeY + root.minTooltipY;
                    const tooltipX = root.axis?.edge === "left" ? (root.barThickness + root.barSpacing + Theme.spacingXS) : (currentScreen.width - root.barThickness - root.barSpacing - Theme.spacingXS);
                    const isLeft = root.axis?.edge === "left";
                    tooltipLoader.item.show(root.selectedMount.mount, screenX + tooltipX, adjustedY, currentScreen, isLeft, !isLeft);
                }
            }
        }
        onExited: {
            if (tooltipLoader.item) {
                tooltipLoader.item.hide();
            }
            tooltipLoader.active = false;
        }
    }

    readonly property real minTooltipY: {
        if (!parentScreen || !root.isVerticalOrientation) {
            return 0;
        }
        if (root.isAutoHideBar) {
            return 0;
        }
        if (parentScreen.y > 0) {
            const spacing = barConfig?.spacing ?? 4;
            const offset = barThickness + spacing;
            return offset;
        }
        return 0;
    }
}
