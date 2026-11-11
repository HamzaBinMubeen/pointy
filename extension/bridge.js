/* =============================================================================
   bridge.js — ISOLATED world.

   WHY THIS FILE EXISTS. The overlay has to read React fibers (`__reactFiber$…`),
   and those are expando properties the page set on DOM nodes. A content script
   in the isolated world cannot see page expandos, so the overlay itself runs in
   the MAIN world (app.js) — where there is no `chrome.*`. This is the relay
   between the two: postMessage on one side, chrome.runtime on the other.
   ========================================================================== */
(() => {
  const VERSION = "0.12.0";
  // A superseded bridge must go quiet, or two copies answer the same request id
  // and the first (orphaned, throwing) one wins the race.
  if (window.__UI_NOTES_BRIDGE__ === VERSION) return;
  window.__UI_NOTES_BRIDGE__ = VERSION;
  const isCurrent = () => window.__UI_NOTES_BRIDGE__ === VERSION;

  // MAIN world -> background
  window.addEventListener("message", async (e) => {
    if (e.source !== window || !isCurrent()) return;
    const d = e.data;
    if (!d || d.__uinotes !== "req") return;
    let payload = null;
    try {
      payload = await chrome.runtime.sendMessage({ type: d.type, payload: d.payload });
    } catch (err) {
      // Reloading the extension orphans this script: the DOM listeners keep
      // working, but every chrome.* call throws. The page must be reloaded, and
      // the overlay needs to be able to say so.
      const msg = String(err && err.message ? err.message : err);
      payload = { error: msg, orphaned: /context invalidated|Receiving end does not exist/i.test(msg) };
    }
    window.postMessage({ __uinotes: "res", id: d.id, payload }, "*");
  });

  // background -> MAIN world
  chrome.runtime.onMessage.addListener((msg) => {
    if (msg && msg.type === "toggle") {
      window.postMessage({ __uinotes: "cmd", cmd: "toggle" }, "*");
    }
    return false;
  });
})();
