import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Item {
  id: root
  required property var player
  required property var host
  property QtObject bar: null
  property bool popupOpen: false
  implicitWidth: buttons.implicitWidth
  implicitHeight: buttons.implicitHeight
  onPlayerChanged: root.popupOpen = false

  function close() { root.popupOpen = false }

  Grid {
    id: buttons
    anchors.centerIn: parent
    columns: root.bar && root.bar.vertical ? 1 : 5
    spacing: Style.space(2)
    LayoutMirroring.enabled: Commons.I18n.rightToLeft
    LayoutMirroring.childrenInherit: true

    BarIconButton {
      objectName: "barPlayerPrevious"
      bar: root.bar
      slotSize: Style.space(24)
      text: Commons.I18n.rightToLeft ? "\uf051" : "\uf048"
      tooltipText: root.host.translations.t("player.previous")
      interactive: root.player.canPrevious
      dimmed: !interactive
      onPressed: function(button) { if (button === Qt.LeftButton && interactive) root.player.previous() }
    }
    BarIconButton {
      objectName: "barPlayerPlayPause"
      bar: root.bar
      slotSize: Style.space(24)
      text: root.player.playing ? "\uf04c" : "\uf04b"
      tooltipText: root.host.translations.t(root.player.playing ? "player.pause" : "player.play")
      onPressed: function(button) { if (button === Qt.LeftButton) root.player.toggle() }
    }
    BarIconButton {
      objectName: "barPlayerNext"
      bar: root.bar
      slotSize: Style.space(24)
      text: Commons.I18n.rightToLeft ? "\uf048" : "\uf051"
      tooltipText: root.host.translations.t("player.next")
      interactive: root.player.canNext
      dimmed: !interactive
      onPressed: function(button) { if (button === Qt.LeftButton && interactive) root.player.next(false) }
    }
    WidgetButton {
      id: titleButton
      objectName: "barPlayerTitle"
      bar: root.bar
      visible: !root.bar || !root.bar.vertical
      fixedWidth: Math.min(Style.space(140), title.implicitWidth + Style.space(12))
      hasVisualContent: true
      labelVisible: false
      tooltipText: root.host.translations.t("bar_player.details")
      onPressed: function(button) {
        if (button === Qt.LeftButton || button === Qt.RightButton) root.popupOpen = !root.popupOpen
      }
      Text {
        id: title
        objectName: "barPlayerTrackTitle"
        anchors.fill: parent
        anchors.margins: Style.space(4)
        textFormat: Text.PlainText
        text: root.player.currentTrack ? root.player.currentTrack.title : ""
        font.family: titleButton.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: titleButton.foreground
        elide: Text.ElideRight
        verticalAlignment: Text.AlignVCenter
      }
    }
    BarIconButton {
      objectName: "barPlayerVolume"
      bar: root.bar
      slotSize: Style.space(24)
      text: root.player.muted ? "\uf026" : "\uf028"
      tooltipText: root.host.translations.t("bar_player.volume_seek")
      active: root.popupOpen
      onPressed: function(button) {
        if (button === Qt.LeftButton || button === Qt.RightButton) root.popupOpen = !root.popupOpen
      }
      onWheelMoved: function(delta) {
        root.player.volume = Math.max(0, Math.min(1, root.player.volume + (delta > 0 ? 0.05 : -0.05)))
      }
    }
  }

  PopupCard {
    id: popup
    objectName: "barPlayerPopup"
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(contents.implicitHeight)

    ColumnLayout {
      id: contents
      objectName: "barPlayerPopupContents"
      anchors.fill: parent
      spacing: Style.space(10)
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: root.player.currentTrack ? root.player.currentTrack.title : ""
        color: root.host.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: root.player.playlistName
        color: root.host.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
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
          objectName: "barPlayerSeek"
          Layout.fillWidth: true
          bar: root.bar
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
        Button {
          objectName: "barPlayerMute"
          text: root.host.translations.t(root.player.muted ? "player.unmute" : "player.mute")
          active: root.player.muted
          focusable: true
          onClicked: root.player.muted = !root.player.muted
        }
        PanelSlider {
          objectName: "barPlayerVolumeSlider"
          Layout.fillWidth: true
          bar: root.bar
          value: root.player.volume
          onMoved: function(value) { root.player.volume = value }
        }
        Text {
          text: root.host.translations.t("bar_player.volume").arg(Commons.I18n.formatNumber(Math.round(root.player.volume * 100)))
          color: root.host.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
      Flickable {
        Layout.fillWidth: true
        visible: root.player.errorKey !== ""
        Layout.preferredHeight: Math.min(Style.space(70), errorText.implicitHeight)
        contentWidth: width
        contentHeight: errorText.implicitHeight
        clip: true
        Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
        Text {
          id: errorText
          width: parent.width
          textFormat: Text.PlainText
          text: root.host.translations.t("bar_player.playback_error") +
            (root.player.errorDetail ? "\n" + root.player.errorDetail : "")
          color: "#ff7777"
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }
      }
      RowLayout {
        Button {
          objectName: "barPlayerStop"
          text: root.host.translations.t("player.stop")
          focusable: true
          onClicked: root.player.stop()
        }
        Item { Layout.fillWidth: true }
        Button {
          objectName: "barPlayerShowAlbum"
          text: root.host.translations.t("player.show_album")
          focusable: true
          onClicked: {
            root.close()
            root.host.revealPlayingAlbum()
            root.host.open()
          }
        }
      }
    }
  }
}
