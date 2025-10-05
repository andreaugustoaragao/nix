pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool isNiri: false
    property string compositor: "unknown"

    readonly property string niriSocket: Quickshell.env("NIRI_SOCKET")

    Component.onCompleted: {
        detectCompositor()
    }

    function detectCompositor() {
        if (niriSocket && niriSocket.length > 0) {
            niriSocketCheck.running = true
        } else {
            isNiri = false
            compositor = "unknown"
            console.warn("CompositorService: No Niri socket found")
        }
    }

    Process {
        id: niriSocketCheck
        command: ["test", "-S", root.niriSocket]

        onExited: exitCode => {
            if (exitCode === 0) {
                root.isNiri = true
                root.compositor = "niri"
                console.log("CompositorService: Detected Niri with socket:", root.niriSocket)
            } else {
                root.isNiri = true  // Default to Niri anyway for this config
                root.compositor = "niri"
                console.warn("CompositorService: Niri socket check failed, defaulting to Niri anyway")
            }
        }
    }
} 