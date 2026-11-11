/* =============================================================================
   background.js — session state, screenshots, and the hand-off to the server.

   The session lives HERE, not in the page, so that walking from /jobs to
   /pricing mid-sentence does not lose the notes you already made.
   ========================================================================== */

const SERVER = "http://127.0.0.1:7777";

/** @type {null | {id:string, startedAt:number, notes:any[], speech:any[], shots:Object, seq:number}} */
let session = null;

const newId = () => {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}_${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
};

/* -------------------------------------------------------------- self-update */

/* The Pointy app ships this extension and rewrites its folder whenever the
   app updates. An unpacked extension only reads new files when it reloads, so
   reload when the app's copy is newer — never mid-session, and never for a
   store install (those carry update_url and update through the store). The
   same request tells the app which version is connected. */
const unpacked = !("update_url" in chrome.runtime.getManifest());
let lastUpdateCheck = 0;

function newer(a, b) {
  const x = String(a).split(".").map(Number), y = String(b).split(".").map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] || 0) - (y[i] || 0);
    if (d) return d > 0;
  }
  return false;
}

/* Our version and the shortcut the browser actually gave us. A browser silently
   skips a suggested shortcut it already uses itself — Edge owns ⌘⇧E — so the
   app shows the real one, or says there is none and offers to set it. */
async function versionQuery() {
  const own = chrome.runtime.getManifest().version;
  let key = "";
  try { key = ((await chrome.commands.getAll()).find((c) => c.name === "toggle") || {}).shortcut || ""; } catch {}
  return `v=${encodeURIComponent(own)}&k=${encodeURIComponent(key)}`;
}

async function checkForUpdate() {
  if (Date.now() - lastUpdateCheck < 60000) return;
  lastUpdateCheck = Date.now();
  try {
    const own = chrome.runtime.getManifest().version;
    const r = await fetch(`${SERVER}/version?${await versionQuery()}`, { cache: "no-store" });
    const { extension } = await r.json();
    if (unpacked && extension && newer(extension, own) && !session) chrome.runtime.reload();
  } catch {
    /* app not running — nothing to compare against */
  }
}

checkForUpdate();

/* ---------------------------------------------------------------- toggling */

async function toggle(tab) {
  if (!tab || !tab.id) return;
  try {
    await chrome.tabs.sendMessage(tab.id, { type: "toggle" });
  } catch {
    // The tab was loaded before the extension was installed/reloaded. Inject
    // both worlds by hand, then retry.
    try {
      await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["bridge.js"] });
      await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["app.js"], world: "MAIN" });
      await chrome.tabs.sendMessage(tab.id, { type: "toggle" });
    } catch (e) {
      console.warn("[pointy] cannot inject into this tab:", e);
    }
  }
}

/**
 * Reloading an extension does NOT refresh content scripts in tabs that are
 * already open. Without this, every reload leaves your working tab running the
 * previous build — which looks like "the new shortcuts do not exist" rather
 * than like a stale script, and cost three debugging rounds before it was
 * spotted. Push the current build into every matching tab instead.
 */
const HOSTS = [
  "http://localhost/*", "http://127.0.0.1/*", "http://*.localhost/*",
];

async function reinjectAll() {
  let tabs = [];
  try { tabs = await chrome.tabs.query({ url: HOSTS }); } catch { return; }
  for (const t of tabs) {
    if (!t.id) continue;
    try {
      await chrome.scripting.executeScript({ target: { tabId: t.id }, files: ["bridge.js"] });
      await chrome.scripting.executeScript({ target: { tabId: t.id }, files: ["app.js"], world: "MAIN" });
    } catch {
      /* chrome:// pages, the web store, and discarded tabs all refuse. Fine. */
    }
  }
}

chrome.runtime.onInstalled.addListener(reinjectAll);
chrome.runtime.onStartup.addListener(reinjectAll);

chrome.action.onClicked.addListener(toggle);
chrome.commands.onCommand.addListener(async (cmd) => {
  if (cmd !== "toggle") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  toggle(tab);
});

/* ------------------------------------------------------------- screenshots */

// captureVisibleTab is rate-limited (~2/s). A human drawing never hits that,
// but a fast double-gesture can, so retry rather than losing the frame.
async function capture(windowId, format, quality) {
  for (let i = 0; i < 4; i++) {
    try {
      return await chrome.tabs.captureVisibleTab(windowId, { format, quality });
    } catch (e) {
      if (i === 3) throw e;
      await new Promise((r) => setTimeout(r, 350 * (i + 1)));
    }
  }
}

async function cropDataUrl(dataUrl, rect, dpr) {
  // Service workers have OffscreenCanvas + createImageBitmap, so the crop
  // happens here and the page never has to hold a multi-MB string.
  const blob = await (await fetch(dataUrl)).blob();
  const bmp = await createImageBitmap(blob);
  const sx = Math.max(0, Math.round(rect.x * dpr));
  const sy = Math.max(0, Math.round(rect.y * dpr));
  const sw = Math.min(bmp.width - sx, Math.round(rect.w * dpr));
  const sh = Math.min(bmp.height - sy, Math.round(rect.h * dpr));
  if (sw <= 0 || sh <= 0) return null;
  // Downscale before saving. A crop taken from a 2x capture was ~2900px wide,
  // and an image that size is 93% of what a session costs a model to read.
  // 1:1 CSS pixels, long edge capped, keeps UI text legible at a fraction of it.
  const MAX_EDGE = 1100;
  const scale = Math.min(1, 1 / (dpr || 1), MAX_EDGE / Math.max(sw, sh));
  const dw = Math.max(1, Math.round(sw * scale));
  const dh = Math.max(1, Math.round(sh * scale));
  const canvas = new OffscreenCanvas(dw, dh);
  const ctx = canvas.getContext("2d");
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(bmp, sx, sy, sw, sh, 0, 0, dw, dh);
  const out = await canvas.convertToBlob({ type: "image/png" });
  return await new Promise((res) => {
    const fr = new FileReader();
    fr.onload = () => res(fr.result);
    fr.readAsDataURL(out);
  });
}

/* ---------------------------------------------------------------- messages */

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  (async () => {
    const windowId = sender.tab ? sender.tab.windowId : undefined; // undefined = current window

    switch (msg.type) {
      case "hello": {
        checkForUpdate(); // page loads wake this worker; a good moment to look
        // Read-only: does a session already exist? Used by a freshly loaded
        // page to decide whether to resume. Must never create one.
        reply({ ok: true, live: !!session, sessionId: session ? session.id : null, notes: session ? session.notes.length : 0 });
        return;
      }

      case "start": {
        // The app answers /version with the transcription engine it is set to;
        // the Node server has no /version, so fall back to /ping and browser speech.
        let serverUp = false;
        let engine = "browser";
        let keymap = null;   // the Pointy app's Shortcuts tab
        try {
          const r = await fetch(`${SERVER}/version?${await versionQuery()}`, { cache: "no-store" });
          if (r.ok) {
            serverUp = true;
            const info = await r.json();
            engine = info.engine || "browser";
            keymap = info.keymap || null;
          } else {
            serverUp = (await fetch(`${SERVER}/ping`, { cache: "no-store" })).ok;
          }
        } catch {
          serverUp = false;
        }
        const resumed = !!session;
        if (!session) {
          session = { id: newId(), startedAt: Date.now(), notes: [], speech: [], shots: {}, seq: 0 };
        }
        reply({ ok: true, sessionId: session.id, seq: session.seq, resumed, serverUp, engine, keymap, notes: session.notes.length });
        return;
      }

      // On-device transcription lives in the app; the overlay switches it and
      // polls it (the poll is also the app's heartbeat).
      case "listen": {
        try {
          await fetch(`${SERVER}/listen`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ on: !!(msg.payload && msg.payload.on) }),
          });
          reply({ ok: true });
        } catch {
          reply({ ok: false });
        }
        return;
      }

      case "transcript": {
        try {
          const r = await fetch(`${SERVER}/listen/status`, { cache: "no-store" });
          reply(await r.json());
        } catch {
          reply({ ok: false, error: "The Pointy app is not running." });
        }
        return;
      }

      case "shot": {
        if (!session) return reply({ ok: false });
        const { rect, dpr } = msg.payload || {};
        try {
          const full = await capture(windowId, "jpeg", 80);
          const id = String(++session.seq).padStart(2, "0");
          session.shots[`${id}.jpg`] = full;
          let cropName = null;
          if (rect) {
            const crop = await cropDataUrl(full, rect, dpr || 1);
            if (crop) {
              cropName = `${id}-crop.png`;
              session.shots[cropName] = crop;
            }
          }
          reply({ ok: true, seq: session.seq, shot: `${id}.jpg`, crop: cropName });
        } catch (e) {
          reply({ ok: false, error: String(e) });
        }
        return;
      }

      case "note": {
        if (!session) return reply({ ok: false });
        session.notes.push(msg.payload);
        reply({ ok: true, count: session.notes.length });
        return;
      }

      case "speech": {
        if (!session) return reply({ ok: false });
        session.speech.push(msg.payload);
        reply({ ok: true });
        return;
      }

      case "dropnote": {
        // Remove ONE mark. Its screenshots go too, so a discarded mark does not
        // leave orphaned images in the session folder.
        if (!session) return reply({ ok: false });
        const { at, kind, shot, crop } = msg.payload || {};
        session.notes = session.notes.filter((n) => !(n.at === at && n.kind === kind));
        if (shot) delete session.shots[shot];
        if (crop) delete session.shots[crop];
        reply({ ok: true, count: session.notes.length });
        return;
      }

      case "abort": {
        session = null;
        reply({ ok: true });
        return;
      }

      case "finish": {
        if (!session) return reply({ ok: false, error: "no session" });
        if (!session.notes.length && !session.speech.length) {
          session = null;
          return reply({ ok: true, dir: "(nothing recorded)", notes: 0 });
        }
        const bundle = {
          id: session.id,
          startedAt: session.startedAt,
          endedAt: Date.now(),
          notes: session.notes,
          speech: session.speech,
          shots: session.shots,
        };
        try {
          const res = await fetch(`${SERVER}/session`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(bundle),
          });
          const out = await res.json();
          // Only forget the session once the server says it WROTE it. Clearing on
          // a 500 threw away every mark of a session that had just failed to
          // save — the one moment the data is most needed.
          if (res.ok && out && out.ok) session = null;
          reply({ ok: !!(res.ok && out && out.ok), ...out });
        } catch (e) {
          // Keep the session alive so nothing is lost — start the server and
          // press Esc again.
          reply({ ok: false, error: `server unreachable at ${SERVER} — start it and press Esc again` });
        }
        return;
      }

      default:
        reply({ ok: false, error: "unknown message" });
    }
  })();
  return true; // async reply
});
