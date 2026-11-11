.pragma library

var SCHEMA_VERSION = 1
var MAX_ALBUMS = 100
var MAX_PLAYLISTS = 200
var MAX_TRACKS_PER_PLAYLIST = 2000
var QUEUE_STATUSES = ["queued", "inspecting", "ready", "downloading", "complete", "failed", "canceled"]
var PLUGIN_ID = "kelmankenberg.omakhinsider"

function playbackWidget(widgets) {
  var active = (widgets || []).filter(function(widget) {
    var player = widget && !widget.playerView ? widget.player : null
    return player && player.currentTrack && (player.playing || player.playbackRequested || player.errorKey)
  })
  return active.find(function(widget) { return widget.player.playing }) || active[0] || null
}

function barPlayerSettings(layout) {
  var sections = ["left", "centerBegin", "center", "centerEnd", "right", "tray"]
  for (var s = 0; s < sections.length; s++) {
    var entries = layout && Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
    var entry = entries.find(function(item) {
      return isRecord(item) && item.id === PLUGIN_ID && item.view === "player"
    })
    if (entry) return { enabled: entry.playerEnabled !== false, side: sections[s] === "centerBegin" ? "left" : "right" }
  }
  return { enabled: false, side: "right" }
}

function emptyState() {
  return { schemaVersion: SCHEMA_VERSION, albumQueue: [], playlists: [],
    settings: { downloadDirectory: "", format: "mp3" } }
}

function stateWith(state, albums, playlists) {
  return { schemaVersion: SCHEMA_VERSION, albumQueue: albums, playlists: playlists,
    settings: state.settings || emptyState().settings }
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function normalizeAlbumUrl(input) {
  var value = String(input || "").trim()
  var match = /^https:\/\/downloads\.khinsider\.com\/game-soundtracks\/album\/([A-Za-z0-9._~%!-]+(?:\/[A-Za-z0-9._~%!-]+)*)\/?$/i.exec(value)
  if (!match) return ""
  var segments = match[1].split("/")
  for (var i = 0; i < segments.length; i++) {
    if (segments[i] === "." || segments[i] === "..") return ""
  }
  return "https://downloads.khinsider.com/game-soundtracks/album/" + match[1]
}

function normalizeTrackUrl(input) {
  var value = normalizeAlbumUrl(input)
  return /^https:\/\/downloads\.khinsider\.com\/game-soundtracks\/album\/[^/]+\/.+/.test(value) ? value : ""
}

function albumUrlForTrack(trackUrl) {
  var match = /^https:\/\/downloads\.khinsider\.com\/game-soundtracks\/album\/([^/]+)\//.exec(trackUrl)
  return match ? "https://downloads.khinsider.com/game-soundtracks/album/" + match[1] : ""
}

function normalizePlaylistName(input) {
  return String(input || "").replace(/\s+/g, " ").trim()
}

function playlistKind(playlist) {
  return playlist.kind === "online" ? "online" : "downloaded"
}

function playlistNameError(name, playlists, ignoreId, kind) {
  var normalized = normalizePlaylistName(name)
  if (!normalized) return "playlist_name_empty"
  if (normalized.length > 100) return "playlist_name_too_long"
  if (/[\u0000-\u001f\u007f<>:"/\\|?*]/.test(normalized)) return "playlist_name_invalid"
  for (var i = 0; i < playlists.length; i++) {
    if (playlists[i].id !== ignoreId && playlistKind(playlists[i]) === (kind || "downloaded") &&
        playlists[i].name.toLowerCase() === normalized.toLowerCase())
      return "playlist_name_duplicate"
  }
  return ""
}

function albumPlaylistName(title, playlists, kind) {
  var base = normalizePlaylistName(title).replace(/[<>:"/\\|?*\u0000-\u001f\u007f]/g, "_").slice(0, 100) || "Album"
  var name = base
  var suffix = 2
  while (playlistNameError(name, playlists, "", kind)) {
    var tail = " (" + suffix++ + ")"
    name = base.slice(0, 100 - tail.length) + tail
  }
  return name
}

function makeId(prefix) {
  return prefix + "-" + Date.now().toString(36) + "-" + Math.floor(Math.random() * 1679616).toString(36)
}

function validString(value, limit) {
  return typeof value === "string" && value.length <= limit
}

function validAlbum(entry) {
  return isRecord(entry) &&
    validString(entry.id, 100) && entry.id.length > 0 &&
    normalizeAlbumUrl(entry.url) === entry.url &&
    validString(entry.title, 500) &&
    validString(entry.addedAt, 64) && entry.addedAt.length > 0 &&
    QUEUE_STATUSES.indexOf(entry.status) >= 0 &&
    (entry.tracks === undefined || (Array.isArray(entry.tracks) && entry.tracks.length <= 1000 &&
      entry.tracks.every(function(track) { return validInspectedTrack(track, entry.url) }))) &&
    (entry.error === undefined || validString(entry.error, 1000)) &&
    (entry.downloadDirectory === undefined || validString(entry.downloadDirectory, 4096))
}

function validInspectedTrack(track, albumUrl) {
  if (!isRecord(track) || !validString(track.title, 500) || !track.title ||
      !validString(track.trackUrl, 2048) || track.trackUrl.indexOf(albumUrl + "/") !== 0 ||
      normalizeAlbumUrl(track.trackUrl) !== track.trackUrl ||
      !Array.isArray(track.audioLinks) || !track.audioLinks.length || track.audioLinks.length > 9)
    return false
  var formats = {}
  return track.audioLinks.every(function(link) {
    if (!validAudioLink(link) || formats[link.format]) return false
    formats[link.format] = true
    return true
  })
}

function validAudioLink(link) {
  if (!isRecord(link) || !/^(mp3|flac|ogg|opus|m4a|aac|wav|wma|alac)$/.test(link.format) ||
      !validString(link.url, 4096)) return false
  var match = /^https:\/\/(?:[a-z0-9-]+\.)*(?:vgmsite\.com|vgmtreasurechest\.com)\/[^#\s]*\.([a-z0-9]+)(?:\?[^#\s]*)?$/i.exec(link.url)
  return !!match && match[1].toLowerCase() === link.format
}

function validStreamTrack(track) {
  return isRecord(track) && track.localPath === undefined &&
    ["mp3", "flac"].indexOf(track.format) >= 0 &&
    validAudioLink({ format: track.format, url: track.streamUrl })
}

function validSettings(settings) {
  return isRecord(settings) && validString(settings.downloadDirectory, 4096) &&
    (settings.downloadDirectory === "" || /^(\/|~\/)/.test(settings.downloadDirectory)) &&
    !/[\u0000-\u001f\u007f]/.test(settings.downloadDirectory) &&
    ["mp3", "flac"].indexOf(settings.format) >= 0 &&
    (settings.panelHeight === undefined || (typeof settings.panelHeight === "number" &&
      isFinite(settings.panelHeight) && settings.panelHeight >= 1 &&
      Math.floor(settings.panelHeight) === settings.panelHeight))
}

function validPlaylistTrack(entry) {
  return isRecord(entry) &&
    validString(entry.id, 100) && entry.id.length > 0 &&
    (entry.localId === undefined || (validString(entry.localId, 100) &&
      /^(kh|local)-[a-f0-9]{64}:\d+$/.test(entry.localId))) &&
    (entry.localId !== undefined && entry.trackUrl === undefined && entry.albumUrl === undefined
      ? entry.streamUrl === undefined && validLocalPath(entry.localPath)
      : normalizeTrackUrl(entry.trackUrl) === entry.trackUrl &&
        normalizeAlbumUrl(entry.albumUrl) === entry.albumUrl &&
        albumUrlForTrack(entry.trackUrl) === entry.albumUrl) &&
    validString(entry.title, 500) &&
    validString(entry.albumTitle, 500) &&
    validString(entry.addedAt, 64) && entry.addedAt.length > 0 &&
    (entry.streamUrl !== undefined
      ? validStreamTrack(entry)
      : entry.localPath === undefined
        ? entry.format === undefined
        : validLocalPath(entry.localPath) && /^(mp3|flac|ogg|opus|m4a|aac|wav|wma|alac)$/.test(entry.format))
}

function validLocalPath(value) {
  return validString(value, 4096) && value.charAt(0) === "/" &&
    !/[\u0000-\u001f\u007f]/.test(value) &&
    value.split("/").every(function(part) { return part !== "." && part !== ".." })
}

function validRelativePath(value) {
  return validString(value, 4096) && value.length > 0 && !/[\\\u0000-\u001f\u007f]/.test(value) &&
    value.split("/").length <= 7 && value.split("/").every(function(part) {
      return part.length > 0 && part.length <= 255 && part !== "." && part !== ".."
    })
}

function validPlaylistMetadata(playlist) {
  if (playlist.folderMissing !== undefined && typeof playlist.folderMissing !== "boolean") return false
  if (playlist.discCount !== undefined && (typeof playlist.discCount !== "number" ||
      Math.floor(playlist.discCount) !== playlist.discCount || playlist.discCount < 2 || playlist.discCount > 100)) return false
  if (playlist.kind !== undefined && ["online", "downloaded"].indexOf(playlist.kind) < 0) return false
  if (playlist.kind === "online")
    return normalizeAlbumUrl(playlist.sourceAlbumUrl) === playlist.sourceAlbumUrl &&
      playlist.downloadDirectory === undefined && playlist.downloadFormat === undefined &&
      validString(playlist.updatedAt, 64) && playlist.updatedAt.length > 0 &&
      playlist.tracks.length > 0 && playlist.tracks.every(function(track) {
        return validStreamTrack(track) && track.albumUrl === playlist.sourceAlbumUrl
      })
  if (playlist.tracks.some(function(track) { return !isRecord(track) || track.streamUrl !== undefined })) return false
  if (playlist.libraryId !== undefined)
    return validLibraryId(playlist.libraryId) && validLocalPath(playlist.downloadDirectory) &&
      (playlist.sourceAlbumUrl === undefined || normalizeAlbumUrl(playlist.sourceAlbumUrl) === playlist.sourceAlbumUrl) &&
      /^(mp3|flac|ogg|opus|m4a|aac|wav|wma|alac|mixed)$/.test(playlist.downloadFormat) &&
      validString(playlist.downloadedAt, 64) && playlist.downloadedAt.length > 0
  if (playlist.sourceAlbumUrl === undefined)
    return playlist.downloadDirectory === undefined && playlist.downloadFormat === undefined
  return normalizeAlbumUrl(playlist.sourceAlbumUrl) === playlist.sourceAlbumUrl &&
    validLocalPath(playlist.downloadDirectory) &&
    ["mp3", "flac"].indexOf(playlist.downloadFormat) >= 0 &&
    validString(playlist.downloadedAt, 64) && playlist.downloadedAt.length > 0
}

function parseState(raw) {
  var data
  try {
    data = JSON.parse(String(raw || ""))
  } catch (error) {
    return { ok: false, error: "state_invalid" }
  }
  if (!isRecord(data) || data.schemaVersion !== SCHEMA_VERSION ||
      !Array.isArray(data.albumQueue) || !Array.isArray(data.playlists) ||
      data.albumQueue.length > MAX_ALBUMS || data.playlists.length > MAX_PLAYLISTS ||
      (data.settings !== undefined && !validSettings(data.settings)) ||
      !data.albumQueue.every(validAlbum)) {
    return { ok: false, error: "state_invalid" }
  }

  var albumIds = {}
  var albumUrls = {}
  for (var i = 0; i < data.albumQueue.length; i++) {
    var album = data.albumQueue[i]
    if (albumIds[album.id] || albumUrls[album.url]) return { ok: false, error: "state_invalid" }
    albumIds[album.id] = true
    albumUrls[album.url] = true
  }

  var playlistIds = {}
  var playlistNames = {}
  for (var j = 0; j < data.playlists.length; j++) {
    var playlist = data.playlists[j]
    if (!isRecord(playlist) || !validString(playlist.id, 100) || !playlist.id ||
        !validString(playlist.name, 100) ||
        !Array.isArray(playlist.tracks) || playlist.tracks.length > MAX_TRACKS_PER_PLAYLIST ||
        playlistNameError(playlist.name, [], "") !== "" ||
        !validPlaylistMetadata(playlist) ||
        !playlist.tracks.every(validPlaylistTrack)) {
      return { ok: false, error: "state_invalid" }
    }
    var foldedName = playlistKind(playlist) + ":" + playlist.name.toLowerCase()
    if (playlistIds[playlist.id] || playlistNames[foldedName]) return { ok: false, error: "state_invalid" }
    playlistIds[playlist.id] = true
    playlistNames[foldedName] = true

    var trackUrls = {}
    for (var k = 0; k < playlist.tracks.length; k++) {
      var trackKey = playlist.tracks[k].trackUrl || playlist.tracks[k].localId
      if (trackUrls[trackKey]) return { ok: false, error: "state_invalid" }
      trackUrls[trackKey] = true
    }
  }
  return {
    ok: true,
    state: {
      schemaVersion: SCHEMA_VERSION,
      albumQueue: data.albumQueue.map(function(album) {
        if (album.status !== "inspecting" && album.status !== "downloading") return album
        return Object.assign({}, album, { status: album.tracks && album.tracks.length ? "ready" : "queued" })
      }),
      playlists: data.playlists,
      settings: data.settings || emptyState().settings
    }
  }
}

function addAlbum(state, input, id, addedAt) {
  var url = normalizeAlbumUrl(input)
  if (!url) return { ok: false, error: "album_url_invalid" }
  if (state.albumQueue.some(function(album) { return album.url === url }))
    return { ok: false, error: "album_duplicate" }
  if (state.albumQueue.length >= MAX_ALBUMS) return { ok: false, error: "album_queue_full" }
  var next = state.albumQueue.slice()
  next.push({
    id: id || makeId("album"),
    url: url,
    title: "",
    addedAt: addedAt || new Date().toISOString(),
    status: "queued"
  })
  return { ok: true, state: stateWith(state, next, state.playlists.slice()) }
}

function removeAlbum(state, id) {
  var next = state.albumQueue.filter(function(album) { return album.id !== id })
  return stateWith(state, next, state.playlists.slice())
}

function moveAlbum(state, id, offset) {
  var next = state.albumQueue.slice()
  var from = next.findIndex(function(album) { return album.id === id })
  if (from < 0) return state
  var to = Math.max(0, Math.min(next.length - 1, from + offset))
  if (to === from) return state
  var item = next.splice(from, 1)[0]
  next.splice(to, 0, item)
  return stateWith(state, next, state.playlists.slice())
}

function updateAlbum(state, id, patch) {
  var index = state.albumQueue.findIndex(function(album) { return album.id === id })
  if (index < 0) return { ok: false, error: "album_not_found" }
  var albums = state.albumQueue.slice()
  var album = Object.assign({}, albums[index], patch)
  if (!validAlbum(album)) return { ok: false, error: "inspection_invalid" }
  albums[index] = album
  return { ok: true, state: stateWith(state, albums, state.playlists.slice()) }
}

function applyInspection(state, album) {
  if (!isRecord(album) || normalizeAlbumUrl(album.url) !== album.url ||
      !validString(album.title, 500) || !album.title ||
      !Array.isArray(album.tracks) || !album.tracks.length || album.tracks.length > 1000)
    return { ok: false, error: "inspection_invalid" }
  var current = state.albumQueue.find(function(item) { return item.url === album.url })
  if (!current) {
    var added = addAlbum(state, album.url)
    if (!added.ok) return added
    state = added.state
    current = state.albumQueue[state.albumQueue.length - 1]
  }
  var result = updateAlbum(state, current.id, {
    title: album.title, tracks: album.tracks, status: "ready", error: ""
  })
  if (result.ok && state.playlists.some(function(playlist) {
    return playlist.kind === "online" && playlist.sourceAlbumUrl === album.url
  })) return saveOnlineAlbum(result.state, current.id)
  return result
}

function saveOnlineAlbum(state, id, when) {
  var album = state.albumQueue.find(function(item) { return item.id === id })
  if (!album) return { ok: false, error: "album_not_found" }
  if (!album.tracks || !album.tracks.length || album.status === "inspecting")
    return { ok: false, error: "online_needs_inspection" }
  var format = albumFormats(album)[0]
  if (!format) return { ok: false, error: "online_format_unavailable" }
  var playlists = state.playlists.slice()
  var index = playlists.findIndex(function(playlist) {
    return playlist.kind === "online" && playlist.sourceAlbumUrl === album.url
  })
  var previous = index >= 0 ? playlists[index] : null
  if (!previous && playlists.length >= MAX_PLAYLISTS) return { ok: false, error: "playlist_limit" }
  var timestamp = when || new Date().toISOString()
  var tracks = album.tracks.map(function(track) {
    var existing = previous && previous.tracks.find(function(item) { return item.trackUrl === track.trackUrl })
    return {
      id: existing ? existing.id : makeId("track"), trackUrl: track.trackUrl, albumUrl: album.url,
      title: track.title, albumTitle: album.title, addedAt: existing ? existing.addedAt : timestamp,
      streamUrl: track.audioLinks.find(function(link) { return link.format === format }).url, format: format
    }
  })
  if (!tracks.every(validPlaylistTrack)) return { ok: false, error: "inspection_invalid" }
  var playlist = {
    id: previous ? previous.id : makeId("playlist"), kind: "online",
    name: previous ? previous.name : albumPlaylistName(album.title, playlists, "online"),
    addedAt: previous ? previous.addedAt : timestamp,
    tracks: tracks, sourceAlbumUrl: album.url, updatedAt: timestamp
  }
  if (previous) playlists[index] = playlist
  else playlists.push(playlist)
  return { ok: true, playlistId: playlist.id, state: stateWith(state, state.albumQueue.slice(), playlists) }
}

function updateSettings(state, settings) {
  if (!isRecord(settings)) return { ok: false, error: "settings_invalid" }
  var next = Object.assign({}, state.settings, settings)
  if (!validSettings(next)) return { ok: false, error: "settings_invalid" }
  return { ok: true, state: {
    schemaVersion: SCHEMA_VERSION, albumQueue: state.albumQueue.slice(),
    playlists: state.playlists.slice(), settings: next
  } }
}

function fitPanelHeight(height, minimum, maximum) {
  return Math.max(1, Math.min(Math.floor(maximum), Math.max(Math.round(minimum), Math.round(height))))
}

function albumFormats(album) {
  if (!album.tracks || !album.tracks.length) return []
  return ["mp3", "flac"].filter(function(format) {
    return album.tracks.every(function(track) {
      return track.audioLinks.some(function(link) { return link.format === format })
    })
  })
}

function albumDownloadFormat(album, preferred) {
  var formats = albumFormats(album)
  if (formats.indexOf(preferred) >= 0) return preferred
  return formats.indexOf("mp3") >= 0 ? "mp3" : ""
}

function readyAlbums(state) {
  return state.albumQueue.filter(function(album) {
    return album.status !== "inspecting" && album.status !== "downloading" &&
      !!albumDownloadFormat(album, state.settings.format)
  })
}

function librarySection(playlist) {
  return playlistKind(playlist) === "online" ? "online" : playlist.downloadDirectory ? "downloaded" : "custom"
}

function libraryAlbums(playlists, section, query) {
  var needle = String(query || "").trim().toLowerCase()
  return playlists.filter(function(playlist) {
    return librarySection(playlist) === section && (!needle || playlist.name.toLowerCase().indexOf(needle) >= 0)
  })
}

function playlistTrackRows(playlist, query) {
  var needle = String(query || "").trim().toLowerCase()
  var previousDisc = ""
  if (!playlist) return []
  return playlist.tracks.reduce(function(rows, track, index) {
    if (needle && track.title.toLowerCase().indexOf(needle) < 0) return rows
    var relative = playlist.discCount && track.localPath &&
      track.localPath.indexOf(playlist.downloadDirectory + "/") === 0
      ? track.localPath.slice(playlist.downloadDirectory.length + 1) : ""
    var match = /^(?:cd|disc|disk)[ _-]*(\d+)\//i.exec(relative)
    var disc = match ? Number(match[1]) : 0
    rows.push({ track: track, index: index, disc: disc, heading: disc > 0 && disc !== previousDisc })
    previousDisc = disc
    return rows
  }, [])
}

function downloadPlan(state, readyOnly) {
  if (!state.albumQueue.length) return { ok: false, error: "batch_empty" }
  var albums = readyOnly ? readyAlbums(state) : state.albumQueue
  if (!albums.length) return { ok: false, error: "batch_none_ready" }
  var neededPlaylists = 0
  for (var i = 0; i < albums.length; i++) {
    var album = albums[i]
    if (!album.tracks || !album.tracks.length || album.status === "inspecting")
      return { ok: false, error: "batch_needs_inspection", albumId: album.id }
    var format = albumDownloadFormat(album, state.settings.format)
    if (!format) return { ok: false, error: "batch_format_unavailable", albumId: album.id }
    if (!state.playlists.some(function(playlist) {
      return playlist.sourceAlbumUrl === album.url && playlist.downloadFormat === format
    })) neededPlaylists++
  }
  if (state.playlists.length + neededPlaylists > MAX_PLAYLISTS)
    return { ok: false, error: "playlist_limit" }
  return { ok: true, ids: albums.map(function(album) { return album.id }) }
}

function completeAlbumDownload(state, id, downloaded, when) {
  var album = state.albumQueue.find(function(item) { return item.id === id })
  if (!album) return { ok: false, error: "album_not_found" }
  if (!album.tracks || !album.tracks.length || !isRecord(downloaded) ||
      !validLocalPath(downloaded.directory) || !Array.isArray(downloaded.files) ||
      downloaded.completed !== album.tracks.length || downloaded.files.length !== album.tracks.length)
    return { ok: false, error: "download_result_invalid" }
  var timestamp = when || new Date().toISOString()
  var tracks = []
  var format = ""
  var paths = {}
  for (var i = 0; i < album.tracks.length; i++) {
    var source = album.tracks[i]
    var file = downloaded.files[i]
    if (!isRecord(file) || file.trackUrl !== source.trackUrl ||
        ["mp3", "flac"].indexOf(file.format) < 0 ||
        !source.audioLinks.some(function(link) { return link.format === file.format }) ||
        !validLocalPath(file.path) || file.path.indexOf(downloaded.directory + "/") !== 0 ||
        file.path.slice(downloaded.directory.length + 1).indexOf("/") >= 0 ||
        !file.path.endsWith("." + file.format) || paths[file.path] ||
        (format && format !== file.format))
      return { ok: false, error: "download_result_invalid" }
    format = file.format
    paths[file.path] = true
    tracks.push({
      id: makeId("track"), trackUrl: source.trackUrl, albumUrl: album.url,
      title: source.title, albumTitle: album.title, addedAt: timestamp,
      localPath: file.path, format: file.format
    })
  }
  if (!tracks.every(validPlaylistTrack)) return { ok: false, error: "download_result_invalid" }
  var playlists = state.playlists.slice()
  var index = playlists.findIndex(function(playlist) {
    return playlist.sourceAlbumUrl === album.url && playlist.downloadFormat === format
  })
  var previous = index >= 0 ? playlists[index] : null
  if (!previous && playlists.length >= MAX_PLAYLISTS) return { ok: false, error: "playlist_limit" }
  if (previous) {
    tracks = tracks.concat(previous.tracks.filter(function(track) {
      return !tracks.some(function(source) {
        return source.trackUrl === track.trackUrl ||
          (track.localId && source.localPath.split("/").pop() === track.localPath.split("/").pop())
      })
    }))
    if (tracks.length > MAX_TRACKS_PER_PLAYLIST) return { ok: false, error: "playlist_full" }
  }
  var playlist = Object.assign({}, previous || {}, {
    id: previous ? previous.id : makeId("playlist"),
    name: previous ? previous.name : albumPlaylistName(album.title, playlists, "downloaded"),
    addedAt: previous ? previous.addedAt : timestamp,
    tracks: tracks, sourceAlbumUrl: album.url, downloadFormat: format,
    downloadDirectory: downloaded.directory, downloadedAt: timestamp, folderMissing: false
  })
  delete playlist.discCount
  if (previous) playlists[index] = playlist
  else playlists.push(playlist)
  return {
    ok: true, playlistId: playlist.id,
    state: stateWith(state, state.albumQueue.filter(function(item) { return item.id !== id }), playlists)
  }
}

function createPlaylist(state, input, id, addedAt) {
  var name = normalizePlaylistName(input)
  var error = playlistNameError(name, state.playlists, "")
  if (error) return { ok: false, error: error }
  if (state.playlists.length >= MAX_PLAYLISTS) return { ok: false, error: "playlist_limit" }
  var playlists = state.playlists.slice()
  playlists.push({
    id: id || makeId("playlist"),
    name: name,
    addedAt: addedAt || new Date().toISOString(),
    tracks: []
  })
  return { ok: true, state: stateWith(state, state.albumQueue.slice(), playlists) }
}

function importLocalAlbumResults(state, albums) {
  if (!Array.isArray(albums) || albums.length > MAX_PLAYLISTS)
    return { ok: false, error: "library_import_invalid" }
  var next = state
  var accepted = []
  var errors = []
  var replacements = []
  for (var i = 0; i < albums.length; i++) {
    var result = importLocalAlbums(next, [albums[i]])
    if (result.ok) {
      next = result.state
      accepted.push({ libraryId: albums[i].libraryId, directory: albums[i].directory })
      replacements = replacements.concat(result.replacements)
    } else {
      errors.push({ directory: isRecord(albums[i]) && validLocalPath(albums[i].directory)
        ? albums[i].directory : "", error: result.error })
    }
  }
  return { ok: true, state: next, accepted: accepted, errors: errors, replacements: replacements }
}

function updatePlaylistLocations(state, locations) {
  if (!Array.isArray(locations) || locations.length > MAX_PLAYLISTS || !locations.every(function(location) {
    return isRecord(location) && validString(location.id, 100) && location.id.length > 0 &&
      validLocalPath(location.directory) && typeof location.missing === "boolean"
  })) return { ok: false, error: "library_import_invalid" }
  var playlists = state.playlists.map(function(playlist) {
    var location = locations.find(function(item) {
      return playlistKind(playlist) === "downloaded" && item.id === playlist.id &&
        item.directory === playlist.downloadDirectory
    })
    return location ? Object.assign({}, playlist, { folderMissing: location.missing }) : playlist
  })
  return { ok: true, state: stateWith(state, state.albumQueue.slice(), playlists) }
}

function validLibraryId(value) {
  return typeof value === "string" && /^(kh|local)-[a-f0-9]{64}$/.test(value)
}

function importLocalAlbums(state, albums, when) {
  if (!Array.isArray(albums) || albums.length > MAX_PLAYLISTS)
    return { ok: false, error: "library_import_invalid" }
  var playlists = state.playlists.slice()
  var timestamp = when || new Date().toISOString()
  var replacements = []
  var lastPlaylistId = ""
  for (var a = 0; a < albums.length; a++) {
    var album = albums[a]
    if (!isRecord(album) || !validLibraryId(album.libraryId) || !validString(album.title, 500) ||
        !album.title || !validLocalPath(album.directory) ||
        (album.albumUrl !== undefined && normalizeAlbumUrl(album.albumUrl) !== album.albumUrl) ||
        !Array.isArray(album.tracks) || !album.tracks.length || album.tracks.length > 1000)
      return { ok: false, error: "library_import_invalid" }
    if (album.discs !== undefined) {
      var discPaths = {}
      var discIds = {}
      if (!Array.isArray(album.discs) || album.discs.length < 2 || album.discs.length > 100 ||
          !album.discs.every(function(disc) {
            if (!isRecord(disc) || !validRelativePath(disc.path) || disc.path.indexOf("/") >= 0 ||
                !validLibraryId(disc.libraryId) || discPaths[disc.path] || discIds[disc.libraryId]) return false
            discPaths[disc.path] = true
            discIds[disc.libraryId] = true
            return album.tracks.some(function(track) {
              return isRecord(track) && typeof track.path === "string" && track.path.indexOf(disc.path + "/") === 0
            })
          })) return { ok: false, error: "library_import_invalid" }
    }
    var paths = {}
    var sources = {}
    var tracks = []
    var format = album.tracks[0].format
    for (var t = 0; t < album.tracks.length; t++) {
      var source = album.tracks[t]
      if (!isRecord(source) || !validRelativePath(source.path) ||
          (album.discs && !discPaths[source.path.split("/")[0]]) ||
          !validString(source.title, 500) || !source.title ||
          !/^(mp3|flac|ogg|opus|m4a|aac|wav|wma|alac)$/.test(source.format) ||
          !source.path.toLowerCase().endsWith("." + source.format) || paths[source.path] ||
          typeof source.bytes !== "number" || !isFinite(source.bytes) ||
          Math.floor(source.bytes) !== source.bytes || source.bytes <= 0 || source.bytes > 2147483648 ||
          !/^[a-f0-9]{64}$/.test(source.sha256))
        return { ok: false, error: "library_import_invalid" }
      paths[source.path] = true
      if (source.format !== format) format = "mixed"
      var track = {
        id: makeId("track"), title: source.title, albumTitle: album.title, addedAt: timestamp,
        localPath: album.directory.replace(/\/$/, "") + "/" + source.path, format: source.format,
        localId: album.libraryId + ":" + t
      }
      if (album.albumUrl && source.trackUrl !== undefined) {
        if (sources[source.trackUrl]) return { ok: false, error: "library_import_invalid" }
        sources[source.trackUrl] = true
        track.trackUrl = source.trackUrl
        track.albumUrl = album.albumUrl
      }
      if (!validPlaylistTrack(track)) return { ok: false, error: "library_import_invalid" }
      tracks.push(track)
    }
    var index = playlists.findIndex(function(item) {
      return playlistKind(item) === "downloaded" && (item.libraryId === album.libraryId ||
        (album.albumUrl && item.sourceAlbumUrl === album.albumUrl && item.downloadFormat === format))
    })
    var own = index >= 0 ? playlists[index] : null
    var members = album.discs ? album.discs.reduce(function(found, disc) {
      return found.concat(playlists.filter(function(item) {
        return playlistKind(item) === "downloaded" && item.libraryId === disc.libraryId &&
          item.downloadFormat === format
      }))
    }, []) : []
    var previous = own || (members.length ? members[0] : null)
    if (!previous && playlists.length >= MAX_PLAYLISTS) return { ok: false, error: "playlist_limit" }
    var pool = (previous ? [previous] : []).concat(members.filter(function(item) { return item !== previous }))
    var poolTracks = pool.reduce(function(found, item) { return found.concat(item.tracks) }, [])
    function sameTrack(item, track, relative) {
      return (track.trackUrl && item.trackUrl === track.trackUrl) || item.localId === track.localId ||
        item.localPath === track.localPath ||
        (album.discs && typeof item.localPath === "string" && item.localPath.endsWith("/" + relative))
    }
    if (previous) {
      tracks = tracks.map(function(track, trackIndex) {
        var old = poolTracks.find(function(item) { return sameTrack(item, track, album.tracks[trackIndex].path) })
        return old ? Object.assign({}, track, { id: old.id, addedAt: old.addedAt }) : track
      })
      var extras = poolTracks.filter(function(track) {
        return !tracks.some(function(item, trackIndex) {
          return sameTrack(track, item, album.tracks[trackIndex].path)
        })
      })
      extras.forEach(function(track) {
        if (!tracks.some(function(item) {
          return item.id === track.id || (track.trackUrl && item.trackUrl === track.trackUrl) ||
            (track.localId && item.localId === track.localId)
        })) tracks.push(track)
      })
    }
    if (tracks.length > MAX_TRACKS_PER_PLAYLIST) return { ok: false, error: "playlist_full" }
    var playlist = Object.assign({}, previous || {}, {
      id: previous ? previous.id : makeId("playlist"),
      name: previous ? previous.name : albumPlaylistName(album.title, playlists, "downloaded"),
      addedAt: previous ? previous.addedAt : timestamp,
      tracks: tracks, libraryId: album.libraryId, downloadDirectory: album.directory,
      downloadFormat: format, downloadedAt: previous ? previous.downloadedAt || timestamp : timestamp,
      folderMissing: false
    })
    if (album.albumUrl) playlist.sourceAlbumUrl = album.albumUrl
    else if (album.discs && !own) delete playlist.sourceAlbumUrl
    if (album.discs) playlist.discCount = album.discs.length
    else delete playlist.discCount
    playlists = playlists.filter(function(item) {
      if (item.id === playlist.id || !members.some(function(member) { return member.id === item.id })) return true
      replacements.push({ from: item.id, to: playlist.id })
      return false
    })
    index = playlists.findIndex(function(item) { return item.id === playlist.id })
    if (index >= 0) playlists[index] = playlist
    else playlists.push(playlist)
    lastPlaylistId = playlist.id
  }
  return { ok: true, state: stateWith(state, state.albumQueue.slice(), playlists),
    replacements: replacements, playlistId: lastPlaylistId }
}

function relinkLocalAlbum(state, id, album) {
  var previous = state.playlists.find(function(item) { return item.id === id })
  if (!previous || playlistKind(previous) !== "downloaded" || !previous.downloadDirectory)
    return { ok: false, error: "playlist_not_found" }
  if (!isRecord(album) || (previous.sourceAlbumUrl && album.albumUrl &&
      previous.sourceAlbumUrl !== album.albumUrl))
    return { ok: false, error: "library_relink_invalid" }
  if (album.previousLibraryId !== undefined && !validLibraryId(album.previousLibraryId))
    return { ok: false, error: "library_relink_invalid" }
  var copies = state.playlists.filter(function(item) {
    return item.id !== id && playlistKind(item) === "downloaded" &&
      item.downloadDirectory === album.directory && item.downloadFormat === previous.downloadFormat &&
      (!item.sourceAlbumUrl || !album.albumUrl || item.sourceAlbumUrl === album.albumUrl)
  })
  var withoutPrevious = stateWith(state, state.albumQueue.slice(), state.playlists.filter(function(item) {
    return item.id !== id && !copies.slice(1).some(function(copy) { return copy.id === item.id })
  }).map(function(item) {
    return copies.length && item.id === copies[0].id
      ? Object.assign({}, item, { libraryId: album.libraryId }) : item
  }))
  var imported = importLocalAlbums(withoutPrevious, [album])
  if (!imported.ok) return imported
  var replacement = imported.state.playlists.find(function(item) { return item.id === imported.playlistId })
  if (replacement.downloadFormat !== previous.downloadFormat)
    return { ok: false, error: "library_relink_invalid" }
  var linked = Object.assign({}, replacement, { id: previous.id, name: previous.name, addedAt: previous.addedAt })
  if (!album.albumUrl && previous.sourceAlbumUrl) linked.sourceAlbumUrl = previous.sourceAlbumUrl
  var extras = [previous].concat(copies).reduce(function(found, item) { return found.concat(item.tracks) }, [])
  extras.forEach(function(track) {
    if (previous.sourceAlbumUrl && track.albumUrl && track.albumUrl !== previous.sourceAlbumUrl &&
        !linked.tracks.some(function(item) { return item.trackUrl === track.trackUrl }))
      linked.tracks = linked.tracks.concat([track])
  })
  if (linked.tracks.length > MAX_TRACKS_PER_PLAYLIST) return { ok: false, error: "playlist_full" }
  var playlists = imported.state.playlists.map(function(item) {
    return item.id === replacement.id ? linked : item
  })
  var replacements = imported.replacements.map(function(item) {
    return { from: item.from, to: item.to === replacement.id ? linked.id : item.to }
  })
  if (replacement.id !== linked.id) replacements.push({ from: replacement.id, to: linked.id })
  copies.forEach(function(copy) {
    if (copy.id !== replacement.id) replacements.push({ from: copy.id, to: linked.id })
  })
  return { ok: true, state: stateWith(state, state.albumQueue.slice(), playlists),
    playlistId: linked.id, replacements: replacements,
    accepted: [{ libraryId: album.libraryId, previousLibraryId: album.previousLibraryId,
      directory: album.directory, relinked: true, format: replacement.downloadFormat }], errors: [] }
}

function renamePlaylist(state, id, input) {
  var index = state.playlists.findIndex(function(playlist) { return playlist.id === id })
  if (index < 0) return { ok: false, error: "playlist_not_found" }
  var name = normalizePlaylistName(input)
  var error = playlistNameError(name, state.playlists, id, playlistKind(state.playlists[index]))
  if (error) return { ok: false, error: error }
  var playlists = state.playlists.slice()
  var current = playlists[index]
  playlists[index] = Object.assign({}, current, {
    name: name,
    tracks: current.tracks.slice()
  })
  return { ok: true, state: stateWith(state, state.albumQueue.slice(), playlists) }
}

function removePlaylist(state, id) {
  return stateWith(state, state.albumQueue.slice(),
    state.playlists.filter(function(playlist) { return playlist.id !== id }))
}

function addTrack(state, playlistId, source) {
  if (!isRecord(source)) return { ok: false, error: "track_invalid" }
  var trackUrl = normalizeTrackUrl(source.trackUrl)
  var albumUrl = normalizeAlbumUrl(source.albumUrl)
  var title = String(source.title || "").trim()
  var albumTitle = String(source.albumTitle || "").trim()
  if (!trackUrl || !albumUrl || albumUrlForTrack(trackUrl) !== albumUrl ||
      !title || !albumTitle || title.length > 500 || albumTitle.length > 500)
    return { ok: false, error: "track_invalid" }
  var playlistIndex = state.playlists.findIndex(function(playlist) { return playlist.id === playlistId })
  if (playlistIndex < 0) return { ok: false, error: "playlist_not_found" }
  var playlist = state.playlists[playlistIndex]
  if (playlist.kind === "online") return { ok: false, error: "track_invalid" }
  if (playlist.tracks.some(function(track) { return track.trackUrl === trackUrl }))
    return { ok: false, error: "track_duplicate" }
  if (playlist.tracks.length >= MAX_TRACKS_PER_PLAYLIST) return { ok: false, error: "playlist_full" }
  var playlists = state.playlists.slice()
  var tracks = playlist.tracks.slice()
  tracks.push({
    id: makeId("track"),
    trackUrl: trackUrl,
    albumUrl: albumUrl,
    title: title,
    albumTitle: albumTitle,
    addedAt: new Date().toISOString()
  })
  playlists[playlistIndex] = Object.assign({}, playlist, { tracks: tracks })
  return { ok: true, state: stateWith(state, state.albumQueue.slice(), playlists) }
}
