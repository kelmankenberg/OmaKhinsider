import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "." as Local
import "Model.js" as Model

BarWidget {
  id: root

  readonly property string pluginId: "kelmankenberg.omakhinsider"
  readonly property bool playerView: root.setting("view", "library") === "player"
  readonly property var panel: panelLoader.item
  readonly property var player: root.panel ? root.panel.player : null
  readonly property var peers: root.bar && typeof root.bar.moduleWidgets === "function"
    ? root.bar.moduleWidgets(root.pluginId) : []
  readonly property var playerSource: root.playerView ? Model.playbackWidget(root.peers) : null
  readonly property var playerStrip: stripLoader.item
  readonly property bool opened: root.playerView
    ? !!root.playerStrip && (root.playerStrip.popupOpen || root.playerSource.opened)
    : !!root.panel && root.panel.opened
  property bool hostReady: false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  moduleName: pluginId
  visible: !root.playerView || stripLoader.active
  implicitWidth: root.playerView ? (root.playerStrip ? root.playerStrip.implicitWidth : 0) : button.implicitWidth
  implicitHeight: root.playerView ? (root.playerStrip ? root.playerStrip.implicitHeight : 0) : button.implicitHeight

  Component.onCompleted: Qt.callLater(function() { root.hostReady = true })

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
    target.manifest = root.manifest
    target.shell = root.bar ? root.bar.shell : null
  }

  function togglePanel() {
    if (root.playerView) {
      if (root.playerSource) root.playerSource.togglePanel()
    } else if (root.panel) root.panel.toggle()
  }

  function open() {
    if (root.playerView) {
      if (root.playerSource) root.playerSource.open()
    } else if (root.panel) root.panel.open()
  }

  function close() {
    if (root.playerView) {
      if (root.playerStrip && root.playerStrip.popupOpen) root.playerStrip.close()
      else if (root.playerSource) root.playerSource.close()
    } else if (root.panel) root.panel.close()
  }

  function closeForPopoutSwitch() {
    if (root.playerView) {
      if (root.playerStrip) root.playerStrip.close()
    } else if (root.panel) root.panel.closeForPopoutSwitch()
  }

  Loader {
    active: root.hostReady && !root.playerView
    sourceComponent: IpcHandler {
      target: root.pluginId
      function checkBrowserConnection(): string {
        if (!root.panel) return "plugin_unavailable"
        return root.panel.checkBrowserConnection()
      }
      function stageAlbumFromBrowser(url: string): string {
        if (!root.panel) return "plugin_unavailable"
        return root.panel.stageAlbumFromBrowser(url)
      }
      function beginAlbumInspection(url: string): string {
        if (!root.panel) return "plugin_unavailable"
        return root.panel.beginAlbumInspection(url)
      }
      function failAlbumInspection(url: string, error: string): string {
        if (!root.panel) return "plugin_unavailable"
        return root.panel.failAlbumInspection(url, error)
      }
      function importAlbumFromBrowser(url: string, path: string): string {
        if (!root.panel) return "plugin_unavailable"
        return root.panel.importAlbumFromBrowser(url, path)
      }
    }
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: root.hostReady && !root.playerView
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Loader {
    id: stripLoader
    anchors.fill: parent
    active: root.hostReady && root.playerView && root.setting("playerEnabled", true) !== false &&
      root.playerSource !== null
    sourceComponent: Local.BarPlayer {
      bar: root.bar
      host: root.playerSource.panel
      player: root.playerSource.player
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    visible: !root.playerView
    text: "KH"
    tooltipText: "OmaKhinsider"
    slotSize: Style.bar.iconSlot
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
    }
  }
}
