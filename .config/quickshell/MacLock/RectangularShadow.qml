import QtQuick
import QtQuick.Effects

Item {
    id: root
    property real radius: 0
    property real blur: 10
    property real spread: 0
    property color color: Qt.rgba(0, 0, 0, 0.35)
    property vector2d offset: Qt.vector2d(0, 0)

    Rectangle {
        id: box
        x: -root.spread
        y: -root.spread
        width: Math.max(1, root.width + root.spread * 2)
        height: Math.max(1, root.height + root.spread * 2)
        radius: root.radius + root.spread
        color: "black"
        visible: false
        layer.enabled: true
    }

    MultiEffect {
        anchors.fill: box
        source: box
        shadowEnabled: true
        shadowColor: root.color
        shadowBlur: Math.max(0, Math.min(1.0, root.blur / 64.0))
        shadowHorizontalOffset: root.offset.x
        shadowVerticalOffset: root.offset.y
        blurMax: 64
    }
}
