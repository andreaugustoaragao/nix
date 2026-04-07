pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

Singleton {
    id: root

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property PwNode source: Pipewire.defaultAudioSource

    readonly property bool muted: !!sink?.audio?.muted
    readonly property real volume: sink?.audio?.volume ?? 0

    readonly property bool sourceMuted: !!source?.audio?.muted
    readonly property real sourceVolume: source?.audio?.volume ?? 0

    function setVolume(newVolume) {
        if (sink?.ready && sink?.audio) {
            sink.audio.muted = false;
            sink.audio.volume = Math.max(0, Math.min(1, newVolume));
        }
    }

    function incrementVolume(amount) {
        setVolume(volume + (amount || 0.05));
    }

    function decrementVolume(amount) {
        setVolume(volume - (amount || 0.05));
    }

    function toggleMute() {
        if (sink?.ready && sink?.audio) {
            sink.audio.muted = !sink.audio.muted;
        }
    }

    function setSourceVolume(newVolume) {
        if (source?.ready && source?.audio) {
            source.audio.muted = false;
            source.audio.volume = Math.max(0, Math.min(1, newVolume));
        }
    }

    function toggleSourceMute() {
        if (source?.ready && source?.audio) {
            source.audio.muted = !source.audio.muted;
        }
    }

    PwObjectTracker {
        objects: [sink, source].filter(node => node !== null)
    }
} 