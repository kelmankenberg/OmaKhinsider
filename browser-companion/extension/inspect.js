"use strict";

async function inspectAlbumInPage(expectedUrl) {
  const api = globalThis.browser || globalThis.chrome;
  const maxBytes = 2 * 1024 * 1024;
  const formats = new Set(["mp3", "flac", "ogg", "opus", "m4a", "aac", "wav", "wma", "alac"]);
  const clean = (text) => String(text || "").replace(/\s+/g, " ").trim();
  const url = new URL(location.href);
  if (url.origin !== "https://downloads.khinsider.com" || url.search || url.hash) {
    throw new Error("Open a KHInsider album page first.");
  }
  const albumUrl = url.href.replace(/\/$/, "");
  if (expectedUrl && albumUrl !== expectedUrl) {
    throw new Error("The album tab changed. Inspect the current album again.");
  }
  if (document.readyState === "loading") {
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        document.removeEventListener("DOMContentLoaded", loaded);
        reject(new Error("The album page is still loading. Wait for it to finish and inspect again."));
      }, 15000);
      function loaded() {
        clearTimeout(timeout);
        resolve();
      }
      document.addEventListener("DOMContentLoaded", loaded, { once: true });
    });
  }
  const tracks = [];
  const seen = new Set();
  for (const row of document.querySelectorAll("#songlist tr")) {
    const cells = [...row.querySelectorAll("td")];
    if (!cells.length) continue;
    for (const anchor of row.querySelectorAll("a[href]")) {
      const link = new URL(anchor.getAttribute("href"), albumUrl);
      const title = clean(anchor.textContent);
      if (link.origin !== url.origin || !link.href.startsWith(albumUrl + "/") ||
          link.search || link.hash || !title || seen.has(link.href)) continue;
      if (title.length > 500) throw new Error("A track title is too long.");
      tracks.push({ title, trackUrl: link.href, audioLinks: [] });
      seen.add(link.href);
      break;
    }
  }
  if (!tracks.length) throw new Error("No track-page links were found in this album's song list.");
  if (tracks.length > 1000) throw new Error("This album exceeds the supported limit of 1000 tracks.");
  const advertised = document.body.textContent.match(/Number of Files:\s*(\d+)/i);
  if (advertised && Number(advertised[1]) !== tracks.length) {
    throw new Error("The number of track links does not match the album's advertised track count.");
  }
  const title = clean(document.title.replace(
    /\s+(?:MP3|FLAC|OGG|OPUS|M4A|AAC|WAV|WMA|ALAC)\s+-\s+Download Soundtracks.*$/i, "",
  ));
  if (!title || title.length > 500) throw new Error("Invalid album title.");
  for (let index = 0; index < tracks.length; index++) {
    if (location.href.replace(/\/$/, "") !== albumUrl) throw new Error("The album tab changed. Inspect again.");
    if (index) await new Promise((resolve) => setTimeout(resolve, 1000));
    const response = await fetch(tracks[index].trackUrl, {
      credentials: "same-origin",
      redirect: "error",
      cache: "no-store",
      signal: AbortSignal.timeout(30000),
    });
    if (!response.ok) {
      throw new Error(`Track ${index + 1}: HTTP ${response.status}. Open that track in your browser and resolve any site prompt before retrying.`);
    }
    if (!response.headers.get("content-type")?.toLowerCase().includes("text/html")) {
      throw new Error(`Track ${index + 1} did not return a track page.`);
    }
    const reader = response.body.getReader();
    const chunks = [];
    let bytes = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.byteLength;
        if (bytes > maxBytes) throw new Error("Track page exceeds the 2 MiB limit.");
        chunks.push(value);
      }
    } finally {
      await reader.cancel();
    }
    const html = new Uint8Array(bytes);
    let offset = 0;
    for (const chunk of chunks) {
      html.set(chunk, offset);
      offset += chunk.byteLength;
    }
    const page = new DOMParser().parseFromString(new TextDecoder().decode(html), "text/html");
    const trackFormats = new Set();
    for (const anchor of page.querySelectorAll("a[href]")) {
      if (!/click here to download as/i.test(anchor.textContent)) continue;
      const media = new URL(anchor.getAttribute("href"), tracks[index].trackUrl);
      const format = media.pathname.split(".").pop().toLowerCase();
      if (media.protocol !== "https:" || media.username || media.password || media.port || media.hash ||
          !/^(?:[a-z0-9-]+\.)*(?:vgmsite\.com|vgmtreasurechest\.com)$/.test(media.hostname) ||
          !formats.has(format) || trackFormats.has(format)) continue;
      tracks[index].audioLinks.push({ format, url: media.href });
      trackFormats.add(format);
    }
    if (!tracks[index].audioLinks.length) {
      throw new Error(`No supported audio links for track ${index + 1}. Open the track in your browser and check for a site prompt.`);
    }
    await api.runtime.sendMessage({ type: "inspection_progress", completed: index + 1, total: tracks.length });
  }
  const album = { url: albumUrl, title, tracks };
  if (new TextEncoder().encode(JSON.stringify(album)).byteLength > maxBytes) {
    throw new Error("Album inspection exceeds the 2 MiB limit.");
  }
  return album;
}
