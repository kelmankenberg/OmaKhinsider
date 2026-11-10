import QtQuick 2.15
import QtTest 1.3
import "../Model.js" as Model

TestCase {
  name: "OmaKhinsiderModel"

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
}
