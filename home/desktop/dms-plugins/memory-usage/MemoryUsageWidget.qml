pragma Singleton

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

BasePill {
    id: root

    property var widgetData: null
    property bool showSwap: (widgetData && widgetData.showSwap !== undefined) ? widgetData.showSwap : false
    readonly property real swapUsage: DgopService.totalSwapKB > 0 ? (DgopService.usedSwapKB / DgopService.totalSwapKB) * 100 : 0

    signal ramClicked

    Component.onCompleted: {
        DgopService.addRef(["memory"]);
    }
    Component.onDestruction: {
        DgopService.removeRef(["memory"]);
    }

    // Format memory in human-readable format
    function formatMemoryMB(mb) {
        if (mb >= 1024) {
            return (mb / 1024).toFixed(1) + "G";
        }
        return Math.round(mb).toString() + "M";
    }

    content: Component {
        Item {
            implicitWidth: root.isVerticalOrientation ? (root.widgetThickness - root.horizontalPadding * 2) : ramContent.implicitWidth
            implicitHeight: root.isVerticalOrientation ? ramColumn.implicitHeight : ramContent.implicitHeight

            Column {
                id: ramColumn
                visible: root.isVerticalOrientation
                anchors.centerIn: parent
                spacing: 1

                DankIcon {
                    name: "memory"
                    size: Theme.barIconSize(root.barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                    color: {
                        if (DgopService.memoryUsage > 90) {
                            return Theme.tempDanger;
                        }
                        if (DgopService.memoryUsage > 75) {
                            return Theme.tempWarning;
                        }
                        return Theme.widgetIconColor;
                    }
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: {
                        if (DgopService.usedMemoryMB === undefined || DgopService.usedMemoryMB === null || DgopService.usedMemoryMB === 0) {
                            return "--";
                        }
                        return root.formatMemoryMB(DgopService.usedMemoryMB) + " / " + root.formatMemoryMB(DgopService.totalMemoryMB);
                    }
                    font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                    color: Theme.widgetTextColor
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    visible: root.swapUsage > 0
                    text: "SWAP " + root.swapUsage.toFixed(0) + "%"
                    font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                    color: Theme.surfaceVariantText
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            Row {
                id: ramContent
                visible: !root.isVerticalOrientation
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    id: ramIcon
                    name: "memory"
                    size: Theme.barIconSize(root.barThickness, undefined, root.barConfig?.maximizeWidgetIcons, root.barConfig?.iconScale)
                    color: {
                        if (DgopService.memoryUsage > 90) {
                            return Theme.tempDanger;
                        }
                        if (DgopService.memoryUsage > 75) {
                            return Theme.tempWarning;
                        }
                        return Theme.widgetIconColor;
                    }
                    anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                    id: textBox
                    anchors.verticalCenter: parent.verticalCenter

                    implicitWidth: Math.max(ramBaseline.width, ramText.paintedWidth)
                    implicitHeight: ramText.implicitHeight
                    width: implicitWidth
                    height: implicitHeight

                    StyledTextMetrics {
                        id: ramBaseline
                        font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
                        text: "18.5G / 63.0G"
                    }

                    StyledText {
                        id: ramText
                        text: {
                            if (DgopService.usedMemoryMB === undefined || DgopService.usedMemoryMB === null || DgopService.usedMemoryMB === 0) {
                                return "--";
                            }
                            return root.formatMemoryMB(DgopService.usedMemoryMB) + " / " + root.formatMemoryMB(DgopService.totalMemoryMB) + " (" + DgopService.memoryUsage.toFixed(0) + "%)";
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

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton
        onPressed: mouse => {
            root.triggerRipple(this, mouse.x, mouse.y);
            DgopService.setSortBy("memory");
            ramClicked();
        }
    }
}
