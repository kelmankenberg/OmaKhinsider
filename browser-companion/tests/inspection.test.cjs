const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../extension/inspect.js"), "utf8");
const albumUrl = "https://downloads.khinsider.com/game-soundtracks/album/test";
const mediaUrl = "https://kappa.vgmsite.com/soundtracks/test/opening.mp3";
const anchor = (href, textContent) => ({ textContent, getAttribute: () => href });
const row = (links, number = "1.") => ({
  querySelectorAll: (selector) => selector === "td"
    ? number === null ? links.map((link) => ({ textContent: link.textContent })) : [{ textContent: number }]
    : links,
});

function inspector({ rows, advertised = 1, status = 200, media = mediaUrl, readyState = "complete" } = {}) {
  const progress = [];
  const requests = [];
  const listeners = new Map();
  const context = vm.createContext({
    URL, TextEncoder, TextDecoder, Uint8Array, AbortSignal,
    setTimeout, clearTimeout,
    location: { href: albumUrl },
    document: {
      readyState,
      title: "Test Album MP3 - Download Soundtracks",
      body: { textContent: `Number of Files: ${advertised}` },
      querySelectorAll: () => rows || [row([anchor(albumUrl + "/01.mp3", "Opening")])],
      addEventListener: (event, listener) => listeners.set(event, listener),
      removeEventListener: (event) => listeners.delete(event),
    },
    DOMParser: class {
      parseFromString() {
        return { querySelectorAll: () => [anchor(media, "Click here to download as MP3")] };
      }
    },
    fetch: async (url, options) => {
      requests.push({ url, options });
      return new Response("<html>track fixture</html>", {
        status, headers: { "content-type": "text/html" },
      });
    },
    chrome: { runtime: { sendMessage: async (message) => progress.push(message) } },
  });
  vm.runInContext(source, context);
  return {
    run: (expectedUrl) => {
      context.expectedUrl = expectedUrl;
      return vm.runInContext("inspectAlbumInPage(expectedUrl)", context);
    },
    finishLoading: () => {
      context.document.readyState = "complete";
      listeners.get("DOMContentLoaded")();
    },
    progress, requests,
  };
}

test("inspects numbered tracks, excludes cross-album links, and deduplicates formats", async () => {
  const fixture = inspector({ rows: [
    row([anchor("https://evil.test/01.mp3", "Wrong"), anchor(albumUrl + "/01.mp3", "Opening")]),
    row([anchor(albumUrl + "/01.mp3", "Duplicate")]),
  ] });
  const result = await fixture.run();
  assert.equal(result.title, "Test Album");
  assert.equal(result.tracks.length, 1);
  assert.equal(result.tracks[0].audioLinks[0].url, mediaUrl);
  assert.equal(fixture.progress[0].completed, 1);
  assert.equal(fixture.requests[0].options.credentials, "same-origin");
  assert.equal(fixture.requests[0].options.redirect, "error");
});

test("inspects unnumbered tracks in display order without including unrelated links", async () => {
  const fixture = inspector({ advertised: 2, rows: [
    { querySelectorAll: () => [] },
    row([anchor("https://downloads.khinsider.com/game-soundtracks/album/other/01.mp3", "Other album")], null),
    row([anchor(albumUrl + "/b.mp3", ""), anchor(albumUrl + "/b.mp3", "AC Town Exploration")], null),
    row([anchor(albumUrl + "/a.mp3", "Ada Conversation Begins")], null),
    row([anchor(albumUrl + "/b.mp3", "Duplicate")], null),
  ] });
  const result = await fixture.run();
  assert.deepEqual(Array.from(result.tracks, (track) => track.title), [
    "AC Town Exploration", "Ada Conversation Begins",
  ]);
  assert.deepEqual(fixture.requests.map((request) => request.url), [
    albumUrl + "/b.mp3", albumUrl + "/a.mp3",
  ]);
});

test("stops on an HTTP access error without reporting partial success", async () => {
  const fixture = inspector({ status: 403 });
  await assert.rejects(fixture.run(), /HTTP 403/);
  assert.equal(fixture.progress.length, 0);
});

test("rejects incomplete album lists and untrusted audio hosts", async () => {
  const incomplete = inspector({ advertised: 2 });
  await assert.rejects(incomplete.run(), /advertised track count/);
  assert.equal(incomplete.requests.length, 0);
  await assert.rejects(inspector({ media: "https://vgmsite.com.evil.test/01.mp3" }).run(), /No supported audio links/);
});

test("rejects a page that changed after inspection was requested", async () => {
  const fixture = inspector();
  await assert.rejects(fixture.run(albumUrl + "-previous"), /album tab changed/);
  assert.equal(fixture.requests.length, 0);
});

test("waits for the album document before looking for track rows", async () => {
  const fixture = inspector({ readyState: "loading" });
  const result = fixture.run(albumUrl);
  assert.equal(fixture.requests.length, 0);
  fixture.finishLoading();
  assert.equal((await result).tracks.length, 1);
});
