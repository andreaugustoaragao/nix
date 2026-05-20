// Inline volume slider for the DankBar.
//
// Drags the default PipeWire sink's volume directly. Scroll wheel nudges
// the value, and clicking the speaker icon (which lives outside the
// slider's internal MouseArea, so it bubbles up to pillClickAction)
// toggles mute. The two-way binding pattern with `Binding on value`
// gated by `when: !slider.isDragging` mirrors DMS's own VolumeOSD.qml —
// without it, the PipeWire-→UI mirror would snap back over the user's
// drag mid-gesture.
//
// The vertical pill variant falls back to a static speaker icon: a
// horizontal slider rotated into a portrait bar adds more complexity
// (rotation, handle dragging in screen-vs-content axes) than it's
// worth for a niche layout. Portrait bars can keep using the
// built-in controlCenterButton's volume affordance.

import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

PluginComponent {
    id: root

    // Width of the bar pill, in logical pixels. Tunable via plugin_settings.json
    // (`sliderWidth: 180` etc.) if the default ever conflicts with a tight bar.
    readonly property int sliderWidth: {
        const v = pluginData && pluginData.sliderWidth;
        return (typeof v === "number" && v > 40) ? v : 160;
    }

    // Live percent for the binding mirror. Guarded with ?? 0 so a transient
    // null sink (e.g., during default-sink change) doesn't render NaN.
    readonly property int displayPercent: Math.round((AudioService.sink?.audio?.volume ?? 0) * 100)

    readonly property string volumeIcon: {
        if (!AudioService.sink?.audio) return "volume_mute";
        if (AudioService.sink.audio.muted) return "volume_off";
        const p = root.displayPercent;
        if (p <= 0) return "volume_mute";
        if (p < 50) return "volume_down";
        return "volume_up";
    }

    // Speaker-icon click toggles mute. DankSlider's internal MouseArea only
    // covers the track + handle, not the leftIcon zone, so clicks on the
    // icon bubble up to BasePill which fires pillClickAction.
    pillClickAction: () => {
        if (AudioService.sink?.audio)
            AudioService.sink.audio.muted = !AudioService.sink.audio.muted;
    }

    horizontalBarPill: Component {
        Item {
            id: pill
            implicitWidth: root.sliderWidth
            // BasePill stretches to barThickness — we just need a sane fallback.
            implicitHeight: root.barThickness
            anchors.verticalCenter: parent.verticalCenter

            DankSlider {
                id: slider
                anchors.fill: parent
                minimum: 0
                maximum: AudioService.sinkMaxVolume
                step: 1
                unit: "%"
                // Bar pill is tight on vertical space; suppress the floating
                // tooltip that the OSD slider uses. The speaker icon already
                // tells you "this is volume" and the fill width shows level.
                showValue: false
                wheelEnabled: true
                leftIcon: root.volumeIcon
                enabled: !!AudioService.sink?.audio
                thumbOutlineColor: Theme.surfaceContainer

                // Push drag/wheel changes back into PipeWire. Un-mute on any
                // explicit movement so the slider never silently no-ops.
                onSliderValueChanged: newValue => {
                    if (!AudioService.sink?.audio)
                        return;
                    AudioService.sink.audio.muted = false;
                    AudioService.sink.audio.volume = newValue / 100;
                }

                // PipeWire-→UI mirror. `isDragging` is DankSlider's own
                // press-and-hold flag (see Widgets/DankSlider.qml); gating the
                // binding with `when: !isDragging` prevents the live volume
                // value from yanking the handle back during a drag.
                Binding on value {
                    value: root.displayPercent
                    when: !slider.isDragging
                }
            }
        }
    }

    // Portrait/vertical bars: a slider rotated 90° drags awkwardly (handle
    // travels along screen-Y but the underlying coordinate is content-X).
    // Show just the speaker icon and rely on pillClickAction for mute.
    verticalBarPill: Component {
        Item {
            implicitWidth: root.barThickness
            implicitHeight: root.barThickness
            anchors.horizontalCenter: parent.horizontalCenter

            DankIcon {
                anchors.centerIn: parent
                name: root.volumeIcon
                size: root.iconSizeLarge
                color: Theme.surfaceText
            }
        }
    }
}
