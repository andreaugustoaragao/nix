pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Singleton {
    id: root

    property var workspaces: ({})
    property var allWorkspaces: []
    property int focusedWorkspaceIndex: 0
    property string focusedWorkspaceId: ""
    property var currentOutputWorkspaces: []
    property string currentOutput: ""

    property var outputs: ({})
    property var windows: []

    property bool inOverview: false

    readonly property string socketPath: Quickshell.env("NIRI_SOCKET")

    signal workspacesChanged()
    signal windowsChanged()

    Component.onCompleted: {
        fetchOutputs()
    }

    function fetchOutputs() {
        outputsProcess.running = true
    }

    Process {
        id: outputsProcess
        command: ["niri", "msg", "-j", "outputs"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const outputsData = JSON.parse(text)
                    outputs = outputsData
                    console.log("NiriService: Loaded", Object.keys(outputsData).length, "outputs")
                } catch (e) {
                    console.warn("NiriService: Failed to parse outputs:", e)
                }
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0) {
                console.warn("NiriService: Failed to fetch outputs, exit code:", exitCode)
            }
        }
    }

    Socket {
        id: eventStreamSocket
        path: root.socketPath
        connected: root.socketPath && root.socketPath.length > 0

        onConnectionStateChanged: {
            if (connected) {
                write('"EventStream"\n')
                console.log("NiriService: Connected to event stream")
            }
        }

        parser: SplitParser {
            onRead: line => {
                try {
                    const event = JSON.parse(line)
                    handleNiriEvent(event)
                } catch (e) {
                    console.warn("NiriService: Failed to parse event:", line, e)
                }
            }
        }
    }

    Socket {
        id: requestSocket
        path: root.socketPath
        connected: root.socketPath && root.socketPath.length > 0
    }

    function handleNiriEvent(event) {
        const eventType = Object.keys(event)[0];
        
        switch (eventType) {
            case 'WorkspacesChanged':
                handleWorkspacesChanged(event.WorkspacesChanged);
                break;
            case 'WorkspaceActivated':
                handleWorkspaceActivated(event.WorkspaceActivated);
                break;
            case 'WorkspaceActiveWindowChanged':
                handleWorkspaceActiveWindowChanged(event.WorkspaceActiveWindowChanged);
                break;
            case 'WindowsChanged':
                handleWindowsChanged(event.WindowsChanged);
                break;
            case 'WindowClosed':
                handleWindowClosed(event.WindowClosed);
                break;
            case 'WindowOpenedOrChanged':
                handleWindowOpenedOrChanged(event.WindowOpenedOrChanged);
                break;
            case 'OutputsChanged':
                handleOutputsChanged(event.OutputsChanged);
                break;
            case 'OverviewOpenedOrClosed':
                handleOverviewChanged(event.OverviewOpenedOrClosed);
                break;
            case 'ConfigLoaded':
                console.log("NiriService: Config loaded");
                break;
        }
    }

    function handleWorkspacesChanged(data) {
        const newWorkspaces = {}

        for (const ws of data.workspaces) {
            newWorkspaces[ws.id] = ws
        }

        root.workspaces = newWorkspaces
        allWorkspaces = [...data.workspaces].sort((a, b) => a.idx - b.idx)

        focusedWorkspaceIndex = allWorkspaces.findIndex(w => w.is_focused)
        if (focusedWorkspaceIndex >= 0) {
            const focusedWs = allWorkspaces[focusedWorkspaceIndex]
            focusedWorkspaceId = focusedWs.id
            currentOutput = focusedWs.output || ""
        } else {
            focusedWorkspaceIndex = 0
            focusedWorkspaceId = ""
        }

        updateCurrentOutputWorkspaces()
        workspacesChanged()
    }

    function handleWorkspaceActivated(data) {
        const ws = root.workspaces[data.id]
        if (!ws) {
            return
        }
        const output = ws.output

        for (const id in root.workspaces) {
            const workspace = root.workspaces[id]
            const got_activated = workspace.id === data.id

            if (workspace.output === output) {
                workspace.is_active = got_activated
            }

            if (data.focused) {
                workspace.is_focused = got_activated
            }
        }

        focusedWorkspaceId = data.id
        focusedWorkspaceIndex = allWorkspaces.findIndex(w => w.id === data.id)

        if (focusedWorkspaceIndex >= 0) {
            currentOutput = allWorkspaces[focusedWorkspaceIndex].output || ""
        }

        allWorkspaces = Object.values(root.workspaces).sort((a, b) => a.idx - b.idx)

        updateCurrentOutputWorkspaces()
        workspacesChanged()
    }

    function handleWorkspaceActiveWindowChanged(data) {
        if (data.active_window_id !== null && data.active_window_id !== undefined) {
            const updatedWindows = []
            for (var i = 0; i < windows.length; i++) {
                const w = windows[i]
                const updatedWindow = {}
                for (let prop in w) {
                    updatedWindow[prop] = w[prop]
                }
                updatedWindow.is_focused = (w.id == data.active_window_id)
                updatedWindows.push(updatedWindow)
            }
            windows = updatedWindows
        } else {
            const updatedWindows = []
            for (var i = 0; i < windows.length; i++) {
                const w = windows[i]
                const updatedWindow = {}
                for (let prop in w) {
                    updatedWindow[prop] = w[prop]
                }
                updatedWindow.is_focused = w.workspace_id == data.workspace_id ? false : w.is_focused
                updatedWindows.push(updatedWindow)
            }
            windows = updatedWindows
        }
        windowsChanged()
    }

    function handleWindowsChanged(data) {
        windows = data.windows
        windowsChanged()
    }

    function handleWindowClosed(data) {
        windows = windows.filter(w => w.id !== data.id)
        windowsChanged()
    }

    function handleWindowOpenedOrChanged(data) {
        if (!data.window) {
            return
        }

        const window = data.window
        const existingIndex = windows.findIndex(w => w.id === window.id)

        if (existingIndex >= 0) {
            const updatedWindows = [...windows]
            updatedWindows[existingIndex] = window
            windows = updatedWindows
        } else {
            windows = [...windows, window]
        }
        windowsChanged()
    }

    function handleOutputsChanged(data) {
        if (data.outputs) {
            outputs = data.outputs
        }
    }

    function handleOverviewChanged(data) {
        inOverview = data.is_open
    }

    function updateCurrentOutputWorkspaces() {
        if (!currentOutput) {
            currentOutputWorkspaces = allWorkspaces
            return
        }

        const outputWs = allWorkspaces.filter(w => w.output === currentOutput)
        currentOutputWorkspaces = outputWs
    }

    function send(request) {
        if (!requestSocket.connected) {
            return false
        }
        requestSocket.write(JSON.stringify(request) + "\n")
        return true
    }

    function switchToWorkspace(workspaceIndex) {
        return send({
            "Action": {
                "FocusWorkspace": {
                    "reference": {
                        "Index": workspaceIndex
                    }
                }
            }
        })
    }

    function focusWindow(windowId) {
        return send({
            "Action": {
                "FocusWindow": {
                    "id": windowId
                }
            }
        })
    }

    function getCurrentWorkspaceNumber() {
        if (focusedWorkspaceIndex >= 0 && focusedWorkspaceIndex < allWorkspaces.length) {
            return allWorkspaces[focusedWorkspaceIndex].idx + 1
        }
        return 1
    }

    function getCurrentOutputWorkspaceNumbers() {
        return currentOutputWorkspaces.map(w => w.idx + 1)
    }

    function getFocusedWindow() {
        for (const window of windows) {
            if (window.is_focused) {
                return window
            }
        }
        return null
    }
} 