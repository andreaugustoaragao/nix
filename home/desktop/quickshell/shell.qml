import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Bluetooth
// import "NiriService.qml" as NiriService
// import "CompositorService.qml" as CompositorService
import "AudioService.qml" as AudioService

ShellRoot {
  id: root
  // Match Niri layout gap so chips align with window borders
  property int niriGap: 10
  
  // Global font settings
  property string defaultFont: "CaskaydiaMono Nerd Font"
  property int defaultFontSize: 11
  
  // Computed properties from NiriService (temporarily disabled)
  property int workspaceCount: 5
  property int focusedWorkspace: 1
  property string activeTitle: "Test Window"
  
  // System monitoring properties
  property real cpuUsage: 0.0
  property real memUsage: 0.0
  property real diskUsage: 0.0
  property real cpuTemp: 0.0
  property real lastCpuTotal: 0.0
  property real lastCpuIdle: 0.0
  property string weatherIcon: "☀"
  property string weatherTemp: "20°C"
  property real currentVolume: AudioService.volume
  
  // Centralized text component with consistent styling
  component StyledText: Text {
    font.family: root.defaultFont
    font.pixelSize: root.defaultFontSize
    color: "#dcd7ba"
  }

  // Utility functions
  function formatKib(kib) {
    if (kib == null || kib == undefined) return "0 KiB";
    const mib = 1024;
    const gib = 1024 * 1024;
    const tib = 1024 * 1024 * 1024;
    
    if (kib >= tib) return (kib / tib).toFixed(1) + " TiB";
    if (kib >= gib) return (kib / gib).toFixed(1) + " GiB";
    if (kib >= mib) return (kib / mib).toFixed(1) + " MiB";
    return kib.toFixed(0) + " KiB";
  }

  function getWeatherIcon(code) {
    const icons = {
      113: "☀",  // Sunny
      116: "⛅", // Partly cloudy
      119: "☁",  // Cloudy
      122: "☁",  // Overcast
      143: "🌫",  // Mist
      176: "🌦",  // Patchy rain possible
      179: "🌨",  // Patchy snow possible
      182: "🌨",  // Patchy sleet possible
      185: "🌨",  // Patchy freezing drizzle possible
      200: "⛈",  // Thundery outbreaks possible
      227: "🌨",  // Blowing snow
      230: "❄",  // Blizzard
      248: "🌫",  // Fog
      260: "🌫"   // Freezing fog
    };
    return icons[code] || "❓";
  }

  function getVolumeIcon(volume, muted) {
    if (muted || volume === 0) return "🔇";
    if (volume < 0.33) return "🔈";
    if (volume < 0.66) return "🔉";
    return "🔊";
  }

  function getBluetoothIcon(icon) {
    if (icon && icon.includes("headset")) return "🎧";
    if (icon && icon.includes("audio")) return "🔊";
    if (icon && icon.includes("phone")) return "📱";
    if (icon && icon.includes("mouse")) return "🖱";
    if (icon && icon.includes("keyboard")) return "⌨";
    return "📱";
  }
  
  function getBluetoothStatus() {
    if (!Bluetooth.defaultAdapter?.enabled) return ""; // disabled 
    return ""; // enabled
  }
  
  // Connect to NiriService signals for real-time updates (temporarily disabled)
  // Connections {
  //   target: NiriService
  //   function onWorkspacesChanged() {
  //     console.log("Workspaces updated:", root.workspaceCount, "workspaces, focused:", root.focusedWorkspace)
  //   }
  //   function onWindowsChanged() {
  //     console.log("Windows updated, active title:", root.activeTitle)
  //   }
  // }
  
  // System monitoring timer
  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      cpuStat.reload()
      memInfo.reload()
      diskUsage.running = true
      cpuTempProc.running = true
    }
  }
  
  // Weather update timer (every 10 minutes)
  Timer {
    interval: 600000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: weatherFetch.running = true
  }
  
  // Bluetooth refresh timer (every 5 seconds)
  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      // Force refresh of bluetooth status by accessing properties
      if (Bluetooth.defaultAdapter) {
        var enabled = Bluetooth.defaultAdapter.enabled;
      }
      if (Bluetooth.devices && Bluetooth.devices.values) {
        var devices = [...Bluetooth.devices.values];
      }
    }
  }
  
  // Weather fetching process
  Process {
    id: weatherFetch
    command: ["curl", "-s", "-A", "curl", "https://wttr.in/Broomfield,Colorado,USA?format=j1"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const json = JSON.parse(text);
          if (json && json.current_condition && json.current_condition[0]) {
            const current = json.current_condition[0];
            root.weatherIcon = getWeatherIcon(parseInt(current.weatherCode));
            root.weatherTemp = current.temp_C + "°C";
          }
        } catch (e) {
          console.log("Weather parsing error:", e);
          root.weatherIcon = "❓";
          root.weatherTemp = "--°C";
        }
      }
    }
  }

  // CPU usage monitoring
  FileView {
    id: cpuStat
    path: "/proc/stat"
    onLoaded: {
      const data = text().match(/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/)
      if (data) {
        const stats = data.slice(1).map(n => parseInt(n, 10))
        const total = stats.reduce((a, b) => a + b, 0)
        const idle = stats[3] + (stats[4] ?? 0)
        
        const totalDiff = total - root.lastCpuTotal
        const idleDiff = idle - root.lastCpuIdle
        
        if (totalDiff > 0) {
          root.cpuUsage = Math.max(0, Math.min(1, (totalDiff - idleDiff) / totalDiff))
        }
        
        root.lastCpuTotal = total
        root.lastCpuIdle = idle
      }
    }
  }

  // Memory usage monitoring  
  FileView {
    id: memInfo
    path: "/proc/meminfo"
    onLoaded: {
      const data = text()
      const totalMatch = data.match(/MemTotal:\s*(\d+)\s*kB/)
      const availMatch = data.match(/MemAvailable:\s*(\d+)\s*kB/)
      
      if (totalMatch && availMatch) {
        const total = parseInt(totalMatch[1])
        const avail = parseInt(availMatch[1])
        root.memUsage = (total - avail) / total
      }
    }
  }

  // Disk usage monitoring
  Process {
    id: diskUsage
    command: ["df", "/"]
    stdout: StdioCollector {
      onStreamFinished: {
        const lines = text.trim().split('\n')
        if (lines.length >= 2) {
          const parts = lines[1].trim().split(/\s+/)
          if (parts.length >= 5) {
            const percMatch = parts[2].match(/(\d+)%/);
            if (percMatch) {
              root.diskUsage = parseInt(percMatch[1]) / 100.0
            } else {
              const used = parseInt(parts[2]) || 0
              const total = parseInt(parts[1]) || 1
              root.diskUsage = used / total
            }
          }
        }
      }
    }
  }

  // CPU temperature monitoring
  Process {
    id: cpuTempProc
    command: ["bash", "-c", "sensors 2>/dev/null | grep -E '(Package id|Tdie|Tctl|Core|temp1):' | head -1 || echo 'temp1: +0.0°C'"]
    stdout: StdioCollector {
      onStreamFinished: {
        const output = text.trim();
        if (output.includes("°C")) {
          const lines = output.split('\n');
          for (const line of lines) {
            const match = line.match(/(?:Package id \d+|Tdie|Tctl|Core \d+|temp1):\s*\+?([0-9.]+)°?C/i);
            if (match) {
              root.cpuTemp = parseFloat(match[1]);
              return;
            }
          }
        } else {
          const tempValue = parseFloat(output);
          if (!isNaN(tempValue)) {
            root.cpuTemp = tempValue;
          }
        }
      }
    }
  }

  // Audio monitoring is handled by AudioService

  // Main panel window
  PanelWindow {
    id: panel
    anchors {
      left: true
      right: true
      top: true
    }
    implicitHeight: 40
    margins {
      left: root.niriGap
      right: root.niriGap
      top: root.niriGap
    }

    color: "transparent"

    Rectangle {
      anchors.fill: parent
      color: "#1f1f28"
      radius: 8

      RowLayout {
      anchors.fill: parent
      anchors.margins: 8
      spacing: 12

      // Left side - Workspaces
      RowLayout {
        spacing: 6
        
        // Display workspace chips using NiriService data
        Repeater {
          model: root.workspaceCount
          delegate: Rectangle {
            required property int index
            width: 18
            height: 18
            radius: 9
            color: (index + 1) === root.focusedWorkspace ? "#7fb4ca" : "#2a2a32"
            border.color: (index + 1) === root.focusedWorkspace ? "#7fb4ca" : "#54546d"

                         MouseArea {
               anchors.fill: parent
               onClicked: {
                 // NiriService.switchToWorkspace(index)
                 console.log("Workspace", index + 1, "clicked")
               }
             }

            StyledText {
              anchors.centerIn: parent
              color: (index + 1) === root.focusedWorkspace ? "#1f1f28" : "#dcd7ba"
              text: (index + 1)
            }
          }
        }
      }

      // Active window title
      StyledText {
        Layout.fillWidth: true
        text: root.activeTitle || "Desktop"
        elide: Text.ElideRight
      }

      // Right side - System info chips
      RowLayout {
        spacing: 6

        // CPU chip
        Rectangle {
          id: cpuChip
          width: cpuText.implicitWidth + 16
          height: 24
          radius: 12
          color: "#2a2a32"
          border.color: "#54546d"

          StyledText {
            id: cpuText
            anchors.centerIn: parent
            text: "CPU " + Math.round(root.cpuUsage * 100) + "%"
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: parent.color = "#3c3c47"
            onExited: parent.color = "#2a2a32"
          }
        }

        // Memory chip
        Rectangle {
          id: memChip
          width: memText.implicitWidth + 16
          height: 24
          radius: 12
          color: "#2a2a32"
          border.color: "#54546d"

          StyledText {
            id: memText
            anchors.centerIn: parent
            text: "MEM " + Math.round(root.memUsage * 100) + "%"
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: parent.color = "#3c3c47"
            onExited: parent.color = "#2a2a32"
          }
        }

        // Disk chip
        Rectangle {
          id: diskChip
          width: diskText.implicitWidth + 16
          height: 24
          radius: 12
          color: "#2a2a32"
          border.color: "#54546d"

          StyledText {
            id: diskText
            anchors.centerIn: parent
            text: "DISK " + Math.round(root.diskUsage * 100) + "%"
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: parent.color = "#3c3c47"
            onExited: parent.color = "#2a2a32"
          }
        }

        // Bluetooth chip
        Rectangle {
          id: bluetoothChip
          width: bluetoothContent.implicitWidth + 16
          height: 24
          radius: 12
          color: "#2a2a32"
          border.color: "#54546d"
          visible: Bluetooth.defaultAdapter

          Row {
            id: bluetoothContent
            anchors.centerIn: parent
            spacing: 4

            StyledText {
              text: "BT"
              color: Bluetooth.defaultAdapter?.enabled ? "#7fb4ca" : "#727169"
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: parent.color = "#3c3c47"
            onExited: parent.color = "#2a2a32"
            onClicked: {
              bluetoothPopup.visible = !bluetoothPopup.visible;
            }
          }
        }

        // Weather chip
        Rectangle {
          id: weatherChip
          width: weatherText.implicitWidth + 16
          height: 24
          radius: 12
          color: "#2a2a32"
          border.color: "#54546d"

          StyledText {
            id: weatherText
            anchors.centerIn: parent
            text: root.weatherIcon + " " + root.weatherTemp
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: parent.color = "#3c3c47"
            onExited: parent.color = "#2a2a32"
          }
        }

        // Volume chip with slider
        Rectangle {
          id: volChip
          width: volContent.implicitWidth + 16
          height: 24
          radius: 12
          color: "#2a2a32"
          border.color: "#54546d"

          Row {
            id: volContent
            anchors.centerIn: parent
            spacing: 8
            
            StyledText {
              anchors.verticalCenter: parent.verticalCenter
              text: getVolumeIcon(AudioService.volume, AudioService.muted)
            }
            
            StyledText {
              anchors.verticalCenter: parent.verticalCenter
              text: Math.round(AudioService.volume * 100) + "%"
            }
            
            // Volume slider
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 60
              height: 4
              radius: 2
              color: "#54546d"
              
              Rectangle {
                width: parent.width * AudioService.volume
                height: parent.height
                radius: parent.radius
                color: "#7fb4ca"
              }
              
              MouseArea {
                anchors.fill: parent
                onPressed: mouse => {
                  const newVolume = Math.max(0, Math.min(1, mouse.x / width))
                  AudioService.setVolume(newVolume)
                }
                onPositionChanged: mouse => {
                  if (pressed) {
                    const newVolume = Math.max(0, Math.min(1, mouse.x / width))
                    AudioService.setVolume(newVolume)
                  }
                }
              }
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: parent.color = "#3c3c47"
            onExited: parent.color = "#2a2a32"
            onWheel: wheel => {
              const delta = wheel.angleDelta.y / 120
              if (delta > 0) {
                AudioService.incrementVolume()
              } else if (delta < 0) {
                AudioService.decrementVolume()
              }
            }
          }
        }

        // Clock
        StyledText {
          text: new Date().toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'})
          
          Timer {
            interval: 1000
            running: true
            repeat: true
            onTriggered: parent.text = new Date().toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'})
          }
        }
      }
    }
    }
  }

  // Bluetooth dashboard popup
  PopupWindow {
    id: bluetoothPopup
    visible: false
    implicitWidth: 300
    implicitHeight: 200
    
    anchor {
      window: panel
      rect {
        x: bluetoothChip.x
        y: panel.implicitHeight + 5
        width: bluetoothChip.width
        height: bluetoothChip.height
      }
    }

    Rectangle {
      anchors.fill: parent
      color: "#1f1f28"
      radius: 8
      border.color: "#54546d"

      Column {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        StyledText {
          text: "Bluetooth"
          font.bold: true
        }

        StyledText {
          text: {
            if (!Bluetooth.defaultAdapter) return "No adapter";
            if (!Bluetooth.defaultAdapter.enabled) return "Disabled";
            const connected = [...Bluetooth.devices.values].filter(d => d.connected);
            return connected.length + " device(s) connected";
          }
        }

        ListView {
          width: parent.width
          height: parent.height - 60
          model: Bluetooth.devices?.values || []
          
          delegate: Rectangle {
            width: parent.width
            height: 30
            color: "transparent"
            
            StyledText {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: getBluetoothIcon(modelData.icon) + " " + (modelData.name || "Unknown Device")
              color: modelData.connected ? "#7fb4ca" : "#727169"
            }
          }
        }
      }
    }
  }
} 