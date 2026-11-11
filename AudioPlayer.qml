import QtQuick
import QtMultimedia
import "Model.js" as Model

Item {
  id: root

  property string playlistId: ""
  property string playlistName: ""
  property var tracks: []
  property var order: []
  property int cursor: -1
  property bool shuffle: false
  property string repeatMode: "off"
  property string errorKey: ""
  property string errorDetail: ""
  property bool playbackRequested: false
  property bool online: false
  property alias volume: output.volume
  property alias muted: output.muted
  readonly property int trackIndex: cursor >= 0 && cursor < order.length ? order[cursor] : -1
  readonly property var currentTrack: trackIndex >= 0 ? tracks[trackIndex] : null
  readonly property bool playing: media.playbackState === MediaPlayer.PlayingState
  readonly property int position: media.position
  readonly property int duration: media.duration
  readonly property bool seekable: media.seekable
  readonly property bool canPrevious: trackIndex >= 0
  readonly property bool canNext: cursor >= 0 && (cursor + 1 < order.length || repeatMode === "all")
  readonly property bool buffering: playbackRequested &&
    [MediaPlayer.LoadingMedia, MediaPlayer.BufferingMedia, MediaPlayer.StalledMedia].indexOf(media.mediaStatus) >= 0

  function localUrl(path) {
    return "file://" + path.split("/").map(function(part) { return encodeURIComponent(part) }).join("/")
  }

  function playPlaylist(playlist, index) {
    var streaming = playlist && playlist.kind === "online"
    if (!playlist || !playlist.tracks.length || !playlist.tracks.every(function(track) {
      return streaming ? Model.validStreamTrack(track)
        : track.streamUrl === undefined && typeof track.localPath === "string" && track.localPath.charAt(0) === "/"
    })) {
      root.errorKey = streaming ? "online_invalid" : "not_downloaded"
      root.errorDetail = ""
      return false
    }
    var start = index === undefined ? 0 : index
    if (start < 0 || start >= playlist.tracks.length) {
      root.errorKey = "not_downloaded"
      root.errorDetail = ""
      return false
    }
    root.stop()
    root.playlistId = playlist.id
    root.playlistName = playlist.name
    root.online = streaming
    root.tracks = playlist.tracks.slice()
    root.order = root.tracks.map(function(_track, i) { return i })
    root.cursor = start
    root.rebuildOrder()
    root.loadCurrent()
    return true
  }

  function syncPlaylist(playlist) {
    root.playlistName = playlist.name
    var current = root.currentTrack
    var index = playlist.tracks.findIndex(function(track) {
      return current && ((track.id && track.id === current.id) ||
        (current.trackUrl && track.trackUrl === current.trackUrl) ||
        (current.localId && track.localId === current.localId) ||
        (current.localPath && track.localPath === current.localPath))
    })
    if (index < 0) {
      root.clear()
      return
    }
    var sameOrder = playlist.tracks.length === root.tracks.length &&
      playlist.tracks.every(function(track, i) {
        return (track.id && track.id === root.tracks[i].id) ||
          (track.trackUrl && track.trackUrl === root.tracks[i].trackUrl) ||
          (track.localId && track.localId === root.tracks[i].localId)
      })
    root.tracks = playlist.tracks.slice()
    if (!sameOrder) {
      root.order = root.tracks.map(function(_track, i) { return i })
      root.cursor = index
      root.rebuildOrder()
    }
  }

  function rebuildOrder() {
    var current = root.trackIndex
    if (current < 0) return
    var next = root.tracks.map(function(_track, i) { return i })
    if (root.shuffle) {
      next.splice(current, 1)
      for (var i = next.length - 1; i > 0; i--) {
        var j = Math.floor(Math.random() * (i + 1))
        var item = next[i]
        next[i] = next[j]
        next[j] = item
      }
      next.unshift(current)
    }
    root.order = next
    root.cursor = next.indexOf(current)
  }

  function loadCurrent() {
    if (!root.currentTrack) return
    media.stop()
    media.source = ""
    root.errorKey = ""
    root.errorDetail = ""
    media.source = root.online ? root.currentTrack.streamUrl : root.localUrl(root.currentTrack.localPath)
    root.playbackRequested = true
    media.play()
  }

  function toggle() {
    if (!root.currentTrack) return
    if (root.playing) {
      media.pause()
    } else if (root.errorKey) {
      root.loadCurrent()
    } else {
      root.errorKey = ""
      root.errorDetail = ""
      root.playbackRequested = true
      media.play()
    }
  }

  function stop() {
    root.playbackRequested = false
    media.stop()
  }

  function clear() {
    root.stop()
    media.source = ""
    root.cursor = -1
    root.order = []
    root.tracks = []
    root.playlistId = ""
    root.playlistName = ""
    root.online = false
    root.errorKey = ""
    root.errorDetail = ""
  }

  function next(automatic) {
    if (!root.currentTrack) return
    if (automatic && root.repeatMode === "one") {
      media.position = 0
      media.play()
      return
    }
    if (root.cursor + 1 < root.order.length) root.cursor++
    else if (root.repeatMode === "all") root.cursor = 0
    else {
      root.stop()
      return
    }
    root.loadCurrent()
  }

  function previous() {
    if (!root.currentTrack) return
    if (media.position > 3000 || (root.cursor === 0 && root.repeatMode !== "all")) {
      root.seek(0)
      return
    }
    root.cursor = root.cursor > 0 ? root.cursor - 1 : root.order.length - 1
    root.loadCurrent()
  }

  function seek(value) {
    if (root.seekable) media.position = Math.max(0, Math.min(root.duration, value))
  }

  onShuffleChanged: root.rebuildOrder()

  AudioOutput {
    id: output
    volume: 0.7
  }

  MediaPlayer {
    id: media
    audioOutput: output
    onMediaStatusChanged: {
      if (media.mediaStatus !== MediaPlayer.EndOfMedia) return
      var source = String(media.source)
      Qt.callLater(function() {
        if (root.playbackRequested && media.mediaStatus === MediaPlayer.EndOfMedia &&
            String(media.source) === source) root.next(true)
      })
    }
    onErrorOccurred: function(_error, errorString) {
      root.stop()
      root.errorDetail = errorString
      root.errorKey = root.online ? "online_failed" : "failed"
      console.warn("OmaKhinsider playback:", errorString)
    }
  }
}
