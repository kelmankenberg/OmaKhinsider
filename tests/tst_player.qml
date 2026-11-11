import QtQuick
import QtTest
import "../" as Plugin

TestCase {
  name: "OmaKhinsiderPlayback"
  property string fixtureDirectory: decodeURIComponent(String(Qt.resolvedUrl("../")).replace(/^file:\/\//, ""))

  Plugin.AudioPlayer { id: player; muted: true }

  function playlist(short, count) {
    var tracks = []
    for (var i = 0; i < (count || 2); i++)
      tracks.push({ title: "Track " + i, localPath: fixtureDirectory + (short ? "short.wav" : "tone #%.wav") })
    return { id: "playlist", name: "Test playlist", tracks: tracks }
  }

  function init() {
    player.clear()
    player.repeatMode = "off"
    player.shuffle = false
  }

  function cleanup() {
    player.clear()
  }

  function test_localPlaybackPauseSeekResumeAndStop() {
    verify(player.playPlaylist(playlist(false)))
    tryCompare(player, "playing", true)
    tryCompare(player, "seekable", true)
    verify(player.duration > 0)
    player.toggle()
    tryCompare(player, "playing", false)
    player.seek(750)
    tryVerify(function() { return Math.abs(player.position - 750) < 100 })
    player.toggle()
    tryCompare(player, "playing", true)
    player.stop()
    compare(player.playing, false)
    compare(player.position, 0)
    wait(250)
    compare(player.trackIndex, 0)
  }

  function test_automaticAdvanceStopsAtPlaylistEnd() {
    player.playPlaylist(playlist(true))
    tryCompare(player, "trackIndex", 1)
    tryCompare(player, "playbackRequested", false)
    compare(player.playing, false)
    compare(player.errorKey, "")
    compare(player.trackIndex, 1)
  }

  function test_repeatOneLoopsButManualNextStillAdvances() {
    player.repeatMode = "one"
    player.playPlaylist(playlist(true))
    tryCompare(player, "playing", true)
    wait(550)
    verify(player.playing)
    compare(player.trackIndex, 0)
    player.next(false)
    compare(player.trackIndex, 1)
    player.previous()
    compare(player.trackIndex, 0)
  }

  function test_repeatAllWrapsAtEndAndPreviousWraps() {
    player.repeatMode = "all"
    player.playPlaylist(playlist(true))
    tryCompare(player, "trackIndex", 1)
    tryCompare(player, "trackIndex", 0)
    player.previous()
    compare(player.trackIndex, 1)
    player.stop()
    wait(250)
    compare(player.trackIndex, 1)
  }

  function test_shuffleVisitsEachTrackOnceAndRestoresTrackOrder() {
    player.shuffle = true
    player.playPlaylist(playlist(false, 4), 2)
    compare(player.trackIndex, 2)
    compare(player.order.length, 4)
    var visited = [player.trackIndex]
    while (player.canNext) {
      player.next(false)
      verify(visited.indexOf(player.trackIndex) < 0)
      visited.push(player.trackIndex)
    }
    compare(visited.length, 4)
    var current = player.trackIndex
    player.shuffle = false
    compare(player.trackIndex, current)
    compare(player.order, [0, 1, 2, 3])
  }

  function test_undownloadedAndRemoteTracksAreRejected() {
    var source = playlist(false)
    source.tracks[0].localPath = undefined
    verify(!player.playPlaylist(source))
    compare(player.errorKey, "not_downloaded")
    source.tracks[0].localPath = "https://example.invalid/audio.mp3"
    verify(!player.playPlaylist(source))
    compare(player.playing, false)
  }

  function test_relocatedLocalPlaylistUpdatesNextTrackWithoutRestartingCurrent() {
    var source = playlist(false)
    source.tracks.forEach(function(track, index) { track.localId = "local-key:" + index })
    verify(player.playPlaylist(source))
    tryCompare(player, "playing", true)
    player.seek(750)
    tryVerify(function() { return player.position >= 700 })
    var moved = JSON.parse(JSON.stringify(source))
    moved.tracks[1].localPath = fixtureDirectory + "short.wav"
    player.syncPlaylist(moved)
    compare(player.tracks[1].localPath, moved.tracks[1].localPath)
    verify(player.position >= 700)
    verify(player.playing)
    player.next(false)
    tryVerify(function() { return player.duration > 0 && player.duration < 500 })
  }

  function test_groupingPlayingDiscKeepsCurrentTrackAndAdvancesIntoNextDisc() {
    var disc = playlist(false)
    disc.tracks.forEach(function(track, index) {
      track.id = "disc-two-" + index
      track.localId = "old-disc:" + index
    })
    verify(player.playPlaylist(disc))
    tryCompare(player, "playing", true)
    player.seek(750)
    tryVerify(function() { return player.position >= 700 })
    var grouped = JSON.parse(JSON.stringify(disc))
    grouped.tracks.unshift({ id: "disc-one", title: "Previous disc", localId: "group:0",
      localPath: fixtureDirectory + "short.wav" })
    grouped.tracks.forEach(function(track, index) { track.localId = "group:" + index })
    grouped.tracks.push({ id: "disc-three", title: "Next disc", localId: "group:3",
      localPath: fixtureDirectory + "short.wav" })
    player.syncPlaylist(grouped)
    compare(player.trackIndex, 1)
    verify(player.position >= 700)
    verify(player.playing)
    player.next(false)
    compare(player.trackIndex, 2)
    player.next(false)
    compare(player.trackIndex, 3)
    tryVerify(function() { return player.duration > 0 && player.duration < 500 })
  }

  function test_missingFileReportsErrorAndCanRecover() {
    var source = playlist(false)
    source.tracks[0].localPath = fixtureDirectory + "missing.wav"
    player.playPlaylist(source)
    tryCompare(player, "errorKey", "failed")
    verify(player.errorDetail.length > 0)
    verify(!player.playing)
    verify(!player.playbackRequested)
    player.playPlaylist(playlist(false))
    tryCompare(player, "playing", true)
    compare(player.errorKey, "")
    player.clear()
    compare(player.currentTrack, null)
    compare(player.playlistId, "")
    verify(!player.playing)
  }

  function test_onlinePlayerRejectsUntrustedAndMixedTrackSourcesWithoutConnecting() {
    var urls = [
      "http://kappa.vgmsite.com/test/01.mp3",
      "https://vgmsite.com.evil.test/01.mp3",
      "file:///tmp/track.mp3",
      "https://kappa.vgmsite.com/test/01.flac"
    ]
    for (var i = 0; i < urls.length; i++) {
      verify(!player.playPlaylist({ id: "online", name: "Online", kind: "online",
        tracks: [{ title: "Track", streamUrl: urls[i], format: "mp3" }] }))
      compare(player.errorKey, "online_invalid")
      verify(!player.playing)
    }
    verify(!player.playPlaylist({ id: "online", name: "Online", kind: "online",
      tracks: [{ title: "Track", streamUrl: "https://kappa.vgmsite.com/test/01.mp3",
        format: "mp3", localPath: fixtureDirectory + "tone #%.wav" }] }))
    compare(player.errorKey, "online_invalid")
  }
}
