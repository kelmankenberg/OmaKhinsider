import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Rectangle {
  id: root
  required property var host
  required property var player
  property bool volumeOpen: false
  color: root.host.background
  implicitHeight: contents.implicitHeight + Style.space(16)

  Rectangle {
    anchors.top: parent.top
    width: parent.width
    height: 1
    color: root.host.border
  }
  ColumnLayout {
    id: contents
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: Style.space(8)
    spacing: Style.space(4)

    RowLayout {
      Layout.fillWidth: true
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: root.player.currentTrack
          ? root.player.buffering
            ? root.host.translations.t("player.buffering").arg(root.player.currentTrack.title)
            : root.host.translations.t("player.now_playing").arg(root.player.playlistName).arg(root.player.currentTrack.title)
          : root.host.translations.t("player.select")
        color: root.host.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Button {
        text: root.host.translations.t("player.show_album")
        visible: !!root.player.currentTrack
        focusable: true
        onClicked: root.host.revealPlayingAlbum()
      }
    }
    RowLayout {
      Layout.fillWidth: true
      Text {
        text: root.host.playbackTime(root.player.position)
        color: root.host.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
      PanelSlider {
        Layout.fillWidth: true
        bar: root.host.bar
        enabled: root.player.seekable
        value: root.player.position
        maximum: Math.max(1, root.player.duration)
        step: 5000
        onReleased: function(value) { root.player.seek(value) }
      }
      Text {
        text: root.host.playbackTime(root.player.duration)
        color: root.host.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(4)
      Button {
        text: root.host.translations.t("player.previous")
        enabled: root.player.canPrevious
        focusable: true
        onClicked: root.player.previous()
      }
      Button {
        objectName: "transportPlayPause"
        text: root.host.translations.t(root.player.playing ? "player.pause" : "player.play")
        enabled: !!root.player.currentTrack
        focusable: true
        onClicked: root.player.toggle()
      }
      Button {
        text: root.host.translations.t("player.next")
        enabled: root.player.canNext
        focusable: true
        onClicked: root.player.next(false)
      }
      Button {
        text: root.host.translations.t("player.stop")
        enabled: !!root.player.currentTrack
        focusable: true
        onClicked: root.player.stop()
      }
      Item { Layout.fillWidth: true }
      Button {
        text: root.host.translations.t("player.shuffle")
        active: root.player.shuffle
        focusable: true
        onClicked: root.player.shuffle = !root.player.shuffle
      }
      Button {
        text: root.host.translations.t("player.repeat_" + root.player.repeatMode)
        active: root.player.repeatMode !== "off"
        focusable: true
        onClicked: root.player.repeatMode = root.player.repeatMode === "off"
          ? "all" : root.player.repeatMode === "all" ? "one" : "off"
      }
      Button {
        text: root.player.muted ? root.host.translations.t("player.muted")
          : root.host.translations.t("player.volume")
            .arg(Commons.I18n.formatNumber(Math.round(root.player.volume * 100)))
        active: root.volumeOpen
        tooltipText: root.host.translations.t("player.volume_controls")
        focusable: true
        onClicked: root.volumeOpen = !root.volumeOpen
      }
    }
    RowLayout {
      Layout.fillWidth: true
      visible: root.volumeOpen
      Button {
        text: root.host.translations.t(root.player.muted ? "player.unmute" : "player.mute")
        active: root.player.muted
        focusable: true
        onClicked: root.player.muted = !root.player.muted
      }
      PanelSlider {
        Layout.fillWidth: true
        bar: root.host.bar
        value: root.player.volume
        onMoved: function(value) { root.player.volume = value }
      }
    }
    Flickable {
      Layout.fillWidth: true
      visible: root.player.errorKey !== ""
      Layout.preferredHeight: Math.min(Style.space(70), playbackError.implicitHeight)
      contentWidth: width
      contentHeight: playbackError.implicitHeight
      clip: true
      Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
      Text {
        id: playbackError
        width: parent.width
        textFormat: Text.PlainText
        text: root.player.errorKey === "failed" || root.player.errorKey === "online_failed"
          ? root.host.translations.t("player." + root.player.errorKey).arg(root.player.errorDetail)
          : root.player.errorKey ? root.host.translations.t("player." + root.player.errorKey) : ""
        color: "#ff7777"
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
      }
    }
  }
}
