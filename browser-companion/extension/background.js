"use strict";

const api = globalThis.browser || globalThis.chrome;
let job = null;

function requestHost(port, message) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => finish(new Error("The plugin did not respond.")), 15000);
    function finish(error, response) {
      clearTimeout(timeout);
      port.onMessage.removeListener(onMessage);
      port.onDisconnect.removeListener(onDisconnect);
      if (error) reject(error);
      else resolve(response);
    }
    function onMessage(response) {
      finish(response.ok ? null : new Error(`Plugin response: ${response.status}`), response);
    }
    function onDisconnect() {
      finish(new Error(api.runtime.lastError?.message || "The native host disconnected."));
    }
    port.onMessage.addListener(onMessage);
    port.onDisconnect.addListener(onDisconnect);
    port.postMessage(message);
  });
}

async function runInspection(currentJob) {
  const { tabId, url } = currentJob;
  let port;
  try {
    port = api.runtime.connectNative("org.omarchy.omakhinsider");
    currentJob.port = port;
    await requestHost(port, { type: "inspection_started", url });
    if (currentJob.canceled) return;
    await api.scripting.executeScript({ target: { tabId }, files: ["inspect.js"] });
    if (currentJob.canceled) return;
    const [result] = await api.scripting.executeScript({
      target: { tabId },
      args: [url],
      func: async (expectedUrl) => {
        try {
          return { album: await inspectAlbumInPage(expectedUrl) };
        } catch (error) {
          return { error: String(error.message || error).slice(0, 1000) };
        }
      },
    });
    if (currentJob.canceled) return;
    if (!result?.result?.album) {
      throw new Error(result?.result?.error || result?.error?.message || "The album tab closed or inspection failed.");
    }
    await requestHost(port, { type: "import_album", album: result.result.album });
    currentJob.running = false;
    currentJob.message = "Inspection sent. Check OmaKhinsider for the result.";
    currentJob.error = false;
    if (job === currentJob) await api.action.setBadgeText({ text: "OK" });
  } catch (error) {
    if (currentJob.canceled) return;
    const message = String(error.message || error).slice(0, 1000);
    console.error("OmaKhinsider inspection:", error);
    currentJob.running = false;
    currentJob.message = message;
    currentJob.error = true;
    if (job === currentJob) await api.action.setBadgeText({ text: "!" });
    if (port) {
      try {
        await requestHost(port, { type: "inspection_failed", url, error: message });
      } catch (reportError) {
        console.error("Could not report inspection failure to OmaKhinsider:", reportError);
      }
    }
  } finally {
    if (port) port.disconnect();
    currentJob.port = null;
  }
}

function statusForPage(tabId, url) {
  if (!job) return null;
  const samePage = job.tabId === tabId && job.url === String(url || "").replace(/\/$/, "");
  if (!samePage && !job.running) return null;
  return {
    running: job.running,
    message: samePage ? job.message : "An inspection is running in another album tab.",
    error: samePage && job.error,
  };
}

function albumTabChanged(tabId, url) {
  if (!job || job.tabId !== tabId || job.url === String(url || "").replace(/\/$/, "")) return;
  const previous = job;
  job = null;
  void api.action.setBadgeText({ text: "" });
  if (!previous.running) return;
  previous.canceled = true;
  previous.running = false;
  if (previous.port) previous.port.disconnect();
  void api.runtime.sendNativeMessage("org.omarchy.omakhinsider", {
    type: "inspection_failed",
    url: previous.url,
    error: "The album tab changed or closed during inspection. Inspect the current album again.",
  }).then((response) => {
    if (!response?.ok) console.error("Could not report interrupted inspection:", response?.status);
  }).catch((error) => console.error("Could not report interrupted inspection:", error));
}

api.tabs.onUpdated.addListener((tabId, change) => {
  if (change.url !== undefined) albumTabChanged(tabId, change.url);
});
api.tabs.onRemoved.addListener((tabId) => albumTabChanged(tabId, ""));

api.runtime.onMessage.addListener((message, sender) => {
  if (sender.id !== api.runtime.id) return;
  if (message.type === "inspection_progress" && job?.running && sender.tab?.id === job.tabId &&
      String(sender.url || "").replace(/\/$/, "") === job.url) {
    job.message = `Inspecting track ${message.completed} of ${message.total}. Keep this album tab open.`;
    void api.action.setBadgeText({ text: String(message.completed) });
    return Promise.resolve({ ok: true });
  }
  if (sender.tab) return;
  if (message.type === "inspection_status") return Promise.resolve(statusForPage(message.tabId, message.url));
  if (message.type === "inspect_album") {
    if (job?.running) return Promise.resolve({ ok: false, message: "An album inspection is already running." });
    return api.tabs.get(message.tabId).then((tab) => {
      if (job?.running) return { ok: false, message: "An album inspection is already running." };
      const url = new URL(tab.url);
      if (url.origin !== "https://downloads.khinsider.com" || url.search || url.hash ||
          !url.pathname.startsWith("/game-soundtracks/album/")) {
        throw new Error("Open a KHInsider album page first.");
      }
      job = {
        running: true, tabId: tab.id, url: url.href.replace(/\/$/, ""),
        message: "Inspecting album. Keep its browser tab open.", error: false,
      };
      void runInspection(job);
      return { ok: true, message: job.message };
    });
  }
});
