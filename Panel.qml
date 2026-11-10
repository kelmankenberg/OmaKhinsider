import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root

  readonly property string pluginId: "kelmankenberg.omakhinsider"
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
  readonly property string statePath: configHome + "/omakhinsider.json"

  moduleName: pluginId
  ipcTarget: pluginId
  manageIpc: false

  property var manifest: null
  property var shell: null
  property var anchorItem: null
  property var hostWidget: null
  property var state: Model.emptyState()
  property var previousState: null
  property bool stateReady: false
  property bool stateSaving: false
  property string stateError: ""
  property string noticeKey: ""
  property string browserStderr: ""
  property string activeTab: "albums"
  property string selectedPlaylistId: ""
  property string playlistDraft: ""
  property bool confirmDelete: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color muted: Color.muted
  readonly property color background: Color.popups.background
  readonly property color border: Color.popups.border

  function open() {
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened && keyboardPanel.loadedContent)
        keyboardPanel.loadedContent.forceActiveFocus()
    })
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
    else
      root.close()
  }

  function openKhinsider() {
    if (browserProc.running) return
    root.noticeKey = ""
    browserProc.command = ["xdg-open", "https://downloads.khinsider.com/"]
    browserProc.running = true
  }

  function loadState(raw) {
    var parsed = Model.parseState(raw)
    if (!parsed.ok) {
      root.stateError = parsed.error
      root.stateReady = false
      return
    }
    root.state = parsed.state
    root.stateReady = true
    root.stateError = ""
  }

  function initializeState() {
    root.state = Model.emptyState()
    root.stateReady = true
    root.writeState(root.state)
  }

  function writeState(next) {
    if (!root.stateReady || root.stateSaving) return false
    root.previousState = root.state
    root.state = next
    root.stateSaving = true
    root.noticeKey = ""
    stateFile.setText(JSON.stringify(next, null, 2) + "\n")
    return true
  }

  function addAlbum(input) {
    var result = Model.addAlbum(root.state, input)
    if (!result.ok) {
      root.noticeKey = result.error
      return false
    }
    if (root.writeState(result.state)) {
      albumField.text = ""
      return true
    }
    return false
  }

  function removeAlbum(id) {
    root.writeState(Model.removeAlbum(root.state, id))
  }

  function moveAlbum(id, offset) {
    root.writeState(Model.moveAlbum(root.state, id, offset))
  }

  function submitPlaylist() {
    var renaming = root.selectedPlaylistId !== ""
    var result = root.selectedPlaylistId
      ? Model.renamePlaylist(root.state, root.selectedPlaylistId, root.playlistDraft)
      : Model.createPlaylist(root.state, root.playlistDraft)
    if (!result.ok) {
      root.noticeKey = result.error
      return
    }
    if (root.writeState(result.state)) {
      if (!root.selectedPlaylistId)
        root.selectedPlaylistId = result.state.playlists[result.state.playlists.length - 1].id
      root.playlistDraft = result.state.playlists.find(function(playlist) {
        return playlist.id === root.selectedPlaylistId
      }).name
      root.noticeKey = renaming ? "playlist_saved" : "playlist_created"
    }
  }

  function selectPlaylist(id) {
    var playlist = root.state.playlists.find(function(item) { return item.id === id })
    if (!playlist) return
    root.selectedPlaylistId = id
    root.playlistDraft = playlist.name
    root.confirmDelete = false
    root.noticeKey = ""
  }

  function deleteSelectedPlaylist() {
    if (!root.selectedPlaylistId || root.confirmDelete) return
    root.confirmDelete = true
  }

  function confirmDeleteSelectedPlaylist() {
    if (!root.selectedPlaylistId || !root.confirmDelete) return
    root.writeState(Model.removePlaylist(root.state, root.selectedPlaylistId))
    root.selectedPlaylistId = ""
    root.playlistDraft = ""
    root.confirmDelete = false
  }

  function statusLabel(status) {
    return strings.t("album.status." + status, status)
  }

  property FileView stateFile: FileView {
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: function(error) {
      if (error === FileViewError.FileNotFound) root.initializeState()
      else {
        root.stateError = "state_read_failed"
        root.stateReady = false
        console.warn("OmaKhinsider could not read its state file:", root.statePath, error)
      }
    }
    onSaved: {
      root.stateSaving = false
      root.previousState = null
      root.stateError = ""
      if (root.noticeKey === "") root.noticeKey = "state.saved"
    }
    onSaveFailed: function(error) {
      root.state = root.previousState || Model.emptyState()
      root.previousState = null
      root.stateSaving = false
      root.noticeKey = "state_save_failed"
      console.warn("OmaKhinsider could not save its state file:", root.statePath, error)
    }
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  Process {
    id: browserProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.browserStderr = String(text || "").trim()
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.noticeKey = "browser_opened"
      } else {
        root.noticeKey = "browser_open_failed"
        console.warn("Could not open KHInsider in the default browser:", exitCode, root.browserStderr)
      }
    }
  }

  KeyboardPanel {
    id: keyboardPanel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    centerOnBar: root.anchorItem === null
    focusTarget: loadedContent
    contentWidth: fittedContentWidth(Style.space(720))
    contentHeight: fittedContentHeight(loadedContentHeight, Style.space(680))

    content: PanelKeyCatcher {
      id: keyCatcher
      implicitWidth: mainCard.implicitWidth
      implicitHeight: Math.min(mainCard.implicitHeight, Style.space(680))
      blocked: albumField.activeFocus || playlistField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        root.activeTab = root.activeTab === "albums" ? "playlists" : "albums"
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainCard.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Rectangle {
          id: mainCard
          width: parent.width
          implicitHeight: contents.implicitHeight + Style.space(36)
          color: root.background
          border.color: root.border
          border.width: Math.max(1, Style.space(1))
          radius: Style.cornerRadius

          ColumnLayout {
            id: contents
            anchors.fill: parent
            anchors.margins: Style.space(18)
            spacing: Style.space(12)

            RowLayout {
              Layout.fillWidth: true

              ColumnLayout {
                spacing: Style.space(2)
                Text {
                  text: strings.t("app.title")
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
                Text {
                  text: strings.t("app.subtitle")
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Item { Layout.fillWidth: true }

              Button {
                text: strings.t("browser.open")
                tooltipText: strings.t("browser.open_tooltip")
                focusable: true
                enabled: !browserProc.running
                onClicked: root.openKhinsider()
              }

              Button {
                text: strings.t("common.close")
                focusable: true
                onClicked: root.dismiss()
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)
              Button {
                text: strings.t("tabs.albums")
                active: root.activeTab === "albums"
                focusable: true
                onClicked: root.activeTab = "albums"
              }
              Button {
                text: strings.t("tabs.playlists")
                active: root.activeTab === "playlists"
                focusable: true
                onClicked: root.activeTab = "playlists"
              }
              Item { Layout.fillWidth: true }
              Text {
                text: root.stateSaving
                  ? strings.t("state.saving")
                  : root.stateReady ? "" : strings.t("state.loading")
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            ColumnLayout {
              visible: root.activeTab === "albums"
              Layout.fillWidth: true
              spacing: Style.space(10)

              Text {
                text: strings.t("album.heading")
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                TextField {
                  id: albumField
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                  enabled: root.stateReady && !root.stateSaving
                  placeholderText: strings.t("album.url_placeholder")
                  onAccepted: root.addAlbum(text)
                }
                Button {
                  text: strings.t("album.add")
                  enabled: root.stateReady && !root.stateSaving
                  focusable: true
                  onClicked: root.addAlbum(albumField.text)
                }
              }

              Text {
                text: strings.t("album.help")
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                Layout.fillWidth: true
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Style.space(280)
                color: Qt.darker(root.background, 1.05)
                radius: Style.cornerRadius

                ListView {
                  id: albumList
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  clip: true
                  spacing: Style.space(6)
                  model: root.state.albumQueue
                  delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: albumList.width
                    height: Style.space(68)
                    color: Color.menu.selectedBackground
                    radius: Style.cornerRadius

                    RowLayout {
                      anchors.fill: parent
                      anchors.margins: Style.space(8)
                      spacing: Style.space(6)

                      ColumnLayout {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        spacing: Style.space(3)
                        Text {
                          Layout.fillWidth: true
                          text: modelData.title || modelData.url
                          color: root.foreground
                          font.family: Style.font.family
                          font.pixelSize: Style.font.body
                          elide: Text.ElideMiddle
                          textFormat: Text.PlainText
                        }
                        Text {
                          text: root.statusLabel(modelData.status)
                          color: root.muted
                          font.family: Style.font.family
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      Button {
                        text: strings.t("common.up")
                        focusable: true
                        enabled: root.stateReady && !root.stateSaving && index > 0
                        onClicked: root.moveAlbum(modelData.id, -1)
                      }
                      Button {
                        text: strings.t("common.down")
                        focusable: true
                        enabled: root.stateReady && !root.stateSaving && index < root.state.albumQueue.length - 1
                        onClicked: root.moveAlbum(modelData.id, 1)
                      }
                      Button {
                        text: strings.t("common.remove")
                        focusable: true
                        enabled: root.stateReady && !root.stateSaving
                        onClicked: root.removeAlbum(modelData.id)
                      }
                    }
                  }
                }

                Text {
                  anchors.centerIn: parent
                  visible: root.stateReady && root.state.albumQueue.length === 0
                  text: strings.t("album.empty")
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
              }
            }

            ColumnLayout {
              visible: root.activeTab === "playlists"
              Layout.fillWidth: true
              spacing: Style.space(10)

              Text {
                text: strings.t("playlist.heading")
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)
                TextField {
                  id: playlistField
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                  enabled: root.stateReady && !root.stateSaving
                  placeholderText: strings.t("playlist.name_placeholder")
                  text: root.playlistDraft
                  onTextEdited: root.playlistDraft = text
                  onAccepted: root.submitPlaylist()
                }
                Button {
                  text: root.selectedPlaylistId
                    ? strings.t("playlist.rename")
                    : strings.t("playlist.create")
                  enabled: root.stateReady && !root.stateSaving
                  focusable: true
                  onClicked: root.submitPlaylist()
                }
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(12)
                Rectangle {
                  Layout.preferredWidth: Style.space(270)
                  Layout.preferredHeight: Style.space(300)
                  color: Qt.darker(root.background, 1.05)
                  radius: Style.cornerRadius

                  ListView {
                    id: playlistList
                    anchors.fill: parent
                    anchors.margins: Style.space(8)
                    clip: true
                    spacing: Style.space(4)
                    model: root.state.playlists
                    delegate: Button {
                      required property var modelData
                      width: playlistList.width
                      text: modelData.name
                      leftAlign: true
                      selected: modelData.id === root.selectedPlaylistId
                      focusable: true
                      onClicked: root.selectPlaylist(modelData.id)
                    }
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: root.stateReady && root.state.playlists.length === 0
                    text: strings.t("playlist.empty")
                    color: root.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(300)
                  color: Qt.darker(root.background, 1.05)
                  radius: Style.cornerRadius

                  ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(14)
                    spacing: Style.space(10)

                    Text {
                      text: root.selectedPlaylistId
                        ? strings.t("playlist.selected")
                        : strings.t("playlist.none_selected")
                      color: root.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Text {
                      Layout.fillWidth: true
                      Layout.fillHeight: true
                      text: root.confirmDelete
                        ? strings.t("playlist.delete_confirm")
                        : root.selectedPlaylistId
                          ? strings.t("playlist.tracks_later")
                          : strings.t("playlist.select_help")
                      color: root.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.Wrap
                    }

                    Button {
                      text: root.confirmDelete
                        ? strings.t("common.cancel")
                        : strings.t("playlist.delete")
                      visible: root.selectedPlaylistId !== ""
                      enabled: root.stateReady && !root.stateSaving
                      focusable: true
                      onClicked: {
                        if (root.confirmDelete) root.confirmDelete = false
                        else root.deleteSelectedPlaylist()
                      }
                    }

                    Button {
                      text: strings.t("playlist.confirm_delete")
                      visible: root.confirmDelete
                      enabled: root.stateReady && !root.stateSaving
                      focusable: true
                      onClicked: root.confirmDeleteSelectedPlaylist()
                    }
                  }
                }
              }
            }

            Text {
              visible: root.stateError !== "" || root.noticeKey !== ""
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.stateError !== ""
                ? strings.t("errors." + root.stateError)
                : strings.t("messages." + root.noticeKey)
              color: root.stateError !== "" || root.noticeKey.indexOf("failed") >= 0 ||
                root.noticeKey.indexOf("invalid") >= 0 || root.noticeKey.indexOf("duplicate") >= 0
                ? "#ff7777"
                : root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Text {
              Layout.fillWidth: true
              text: strings.t("app.scope_note")
              color: root.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }
        }
      }
    }
  }
}
