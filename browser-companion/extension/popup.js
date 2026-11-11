"use strict";

const HOST_NAME = "org.omarchy.omakhinsider";
const api = globalThis.browser || globalThis.chrome;
const pageStatus = document.getElementById("page-status");
const stageButton = document.getElementById("stage-button");
const testButton = document.getElementById("test-button");
const inspectButton = document.getElementById("inspect-button");
const inspectionStatus = document.getElementById("inspection-status");
const resultText = document.getElementById("result");
let validAlbumPage = false;
let currentPage = "";
let stageSending = false;
let inspectionStarting = false;

const messages = {
  connected: ["Connected to OmaKhinsider. You can now inspect an album.", "success"],
  staged: ["Album URL filled in. Select Add album in OmaKhinsider to queue it.", "success"],
  album_url_invalid: ["Open a valid KHInsider album page first.", "error"],
  state_unavailable: ["OmaKhinsider is still loading. Try again shortly.", "error"],
  plugin_unavailable: ["Enable the OmaKhinsider plugin in Omarchy, then try again.", "error"],
  native_host_unavailable: ["Cannot connect to the native host. Check registration, extension ID, and Python 3; see Browser setup in OmaKhinsider.", "error"],
  invalid_request: ["Companion and host versions differ. Rebuild/reload the extension and rerun host registration; see Browser setup in OmaKhinsider.", "error"],
  plugin_error: ["OmaKhinsider could not complete this request.", "error"]
};

function isAlbumUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" &&
      url.hostname.toLowerCase() === "downloads.khinsider.com" &&
      !url.username && !url.password && !url.port &&
      !url.search && !url.hash &&
      /^\/game-soundtracks\/album\/[A-Za-z0-9._~%!-]+(?:\/[A-Za-z0-9._~%!-]+)*\/?$/.test(url.pathname);
  } catch {
    return false;
  }
}

function showResult(status) {
  const [message, kind] = messages[status] || messages.plugin_error;
  resultText.textContent = message;
  resultText.dataset.state = kind;
}

async function initialize() {
  await refreshInspection();
}

testButton.addEventListener("click", async () => {
  testButton.disabled = true;
  resultText.textContent = "Testing plugin connection…";
  resultText.dataset.state = "";
  try {
    const response = await api.runtime.sendNativeMessage(HOST_NAME, { type: "ping" });
    if (response?.ok && response.status === "connected") showResult("connected");
    else if (!response?.ok &&
        ["plugin_unavailable", "state_unavailable", "invalid_request"].includes(response?.status)) {
      showResult(response.status);
    } else showResult("plugin_error");
  } catch (error) {
    console.error("Could not test plugin connection:", error);
    showResult("native_host_unavailable");
  } finally {
    testButton.disabled = false;
  }
});

stageButton.addEventListener("click", async () => {
  stageSending = true;
  stageButton.disabled = true;
  resultText.textContent = "Sending album URL…";
  resultText.dataset.state = "";
  try {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
    if (!tab || !isAlbumUrl(tab.url || "")) {
      showResult("album_url_invalid");
      return;
    }
    const response = await api.runtime.sendNativeMessage(HOST_NAME, {
      type: "stage_album",
      url: tab.url
    });
    showResult(response && response.status ? response.status : "plugin_error");
  } catch {
    showResult("native_host_unavailable");
  } finally {
    stageSending = false;
    stageButton.disabled = !validAlbumPage;
  }
});

initialize();

async function refreshInspection() {
  try {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
    const page = tab ? `${tab.id}:${String(tab.url || "").replace(/\/$/, "")}` : "";
    if (page !== currentPage) {
      currentPage = page;
      resultText.textContent = "";
      resultText.dataset.state = "";
    }
    validAlbumPage = !!tab && isAlbumUrl(tab.url || "");
    pageStatus.textContent = validAlbumPage
      ? "KHInsider album page ready."
      : "Open a KHInsider album page to add it.";
    stageButton.disabled = stageSending || !validAlbumPage;
    const status = await api.runtime.sendMessage({
      type: "inspection_status", tabId: tab?.id, url: tab?.url,
    });
    if (currentPage !== page) return;
    inspectionStatus.textContent = status?.message || "";
    inspectButton.disabled = inspectionStarting || !validAlbumPage || !!status?.running;
  } catch (error) {
    console.error("Could not read inspection status:", error);
    inspectionStatus.textContent = "Could not read inspection status. Reload the companion extension.";
  }
}

inspectButton.addEventListener("click", async () => {
  inspectionStarting = true;
  inspectButton.disabled = true;
  try {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
    if (!tab || !isAlbumUrl(tab.url || "")) throw new Error("Open a valid KHInsider album page first.");
    const response = await api.runtime.sendMessage({ type: "inspect_album", tabId: tab.id });
    inspectionStatus.textContent = response.message;
    if (!response.ok) inspectButton.disabled = false;
  } catch (error) {
    inspectionStatus.textContent = String(error.message || error);
    inspectButton.disabled = false;
  } finally {
    inspectionStarting = false;
  }
});

setInterval(refreshInspection, 1000);
