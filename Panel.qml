import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "." as Local
import "Model.js" as Model

Panel {
  id: root

  readonly property string pluginId: "kelmankenberg.omakhinsider"
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
  readonly property string statePath: configHome + "/omakhinsider.json"
  readonly property string workerPath: decodeURIComponent(String(Qt.resolvedUrl("backend/worker.py")).replace(/^(file|qs):\/\//, ""))
  readonly property string pluginDirectory: workerPath.slice(0, -"/backend/worker.py".length)
  readonly property string downloadDirectory: root.state.settings.downloadDirectory ||
    (Quickshell.env("HOME") + "/Music/OmaKhinsider")
  readonly property bool workerBusy: root.stateSaving || importProc.running || settingsProc.running || folderProc.running ||
    barPlayerProc.running || root.barPlayerRequestPending ||
    libraryProc.running || root.libraryRequestPending || root.activeDownloadId !== ""
  readonly property bool libraryBusy: root.workerBusy || root.batchRunning
  readonly property var selectedPlaylist: root.state.playlists.find(function(item) { return item.id === root.selectedPlaylistId })
  readonly property string librarySection: root.customPlaylists ? "custom" : root.playlistKind
  readonly property var visiblePlaylists: Model.libraryAlbums(root.state.playlists, root.librarySection, root.librarySearch)

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
  property string pendingBrowserUrl: ""
  property string activeTab: "albums"
  property string browserSetupReturnTab: "albums"
  property string selectedPlaylistId: ""
  property string playlistDraft: ""
  property string playlistKind: "downloaded"
  property bool customPlaylists: false
  property string librarySearch: ""
  property string trackSearch: ""
  property bool playlistEditorOpen: false
  property bool libraryMenuOpen: false
  property bool showAlbumDetails: false
  property string queueMenuId: ""
  property bool queueHelpOpen: false
  property string noticeContext: "global"
  property bool confirmDelete: false
  property string downloadDirectoryDraft: ""
  property string formatDraft: "mp3"
  property bool barPlayerEnabledDraft: false
  property string barPlayerSideDraft: "right"
  property bool barPlayerRequestPending: false
  readonly property var player: audio
  property string operationError: ""
  property string activeDownloadId: ""
  property string downloadRequest: ""
  property int downloadedTracks: 0
  property int downloadTotal: 0
  property int downloadPercent: -1
  property bool cancelRequested: false
  property bool batchRunning: false
  property var batchAlbumIds: []
  property int batchTotal: 0
  property int batchCompleted: 0
  property int batchFailed: 0
  property bool downloadInBatch: false
  property var pendingChanges: []
  property string selectedAlbumId: ""
  property string browserNoticeKey: "browser_opened"
  property int panelHeightDraft: 0
  property bool pendingLibraryScan: false
  property var importPreviews: []
  property var libraryWarnings: []
  property var libraryImportErrors: []
  property bool libraryRequestPending: false
  property var pendingLocalImports: []
  property bool pendingBulkImport: false
  property int importTotal: 0
  property int importProcessed: 0
  property int importCompleted: 0
  property int importFailed: 0
  property string importingDirectory: ""
  property string scannedDirectory: ""
  readonly property var importPreview: root.importPreviews.length ? root.importPreviews[0] : null
  readonly property real requestedPanelHeight: root.panelHeightDraft || root.state.settings.panelHeight || 0
  readonly property real maximumPanelHeight: keyboardPanel.screenH > 0
    ? Math.max(1, Math.min(keyboardPanel.screenH, keyboardPanel.availableCardHeight))
    : Style.space(680)

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color muted: Qt.tint(root.background,
    Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.75))
  readonly property color background: Commons.Color.popups.background
  readonly property color border: Commons.Color.popups.border
  property alias translations: strings
  readonly property bool noticeIsError: !!root.operationError ||
    /failed|invalid|duplicate|errors|unavailable|not_found|full|limit|needs_|none_ready/.test(root.noticeKey)

  onNoticeKeyChanged: {
    if (!root.noticeKey) return
    root.noticeContext = root.noticeKey === "state_save_failed" ? "global"
      : /^(library|playlist|online_)/.test(root.noticeKey) ? "library"
      : /^(settings|folder_|bar_player_|support_)/.test(root.noticeKey)
        ? folderProc.purpose === "relink" && root.noticeKey === "folder_chooser_failed" ? "library" : "settings"
      : /^(browser|album|inspection|batch|download)/.test(root.noticeKey)
        ? root.activeTab === "playlists" || root.activeTab === "review" ? "library" : "albums"
      : "global"
  }

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

  function openKhinsider() {
    root.openBrowser("https://downloads.khinsider.com/", "browser_opened")
  }

  function openBrowser(url, notice) {
    if (browserProc.running) return
    root.noticeKey = ""
    root.browserNoticeKey = notice
    browserProc.command = ["xdg-open", url]
    browserProc.running = true
  }

  function inspectAlbum(url) {
    if (!Model.normalizeAlbumUrl(url)) return
    root.openBrowser(url, "browser_inspection_help")
  }

  function showBrowserSetup() {
    if (root.activeTab !== "browser-setup") root.browserSetupReturnTab = root.activeTab
    root.activeTab = "browser-setup"
  }

  function checkBrowserConnection() {
    return root.stateReady ? "connected" : "state_unavailable"
  }

  function enqueueChange(change) {
    root.pendingChanges = root.pendingChanges.concat([change])
    root.flushChanges()
  }

  function flushChanges() {
    if (!root.stateReady || root.stateSaving || !root.pendingChanges.length) return
    var changes = root.pendingChanges
    root.pendingChanges = []
    var next = root.state
    var notice = ""
    var errorKey = ""
    for (var i = 0; i < changes.length; i++) {
      var change = changes[i]
      if (change.locations !== undefined) {
        var located = Model.updatePlaylistLocations(next, change.locations)
        if (!located.ok) {
          errorKey = located.error
          console.warn("OmaKhinsider received invalid folder locations:", located.error)
          continue
        }
        next = located.state
      }
      var result = change.kind === "inspection"
        ? Model.applyInspection(next, change.album)
        : change.kind === "settings" || change.kind === "height"
          ? Model.updateSettings(next, change.kind === "height" ? { panelHeight: change.height } : change.settings)
          : change.kind === "complete"
            ? Model.completeAlbumDownload(next, change.id, change.downloaded)
            : change.kind === "local-import"
              ? Model.importLocalAlbumResults(next, change.albums)
              : change.kind === "relink"
                ? Model.relinkLocalAlbum(next, change.id, change.albums[0])
                : Model.updateAlbum(next, change.id, change.patch)
      if (!result.ok) {
        errorKey = result.error
        console.warn("OmaKhinsider could not apply worker update:", result.error)
        if (change.kind === "relink") root.operationError = strings.t("messages." + result.error)
        if (change.kind === "complete") {
          root.operationError = strings.t("messages." + result.error)
          var failed = Model.updateAlbum(next, change.id, { status: "failed", error: root.operationError })
          if (failed.ok) next = failed.state
          if (change.batch) root.batchFailed++
        }
        continue
      }
      next = result.state
      if (change.kind === "local-import" || change.kind === "relink") {
        root.reconcilePlaylistReferences(next, result.replacements)
        root.pendingLocalImports = result.accepted
        root.pendingBulkImport = change.bulk === true
        root.libraryImportErrors = root.libraryImportErrors.concat(result.errors.map(function(problem) {
          return { directory: problem.directory, message: strings.t("messages." + problem.error) }
        }))
        if (change.bulk) {
          root.importFailed = root.libraryImportErrors.length
          root.importProcessed = root.importTotal
        }
        if (root.libraryImportErrors.length)
          change.notice = change.bulk ? "library_import_all_errors" : "library_failed"
      }
      if (change.kind === "complete") {
        if (root.activeTab !== "playlists" || !root.selectedPlaylist) {
          root.playlistKind = "downloaded"
          root.selectedPlaylistId = result.playlistId
          root.playlistDraft = next.playlists.find(function(item) { return item.id === result.playlistId }).name
        }
        if (root.selectedAlbumId === change.id) root.selectedAlbumId = ""
        if (change.batch) root.batchCompleted++
      }
      if (change.notice) notice = change.notice
    }
    if (next !== root.state) root.writeState(next)
    else root.finishLocalImports()
    if (errorKey || notice) root.noticeKey = errorKey || notice
  }

  function beginAlbumInspection(input) {
    if (!root.stateReady) return "state_unavailable"
    if (root.libraryBusy) return "busy"
    var url = Model.normalizeAlbumUrl(input)
    if (!url) return "album_url_invalid"
    var album = root.state.albumQueue.find(function(item) { return item.url === url })
    if (!album) {
      var result = Model.addAlbum(root.state, url)
      if (!result.ok) return result.error
      if (!root.writeState(result.state)) return "busy"
      album = root.state.albumQueue[root.state.albumQueue.length - 1]
    }
    root.operationError = ""
    root.enqueueChange({ kind: "album", id: album.id, patch: { status: "inspecting", error: "" } })
    return "inspecting"
  }

  function failAlbumInspection(input, error) {
    var url = Model.normalizeAlbumUrl(input)
    var album = root.state.albumQueue.find(function(item) { return item.url === url })
    if (!album) return "album_url_invalid"
    root.enqueueChange({ kind: "album", id: album.id, patch: { status: "failed", error: String(error).slice(0, 1000) } })
    root.operationError = String(error).slice(0, 1000)
    root.noticeKey = "inspection_failed"
    return "inspection_failed"
  }

  function importAlbumFromBrowser(url, path) {
    if (!root.stateReady) return "state_unavailable"
    if (root.libraryBusy) return "busy"
    if (!Model.normalizeAlbumUrl(url)) return "album_url_invalid"
    root.operationError = ""
    importProc.response = null
    importProc.albumUrl = url
    importProc.command = ["python3", root.workerPath, "read-import", path]
    importProc.running = true
    root.activeTab = "albums"
    root.open()
    return "importing"
  }

  function showSettings() {
    root.downloadDirectoryDraft = root.downloadDirectory
    root.formatDraft = root.state.settings.format
    var barSettings = Model.barPlayerSettings(root.bar ? root.bar.layoutConfig : null)
    root.barPlayerEnabledDraft = barSettings.enabled
    root.barPlayerSideDraft = barSettings.side
    root.activeTab = "settings"
  }

  function applyBarPlayerSettings() {
    if (!root.stateReady || root.libraryBusy) return
    root.operationError = ""
    root.noticeKey = ""
    root.barPlayerRequestPending = true
    barPlayerProc.response = null
    barPlayerProc.running = true
    barPlayerProc.write(JSON.stringify({
      enabled: root.barPlayerEnabledDraft, side: root.barPlayerSideDraft
    }) + "\n")
  }

  function saveSettings() {
    if (!root.stateReady || root.libraryBusy) return
    root.operationError = ""
    settingsProc.response = null
    settingsProc.running = true
    settingsProc.write(JSON.stringify({ directory: root.downloadDirectoryDraft }) + "\n")
  }

  function browseDownloadDirectory() {
    if (!root.stateReady || root.libraryBusy) return
    root.operationError = ""
    root.noticeKey = ""
    folderProc.response = null
    folderProc.purpose = "download"
    var initial = root.downloadDirectoryDraft
    if (!Model.validLocalPath(initial) && !initial.startsWith("~/")) initial = root.downloadDirectory
    root.close()
    folderProc.running = true
    folderProc.write(JSON.stringify({
      directory: initial, title: strings.t("settings.choose_directory")
    }) + "\n")
  }

  function browseRelinkDirectory() {
    if (!root.stateReady || root.libraryBusy || !root.selectedPlaylist ||
        Model.playlistKind(root.selectedPlaylist) !== "downloaded" || !root.selectedPlaylist.downloadDirectory) return
    root.operationError = ""
    root.noticeKey = ""
    folderProc.response = null
    folderProc.purpose = "relink"
    folderProc.playlistId = root.selectedPlaylistId
    root.close()
    folderProc.running = true
    folderProc.write(JSON.stringify({
      directory: root.selectedPlaylist.downloadDirectory, title: strings.t("library.choose_replacement")
    }) + "\n")
  }

  function relinkDirectory(id, directory) {
    var playlist = root.state.playlists.find(function(item) { return item.id === id })
    if (!playlist) {
      root.noticeKey = "playlist_not_found"
      return
    }
    root.importTotal = 0
    root.libraryImportErrors = []
    libraryProc.action = "relink-folder"
    libraryProc.playlistId = id
    libraryProc.response = null
    libraryProc.command = ["python3", root.workerPath, libraryProc.action]
    root.libraryRequestPending = true
    libraryProc.running = true
    libraryProc.write(JSON.stringify({
      folder: directory, playlistId: id, format: playlist.downloadFormat, albumUrl: playlist.sourceAlbumUrl,
      playlists: root.localLibraryHints()
    }) + "\n")
    root.noticeKey = "library_relinking"
  }

  function reconcilePlaylistReferences(next, replacements) {
    replacements.forEach(function(replacement) {
      if (root.selectedPlaylistId === replacement.from) {
        root.selectedPlaylistId = replacement.to
        root.playlistDraft = next.playlists.find(function(item) { return item.id === replacement.to }).name
      }
      if (audio.playlistId === replacement.from) audio.playlistId = replacement.to
    })
  }

  function localLibraryHints() {
    return root.state.playlists.filter(function(item) {
      return Model.playlistKind(item) === "downloaded" && item.downloadDirectory
    })
  }

  function scanLibrary() {
    if (!root.stateReady || root.libraryBusy || root.pendingChanges.length) return
    root.pendingLibraryScan = false
    root.operationError = ""
    root.importPreviews = []
    root.libraryWarnings = []
    root.libraryImportErrors = []
    root.importTotal = 0
    root.scannedDirectory = root.downloadDirectory
    libraryProc.action = "scan-library"
    libraryProc.response = null
    libraryProc.command = ["python3", root.workerPath, libraryProc.action]
    root.libraryRequestPending = true
    libraryProc.running = true
    libraryProc.write(JSON.stringify({
      directory: root.scannedDirectory, playlists: root.localLibraryHints()
    }) + "\n")
    root.noticeKey = "library_scanning"
  }

  function scanLibraryWhenReady() {
    if (root.pendingLibraryScan) root.scanLibrary()
  }

  function importPreviewAlbum() {
    if (!root.importPreview || root.libraryBusy) return
    root.operationError = ""
    root.importTotal = 0
    root.libraryImportErrors = root.libraryImportErrors.filter(function(problem) {
      return problem.directory !== root.importPreview.directory
    })
    libraryProc.action = "import-folder"
    libraryProc.response = null
    libraryProc.command = ["python3", root.workerPath, libraryProc.action]
    root.libraryRequestPending = true
    libraryProc.running = true
    libraryProc.write(JSON.stringify({
      directory: root.scannedDirectory, folder: root.importPreview.directory,
      libraryId: root.importPreview.libraryId, playlists: root.localLibraryHints()
    }) + "\n")
  }

  function importAllPreviews() {
    if (!root.stateReady || root.libraryBusy || !root.importPreviews.length) return
    root.operationError = ""
    root.libraryImportErrors = []
    root.importTotal = root.importPreviews.length
    root.importProcessed = 0
    root.importCompleted = 0
    root.importFailed = 0
    root.importingDirectory = ""
    root.noticeKey = "library_importing_all"
    libraryProc.action = "import-folders"
    libraryProc.response = null
    libraryProc.command = ["python3", root.workerPath, libraryProc.action]
    root.libraryRequestPending = true
    libraryProc.running = true
    libraryProc.write(JSON.stringify({
      directory: root.scannedDirectory, playlists: root.localLibraryHints(),
      folders: root.importPreviews.map(function(album) {
        return { folder: album.directory, libraryId: album.libraryId }
      })
    }) + "\n")
  }

  function finishLocalImports() {
    if (!root.pendingLocalImports.length && !root.pendingBulkImport) return
    if (root.pendingBulkImport) root.importCompleted = root.pendingLocalImports.length
    root.importPreviews = root.importPreviews.filter(function(preview) {
      return !root.pendingLocalImports.some(function(album) {
        var sameFormat = album.relinked && (album.format === "mixed"
          ? preview.tracks.some(function(track) { return track.format !== preview.tracks[0].format })
          : preview.tracks.every(function(track) { return track.format === album.format }))
        return (album.libraryId === preview.libraryId || album.previousLibraryId === preview.libraryId || sameFormat) &&
          album.directory === preview.directory
      })
    })
    root.pendingLocalImports = []
    root.pendingBulkImport = false
    root.importingDirectory = ""
    if (root.activeTab === "review" && !root.importPreviews.length &&
        !root.libraryWarnings.length && !root.libraryImportErrors.length)
      root.activeTab = "playlists"
  }

  function startDownload(album, fromBatch) {
    if (!root.stateReady || (fromBatch ? root.workerBusy : root.libraryBusy)) return false
    if (!album.tracks || !album.tracks.length) {
      root.noticeKey = "browser_inspection_help"
      return false
    }
    var format = Model.albumDownloadFormat(album, root.state.settings.format)
    if (!format) {
      root.noticeKey = "batch_format_unavailable"
      root.operationError = strings.t("download.album_problem").arg(album.title || album.url)
      return false
    }
    if (!fromBatch) root.batchTotal = 0
    root.downloadInBatch = fromBatch === true
    root.operationError = ""
    root.activeDownloadId = album.id
    root.downloadedTracks = 0
    root.downloadTotal = album.tracks.length
    root.downloadPercent = -1
    root.cancelRequested = false
    root.downloadRequest = JSON.stringify({
      album: { url: album.url, title: album.title, tracks: album.tracks },
      directory: root.downloadDirectory, format: format
    })
    root.enqueueChange({ kind: "album", id: album.id, patch: { status: "downloading", error: "" } })
    downloadProc.response = null
    downloadProc.running = true
    downloadProc.write(root.downloadRequest + "\n")
    return true
  }

  function downloadAll() {
    if (!root.stateReady || root.libraryBusy) return
    var plan = Model.downloadPlan(root.state, true)
    if (!plan.ok) {
      root.noticeKey = plan.error
      var album = root.state.albumQueue.find(function(item) { return item.id === plan.albumId })
      root.operationError = album
        ? strings.t("download.album_problem").arg(album.title || album.url) : ""
      return
    }
    root.batchAlbumIds = plan.ids
    root.batchTotal = plan.ids.length
    root.batchCompleted = 0
    root.batchFailed = 0
    root.batchRunning = true
    root.operationError = ""
    root.advanceBatch()
  }

  function advanceBatch() {
    if (!root.batchRunning || !root.stateReady || root.workerBusy || root.pendingChanges.length) return
    if (!root.batchAlbumIds.length) {
      root.batchRunning = false
      root.noticeKey = root.batchFailed ? "batch_finished_with_errors" : "batch_finished"
      return
    }
    var id = root.batchAlbumIds[0]
    var album = root.state.albumQueue.find(function(item) { return item.id === id })
    if (!album) {
      root.batchRunning = false
      root.batchAlbumIds = []
      root.noticeKey = "album_not_found"
      console.warn("OmaKhinsider batch album is missing:", id)
      return
    }
    if (root.startDownload(album, true)) root.batchAlbumIds = root.batchAlbumIds.slice(1)
  }

  function cancelDownload() {
    var wasBatch = root.batchRunning
    root.batchRunning = false
    root.batchAlbumIds = []
    if (!downloadProc.running || root.cancelRequested) {
      if (wasBatch) root.noticeKey = "batch_canceled"
      return
    }
    root.cancelRequested = true
    downloadProc.signal(15)
  }

  function handleWorkerLine(process, line) {
    try {
      var message = JSON.parse(line)
      if (message.type === "progress" && process === downloadProc) {
        root.downloadedTracks = message.completed
        root.downloadTotal = message.total
        root.downloadPercent = message.percent
      } else if (message.type === "progress" && process === libraryProc &&
          libraryProc.action === "import-folders") {
        if (!Number.isInteger(message.completed) || !Number.isInteger(message.total) ||
            message.total !== root.importTotal || message.completed < 0 ||
            message.completed > message.total || !Model.validLocalPath(message.directory))
          throw new Error("Invalid import progress")
        root.importProcessed = message.completed
        root.importingDirectory = message.directory
      } else if (["result", "error", "canceled"].indexOf(message.type) >= 0) {
        process.response = message
      } else {
        throw new Error("Unknown worker message")
      }
    } catch (error) {
      console.warn("OmaKhinsider worker output is invalid:", error)
      process.response = { type: "error", message: strings.t("errors.worker_response_invalid") }
    }
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
    Qt.callLater(function() { root.writeState(root.state, true) })
  }

  function writeState(next, force) {
    if (!root.stateReady || root.stateSaving) return false
    // FileView does not emit saved when setText receives unchanged content.
    if (!force && JSON.stringify(next) === JSON.stringify(root.state)) {
      root.finishLocalImports()
      Qt.callLater(root.flushChanges)
      Qt.callLater(root.advanceBatch)
      Qt.callLater(root.scanLibraryWhenReady)
      return true
    }
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
      keyboardPanel.loadedContent.albumSourceField.text = ""
      return true
    }
    return false
  }

  function stageAlbumFromBrowser(input) {
    if (!root.stateReady) return "state_unavailable"
    var url = Model.normalizeAlbumUrl(input)
    if (!url) {
      root.noticeKey = "album_url_invalid"
      return "album_url_invalid"
    }
    root.activeTab = "albums"
    root.noticeKey = ""
    root.pendingBrowserUrl = url
    root.open()
    keyboardPanel.ensureContent()
    Qt.callLater(root.applyPendingBrowserUrl)
    return "staged"
  }

  function applyPendingBrowserUrl() {
    if (!root.pendingBrowserUrl || !keyboardPanel.loadedContent) return
    var field = keyboardPanel.loadedContent.albumSourceField
    field.text = root.pendingBrowserUrl
    root.pendingBrowserUrl = ""
    root.noticeKey = "album_staged_from_browser"
    field.forceActiveFocus()
  }

  onOpenedChanged: if (root.opened) {
    keyboardPanel.ensureContent()
    Qt.callLater(root.applyPendingBrowserUrl)
  }

  function removeAlbum(id) {
    root.writeState(Model.removeAlbum(root.state, id))
  }

  function moveAlbum(id, offset) {
    root.writeState(Model.moveAlbum(root.state, id, offset))
  }

  function submitPlaylist() {
    if (root.playlistKind === "online" && !root.selectedPlaylistId) {
      root.noticeKey = "online_add_help"
      return
    }
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
      root.playlistEditorOpen = false
    }
  }

  function selectPlaylist(id) {
    var playlist = root.state.playlists.find(function(item) { return item.id === id })
    if (!playlist) return
    root.selectedPlaylistId = id
    root.playlistKind = Model.playlistKind(playlist)
    root.customPlaylists = Model.librarySection(playlist) === "custom"
    root.playlistDraft = playlist.name
    root.confirmDelete = false
    root.libraryMenuOpen = false
    root.showAlbumDetails = false
    root.playlistEditorOpen = false
    root.trackSearch = ""
    root.noticeKey = ""
  }

  function showPlaylistKind(kind) {
    root.customPlaylists = kind === "custom"
    root.playlistKind = root.customPlaylists ? "downloaded" : kind
    root.librarySearch = ""
    root.trackSearch = ""
    root.playlistEditorOpen = false
    root.libraryMenuOpen = false
    root.showAlbumDetails = false
    root.selectedPlaylistId = ""
    root.playlistDraft = ""
    root.confirmDelete = false
    if (root.visiblePlaylists.length) root.selectPlaylist(root.visiblePlaylists[0].id)
  }

  function addOnlineAlbum(id) {
    var result = Model.saveOnlineAlbum(root.state, id)
    if (!result.ok) {
      root.noticeKey = result.error
      return
    }
    if (root.writeState(result.state)) {
      root.selectPlaylist(result.playlistId)
      root.activeTab = "playlists"
      root.noticeKey = "online_playlist_saved"
    }
  }

  function togglePlayback() {
    audio.toggle()
  }

  function revealPlayingAlbum() {
    root.activeTab = "playlists"
    root.librarySearch = ""
    root.selectPlaylist(audio.playlistId)
  }

  function editPlaylist(create) {
    root.libraryMenuOpen = false
    if (create) {
      root.librarySearch = ""
      root.selectedPlaylistId = ""
      root.playlistDraft = ""
    } else root.playlistDraft = root.selectedPlaylist.name
    root.playlistEditorOpen = true
  }

  function playbackTime(value) {
    var seconds = Math.floor(value / 1000)
    return Commons.I18n.formatNumber(Math.floor(seconds / 60)) + ":" +
      Commons.I18n.formatNumber(seconds % 60).padStart(2, Commons.I18n.formatNumber(0))
  }

  onStateChanged: {
    if (!audio || !audio.playlistId) return
    var playlist = root.state.playlists.find(function(item) { return item.id === audio.playlistId })
    if (playlist) audio.syncPlaylist(playlist)
    else audio.clear()
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
      root.finishLocalImports()
      if (root.noticeKey === "") root.noticeKey = "state.saved"
      Qt.callLater(root.flushChanges)
      Qt.callLater(root.advanceBatch)
      Qt.callLater(root.scanLibraryWhenReady)
    }
    onSaveFailed: function(error) {
      root.state = root.previousState || Model.emptyState()
      root.previousState = null
      root.stateSaving = false
      root.noticeKey = "state_save_failed"
      root.panelHeightDraft = 0
      root.pendingChanges = []
      root.batchRunning = false
      root.batchAlbumIds = []
      root.pendingLibraryScan = false
      if (root.pendingLocalImports.length) {
        root.libraryImportErrors = root.libraryImportErrors.concat(root.pendingLocalImports.map(function(album) {
          return { directory: album.directory, message: strings.t("messages.state_save_failed") }
        }))
        if (root.pendingBulkImport) {
          root.importCompleted = 0
          root.importFailed = root.libraryImportErrors.length
        }
      }
      root.pendingLocalImports = []
      root.pendingBulkImport = false
      root.importingDirectory = ""
      if (downloadProc.running) root.cancelDownload()
      console.warn("OmaKhinsider could not save its state file:", root.statePath, error)
      // Discard FileView's failed write cache so an identical retry is actually saved.
      root.stateReady = false
      Qt.callLater(function() { stateFile.reload() })
    }
  }

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  Local.AudioPlayer { id: audio }

  Process {
    id: barPlayerProc
    property var response: null
    command: ["python3", root.workerPath, "bar-player-settings"]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleWorkerLine(barPlayerProc, line) } }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim()) console.warn("OmaKhinsider bar settings:", text.trim())
    }
    onExited: function(exitCode) {
      root.barPlayerRequestPending = false
      if (exitCode === 0 && response && response.type === "result") {
        root.barPlayerEnabledDraft = response.enabled
        root.barPlayerSideDraft = response.side
        root.noticeKey = "bar_player_saved"
      } else {
        root.operationError = response && response.message ? response.message : strings.t("errors.worker_failed")
        root.noticeKey = "bar_player_failed"
      }
    }
  }

  Process {
    id: browserProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.browserStderr = String(text || "").trim()
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.noticeKey = root.browserNoticeKey
      } else {
        root.noticeKey = root.browserNoticeKey === "support_opened" ? "support_open_failed" : "browser_open_failed"
        console.warn("Could not open URL in the default browser:", exitCode, root.browserStderr)
      }
    }
  }

  Process {
    id: importProc
    property var response: null
    property string albumUrl: ""
    stdout: SplitParser { onRead: function(line) { root.handleWorkerLine(importProc, line) } }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim()) console.warn("OmaKhinsider import:", text.trim())
    }
    onExited: function(exitCode) {
      if (exitCode === 0 && response && response.type === "result" && response.album.url === albumUrl) {
        root.enqueueChange({ kind: "inspection", album: response.album, notice: "album_inspected" })
      } else {
        root.failAlbumInspection(albumUrl,
          response && response.message ? response.message : strings.t("errors.worker_failed"))
      }
    }
  }

  Process {
    id: folderProc
    property var response: null
    property string purpose: "download"
    property string playlistId: ""
    command: ["python3", root.workerPath, "choose-directory"]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleWorkerLine(folderProc, line) } }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim()) console.warn("OmaKhinsider folder chooser:", text.trim())
    }
    onExited: function(exitCode) {
      if (exitCode === 0 && response && response.type === "result" && Model.validLocalPath(response.directory)) {
        if (purpose === "relink") root.relinkDirectory(playlistId, response.directory)
        else {
          root.downloadDirectoryDraft = response.directory
          root.noticeKey = "folder_selected"
        }
      } else if (!response || response.type !== "canceled") {
        root.operationError = response && response.message ? response.message : strings.t("errors.worker_failed")
        root.noticeKey = "folder_chooser_failed"
      }
      root.activeTab = purpose === "relink" ? "playlists" : "settings"
      root.open()
    }
  }

  Process {
    id: settingsProc
    property var response: null
    command: ["python3", root.workerPath, "check-directory"]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleWorkerLine(settingsProc, line) } }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim()) console.warn("OmaKhinsider settings:", text.trim())
    }
    onExited: function(exitCode) {
      if (exitCode === 0 && response && response.type === "result") {
        if (root.downloadDirectory !== response.directory) root.pendingLibraryScan = true
        root.downloadDirectoryDraft = response.directory
        root.enqueueChange({ kind: "settings", notice: "settings_saved", settings: {
          downloadDirectory: response.directory, format: root.formatDraft
        } })
      } else {
        root.operationError = response && response.message ? response.message : strings.t("errors.worker_failed")
        root.noticeKey = "settings_failed"
      }
    }
  }

  Process {
    id: libraryProc
    property var response: null
    property string action: ""
    property string playlistId: ""
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleWorkerLine(libraryProc, line) } }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim()) console.warn("OmaKhinsider library:", text.trim())
    }
    onExited: function(exitCode) {
      root.libraryRequestPending = false
      if (exitCode === 0 && response && response.type === "result" && Array.isArray(response.albums) &&
          (action !== "scan-library" || (Array.isArray(response.previews) && Array.isArray(response.warnings) &&
            Array.isArray(response.locations))) &&
          (action !== "relink-folder" || response.albums.length === 1) &&
          (action !== "import-folders" || (Array.isArray(response.errors) && response.errors.every(function(problem) {
            return Model.isRecord(problem) && Model.validLocalPath(problem.directory) &&
              Model.validString(problem.message, 1000)
          })))) {
        if (action === "scan-library") {
          root.importPreviews = response.previews
          root.libraryWarnings = response.warnings
          if (root.importPreviews.length) {
            root.activeTab = "playlists"
            root.showPlaylistKind("downloaded")
          }
        } else if (action === "import-folders") {
          root.libraryImportErrors = response.errors
        }
        root.enqueueChange({ kind: action === "relink-folder" ? "relink" : "local-import",
          id: playlistId, albums: response.albums,
          locations: action === "scan-library" ? response.locations : undefined,
          bulk: action === "import-folders",
          notice: action === "scan-library" ? "library_scanned"
            : action === "import-folders" ? "library_import_all_complete"
              : action === "relink-folder" ? "library_relinked" : "library_imported" })
      } else {
        root.operationError = response && response.message ? response.message : strings.t("errors.worker_failed")
        root.noticeKey = "library_failed"
        root.importingDirectory = ""
        if (action === "import-folders") {
          root.importFailed = root.importTotal
          root.importProcessed = root.importTotal
        }
      }
    }
  }

  Process {
    id: downloadProc
    property var response: null
    command: ["python3", root.workerPath, "download"]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.handleWorkerLine(downloadProc, line) } }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim()) console.warn("OmaKhinsider download:", text.trim())
    }
    onExited: function(exitCode) {
      var change
      var notice
      if (exitCode === 0 && response && response.type === "result") {
        notice = root.downloadInBatch && !root.batchRunning ? "batch_canceled" : "download_complete"
        change = { kind: "complete", id: root.activeDownloadId, downloaded: response,
          batch: root.downloadInBatch, notice: notice }
      } else if (root.cancelRequested || (response && response.type === "canceled")) {
        notice = root.downloadInBatch ? "batch_canceled" : "download_canceled"
        change = { kind: "album", id: root.activeDownloadId,
          patch: { status: "canceled", error: "" }, notice: notice }
      } else {
        root.operationError = response && response.message ? response.message : strings.t("errors.worker_failed")
        notice = "download_failed"
        change = { kind: "album", id: root.activeDownloadId,
          patch: { status: "failed", error: root.operationError }, notice: notice }
        if (root.downloadInBatch) root.batchFailed++
      }
      root.enqueueChange(change)
      root.activeDownloadId = ""
      Qt.callLater(root.advanceBatch)
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
    contentHeight: root.requestedPanelHeight > 0
      ? Model.fitPanelHeight(root.requestedPanelHeight, Style.space(360), root.maximumPanelHeight)
      : Math.min(root.maximumPanelHeight, fittedContentHeight(loadedContentHeight, Style.space(680)))
    onLoadedContentChanged: Qt.callLater(root.applyPendingBrowserUrl)

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias albumSourceField: albumField
      implicitWidth: mainCard.implicitWidth
      implicitHeight: mainCard.implicitHeight + playerStrip.height + resizeHandle.height
      blocked: albumField.activeFocus || playlistField.activeFocus || downloadDirectoryField.activeFocus ||
        librarySearchField.activeFocus || trackSearchField.activeFocus ||
        (browserSetup.visible && browserSetup.editing)
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        var tabs = ["albums", "playlists", "settings"]
        var current = root.activeTab === "browser-setup" ? root.browserSetupReturnTab : root.activeTab
        if (current === "review") current = "playlists"
        var next = tabs[(tabs.indexOf(current) + direction + tabs.length) % tabs.length]
        if (next === "settings") root.showSettings()
        else root.activeTab = next
      }

      Flickable {
        id: panelScroll
        objectName: "workspaceScroll"
        anchors.fill: parent
        anchors.bottomMargin: resizeHandle.height + playerStrip.height
        contentWidth: width
        contentHeight: mainCard.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

        Rectangle {
          id: mainCard
          width: parent.width
          implicitHeight: contents.implicitHeight + Style.space(36)
          height: Math.max(panelScroll.height, implicitHeight)
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
              spacing: Style.space(10)

              Image {
                Layout.preferredWidth: Style.space(36)
                Layout.preferredHeight: Style.space(36)
                Layout.alignment: Qt.AlignVCenter
                source: Qt.resolvedUrl("icons/omakhinsider.png")
                sourceSize: Qt.size(128, 128)
                fillMode: Image.PreserveAspectFit
                smooth: true
              }

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
                onClicked: root.close()
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)
              Button {
                text: strings.t("tabs.albums")
                active: root.activeTab === "albums" ||
                  (root.activeTab === "browser-setup" && root.browserSetupReturnTab === "albums")
                focusable: true
                onClicked: root.activeTab = "albums"
              }
              Button {
                text: strings.t("tabs.playlists")
                active: root.activeTab === "playlists" || root.activeTab === "review"
                focusable: true
                onClicked: root.activeTab = "playlists"
              }
              Button {
                text: strings.t("tabs.settings")
                active: root.activeTab === "settings" ||
                  (root.activeTab === "browser-setup" && root.browserSetupReturnTab === "settings")
                focusable: true
                onClicked: root.showSettings()
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

            Local.BrowserSetup {
              id: browserSetup
              objectName: "browserSetup"
              visible: root.activeTab === "browser-setup"
              Layout.fillWidth: true
              host: root
              pluginDirectory: root.pluginDirectory
              onVisibleChanged: if (visible) Qt.callLater(function() { panelScroll.contentY = 0 })
              onBackRequested: {
                root.activeTab = root.browserSetupReturnTab
                Qt.callLater(function() { panelScroll.contentY = 0 })
              }
            }

            ColumnLayout {
              visible: root.activeTab === "albums"
              Layout.fillWidth: true
              Layout.fillHeight: true
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
                  enabled: root.stateReady && !root.libraryBusy
                  placeholderText: strings.t("album.url_placeholder")
                  onAccepted: root.addAlbum(text)
                }
                Button {
                  text: strings.t("common.clear")
                  enabled: albumField.enabled && albumField.text.length > 0
                  focusable: true
                  onClicked: {
                    albumField.text = ""
                    albumField.forceActiveFocus()
                  }
                }
                Button {
                  text: strings.t("album.add")
                  enabled: root.stateReady && !root.libraryBusy
                  focusable: true
                  onClicked: root.addAlbum(albumField.text)
                }
              }

              Text {
                visible: root.queueHelpOpen
                text: strings.t("album.help")
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                Layout.fillWidth: true
              }

              RowLayout {
                Layout.fillWidth: true
                Text {
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                  text: strings.t("setup.required")
                  textFormat: Text.PlainText
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
                Button {
                  objectName: "queueBrowserSetup"
                  text: strings.t("setup.instructions")
                  focusable: true
                  onClicked: root.showBrowserSetup()
                }
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)
                Button {
                  text: strings.t("download.all")
                  tooltipText: strings.t("download.all_tooltip")
                  enabled: root.stateReady && !root.libraryBusy && Model.readyAlbums(root.state).length > 0
                  focusable: true
                  onClicked: root.downloadAll()
                }
                Button {
                  text: strings.t("download.cancel_all")
                  visible: root.batchRunning
                  enabled: !root.cancelRequested
                  focusable: true
                  onClicked: root.cancelDownload()
                }
                Text {
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                  visible: root.batchRunning || (root.batchTotal > 0 &&
                    ["batch_finished", "batch_finished_with_errors", "batch_canceled"].indexOf(root.noticeKey) >= 0)
                  text: strings.tn("download.batch_progress", root.batchTotal)
                    .arg(Commons.I18n.formatNumber(root.batchCompleted + root.batchFailed))
                    .arg(Commons.I18n.formatNumber(root.batchTotal))
                    .arg(Commons.I18n.formatNumber(root.batchFailed))
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
                Button {
                  text: strings.t("album.how_to")
                  active: root.queueHelpOpen
                  focusable: true
                  onClicked: root.queueHelpOpen = !root.queueHelpOpen
                }
              }

              Local.StatusBanner {
                Layout.fillWidth: true
                host: root
                area: "albums"
              }

              Text {
                Layout.fillWidth: true
                visible: root.queueHelpOpen
                text: strings.t("app.scope_note")
                textFormat: Text.PlainText
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
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
                  Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                  delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: albumList.width
                    height: albumContents.implicitHeight + Style.space(16)
                    color: Commons.Color.menu.selectedBackground
                    radius: Style.cornerRadius

                    ColumnLayout {
                      id: albumContents
                      anchors.fill: parent
                      anchors.margins: Style.space(8)
                      spacing: Style.space(6)

                      RowLayout {
                        Layout.fillWidth: true
                        Text {
                          Layout.fillWidth: true
                          Layout.minimumWidth: 0
                          text: modelData.title || modelData.url
                          color: root.foreground
                          font.family: Style.font.family
                          font.pixelSize: Style.font.body
                          elide: Text.ElideMiddle
                          textFormat: Text.PlainText
                        }
                        Text {
                          text: modelData.tracks && modelData.tracks.length
                            ? strings.tn("album.track_count", modelData.tracks.length).arg(Commons.I18n.formatNumber(modelData.tracks.length))
                            : ""
                          color: root.muted
                          font.family: Style.font.family
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: modelData.id === root.activeDownloadId
                          ? strings.t("download.progress").arg(Commons.I18n.formatNumber(root.downloadedTracks))
                            .arg(Commons.I18n.formatNumber(root.downloadTotal))
                            .arg(root.downloadPercent >= 0 ? Commons.I18n.formatNumber(root.downloadPercent) + "%" : "")
                          : modelData.error || root.statusLabel(modelData.status)
                        color: modelData.error ? "#ff7777" : root.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }

                      Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: {
                          if (!modelData.tracks || !modelData.tracks.length)
                            return strings.t("album.format_pending")
                          var formats = Model.albumFormats(modelData)
                          if (formats.length === 1 && formats[0] === "mp3")
                            return strings.t("album.mp3_only")
                          var format = Model.albumDownloadFormat(modelData, root.state.settings.format)
                          return format
                            ? strings.t("album.formats").arg(formats.join(", ").toUpperCase()).arg(format.toUpperCase())
                            : strings.t("album.format_unavailable")
                        }
                        color: root.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.Wrap
                      }

                      Text {
                        Layout.fillWidth: true
                        visible: !!modelData.error && root.queueMenuId === modelData.id
                        textFormat: Text.PlainText
                        text: modelData.error || ""
                        color: "#ff7777"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.Wrap
                      }

                      RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(6)
                        Button {
                          text: modelData.id === root.activeDownloadId ? strings.t("album.status.downloading")
                            : modelData.status === "inspecting" ? strings.t("album.status.inspecting")
                            : !modelData.tracks || !modelData.tracks.length ? strings.t("album.inspect")
                            : strings.t(modelData.status === "failed" || modelData.status === "canceled"
                              ? "album.retry" : "album.download")
                          focusable: true
                          enabled: root.stateReady && !root.libraryBusy && !browserProc.running &&
                            modelData.status !== "inspecting" && (!modelData.tracks || !modelData.tracks.length ||
                              !!Model.albumDownloadFormat(modelData, root.state.settings.format))
                          onClicked: {
                            if (!modelData.tracks || !modelData.tracks.length) root.inspectAlbum(modelData.url)
                            else root.startDownload(modelData)
                          }
                        }
                        Button {
                          text: strings.t("common.cancel")
                          visible: modelData.id === root.activeDownloadId
                          enabled: !root.cancelRequested
                          focusable: true
                          onClicked: root.cancelDownload()
                        }
                        Button {
                          text: strings.t("album.add_online")
                          tooltipText: strings.t("album.add_online_tooltip")
                          visible: modelData.id !== root.activeDownloadId
                          enabled: root.stateReady && !root.libraryBusy && modelData.status !== "inspecting" &&
                            !!modelData.tracks && modelData.tracks.length > 0
                          focusable: true
                          onClicked: root.addOnlineAlbum(modelData.id)
                        }
                        Item { Layout.fillWidth: true }
                        Button {
                          text: strings.t("common.more")
                          active: root.queueMenuId === modelData.id
                          focusable: true
                          onClicked: root.queueMenuId = root.queueMenuId === modelData.id ? "" : modelData.id
                        }
                      }

                      Flow {
                        visible: root.queueMenuId === modelData.id
                        Layout.fillWidth: true
                        spacing: Style.space(4)
                        Button {
                          text: strings.t("album.inspect_again")
                          visible: !!modelData.tracks && modelData.tracks.length > 0
                          enabled: root.stateReady && !root.libraryBusy && !browserProc.running &&
                            modelData.status !== "inspecting"
                          focusable: true
                          onClicked: root.inspectAlbum(modelData.url)
                        }
                        Button {
                          text: strings.t("album.details")
                          visible: !!modelData.tracks && modelData.tracks.length > 0
                          focusable: true
                          onClicked: root.selectedAlbumId = root.selectedAlbumId === modelData.id ? "" : modelData.id
                        }
                        Button {
                          text: strings.t("common.up")
                          focusable: true
                          enabled: root.stateReady && !root.libraryBusy && index > 0
                          onClicked: root.moveAlbum(modelData.id, -1)
                        }
                        Button {
                          text: strings.t("common.down")
                          focusable: true
                          enabled: root.stateReady && !root.libraryBusy && index < root.state.albumQueue.length - 1
                          onClicked: root.moveAlbum(modelData.id, 1)
                        }
                        Button {
                          text: strings.t("common.remove")
                          focusable: true
                          enabled: root.stateReady && !root.libraryBusy && modelData.status !== "inspecting"
                          onClicked: root.removeAlbum(modelData.id)
                        }
                      }
                    }
                  }
                }

                Text {
                  anchors.centerIn: parent
                  visible: root.stateReady && root.state.albumQueue.length === 0
                  text: strings.t("album.empty")
                  width: parent.width - Style.space(24)
                  wrapMode: Text.Wrap
                  horizontalAlignment: Text.AlignHCenter
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
              }

              ListView {
                id: inspectedTrackList
                readonly property var album: root.state.albumQueue.find(function(item) { return item.id === root.selectedAlbumId })
                visible: !!album && !!album.tracks && album.tracks.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? Style.space(150) : 0
                clip: true
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                model: album && album.tracks ? album.tracks : []
                delegate: Text {
                  required property var modelData
                  required property int index
                  width: inspectedTrackList.width
                  height: Style.space(25)
                  textFormat: Text.PlainText
                  text: strings.t("album.track_detail")
                    .arg(Commons.I18n.formatNumber(index + 1)).arg(modelData.title)
                    .arg(modelData.audioLinks.map(function(link) { return link.format.toUpperCase() }).join(", "))
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }
            }

            ColumnLayout {
              visible: root.activeTab === "settings"
              Layout.fillWidth: true
              Layout.fillHeight: true
              spacing: Style.space(12)
              Text {
                text: strings.t("settings.heading")
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
              Text {
                text: strings.t("settings.directory")
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)
                TextField {
                  id: downloadDirectoryField
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                  text: root.downloadDirectoryDraft
                  enabled: root.stateReady && !root.libraryBusy
                  onTextEdited: root.downloadDirectoryDraft = text
                  onAccepted: root.saveSettings()
                }
                Button {
                  text: strings.t("settings.browse")
                  enabled: root.stateReady && !root.libraryBusy
                  focusable: true
                  onClicked: root.browseDownloadDirectory()
                }
              }
              Text {
                Layout.fillWidth: true
                text: strings.t("settings.directory_help")
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
              RowLayout {
                Text {
                  text: strings.t("settings.format")
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                Button {
                  text: "MP3"
                  active: root.formatDraft === "mp3"
                  enabled: !root.libraryBusy
                  focusable: true
                  onClicked: root.formatDraft = "mp3"
                }
                Button {
                  text: "FLAC"
                  active: root.formatDraft === "flac"
                  enabled: !root.libraryBusy
                  focusable: true
                  onClicked: root.formatDraft = "flac"
                }
              }
              Text {
                Layout.fillWidth: true
                text: strings.t("settings.format_help")
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
              Button {
                text: strings.t("settings.save")
                enabled: root.stateReady && !root.libraryBusy
                focusable: true
                onClicked: root.saveSettings()
              }
              Local.StatusBanner {
                Layout.fillWidth: true
                host: root
                area: "settings"
              }
              Text {
                text: strings.t("bar_player.heading")
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
              RowLayout {
                Button {
                  objectName: "barPlayerEnable"
                  text: strings.t("bar_player.enabled")
                  active: root.barPlayerEnabledDraft
                  enabled: !root.libraryBusy
                  focusable: true
                  onClicked: root.barPlayerEnabledDraft = true
                }
                Button {
                  objectName: "barPlayerDisable"
                  text: strings.t("bar_player.disabled")
                  active: !root.barPlayerEnabledDraft
                  enabled: !root.libraryBusy
                  focusable: true
                  onClicked: root.barPlayerEnabledDraft = false
                }
              }
              RowLayout {
                Button {
                  objectName: "barPlayerLeft"
                  text: strings.t("bar_player.left")
                  active: root.barPlayerSideDraft === "left"
                  enabled: !root.libraryBusy
                  focusable: true
                  onClicked: root.barPlayerSideDraft = "left"
                }
                Button {
                  objectName: "barPlayerRight"
                  text: strings.t("bar_player.right")
                  active: root.barPlayerSideDraft === "right"
                  enabled: !root.libraryBusy
                  focusable: true
                  onClicked: root.barPlayerSideDraft = "right"
                }
              }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: strings.t("bar_player.help")
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
              Button {
                objectName: "barPlayerApply"
                text: strings.t("bar_player.apply")
                enabled: root.stateReady && !root.libraryBusy
                focusable: true
                onClicked: root.applyBarPlayerSettings()
              }
              Button {
                objectName: "settingsBrowserSetup"
                text: strings.t("setup.title")
                focusable: true
                onClicked: root.showBrowserSetup()
              }
              Text {
                textFormat: Text.PlainText
                text: strings.t("support.heading")
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: strings.t("support.help")
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
              Button {
                objectName: "settingsFeedback"
                text: strings.t("support.open")
                enabled: !browserProc.running
                focusable: true
                onClicked: {
                  root.operationError = ""
                  root.openBrowser("https://github.com/kelmankenberg/OmaKhinsider/issues/new/choose", "support_opened")
                }
              }
              Item { Layout.fillHeight: true }
            }

            ColumnLayout {
              visible: root.activeTab === "playlists" || root.activeTab === "review"
              Layout.fillWidth: true
              Layout.fillHeight: true
              spacing: Style.space(10)

              RowLayout {
                visible: root.activeTab === "review"
                Layout.fillWidth: true
                Button {
                  text: strings.t("library.back")
                  focusable: true
                  onClicked: root.activeTab = "playlists"
                }
                Text {
                  text: strings.t("library.review_heading")
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
              }

              RowLayout {
                visible: root.activeTab !== "review"
                Layout.fillWidth: true
                Button {
                  text: strings.t("playlist.downloaded")
                  active: root.librarySection === "downloaded"
                  focusable: true
                  onClicked: root.showPlaylistKind("downloaded")
                }
                Button {
                  text: strings.t("playlist.online")
                  active: root.playlistKind === "online"
                  focusable: true
                  onClicked: root.showPlaylistKind("online")
                }
                Button {
                  text: strings.t("playlist.custom")
                  active: root.customPlaylists
                  focusable: true
                  onClicked: root.showPlaylistKind("custom")
                }
                Item { Layout.fillWidth: true }
                Button {
                  text: libraryProc.running ? strings.t("library.scanning") : strings.t("library.refresh")
                  visible: root.librarySection === "downloaded"
                  enabled: root.stateReady && !root.libraryBusy
                  tooltipText: strings.t("library.refresh_help")
                  focusable: true
                  onClicked: root.scanLibrary()
                }
              }

              RowLayout {
                visible: root.activeTab !== "review"
                Layout.fillWidth: true
                TextField {
                  id: librarySearchField
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                  placeholderText: strings.t("library.search_albums")
                  text: root.librarySearch
                  onTextEdited: root.librarySearch = text
                }
                Button {
                  text: strings.t("common.clear")
                  visible: root.librarySearch !== ""
                  focusable: true
                  onClicked: root.librarySearch = ""
                }
                Button {
                  text: strings.t("playlist.create")
                  visible: root.customPlaylists
                  enabled: root.stateReady && !root.libraryBusy
                  focusable: true
                  onClicked: root.editPlaylist(true)
                }
              }

              RowLayout {
                visible: root.activeTab !== "review" && (root.importPreviews.length > 0 ||
                  root.libraryWarnings.length > 0 || root.libraryImportErrors.length > 0)
                Layout.fillWidth: true
                Text {
                  Layout.fillWidth: true
                  text: root.importPreviews.length
                    ? strings.tn("library.discovered", root.importPreviews.length)
                      .arg(Commons.I18n.formatNumber(root.importPreviews.length))
                    : strings.t("library.attention")
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
                Button {
                  text: strings.t("library.review")
                  focusable: true
                  onClicked: root.activeTab = "review"
                }
                Button {
                  text: strings.t("library.import_all")
                  visible: root.importPreviews.length > 0
                  enabled: !root.libraryBusy
                  focusable: true
                  onClicked: {
                    root.activeTab = "review"
                    root.importAllPreviews()
                  }
                }
              }

              Local.StatusBanner {
                Layout.fillWidth: true
                host: root
                area: "library"
              }

              ColumnLayout {
                visible: root.activeTab === "review" && root.importTotal > 0
                Layout.fillWidth: true
                spacing: Style.space(4)
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: strings.tn("library.import_progress", root.importTotal)
                    .arg(Commons.I18n.formatNumber(root.importProcessed))
                    .arg(Commons.I18n.formatNumber(root.importTotal))
                    .arg(Commons.I18n.formatNumber(root.importCompleted))
                    .arg(Commons.I18n.formatNumber(root.importFailed))
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
                Text {
                  Layout.fillWidth: true
                  visible: root.importingDirectory !== ""
                  textFormat: Text.PlainText
                  text: strings.t("library.importing_folder").arg(root.importingDirectory)
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideMiddle
                }
              }

              ColumnLayout {
                visible: root.activeTab === "review" && root.importPreview !== null
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Style.space(6)
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: strings.tn("library.preview", root.importPreviews.length)
                    .arg(Commons.I18n.formatNumber(root.importPreviews.length))
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: Text.Wrap
                }
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.importPreview ? strings.t("library.preview_album")
                    .arg(root.importPreview.title).arg(root.importPreview.directory) : ""
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: strings.t("library.preview_help")
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
                ListView {
                  id: importTrackList
                  objectName: "importReviewTracks"
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(180)
                  Layout.fillHeight: true
                  clip: true
                  Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                  model: root.importPreview ? root.importPreview.tracks : []
                  delegate: Text {
                    required property var modelData
                    required property int index
                    width: importTrackList.width
                    textFormat: Text.PlainText
                    text: strings.t("playlist.track").arg(Commons.I18n.formatNumber(index + 1)).arg(modelData.title)
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }
                RowLayout {
                  Button {
                    text: strings.t("library.import")
                    enabled: !root.libraryBusy
                    focusable: true
                    onClicked: root.importPreviewAlbum()
                  }
                  Button {
                    text: strings.t("library.import_all")
                    enabled: !root.libraryBusy
                    focusable: true
                    onClicked: root.importAllPreviews()
                  }
                  Button {
                    text: strings.t("library.skip")
                    enabled: !root.libraryBusy
                    focusable: true
                    onClicked: root.importPreviews = root.importPreviews.slice(1)
                  }
                  Button {
                    text: strings.t("library.review_later")
                    focusable: true
                    onClicked: root.activeTab = "playlists"
                  }
                }
              }

              Flickable {
                visible: root.activeTab === "review" &&
                  (root.libraryWarnings.length > 0 || root.libraryImportErrors.length > 0)
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(Style.space(160), libraryWarningText.implicitHeight)
                Layout.fillHeight: root.importPreview === null
                contentWidth: width
                contentHeight: libraryWarningText.implicitHeight
                clip: true
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                Text {
                  id: libraryWarningText
                  width: parent.width
                  textFormat: Text.PlainText
                  text: strings.t("library.warnings").arg(root.libraryWarnings.concat(
                    root.libraryImportErrors.map(function(problem) {
                      return strings.t("library.import_problem").arg(problem.directory).arg(problem.message)
                    })).join("\n"))
                  color: root.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }
              }

              Text {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: root.activeTab === "review" && root.importPreview === null &&
                  !root.libraryWarnings.length && !root.libraryImportErrors.length && !root.libraryBusy
                text: strings.t("library.review_empty")
                color: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              RowLayout {
                visible: root.activeTab !== "review" && root.playlistEditorOpen
                Layout.fillWidth: true
                spacing: Style.space(8)
                TextField {
                  id: playlistField
                  Layout.fillWidth: true
                  Layout.minimumWidth: 0
                  enabled: root.stateReady && !root.libraryBusy &&
                    (root.playlistKind === "downloaded" || !!root.selectedPlaylist)
                  placeholderText: strings.t("playlist.name_placeholder")
                  text: root.playlistDraft
                  onTextEdited: root.playlistDraft = text
                  onAccepted: root.submitPlaylist()
                }
                Button {
                  text: strings.t("common.save")
                  enabled: root.stateReady && !root.libraryBusy &&
                    (root.playlistKind === "downloaded" || !!root.selectedPlaylist)
                  focusable: true
                  onClicked: root.submitPlaylist()
                }
                Button {
                  text: strings.t("common.cancel")
                  enabled: !root.libraryBusy
                  focusable: true
                  onClicked: root.playlistEditorOpen = false
                }
              }

              RowLayout {
                visible: root.activeTab !== "review"
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Style.space(12)
                Rectangle {
                  Layout.preferredWidth: Style.space(270)
                  Layout.preferredHeight: Style.space(300)
                  Layout.fillHeight: true
                  color: Qt.darker(root.background, 1.05)
                  radius: Style.cornerRadius

                  ListView {
                    id: playlistList
                    objectName: "libraryAlbums"
                    anchors.fill: parent
                    anchors.margins: Style.space(8)
                    clip: true
                    spacing: Style.space(4)
                    model: root.visiblePlaylists
                    Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                    delegate: Button {
                      required property var modelData
                      width: playlistList.width
                      text: modelData.folderMissing
                        ? strings.t("playlist.missing_name").arg(modelData.name) : modelData.name
                      leftAlign: true
                      selected: modelData.id === root.selectedPlaylistId
                      focusable: true
                      onClicked: root.selectPlaylist(modelData.id)
                    }
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: root.stateReady && root.visiblePlaylists.length === 0
                    width: parent.width - Style.space(16)
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    text: root.librarySearch ? strings.t("library.no_matches")
                      : root.playlistKind === "online" ? strings.t("playlist.online_empty")
                      : strings.t(root.customPlaylists ? "playlist.custom_empty" : "playlist.empty")
                    color: root.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(300)
                  Layout.fillHeight: true
                  color: Qt.darker(root.background, 1.05)
                  radius: Style.cornerRadius

                  ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(14)
                    spacing: Style.space(6)

                    RowLayout {
                      Layout.fillWidth: true
                      Text {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        textFormat: Text.PlainText
                        text: root.selectedPlaylist ? root.selectedPlaylist.name : strings.t("playlist.none_selected")
                        color: root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }
                      Button {
                        text: strings.t("common.more")
                        visible: !!root.selectedPlaylist
                        active: root.libraryMenuOpen
                        focusable: true
                        onClicked: root.libraryMenuOpen = !root.libraryMenuOpen
                      }
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      visible: !!root.selectedPlaylist && !root.confirmDelete
                      Text {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        textFormat: Text.PlainText
                        text: root.selectedPlaylist
                          ? root.selectedPlaylist.discCount
                            ? strings.t("library.album_summary")
                              .arg(strings.tn("library.disc_count", root.selectedPlaylist.discCount)
                                .arg(Commons.I18n.formatNumber(root.selectedPlaylist.discCount)))
                              .arg(strings.tn("album.track_count", root.selectedPlaylist.tracks.length)
                                .arg(Commons.I18n.formatNumber(root.selectedPlaylist.tracks.length)))
                            : strings.tn("album.track_count", root.selectedPlaylist.tracks.length)
                              .arg(Commons.I18n.formatNumber(root.selectedPlaylist.tracks.length))
                          : ""
                        color: root.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }
                      Button {
                        objectName: "playSelectedAlbum"
                        text: strings.t(root.customPlaylists ? "player.play_playlist" : "player.play_album")
                        enabled: !!root.selectedPlaylist && !root.selectedPlaylist.folderMissing &&
                          root.selectedPlaylist.tracks.length > 0
                        focusable: true
                        onClicked: audio.playPlaylist(root.selectedPlaylist)
                      }
                    }

                    Text {
                      Layout.fillWidth: true
                      visible: !!root.selectedPlaylist && root.showAlbumDetails && !root.confirmDelete
                      textFormat: Text.PlainText
                      text: root.selectedPlaylist
                        ? strings.t("library.source_details")
                          .arg(root.selectedPlaylist.kind === "online"
                            ? root.selectedPlaylist.sourceAlbumUrl : root.selectedPlaylist.downloadDirectory || strings.t("playlist.custom"))
                          .arg((root.selectedPlaylist.downloadFormat ||
                            (root.selectedPlaylist.tracks[0] ? root.selectedPlaylist.tracks[0].format : "") || "-").toUpperCase())
                        : ""
                      color: root.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.Wrap
                      maximumLineCount: 4
                      elide: Text.ElideMiddle
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      visible: !!root.selectedPlaylist && root.selectedPlaylist.folderMissing === true && !root.confirmDelete
                      Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: strings.t("library.folder_missing")
                        color: root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.Wrap
                      }
                      Button {
                        text: strings.t("library.locate")
                        enabled: root.stateReady && !root.libraryBusy
                        focusable: true
                        onClicked: root.browseRelinkDirectory()
                      }
                    }

                    TextField {
                      id: trackSearchField
                      Layout.fillWidth: true
                      Layout.minimumWidth: 0
                      visible: !!root.selectedPlaylist && root.selectedPlaylist.tracks.length > 0 && !root.confirmDelete
                      placeholderText: strings.t("library.search_tracks")
                      text: root.trackSearch
                      onTextEdited: root.trackSearch = text
                    }

                    Text {
                      Layout.fillWidth: true
                      Layout.fillHeight: true
                      visible: root.confirmDelete || !root.selectedPlaylist || root.selectedPlaylist.tracks.length === 0 ||
                        (root.trackSearch !== "" && downloadedTrackList.count === 0)
                      text: root.confirmDelete
                        ? strings.t("playlist.delete_confirm")
                        : root.trackSearch ? strings.t("library.no_matches")
                        : root.selectedPlaylist
                          ? strings.t("playlist.no_tracks")
                          : strings.t("playlist.select_help")
                      color: root.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      wrapMode: Text.Wrap
                    }

                    ListView {
                      id: downloadedTrackList
                      visible: !!root.selectedPlaylist && root.selectedPlaylist.tracks.length > 0 &&
                        downloadedTrackList.count > 0 && !root.confirmDelete
                      Layout.fillWidth: true
                      Layout.fillHeight: true
                      clip: true
                      model: Model.playlistTrackRows(root.selectedPlaylist, root.trackSearch)
                      Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
                      delegate: Column {
                        required property var modelData
                        width: downloadedTrackList.width
                        Text {
                          visible: modelData.heading
                          textFormat: Text.PlainText
                          text: strings.t("library.disc_heading").arg(Commons.I18n.formatNumber(modelData.disc))
                          color: root.muted
                          font.family: Style.font.family
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                        }
                        Button {
                          width: parent.width
                          text: strings.t("playlist.track")
                            .arg(Commons.I18n.formatNumber(modelData.index + 1)).arg(modelData.track.title)
                          leftAlign: true
                          selected: audio.playlistId === root.selectedPlaylistId && audio.trackIndex === modelData.index
                          enabled: root.selectedPlaylist && !root.selectedPlaylist.folderMissing &&
                            (!!modelData.track.localPath || !!modelData.track.streamUrl)
                          focusable: true
                          onClicked: audio.playPlaylist(root.selectedPlaylist, modelData.index)
                        }
                      }
                    }

                    Flow {
                      visible: !!root.selectedPlaylist && (root.libraryMenuOpen || root.confirmDelete)
                      Layout.fillWidth: true
                      spacing: Style.space(4)
                      Button {
                        text: strings.t("playlist.rename")
                        visible: !root.confirmDelete
                        enabled: root.stateReady && !root.libraryBusy
                        focusable: true
                        onClicked: root.editPlaylist(false)
                      }
                      Button {
                        text: strings.t(root.showAlbumDetails ? "library.hide_details" : "library.details")
                        visible: !root.confirmDelete
                        focusable: true
                        onClicked: {
                          root.showAlbumDetails = !root.showAlbumDetails
                          root.libraryMenuOpen = false
                        }
                      }
                      Button {
                        text: strings.t("library.relink")
                        visible: !!root.selectedPlaylist && Model.playlistKind(root.selectedPlaylist) === "downloaded" &&
                          !!root.selectedPlaylist.downloadDirectory && !root.selectedPlaylist.folderMissing && !root.confirmDelete
                        enabled: root.stateReady && !root.libraryBusy
                        tooltipText: strings.t("library.relink_help")
                        focusable: true
                        onClicked: root.browseRelinkDirectory()
                      }

                      Button {
                        text: strings.t("playlist.refresh")
                        visible: !!root.selectedPlaylist && root.selectedPlaylist.kind === "online" && !root.confirmDelete
                        enabled: root.stateReady && !root.libraryBusy && !browserProc.running
                        tooltipText: strings.t("playlist.refresh_help")
                        focusable: true
                        onClicked: root.inspectAlbum(root.selectedPlaylist.sourceAlbumUrl)
                      }

                      Button {
                        text: root.confirmDelete
                          ? strings.t("common.cancel")
                          : strings.t("playlist.delete")
                        visible: root.selectedPlaylistId !== ""
                        enabled: root.stateReady && !root.libraryBusy
                        focusable: true
                        onClicked: {
                          if (root.confirmDelete) root.confirmDelete = false
                          else root.deleteSelectedPlaylist()
                        }
                      }

                      Button {
                        text: strings.t("playlist.confirm_delete")
                        visible: root.confirmDelete
                        enabled: root.stateReady && !root.libraryBusy
                        focusable: true
                        onClicked: root.confirmDeleteSelectedPlaylist()
                      }
                    }
                  }

                }
              }

            }

            Local.StatusBanner {
              Layout.fillWidth: true
              host: root
              area: "global"
            }
          }
        }

      }

      Local.PlayerStrip {
        id: playerStrip
        objectName: "persistentPlayer"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: resizeHandle.top
        height: implicitHeight
        host: root
        player: audio
      }

      MouseArea {
        id: resizeHandle
        objectName: "panelResizeHandle"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Style.space(20)
        enabled: root.stateReady
        hoverEnabled: true
        cursorShape: Qt.SizeVerCursor
        acceptedButtons: Qt.LeftButton
        preventStealing: true
        property real startY: 0
        property int startHeight: 0

        Text {
          anchors.centerIn: parent
          text: strings.t("panel.resize")
          color: resizeHandle.containsMouse ? root.foreground : root.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
        }

        onPressed: function(mouse) {
          startY = mapToGlobal(mouse.x, mouse.y).y
          startHeight = keyboardPanel.contentHeight
          root.panelHeightDraft = startHeight
          keyboardPanel.heightLive = false
        }
        onPositionChanged: function(mouse) {
          if (!pressed) return
          var direction = keyboardPanel.barPos === "bottom" ? -1 : 1
          var height = startHeight + direction * (mapToGlobal(mouse.x, mouse.y).y - startY)
          root.panelHeightDraft = Model.fitPanelHeight(height, Style.space(360), root.maximumPanelHeight)
        }
        onReleased: {
          keyboardPanel.heightLive = true
          root.enqueueChange({ kind: "height", height: root.panelHeightDraft })
        }
        onCanceled: {
          keyboardPanel.heightLive = true
          root.panelHeightDraft = 0
        }
      }
    }
  }
}
