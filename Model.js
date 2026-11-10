.pragma library

var SCHEMA_VERSION = 1
var MAX_ALBUMS = 100
var MAX_PLAYLISTS = 200
var MAX_TRACKS_PER_PLAYLIST = 2000
var QUEUE_STATUSES = ["queued", "inspecting", "ready", "downloading", "complete", "failed", "canceled"]

function emptyState() {
  return { schemaVersion: SCHEMA_VERSION, albumQueue: [], playlists: [] }
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
  var value = String(input || "").trim()
  var match = /^https:\/\/downloads\.khinsider\.com\/game-soundtracks\/album\/([^/?#]+)\/([^/?#]+)\/?$/i.exec(value)
  if (!match || match[1] === "." || match[1] === ".." || match[2] === "." || match[2] === "..") return ""
  return "https://downloads.khinsider.com/game-soundtracks/album/" + match[1] + "/" + match[2]
}

function albumUrlForTrack(trackUrl) {
  var match = /^https:\/\/downloads\.khinsider\.com\/game-soundtracks\/album\/([^/]+)\//.exec(trackUrl)
  return match ? "https://downloads.khinsider.com/game-soundtracks/album/" + match[1] : ""
}

function normalizePlaylistName(input) {
  return String(input || "").replace(/\s+/g, " ").trim()
}

function playlistNameError(name, playlists, ignoreId) {
  var normalized = normalizePlaylistName(name)
  if (!normalized) return "playlist_name_empty"
  if (normalized.length > 100) return "playlist_name_too_long"
  if (/[\u0000-\u001f\u007f<>:"/\\|?*]/.test(normalized)) return "playlist_name_invalid"
  for (var i = 0; i < playlists.length; i++) {
    if (playlists[i].id !== ignoreId && playlists[i].name.toLowerCase() === normalized.toLowerCase())
      return "playlist_name_duplicate"
  }
  return ""
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
    QUEUE_STATUSES.indexOf(entry.status) >= 0
}

function validPlaylistTrack(entry) {
  return isRecord(entry) &&
    validString(entry.id, 100) && entry.id.length > 0 &&
    normalizeTrackUrl(entry.trackUrl) === entry.trackUrl &&
    normalizeAlbumUrl(entry.albumUrl) === entry.albumUrl &&
    albumUrlForTrack(entry.trackUrl) === entry.albumUrl &&
    validString(entry.title, 500) &&
    validString(entry.albumTitle, 500) &&
    validString(entry.addedAt, 64) && entry.addedAt.length > 0
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
        !playlist.tracks.every(validPlaylistTrack)) {
      return { ok: false, error: "state_invalid" }
    }
    var foldedName = playlist.name.toLowerCase()
    if (playlistIds[playlist.id] || playlistNames[foldedName]) return { ok: false, error: "state_invalid" }
    playlistIds[playlist.id] = true
    playlistNames[foldedName] = true

    var trackUrls = {}
    for (var k = 0; k < playlist.tracks.length; k++) {
      if (trackUrls[playlist.tracks[k].trackUrl]) return { ok: false, error: "state_invalid" }
      trackUrls[playlist.tracks[k].trackUrl] = true
    }
  }
  return {
    ok: true,
    state: {
      schemaVersion: SCHEMA_VERSION,
      albumQueue: data.albumQueue,
      playlists: data.playlists
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
  return { ok: true, state: { schemaVersion: SCHEMA_VERSION, albumQueue: next, playlists: state.playlists.slice() } }
}

function removeAlbum(state, id) {
  var next = state.albumQueue.filter(function(album) { return album.id !== id })
  return { schemaVersion: SCHEMA_VERSION, albumQueue: next, playlists: state.playlists.slice() }
}

function moveAlbum(state, id, offset) {
  var next = state.albumQueue.slice()
  var from = next.findIndex(function(album) { return album.id === id })
  if (from < 0) return state
  var to = Math.max(0, Math.min(next.length - 1, from + offset))
  if (to === from) return state
  var item = next.splice(from, 1)[0]
  next.splice(to, 0, item)
  return { schemaVersion: SCHEMA_VERSION, albumQueue: next, playlists: state.playlists.slice() }
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
  return { ok: true, state: { schemaVersion: SCHEMA_VERSION, albumQueue: state.albumQueue.slice(), playlists: playlists } }
}

function renamePlaylist(state, id, input) {
  var index = state.playlists.findIndex(function(playlist) { return playlist.id === id })
  if (index < 0) return { ok: false, error: "playlist_not_found" }
  var name = normalizePlaylistName(input)
  var error = playlistNameError(name, state.playlists, id)
  if (error) return { ok: false, error: error }
  var playlists = state.playlists.slice()
  var current = playlists[index]
  playlists[index] = {
    id: current.id,
    name: name,
    addedAt: current.addedAt,
    tracks: current.tracks.slice()
  }
  return { ok: true, state: { schemaVersion: SCHEMA_VERSION, albumQueue: state.albumQueue.slice(), playlists: playlists } }
}

function removePlaylist(state, id) {
  return {
    schemaVersion: SCHEMA_VERSION,
    albumQueue: state.albumQueue.slice(),
    playlists: state.playlists.filter(function(playlist) { return playlist.id !== id })
  }
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
  playlists[playlistIndex] = { id: playlist.id, name: playlist.name, addedAt: playlist.addedAt, tracks: tracks }
  return { ok: true, state: { schemaVersion: SCHEMA_VERSION, albumQueue: state.albumQueue.slice(), playlists: playlists } }
}
