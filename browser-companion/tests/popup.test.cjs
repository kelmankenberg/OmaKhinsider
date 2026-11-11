const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

async function popup(response, transportError = false) {
  const elements = new Map();
  const requests = [];
  const getElement = (id) => {
    if (!elements.has(id)) elements.set(id, {
      textContent: "", dataset: {}, disabled: false, listeners: {},
      addEventListener(event, listener) { this.listeners[event] = listener; },
    });
    return elements.get(id);
  };
  const context = vm.createContext({
    URL,
    document: { getElementById: getElement },
    setInterval() {},
    console: { error() {} },
    chrome: {
      tabs: { query: async () => [{ id: 1, url: "about:blank" }] },
      runtime: {
        sendMessage: async () => null,
        sendNativeMessage: async (host, message) => {
          requests.push({ host, message });
          if (transportError) throw new Error("Host not found");
          return response;
        },
      },
    },
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, "../extension/popup.js"), "utf8"), context);
  await new Promise((resolve) => setImmediate(resolve));
  await getElement("test-button").listeners.click();
  return { elements, requests };
}

test("connection test works without an album and only sends a read-only ping", async () => {
  const { elements, requests } = await popup({ ok: true, status: "connected" });
  assert.equal(requests.length, 1);
  assert.equal(requests[0].host, "org.omarchy.omakhinsider");
  assert.equal(JSON.stringify(requests[0].message), '{"type":"ping"}');
  assert.match(elements.get("result").textContent, /Connected to OmaKhinsider/);
  assert.equal(elements.get("result").dataset.state, "success");
  assert.equal(elements.get("test-button").disabled, false);
  assert.equal(elements.get("stage-button").disabled, true);
  assert.equal(elements.get("inspect-button").disabled, true);
});

test("failed, outdated, and unexpected connections never report success", async (t) => {
  const cases = [
    { name: "missing host", error: true, expected: /Check registration, extension ID/ },
    { name: "disabled plugin", response: { ok: false, status: "plugin_unavailable" }, expected: /Enable/ },
    { name: "outdated host", response: { ok: false, status: "invalid_request" }, expected: /versions differ/ },
    { name: "contradictory reply", response: { ok: false, status: "connected" }, expected: /could not complete/ },
    { name: "wrong operation", response: { ok: true, status: "staged" }, expected: /could not complete/ },
  ];
  for (const entry of cases) {
    await t.test(entry.name, async () => {
      const { elements } = await popup(entry.response, entry.error);
      assert.equal(elements.get("result").dataset.state, "error");
      assert.match(elements.get("result").textContent, entry.expected);
      assert.equal(elements.get("test-button").disabled, false);
    });
  }
});
