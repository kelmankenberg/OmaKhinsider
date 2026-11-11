import QtQuick 2.15
import QtTest 1.3
import "../Model.js" as Model

TestCase {
  name: "OmaKhinsiderModel"

  function test_barPlayerUsesExistingPlaybackAndKeepsPausedAndErroredAlbumsAccessible() {
    var idle = { playerView: false, player: { currentTrack: {}, playing: false, playbackRequested: false, errorKey: "" } }
    var paused = { playerView: false, player: { currentTrack: {}, playing: false, playbackRequested: true, errorKey: "" } }
    var playing = { playerView: false, player: { currentTrack: {}, playing: true, playbackRequested: true, errorKey: "" } }
    var strip = { playerView: true, player: playing.player }
    compare(Model.playbackWidget([idle, strip]), null)
    compare(Model.playbackWidget([idle, paused]), paused)
    compare(Model.playbackWidget([paused, playing]), playing)
    paused.player.playbackRequested = false
    paused.player.errorKey = "online_failed"
    compare(Model.playbackWidget([paused, idle]), paused)
    paused.player.currentTrack = null
    compare(Model.playbackWidget([paused]), null)
  }

  function test_barPlayerSettingsDistinguishThePlayerFromTheLibraryIcon() {
    var id = "kelmankenberg.omakhinsider"
    compare(Model.barPlayerSettings({ right: [{ id: id }] }), { enabled: false, side: "right" })
    compare(Model.barPlayerSettings({ right: [{ id: id }], centerBegin: [
      { id: id, view: "player", playerEnabled: false }
    ] }), { enabled: false, side: "left" })
    compare(Model.barPlayerSettings({ centerEnd: [{ id: id, view: "player" }] }),
      { enabled: true, side: "right" })
  }

  function test_librarySearchSeparatesAlbumsOnlineAndCustomWithoutChangingSavedKinds() {
    var playlists = [
      { id: "local", name: "Forest Suite", downloadDirectory: "/music/Forest" },
      { id: "online", name: "Forest Suite", kind: "online" },
      { id: "custom", name: "Favorites" }
    ]
    compare(Model.libraryAlbums(playlists, "downloaded", "  FOREST  ").map(function(p) { return p.id }), ["local"])
    compare(Model.libraryAlbums(playlists, "online", "forest").map(function(p) { return p.id }), ["online"])
    compare(Model.libraryAlbums(playlists, "custom", "").map(function(p) { return p.id }), ["custom"])
    compare(Model.libraryAlbums(playlists, "downloaded", "unknown"), [])
    compare(playlists[0].kind, undefined)
  }

  function test_filteredTrackRowsRetainPlaybackIndicesAndDiscHeadings() {
    var playlist = { downloadDirectory: "/music/Suite", discCount: 2, tracks: [
      { title: "Opening", localPath: "/music/Suite/CD1/01.mp3" },
      { title: "Ending", localPath: "/music/Suite/CD1/02.mp3" },
      { title: "Opening", localPath: "/music/Suite/Disc 2/01.mp3" },
      { title: "Ending", localPath: "/music/Suite/Disc 2/02.mp3" }
    ] }
    var all = Model.playlistTrackRows(playlist, "")
    compare(all.map(function(row) { return row.heading }), [true, false, true, false])
    var rows = Model.playlistTrackRows(playlist, " END ")
    compare(rows.map(function(row) { return row.index }), [1, 3])
    compare(rows.map(function(row) { return row.disc }), [1, 2])
    verify(rows.every(function(row) { return row.heading }))
    compare(Model.playlistTrackRows(playlist, "missing"), [])
    delete playlist.discCount
    verify(Model.playlistTrackRows(playlist, "").every(function(row) { return !row.heading }))
    compare(Model.playlistTrackRows(null, ""), [])
  }

  function test_readyBatchSkipsUninspectedIncompatibleAndActiveAlbumsInQueueOrder() {
    var first = inspectedAlbum("first", "First")
    var state = Model.applyInspection(Model.emptyState(), first).state
    var firstId = state.albumQueue[0].id
    state = Model.addAlbum(state, first.url + "-pending", "pending", "now").state
    var retry = inspectedAlbum("retry", "Retry")
    state = Model.applyInspection(state, retry).state
    var retryId = state.albumQueue[2].id
    state = Model.updateAlbum(state, retryId, { status: "failed", error: "Try again" }).state
    var incompatible = inspectedAlbum("other", "Other")
    incompatible.tracks[0].audioLinks = [{ format: "ogg", url: "https://kappa.vgmsite.com/test/01.ogg" }]
    state = Model.applyInspection(state, incompatible).state
    compare(Model.downloadPlan(state, true).ids, [firstId, retryId])
    state = Model.updateAlbum(state, firstId, { status: "inspecting" }).state
    compare(Model.downloadPlan(state, true).ids, [retryId])
    state = Model.updateAlbum(state, retryId, { status: "downloading" }).state
    compare(Model.downloadPlan(state, true).error, "batch_none_ready")
    compare(state.albumQueue.length, 4)
  }

  function localAlbum() {
    return { libraryId: "local-" + "a".repeat(64), title: "<b>Local album</b>", directory: "/music/Album",
      tracks: [
        { path: "01 Opening.mp3", title: "<img src='https://invalid.test/image'>",
          format: "mp3", bytes: 42, sha256: "b".repeat(64) },
        { path: "02 Ending.flac", title: "Ending", format: "flac", bytes: 84, sha256: "c".repeat(64) }
      ] }
  }

  function test_localAlbumImportRelocationPreservesNamesSettingsQueueAndOnline() {
    var state = Model.updateSettings(Model.emptyState(), { panelHeight: 900 }).state
    state = Model.addAlbum(state, "https://downloads.khinsider.com/game-soundtracks/album/queued").state
    var imported = Model.importLocalAlbums(state, [localAlbum()], "now")
    verify(imported.ok)
    var playlist = imported.state.playlists[0]
    compare(playlist.tracks[0].localPath, "/music/Album/01 Opening.mp3")
    compare(playlist.downloadFormat, "mixed")
    compare(playlist.tracks[0].trackUrl, undefined)
    verify(Model.parseState(JSON.stringify(imported.state)).ok)
    state = Model.renamePlaylist(imported.state, playlist.id, "My album").state
    var album = localAlbum()
    album.directory = "/new/library/Moved"
    var moved = Model.importLocalAlbums(state, [album])
    verify(moved.ok)
    compare(moved.state.playlists.length, 1)
    compare(moved.state.playlists[0].name, "My album")
    compare(moved.state.playlists[0].id, playlist.id)
    compare(moved.state.playlists[0].tracks[0].id, playlist.tracks[0].id)
    compare(moved.state.playlists[0].tracks[0].localPath, "/new/library/Moved/01 Opening.mp3")
    compare(moved.state.settings.panelHeight, 900)
    compare(moved.state.albumQueue.length, 1)
    verify(Model.parseState(JSON.stringify(moved.state)).ok)
    var different = localAlbum()
    different.libraryId = "local-" + "d".repeat(64)
    compare(Model.importLocalAlbums(moved.state, [different]).state.playlists.length, 2)
  }

  function test_localAlbumImportRejectsTraversalInvalidSourcesAndDuplicatesAtomically() {
    var paths = ["../outside.mp3", "/tmp/outside.mp3", "nested/../audio.mp3", "bad\n.mp3"]
    for (var i = 0; i < paths.length; i++) {
      var album = localAlbum()
      album.tracks[0].path = paths[i]
      verify(!Model.importLocalAlbums(Model.emptyState(), [album]).ok)
    }
    album = localAlbum()
    album.tracks[1] = album.tracks[0]
    verify(!Model.importLocalAlbums(Model.emptyState(), [album]).ok)
    album = localAlbum()
    album.albumUrl = "https://example.invalid/album"
    verify(!Model.importLocalAlbums(Model.emptyState(), [album]).ok)
    album = localAlbum()
    album.libraryId = "not-a-stable-id"
    var state = Model.emptyState()
    verify(!Model.importLocalAlbums(state, [localAlbum(), album]).ok)
    compare(state.playlists.length, 0)
  }

  function test_bulkLocalImportRetainsSuccessesAndReportsRejectedAlbums() {
    var first = localAlbum()
    var invalid = localAlbum()
    invalid.directory = "/music/Bad"
    invalid.tracks[0].path = "../outside.mp3"
    var last = localAlbum()
    last.libraryId = "local-" + "d".repeat(64)
    last.directory = "/music/Last"
    var imported = Model.importLocalAlbumResults(Model.emptyState(), [first, invalid, last])
    verify(imported.ok)
    compare(imported.state.playlists.length, 2)
    compare(imported.accepted.length, 2)
    compare(imported.errors.length, 1)
    compare(imported.errors[0].directory, "/music/Bad")
    compare(imported.errors[0].error, "library_import_invalid")
    verify(Model.parseState(JSON.stringify(imported.state)).ok)
    var repeated = Model.importLocalAlbumResults(imported.state, [first, last])
    compare(repeated.state.playlists.length, 2)
    compare(repeated.errors.length, 0)
    var rejected = Model.importLocalAlbumResults(Model.emptyState(), [invalid])
    compare(rejected.accepted.length, 0)
    compare(rejected.errors.length, 1)
    compare(rejected.state.playlists.length, 0)
    var full = Model.emptyState()
    for (var i = 0; i < Model.MAX_PLAYLISTS - 1; i++)
      full = Model.createPlaylist(full, "Existing " + i).state
    var limited = Model.importLocalAlbumResults(full, [first, last])
    compare(limited.state.playlists.length, Model.MAX_PLAYLISTS)
    compare(limited.accepted.length, 1)
    compare(limited.errors[0].error, "playlist_limit")
  }

  function test_groupedDiscsReplaceMemberPlaylistsAndKeepNamesIdsAndOrdering() {
    var first = localAlbum()
    first.directory = "/music/Bundle/CD1"
    var second = localAlbum()
    second.directory = "/music/Bundle/CD2"
    second.libraryId = "local-" + "d".repeat(64)
    var state = Model.importLocalAlbums(Model.emptyState(), [first, second]).state
    var firstId = state.playlists[0].id
    var secondId = state.playlists[1].id
    var trackIds = state.playlists[0].tracks.concat(state.playlists[1].tracks).map(function(track) { return track.id })
    state = Model.renamePlaylist(state, firstId, "My bundle").state
    var group = {
      libraryId: "local-" + "e".repeat(64), title: "Bundle", directory: "/music/Bundle",
      discs: [{ path: "CD1", libraryId: first.libraryId }, { path: "CD2", libraryId: second.libraryId }],
      tracks: first.tracks.map(function(track) { return Object.assign({}, track, { path: "CD1/" + track.path }) })
        .concat(second.tracks.map(function(track) { return Object.assign({}, track, { path: "CD2/" + track.path }) }))
    }
    var imported = Model.importLocalAlbumResults(state, [group])
    verify(imported.ok)
    compare(imported.errors.length, 0)
    compare(imported.state.playlists.length, 1)
    var playlist = imported.state.playlists[0]
    compare(playlist.id, firstId)
    compare(playlist.name, "My bundle")
    compare(playlist.discCount, 2)
    compare(playlist.tracks.length, 4)
    compare(playlist.tracks.map(function(track) { return track.id }), trackIds)
    compare(playlist.tracks[2].localPath, "/music/Bundle/CD2/01 Opening.mp3")
    compare(imported.replacements[0].from, secondId)
    compare(imported.replacements[0].to, firstId)
    verify(Model.parseState(JSON.stringify(imported.state)).ok)
    group.directory = "/new/Bundle"
    var moved = Model.importLocalAlbums(imported.state, [group])
    verify(moved.ok)
    compare(moved.state.playlists.length, 1)
    compare(moved.state.playlists[0].tracks.length, 4)
    compare(moved.state.playlists[0].tracks[2].localPath, "/new/Bundle/CD2/01 Opening.mp3")
    compare(moved.state.playlists[0].tracks.map(function(track) { return track.id }), trackIds)
    group.discs[1].path = "../outside"
    verify(!Model.importLocalAlbums(state, [group]).ok)
  }

  function test_missingLocationsAndExplicitRelinkingMergeAnExistingImportedCopy() {
    var url = "https://downloads.khinsider.com/game-soundtracks/album/test"
    var old = localAlbum()
    old.libraryId = "kh-" + "e".repeat(64)
    old.albumUrl = url
    old.directory = "/music/Missing"
    var replacement = localAlbum()
    replacement.directory = "/music/Replacement"
    var state = Model.importLocalAlbums(Model.emptyState(), [old, replacement]).state
    var id = state.playlists[0].id
    var duplicateId = state.playlists[1].id
    state = Model.renamePlaylist(state, id, "Original custom name").state
    var located = Model.updatePlaylistLocations(state, [{ id: id, directory: old.directory, missing: true }])
    verify(located.ok)
    verify(located.state.playlists[0].folderMissing)
    var stale = Model.updatePlaylistLocations(located.state, [{ id: id, directory: "/wrong/path", missing: false }])
    verify(stale.state.playlists[0].folderMissing)
    replacement.previousLibraryId = replacement.libraryId
    replacement.libraryId = old.libraryId
    replacement.albumUrl = url
    var linked = Model.relinkLocalAlbum(located.state, id, replacement)
    verify(linked.ok)
    compare(linked.state.playlists.length, 1)
    compare(linked.state.playlists[0].id, id)
    compare(linked.state.playlists[0].name, "Original custom name")
    compare(linked.state.playlists[0].downloadDirectory, replacement.directory)
    compare(linked.state.playlists[0].tracks.length, 2)
    verify(!linked.state.playlists[0].folderMissing)
    compare(linked.replacements[0].from, duplicateId)
    compare(linked.replacements[0].to, id)
    compare(linked.state.playlists[0].sourceAlbumUrl, url)
    verify(Model.parseState(JSON.stringify(linked.state)).ok)
    replacement.previousLibraryId = replacement.libraryId
    var retried = Model.relinkLocalAlbum(located.state, id, replacement)
    verify(retried.ok)
    compare(retried.state.playlists.length, 1)
    compare(retried.state.playlists[0].id, id)
    replacement.albumUrl = "https://downloads.khinsider.com/game-soundtracks/album/other"
    compare(Model.relinkLocalAlbum(located.state, id, replacement).error, "library_relink_invalid")
    replacement.albumUrl = url
    replacement.tracks = [replacement.tracks[0]]
    compare(Model.relinkLocalAlbum(located.state, id, replacement).error, "library_relink_invalid")
    compare(located.state.playlists.length, 2)
  }

  function test_scannedKhinsiderAlbumUpdatesLegacyDownloadedButNotOnline() {
    var url = "https://downloads.khinsider.com/game-soundtracks/album/test"
    var state = Model.applyInspection(Model.emptyState(), { url: url, title: "Test", tracks: [{
      title: "Opening", trackUrl: url + "/01.mp3",
      audioLinks: [{ format: "mp3", url: "https://kappa.vgmsite.com/test/01.mp3" }]
    }] }).state
    state = Model.saveOnlineAlbum(state, state.albumQueue[0].id).state
    state = Model.completeAlbumDownload(state, state.albumQueue[0].id, {
      directory: "/music/Old", completed: 1,
      files: [{ path: "/music/Old/01.mp3", format: "mp3", trackUrl: url + "/01.mp3" }]
    }).state
    var downloaded = state.playlists.find(function(item) { return item.kind !== "online" })
    state = Model.renamePlaylist(state, downloaded.id, "Custom").state
    var online = JSON.stringify(state.playlists.find(function(item) { return item.kind === "online" }))
    var album = localAlbum()
    album.libraryId = "kh-" + "e".repeat(64)
    album.albumUrl = url
    album.directory = "/music/New"
    album.tracks = [album.tracks[0]]
    album.tracks[0].trackUrl = url + "/01.mp3"
    var imported = Model.importLocalAlbums(state, [album])
    verify(imported.ok)
    compare(imported.state.playlists.length, 2)
    compare(imported.state.playlists.find(function(item) { return item.id === downloaded.id }).name, "Custom")
    compare(imported.state.playlists.find(function(item) { return item.id === downloaded.id }).tracks[0].localPath,
      "/music/New/01 Opening.mp3")
    compare(JSON.stringify(imported.state.playlists.find(function(item) { return item.kind === "online" })), online)
    verify(Model.parseState(JSON.stringify(imported.state)).ok)
  }

  function test_localLegacyTracksCanGainOriginalSourceUrlsWithoutDuplicates() {
    var url = "https://downloads.khinsider.com/game-soundtracks/album/test"
    var album = localAlbum()
    album.libraryId = "kh-" + "e".repeat(64)
    album.albumUrl = url
    album.tracks = [album.tracks[0]]
    var state = Model.importLocalAlbums(Model.emptyState(), [album]).state
    verify(Model.parseState(JSON.stringify(state)).ok)
    var id = state.playlists[0].tracks[0].id
    album.tracks[0].trackUrl = url + "/01.mp3"
    state = Model.importLocalAlbums(state, [album]).state
    compare(state.playlists[0].tracks.length, 1)
    compare(state.playlists[0].tracks[0].id, id)
    compare(state.playlists[0].tracks[0].trackUrl, url + "/01.mp3")
  }

  function test_albumUrlValidationAndNormalization() {
    compare(
      Model.normalizeAlbumUrl(" https://downloads.khinsider.com/game-soundtracks/album/example-ost/ "),
      "https://downloads.khinsider.com/game-soundtracks/album/example-ost"
    )
    compare(Model.normalizeAlbumUrl("http://downloads.khinsider.com/game-soundtracks/album/example"), "")
    compare(Model.normalizeAlbumUrl("https://example.com/game-soundtracks/album/example"), "")
    compare(Model.normalizeAlbumUrl("https://downloads.khinsider.com/game-soundtracks/album/../private"), "")
  }

  function test_queueAddsOnceAndMovesWithoutLoss() {
    var state = Model.emptyState()
    var first = Model.addAlbum(state, "https://downloads.khinsider.com/game-soundtracks/album/one", "a", "now")
    verify(first.ok)
    var second = Model.addAlbum(first.state, "https://downloads.khinsider.com/game-soundtracks/album/two", "b", "now")
    verify(second.ok)
    compare(Model.addAlbum(second.state, first.state.albumQueue[0].url).error, "album_duplicate")
    var moved = Model.moveAlbum(second.state, "b", -1)
    compare(moved.albumQueue[0].id, "b")
    var removed = Model.removeAlbum(moved, "a")
    compare(removed.albumQueue.length, 1)
    compare(removed.albumQueue[0].id, "b")
  }

  function test_playlistCreateRenameAndDelete() {
    var state = Model.emptyState()
    var created = Model.createPlaylist(state, "  Favorites  ", "p1", "now")
    verify(created.ok)
    compare(created.state.playlists[0].name, "Favorites")
    compare(Model.createPlaylist(created.state, "favorites").error, "playlist_name_duplicate")
    var renamed = Model.renamePlaylist(created.state, "p1", "Game OSTs")
    verify(renamed.ok)
    compare(renamed.state.playlists[0].name, "Game OSTs")
    compare(Model.removePlaylist(renamed.state, "p1").playlists.length, 0)
  }

  function test_trackAddAndDuplicateProtection() {
    var created = Model.createPlaylist(Model.emptyState(), "Favorites", "p1", "now")
    var track = {
      trackUrl: "https://downloads.khinsider.com/game-soundtracks/album/example/01-opening",
      albumUrl: "https://downloads.khinsider.com/game-soundtracks/album/example",
      title: "Opening",
      albumTitle: "Example OST"
    }
    var added = Model.addTrack(created.state, "p1", track)
    verify(added.ok)
    compare(added.state.playlists[0].tracks.length, 1)
    compare(Model.addTrack(added.state, "p1", track).error, "track_duplicate")
    track.albumUrl = "https://downloads.khinsider.com/game-soundtracks/album/other"
    compare(Model.addTrack(created.state, "p1", track).error, "track_invalid")
  }

  function test_stateParsingRejectsCorruptAndRoundTripsValidData() {
    compare(Model.parseState("{").ok, false)
    var state = Model.createPlaylist(Model.emptyState(), "Favorites", "p1", "now").state
    var parsed = Model.parseState(JSON.stringify(state))
    verify(parsed.ok)
    compare(parsed.state.playlists[0].name, "Favorites")
    state.playlists[0].name = 42
    compare(Model.parseState(JSON.stringify(state)).ok, false)
  }

  function test_settingsSurviveQueueAndPlaylistChangesAndOldStateLoads() {
    var legacy = { schemaVersion: 1, albumQueue: [], playlists: [] }
    var parsed = Model.parseState(JSON.stringify(legacy))
    verify(parsed.ok)
    compare(parsed.state.settings.format, "mp3")
    var settings = { downloadDirectory: "/tmp/omakhinsider-tests", format: "flac" }
    var state = Model.updateSettings(parsed.state, settings).state
    verify(!Model.updateSettings(state, { downloadDirectory: "relative", format: "mp3" }).ok)
    state = Model.addAlbum(state, "https://downloads.khinsider.com/game-soundtracks/album/test", "a", "now").state
    state = Model.createPlaylist(state, "Test", "p", "now").state
    state = Model.renamePlaylist(state, "p", "Renamed").state
    state = Model.removePlaylist(state, "p")
    state = Model.removeAlbum(state, "a")
    compare(state.settings.downloadDirectory, settings.downloadDirectory)
    compare(Model.parseState(JSON.stringify(state)).state.settings.format, "flac")
  }

  function test_inspectionValidationAndInterruptedDownloadRecovery() {
    var url = "https://downloads.khinsider.com/game-soundtracks/album/test"
    var album = { url: url, title: "<img src='https://invalid.test/image'>", tracks: [{
      title: "<b>Opening</b>", trackUrl: url + "/01.mp3",
      audioLinks: [{ format: "mp3", url: "https://kappa.vgmsite.com/test/01.mp3" }]
    }] }
    var inspected = Model.applyInspection(Model.emptyState(), album)
    verify(inspected.ok)
    compare(inspected.state.albumQueue[0].status, "ready")
    compare(inspected.state.albumQueue[0].tracks[0].title, "<b>Opening</b>")
    var downloading = Model.updateAlbum(inspected.state, inspected.state.albumQueue[0].id, { status: "downloading" })
    verify(downloading.ok)
    var recovered = Model.parseState(JSON.stringify(downloading.state))
    compare(recovered.state.albumQueue[0].status, "ready")
    album.tracks[0].audioLinks[0].url = "https://vgmsite.com.evil.test/01.mp3"
    compare(Model.applyInspection(Model.emptyState(), album).ok, false)
    album.tracks[0].audioLinks[0].url = "https://kappa.vgmsite.com/01.mp3"
    album.tracks[0].trackUrl = url + "/../other.mp3"
    compare(Model.applyInspection(Model.emptyState(), album).ok, false)
  }

  function test_panelHeightPersistsAndSurvivesDownloadSettingsChanges() {
    var state = Model.emptyState()
    var resized = Model.updateSettings(state, { panelHeight: 900 })
    verify(resized.ok)
    compare(state.settings.panelHeight, undefined)
    state = resized.state
    state = Model.updateSettings(state, { downloadDirectory: "/tmp/music", format: "flac" }).state
    compare(state.settings.panelHeight, 900)
    state = Model.addAlbum(state, "https://downloads.khinsider.com/game-soundtracks/album/height", "a", "now").state
    state = Model.createPlaylist(state, "Height", "p", "now").state
    var parsed = Model.parseState(JSON.stringify(state))
    verify(parsed.ok)
    compare(parsed.state.settings.panelHeight, 900)
    compare(parsed.state.settings.format, "flac")
    compare(parsed.state.settings.downloadDirectory, "/tmp/music")
    verify(Model.parseState(JSON.stringify(Model.emptyState())).ok)
    for (var i = 0; i < 5; i++)
      verify(!Model.updateSettings(state, { panelHeight: [0, -1, 1.5, "900", NaN][i] }).ok)
  }

  function test_panelHeightFitsSmallerScreensAndRespectsUsableHeight() {
    compare(Model.fitPanelHeight(900, 360, 1040), 900)
    compare(Model.fitPanelHeight(2000, 360, 720), 720)
    compare(Model.fitPanelHeight(1000000000, 360, 720), 720)
    compare(Model.fitPanelHeight(100, 360, 1040), 360)
    compare(Model.fitPanelHeight(900, 360, 240), 240)
    compare(Model.fitPanelHeight(900, 360, 720.8), 720)
  }

  function inspectedAlbum(slug, title) {
    var url = "https://downloads.khinsider.com/game-soundtracks/album/" + slug
    return { url: url, title: title, tracks: [{
      title: "Opening", trackUrl: url + "/cd1/01.mp3",
      audioLinks: [{ format: "mp3", url: "https://kappa.vgmsite.com/test/01.mp3" }]
    }] }
  }

  function downloadResult(album, directory) {
    return { directory: directory, completed: 1, files: [{
      trackUrl: album.tracks[0].trackUrl, format: "mp3", path: directory + "/0001 - Opening.mp3"
    }] }
  }

  function test_downloadCompletionAtomicallyMovesAlbumToLocalPlaylist() {
    var album = inspectedAlbum("one", "Album: One")
    var state = Model.applyInspection(Model.emptyState(), album).state
    var completed = Model.completeAlbumDownload(state, state.albumQueue[0].id, downloadResult(album, "/tmp/album-one"), "now")
    verify(completed.ok)
    compare(state.albumQueue.length, 1)
    compare(state.playlists.length, 0)
    compare(completed.state.albumQueue.length, 0)
    compare(completed.state.playlists.length, 1)
    compare(completed.state.playlists[0].name, "Album_ One")
    compare(completed.state.playlists[0].tracks[0].localPath, "/tmp/album-one/0001 - Opening.mp3")
    var loaded = Model.parseState(JSON.stringify(completed.state))
    verify(loaded.ok)
    compare(loaded.state.playlists[0].tracks[0].format, "mp3")
    compare(loaded.state.settings.format, "mp3")
  }

  function test_invalidCompletionKeepsAlbumQueuedWithoutCreatingPlaylist() {
    var album = inspectedAlbum("one", "One")
    var state = Model.applyInspection(Model.emptyState(), album).state
    var result = downloadResult(album, "/tmp/one")
    result.files[0].path = "/tmp/elsewhere/track.mp3"
    verify(!Model.completeAlbumDownload(state, state.albumQueue[0].id, result).ok)
    result = downloadResult(album, "/tmp/one")
    result.completed = 0
    verify(!Model.completeAlbumDownload(state, state.albumQueue[0].id, result).ok)
    result = downloadResult(album, "/tmp/one")
    result.files[0].path = "/tmp/one/../track.mp3"
    verify(!Model.completeAlbumDownload(state, state.albumQueue[0].id, result).ok)
    compare(state.albumQueue.length, 1)
    compare(state.playlists.length, 0)
  }

  function test_completedAlbumPlaylistSurvivesRenameAndRedownloadWithoutDuplicates() {
    var album = inspectedAlbum("one", "One")
    var state = Model.createPlaylist(Model.emptyState(), "One", "manual", "now").state
    state = Model.applyInspection(state, album).state
    var completed = Model.completeAlbumDownload(state, state.albumQueue[0].id, downloadResult(album, "/tmp/one"))
    verify(completed.ok)
    var playlistId = completed.playlistId
    compare(completed.state.playlists[1].name, "One (2)")
    state = Model.renamePlaylist(completed.state, playlistId, "Renamed").state
    compare(state.playlists[1].sourceAlbumUrl, album.url)
    state = Model.addTrack(state, playlistId, {
      trackUrl: album.url + "/bonus.mp3", albumUrl: album.url,
      title: "Bonus", albumTitle: album.title
    }).state
    compare(state.playlists[1].sourceAlbumUrl, album.url)
    state = Model.applyInspection(state, album).state
    completed = Model.completeAlbumDownload(state, state.albumQueue[0].id, downloadResult(album, "/tmp/another-folder"))
    verify(completed.ok)
    compare(completed.playlistId, playlistId)
    compare(completed.state.playlists.length, 2)
    compare(completed.state.playlists[1].name, "Renamed")
    compare(completed.state.playlists[1].tracks.length, 2)
    compare(completed.state.playlists[1].tracks[0].localPath, "/tmp/another-folder/0001 - Opening.mp3")
    verify(Model.parseState(JSON.stringify(completed.state)).ok)
  }

  function test_downloadAllRequiresInspectionAndCompatibleFormatAndKeepsQueueOrder() {
    var first = inspectedAlbum("first", "First")
    var second = inspectedAlbum("second", "Second")
    var state = Model.applyInspection(Model.emptyState(), first).state
    state = Model.addAlbum(state, second.url, "second", "now").state
    compare(Model.downloadPlan(state).error, "batch_needs_inspection")
    state = Model.applyInspection(state, second).state
    var plan = Model.downloadPlan(state)
    verify(plan.ok)
    compare(plan.ids[0], state.albumQueue[0].id)
    compare(plan.ids[1], "second")
    state = Model.updateAlbum(state, "second", { status: "failed", error: "Prior transfer failed" }).state
    verify(Model.downloadPlan(state).ok)
    state = Model.updateSettings(state, { downloadDirectory: "", format: "flac" }).state
    verify(Model.downloadPlan(state).ok)
    second.tracks[0].audioLinks = [{ format: "ogg", url: "https://kappa.vgmsite.com/test/01.ogg" }]
    state = Model.applyInspection(state, second).state
    compare(Model.downloadPlan(state).error, "batch_format_unavailable")
  }

  function test_albumFormatsPreferFlacAndFallBackToMp3ForTheWholeAlbum() {
    var album = inspectedAlbum("formats", "Formats")
    compare(Model.albumFormats({}), [])
    compare(Model.albumDownloadFormat({}, "flac"), "")
    compare(Model.albumFormats(album), ["mp3"])
    compare(Model.albumDownloadFormat(album, "flac"), "mp3")
    album.tracks[0].audioLinks.push({ format: "flac", url: "https://kappa.vgmsite.com/test/01.flac" })
    compare(Model.albumFormats(album), ["mp3", "flac"])
    compare(Model.albumDownloadFormat(album, "flac"), "flac")
    compare(Model.albumDownloadFormat(album, "mp3"), "mp3")
    album.tracks.push({
      title: "Ending", trackUrl: album.url + "/02.mp3",
      audioLinks: [{ format: "mp3", url: "https://kappa.vgmsite.com/test/02.mp3" }]
    })
    compare(Model.albumFormats(album), ["mp3"])
    compare(Model.albumDownloadFormat(album, "flac"), "mp3")
    album.tracks[1].audioLinks = [{ format: "flac", url: "https://kappa.vgmsite.com/test/02.flac" }]
    compare(Model.albumFormats(album), ["flac"])
    compare(Model.albumDownloadFormat(album, "flac"), "flac")
    compare(Model.albumDownloadFormat(album, "mp3"), "")
    album.tracks[0].audioLinks = [{ format: "mp3", url: "https://kappa.vgmsite.com/test/01.mp3" }]
    compare(Model.albumFormats(album), [])
    compare(Model.albumDownloadFormat(album, "flac"), "")
  }

  function test_fallbackReusesExistingMp3PlaylistWhenPlaylistLibraryIsFull() {
    var album = inspectedAlbum("fallback", "Fallback")
    var state = Model.applyInspection(Model.emptyState(), album).state
    var completed = Model.completeAlbumDownload(state, state.albumQueue[0].id, downloadResult(album, "/tmp/fallback"))
    verify(completed.ok)
    state = completed.state
    for (var i = 1; i < Model.MAX_PLAYLISTS; i++)
      state = Model.createPlaylist(state, "Playlist " + i, "p" + i, "now").state
    state = Model.applyInspection(state, album).state
    state = Model.updateSettings(state, { downloadDirectory: "", format: "flac" }).state
    verify(Model.downloadPlan(state).ok)
    completed = Model.completeAlbumDownload(state, state.albumQueue[0].id, downloadResult(album, "/tmp/fallback"))
    verify(completed.ok)
    compare(completed.playlistId, state.playlists[0].id)
    compare(completed.state.playlists.length, Model.MAX_PLAYLISTS)
    compare(completed.state.settings.format, "flac")
    state = Model.applyInspection(state, inspectedAlbum("another", "Another")).state
    compare(Model.downloadPlan(state).error, "playlist_limit")
  }

  function test_onlineAlbumKeepsQueueAndDownloadsRemainIndependent() {
    var album = inspectedAlbum("online", "Online Album")
    album.tracks[0].audioLinks.push({ format: "flac", url: "https://kappa.vgmsite.com/test/01.flac" })
    var state = Model.applyInspection(Model.emptyState(), album).state
    state = Model.updateSettings(state, { format: "flac", panelHeight: 800 }).state
    var saved = Model.saveOnlineAlbum(state, state.albumQueue[0].id, "now")
    verify(saved.ok)
    compare(state.playlists.length, 0)
    compare(saved.state.albumQueue.length, 1)
    compare(saved.state.playlists[0].kind, "online")
    compare(saved.state.playlists[0].sourceAlbumUrl, album.url)
    compare(saved.state.playlists[0].tracks[0].trackUrl, album.tracks[0].trackUrl)
    compare(saved.state.playlists[0].tracks[0].format, "mp3")
    compare(saved.state.playlists[0].tracks[0].localPath, undefined)
    compare(saved.state.playlists[0].tracks[0].streamUrl, album.tracks[0].audioLinks[0].url)
    verify(Model.parseState(JSON.stringify(saved.state)).ok)
    var downloaded = Model.completeAlbumDownload(saved.state, saved.state.albumQueue[0].id,
      downloadResult(album, "/tmp/online"))
    verify(downloaded.ok)
    compare(downloaded.state.playlists.length, 2)
    compare(downloaded.state.albumQueue.length, 0)
    compare(downloaded.state.playlists[0].name, downloaded.state.playlists[1].name)
    compare(Model.playlistKind(downloaded.state.playlists[1]), "downloaded")
    compare(downloaded.state.settings.format, "flac")
    compare(downloaded.state.settings.panelHeight, 800)
    verify(Model.parseState(JSON.stringify(downloaded.state)).ok)
    var removed = Model.removePlaylist(downloaded.state, saved.playlistId)
    compare(removed.playlists.length, 1)
    compare(removed.playlists[0].tracks[0].localPath, "/tmp/online/0001 - Opening.mp3")
  }

  function test_onlineReinspectionUpdatesLinksWithoutDuplicatesOrLosingRename() {
    var album = inspectedAlbum("refresh", "Refresh")
    var state = Model.applyInspection(Model.emptyState(), album).state
    var saved = Model.saveOnlineAlbum(state, state.albumQueue[0].id, "now")
    var playlistId = saved.playlistId
    var trackId = saved.state.playlists[0].tracks[0].id
    state = Model.renamePlaylist(saved.state, playlistId, "Renamed").state
    album.tracks[0].audioLinks[0].url += "?refreshed=1"
    var refreshed = Model.applyInspection(state, album)
    verify(refreshed.ok)
    compare(refreshed.state.playlists.length, 1)
    compare(refreshed.state.playlists[0].id, playlistId)
    compare(refreshed.state.playlists[0].name, "Renamed")
    compare(refreshed.state.playlists[0].tracks[0].id, trackId)
    compare(refreshed.state.playlists[0].tracks[0].streamUrl, album.tracks[0].audioLinks[0].url)
    saved = Model.saveOnlineAlbum(refreshed.state, refreshed.state.albumQueue[0].id)
    verify(saved.ok)
    compare(saved.playlistId, playlistId)
    compare(saved.state.playlists.length, 1)
    verify(Model.parseState(JSON.stringify(saved.state)).ok)
    var another = inspectedAlbum("another", "Renamed")
    state = Model.applyInspection(saved.state, another).state
    saved = Model.saveOnlineAlbum(state, state.albumQueue[1].id)
    compare(saved.state.playlists[1].name, "Renamed (2)")
  }

  function test_onlinePlaylistValidationRejectsUntrustedOrMixedSources() {
    var album = inspectedAlbum("validate", "Validate")
    var state = Model.applyInspection(Model.emptyState(), album).state
    state = Model.saveOnlineAlbum(state, state.albumQueue[0].id).state
    var original = JSON.stringify(state)
    var invalid = [
      "http://kappa.vgmsite.com/test/01.mp3",
      "https://vgmsite.com.evil.test/01.mp3",
      "file:///tmp/track.mp3",
      "https://kappa.vgmsite.com/test/01.flac"
    ]
    for (var i = 0; i < invalid.length; i++) {
      state = JSON.parse(original)
      state.playlists[0].tracks[0].streamUrl = invalid[i]
      verify(!Model.parseState(JSON.stringify(state)).ok)
    }
    state = JSON.parse(original)
    state.playlists[0].tracks[0].localPath = "/tmp/track.mp3"
    verify(!Model.parseState(JSON.stringify(state)).ok)
    state = JSON.parse(original)
    state.playlists[0].kind = "downloaded"
    verify(!Model.parseState(JSON.stringify(state)).ok)
    state = JSON.parse(original)
    state.playlists[0].sourceAlbumUrl = "https://downloads.khinsider.com/game-soundtracks/album/other"
    verify(!Model.parseState(JSON.stringify(state)).ok)
    state = JSON.parse(original)
    state.playlists[0].tracks = [null]
    verify(!Model.parseState(JSON.stringify(state)).ok)
    state.playlists[0].kind = "downloaded"
    verify(!Model.parseState(JSON.stringify(state)).ok)
  }

  function test_onlineRequiresInspectionAndUsesFlacWhenMp3IsUnavailable() {
    var album = inspectedAlbum("formats-online", "Formats")
    var state = Model.addAlbum(Model.emptyState(), album.url, "a", "now").state
    compare(Model.saveOnlineAlbum(state, "a").error, "online_needs_inspection")
    album.tracks[0].audioLinks = [{ format: "flac", url: "https://kappa.vgmsite.com/test/01.flac" }]
    state = Model.applyInspection(state, album).state
    var saved = Model.saveOnlineAlbum(state, "a")
    verify(saved.ok)
    compare(saved.state.playlists[0].tracks[0].format, "flac")
    album.tracks[0].audioLinks = [{ format: "ogg", url: "https://kappa.vgmsite.com/test/01.ogg" }]
    state = Model.applyInspection(state, album).state
    compare(Model.saveOnlineAlbum(state, "a").error, "online_format_unavailable")
  }
}
