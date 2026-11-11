const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const firstUrl = "https://downloads.khinsider.com/game-soundtracks/album/first";
const secondUrl = "https://downloads.khinsider.com/game-soundtracks/album/second";
const extensionId = "test-extension";
const settle = () => new Promise((resolve) => setImmediate(resolve));

function event() {
  const listeners = new Set();
  return {
    addListener: (listener) => listeners.add(listener),
    removeListener: (listener) => listeners.delete(listener),
    emit: (...args) => [...listeners].map((listener) => listener(...args)),
  };
}

function background() {
  const messages = event();
  const updated = event();
  const removed = event();
  const nativeMessages = [];
  const scripts = [];
  const tab = { id: 1, url: firstUrl };
  const api = {
    runtime: {
      id: extensionId,
      onMessage: messages,
      connectNative() {
        const port = {
          onMessage: event(),
          onDisconnect: event(),
          postMessage(message) {
            nativeMessages.push(message);
            queueMicrotask(() => port.onMessage.emit({ ok: true, status: "accepted" }));
          },
          disconnect() { port.onDisconnect.emit(); },
        };
        return port;
      },
      sendNativeMessage: async (_, message) => {
        nativeMessages.push(message);
        return { ok: true };
      },
    },
    tabs: { get: async () => ({ ...tab }), onUpdated: updated, onRemoved: removed },
    scripting: {
      executeScript(options) {
        if (options.files) return Promise.resolve([]);
        return new Promise((resolve) => scripts.push({ options, resolve }));
      },
    },
    action: { setBadgeText: async () => {} },
  };
  const context = vm.createContext({
    chrome: api, URL, setTimeout, clearTimeout,
    console: { error() {} },
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../extension/background.js"), "utf8"), context);
  const send = async (message) => messages.emit(message, { id: extensionId })[0];
  return { tab, updated, removed, nativeMessages, scripts, send };
}

test("completed inspection status belongs only to its original album and tab", async () => {
  const fixture = background();
  await fixture.send({ type: "inspect_album", tabId: 1 });
  await settle();
  fixture.scripts[0].resolve([{ result: { error: "Old album has no track list" } }]);
  await settle();
  const ownStatus = await fixture.send({ type: "inspection_status", tabId: 1, url: firstUrl });
  assert.equal(ownStatus.message, "Old album has no track list");
  assert.equal(await fixture.send({ type: "inspection_status", tabId: 1, url: secondUrl }), null);
  assert.equal(await fixture.send({ type: "inspection_status", tabId: 2, url: firstUrl }), null);
});

test("navigation cancels the old job without letting its late result replace the new job", async () => {
  const fixture = background();
  await fixture.send({ type: "inspect_album", tabId: 1 });
  await settle();
  fixture.tab.url = secondUrl;
  fixture.updated.emit(1, { url: secondUrl });
  await fixture.send({ type: "inspect_album", tabId: 1 });
  await settle();
  assert.equal(fixture.scripts[1].options.args[0], secondUrl);
  fixture.scripts[0].resolve([{ result: { error: "Late result from old page" } }]);
  await settle();
  const current = await fixture.send({ type: "inspection_status", tabId: 1, url: secondUrl });
  assert.equal(current.running, true);
  assert.doesNotMatch(current.message, /Late result/);
  fixture.scripts[1].resolve([{ result: { album: { url: secondUrl } } }]);
  await settle();
  assert.equal(fixture.nativeMessages.filter((message) => message.type === "import_album").length, 1);
  assert.equal(fixture.nativeMessages.find((message) => message.type === "import_album").album.url, secondUrl);
  assert.equal(fixture.nativeMessages.find((message) => message.type === "inspection_failed").url, firstUrl);
});

test("popup refresh reads the current URL and clears previous-album messages", async () => {
  const elements = new Map();
  const getElement = (id) => {
    if (!elements.has(id)) elements.set(id, { textContent: "", dataset: {}, addEventListener() {} });
    return elements.get(id);
  };
  const tab = { id: 1, url: firstUrl };
  let interval;
  const queries = [];
  const context = vm.createContext({
    URL,
    document: { getElementById: getElement },
    setInterval: (callback) => { interval = callback; },
    console,
    chrome: {
      tabs: { query: async () => [{ ...tab }] },
      runtime: {
        sendMessage: async (message) => {
          queries.push(message);
          return message.url === firstUrl ? { message: "Old album error", running: false } : null;
        },
      },
    },
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../extension/popup.js"), "utf8"), context);
  await settle();
  assert.equal(getElement("inspection-status").textContent, "Old album error");
  getElement("result").textContent = "Old album was staged";
  tab.url = secondUrl;
  await interval();
  assert.equal(queries.at(-1).url, secondUrl);
  assert.equal(getElement("inspection-status").textContent, "");
  assert.equal(getElement("result").textContent, "");
  assert.equal(getElement("inspect-button").disabled, false);
});
