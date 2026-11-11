/* =============================================================================
   app.js — Pointy overlay. Runs in the page's MAIN world.

   You pick a tool, draw, and talk. Every mark resolves to the actual UI
   ELEMENTS involved — by name — not to a box on a screen.

   Tools (you choose; nothing is guessed):
     V  select ....... click an element and talk about it; no shape drawn
     R  rectangle .... selects every element that sits fully inside it
     O  oval ......... same, drawn as an ellipse — for highlighting an area
     A  arrow ........ points at something: "this goes there", or "I mean that"
     H  use the page . clicks and scrolls go to the page until pressed again
     a click .......... in any tool, selects the one element under the cursor

   The element under your cursor is outlined and named before you draw, so you
   commit to a target you can see. Hold Shift to take its PARENT instead.

   Keys:
     T ........... type a note for the newest mark
     ⌘Z .......... undo the newest mark
     ⌘⌫ .......... start over (asks first)
     ⌘↩ .......... done: save, and the brief lands on the clipboard
     Esc ......... cancel (a shape mid-drag, the note field, start over, use the page)
   ========================================================================== */
(() => {
  const VERSION = "0.12.0";

  /* A tab that was already open when the extension reloaded keeps running the
     OLD copy of this file — the listeners still work, so nothing looks broken;
     the HUD is simply missing whatever the new build added. Rather than relying
     on remembering to hard-reload, a newer copy now TAKES OVER from an older
     one, and the version is printed in the HUD so a stale tab is visible at a
     glance. (Copies predating 0.3.0 set this flag to `true` and have no
     teardown — they are superseded by removing their overlay in build().) */
  // Internal names (__UI_NOTES__, __uinotes, #ui-notes-host) keep the pre-Pointy
  // spelling on purpose: they are how a newer copy finds and replaces an older
  // one already running in a tab. Renaming them would leave both on the page.
  const prev = window.__UI_NOTES__;
  if (prev && prev.version === VERSION) return;
  if (prev && typeof prev.teardown === "function") { try { prev.teardown(); } catch {} }
  window.__UI_NOTES__ = { version: VERSION, teardown: () => teardown() };
  const isCurrent = () => window.__UI_NOTES__ && window.__UI_NOTES__.version === VERSION;

  /* Mono & lime, matching the app. Lime is the shape you drew, edged in
     near-black so it holds on white pages as well as dark ones; green is what
     got selected. Keep that meaning for anything new. */
  const INK = "#c8f53c";
  const EDGE = "#111111";
  const GREEN = "#16a34a";

  /* A slip on a trackpad is easily 20-30px. At the old 9px threshold, 11 of the
     first 91 real marks were sub-45px shapes — clicks that became rectangles
     enclosing nothing. Select mode removes the guess entirely; this covers the
     accidental case in the other modes. */
  const CLICK_PX = 14;
  const SLIP_PX = 60;

  /* ------------------------------------------------------- bridge plumbing */

  let reqId = 0;
  const pending = new Map();

  window.addEventListener("message", (e) => {
    if (e.source !== window || !isCurrent()) return;
    const d = e.data;
    if (!d) return;
    if (d.__uinotes === "res") {
      const done = pending.get(d.id);
      if (done) { pending.delete(d.id); done(d.payload); }
    } else if (d.__uinotes === "cmd" && d.cmd === "toggle") toggle();
  });

  function call(type, payload) {
    return new Promise((resolve) => {
      const id = ++reqId;
      pending.set(id, resolve);
      window.postMessage({ __uinotes: "req", id, type, payload }, "*");
      setTimeout(() => { if (pending.has(id)) { pending.delete(id); resolve(null); } }, 20000);
    });
  }

  /* ------------------------------------------------------------ small math */

  const r1 = (n) => Math.round(n * 10) / 10;
  const ri = (n) => Math.round(n);

  const S = {
    on: false, pass: false, mode: "rect",
    t0: 0, notes: [], drawing: null,
    interim: "", tail: "", warn: "", banner: "",
    rec: null, recRun: 0, saving: false, timer: null, engine: "browser", poll: null, stage: "", level: 0, keys: null,
    brief: "", hideTimer: null, confirmAt: 0, sessionCount: 0, speechCount: 0, micOk: null,
    hoverRaw: null, hoverShift: false, hoverEl: null, lastPt: null, uidSeq: 0,
  };

  const now = () => Date.now() - S.t0;

  /* ------------------------------------------------------------- shadow UI */

  /* The toolbar is one slim strip of dark glass, bottom centre — the shape of
     macOS's own screenshot bar. Dark glass because it floats over any page;
     lime is the selected tool and the Done button, as in the app. */
  const ICON = {
    select: '<path transform="translate(-.6 0)" d="M7.5 4.5v13.2l3.4-3.2 2.3 5 2.2-1-2.3-4.9 4.6-.3z"/>',
    rect: '<rect x="4.5" y="6.5" width="15" height="11" rx="2.5"/>',
    circle: '<ellipse cx="12" cy="12" rx="7.5" ry="5.75"/>',
    arrow: '<path d="M6.5 17.5l11-11M10 6.5h7.5V14"/>',
    pass: '<path transform="translate(.7 .5)" d="M9.5 11.5V7.25a1.25 1.25 0 012.5 0V11m0-4.75v-.5a1.25 1.25 0 012.5 0V11m0-3.25a1.25 1.25 0 012.5 0v5.5a5.25 5.25 0 01-5.25 5.25h-.35a4.8 4.8 0 01-3.9-2l-1.8-2.55a1.2 1.2 0 011.9-1.45l1.9 2.05"/>',
    note: '<path d="M5.5 5h13a1.5 1.5 0 011.5 1.5v8a1.5 1.5 0 01-1.5 1.5H12l-4 3.5V16H5.5A1.5 1.5 0 014 14.5v-8A1.5 1.5 0 015.5 5z"/><path d="M9 9h6M12 9v4"/>',
    undo: '<path d="M9 13.5L4.5 9 9 4.5"/><path d="M4.5 9h10a5 5 0 010 10H11"/>',
    over: '<path d="M4.5 7h15M9.5 7V4.8h5V7M6.8 7l.9 12h8.6l.9-12"/>',
    done: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    copy: '<rect x="8.5" y="8.5" width="11" height="11" rx="2.5"/><path d="M15.5 8.5V6.5a2 2 0 00-2-2h-7a2 2 0 00-2 2v7a2 2 0 002 2h2"/>',
    close: '<path d="M7 7l10 10M17 7L7 17"/>',
  };
  const icon = (name) => `<svg viewBox="0 0 24 24" aria-hidden="true">${ICON[name]}</svg>`;

  /* The tools, in strip order. `keys` are what the tooltip shows. */
  const TOOLS = [
    { mode: "select", action: "select", label: "Select" },
    { mode: "rect", action: "rect", label: "Rectangle" },
    { mode: "circle", action: "oval", label: "Oval" },
    { mode: "arrow", action: "arrow", label: "Arrow" },
  ];

  /* The keys, as the Pointy app's Shortcuts tab sets them (sent with "start").
     `key` is the key's name, lower-case; letters and digits are matched by the
     physical key, so ⌥R still means R when macOS would type "®". */
  const DEFAULT_KEYS = {
    select: { key: "v", label: "V" }, rect: { key: "r", label: "R" }, oval: { key: "o", label: "O" },
    arrow: { key: "a", label: "A" }, pass: { key: "h", label: "H" }, note: { key: "t", label: "T" },
    undo: { key: "z", cmd: true, label: "⌘Z" }, over: { key: "backspace", cmd: true, label: "⌘⌫" },
    done: { key: "enter", cmd: true, label: "⌘↩" },
  };
  const keyLabel = (a) => ((S.keys || DEFAULT_KEYS)[a] || DEFAULT_KEYS[a]).label;

  const CSS = `
    :host { all: initial; }
    .layer { position: fixed; inset: 0; pointer-events: auto; cursor: crosshair; }
    .layer.pass { pointer-events: none; cursor: default; }
    /* Only the numbered badges are clickable; everything else drawn must never
       intercept a drag that starts on top of an existing mark. */
    .layer > svg { position: absolute; inset: 0; width: 100%; height: 100%; overflow: visible; pointer-events: none; }
    .badge { pointer-events: auto; cursor: pointer; }
    .badge:hover circle { fill: #ff453a; }
    .hov { position: fixed; display: none; pointer-events: none; box-sizing: border-box;
           border: 1.5px dashed ${EDGE}; border-radius: 3px; background: rgba(200,245,60,.16); }
    .hov.show { display: block; }
    .hovname { position: absolute; left: -1.5px; top: 0; transform: translateY(-100%);
               background: ${EDGE}; color: ${INK}; border-radius: 5px 5px 0 0; padding: 2px 7px;
               font: 600 12px/1.5 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
               white-space: nowrap; max-width: 460px; overflow: hidden; text-overflow: ellipsis; }

    .hud { position: fixed; left: 50%; bottom: 18px; transform: translateX(-50%);
           width: min(940px, calc(100vw - 32px)); pointer-events: auto; user-select: none;
           font: 13px/1.3 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
           color: #f5f5f7; -webkit-font-smoothing: antialiased;
           animation: rise .28s cubic-bezier(.2,.8,.2,1) both; }
    @keyframes rise { from { opacity: 0; transform: translate(-50%, 10px); } to { opacity: 1; transform: translate(-50%, 0); } }
    .bar { height: 50px; border-radius: 25px; background: rgba(30,30,32,.80);
           -webkit-backdrop-filter: blur(26px) saturate(180%); backdrop-filter: blur(26px) saturate(180%);
           box-shadow: inset 0 0 0 .5px rgba(255,255,255,.16), 0 14px 40px rgba(0,0,0,.30), 0 2px 8px rgba(0,0,0,.20); }
    .main, .saved { display: flex; align-items: center; height: 100%; gap: 2px; padding: 0 7px 0 16px; }
    .saved { display: none; gap: 12px; padding: 0 7px 0 9px; }
    .hud.is-saved .main { display: none; }
    .hud.is-saved .saved { display: flex; }
    .sep { width: 1px; height: 22px; background: rgba(255,255,255,.13); margin: 0 7px; flex: none; }

    button { all: unset; box-sizing: border-box; position: relative; flex: none;
             display: inline-flex; align-items: center; justify-content: center; gap: 6px;
             width: 36px; height: 36px; border-radius: 12px; color: rgba(255,255,255,.86);
             transition: background-color .15s ease, color .15s ease; }
    button:hover { background: rgba(255,255,255,.10); color: #fff; }
    button:active { background: rgba(255,255,255,.17); }
    button svg { display: block; width: 20px; height: 20px; flex: none; fill: none; stroke: currentColor; stroke-width: 1.7;
                 stroke-linecap: round; stroke-linejoin: round; }
    button.on, button.on:hover { background: ${INK}; color: ${EDGE}; }
    /* Tools carry their key: icon, then a small keycap. */
    button.tool { width: auto; height: 36px; padding: 0 8px 0 9px; gap: 5px; }
    button.tool kbd { display: inline-flex; align-items: center; justify-content: center; min-width: 15px; height: 15px;
                      padding: 0 3px; box-sizing: border-box; border-radius: 4px;
                      font: 600 10px/1 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
                      color: rgba(255,255,255,.62); background: rgba(255,255,255,.10);
                      box-shadow: inset 0 -.5px 0 rgba(255,255,255,.12); }
    button.tool.on kbd { color: ${EDGE}; background: rgba(17,17,17,.12); box-shadow: none; }
    button.wide { width: auto; padding: 0 12px; font-weight: 600; font-size: 13px; }
    .done { width: auto; height: 36px; padding: 0 13px 0 10px; margin-left: 4px; border-radius: 18px;
            background: ${INK}; color: ${EDGE}; font-weight: 600; font-size: 13px; }
    .done:hover { background: #d6fa6e; color: ${EDGE}; }
    .done kbd { font: 500 11.5px/1 -apple-system, system-ui, sans-serif; opacity: .5; margin-left: 1px; }
    .done.busy { opacity: .7; }
    .over.armed, .over.armed:hover { width: auto; padding: 0 12px; background: #ff453a; color: #fff;
                                     font-weight: 600; font-size: 13px; }

    /* Tooltips: name and key, after a short hover, above the strip. */
    [data-tip]:hover::after { content: attr(data-tip); position: absolute; bottom: calc(100% + 12px); left: 50%;
      transform: translateX(-50%); white-space: pre; pointer-events: none;
      font: 500 12px/1 -apple-system, system-ui, sans-serif; color: #fff; padding: 6px 9px; border-radius: 8px;
      background: rgba(30,30,32,.94); box-shadow: inset 0 0 0 .5px rgba(255,255,255,.14), 0 6px 18px rgba(0,0,0,.28);
      animation: tip .14s .4s both; }
    @keyframes tip { from { opacity: 0; } to { opacity: 1; } }

    .rec { display: flex; align-items: center; gap: 9px; flex: none; color: rgba(255,255,255,.72);
           font-variant-numeric: tabular-nums; font-size: 13px; }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: #ff453a;
           box-shadow: 0 0 0 3px rgba(255,69,58,.20); animation: pulse 1.8s ease-in-out infinite; }
    .dot.off { background: rgba(255,255,255,.32); box-shadow: none; animation: none; }
    @keyframes pulse { 50% { opacity: .45; } }
    .count { display: none; min-width: 20px; height: 20px; padding: 0 6px; box-sizing: border-box; border-radius: 10px;
             background: rgba(255,255,255,.13); color: #fff; font-size: 11.5px; font-weight: 600;
             align-items: center; justify-content: center; }
    .count.show { display: inline-flex; }

    .say { flex: 1; min-width: 0; display: flex; align-items: center; gap: 10px; height: 36px; padding: 0 4px; }
    .status { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
              font-size: 13px; color: rgba(255,255,255,.55); }
    .meter { display: flex; align-items: center; gap: 2.5px; height: 18px; flex: none; }
    .meter i { width: 3px; height: 3px; border-radius: 2px; background: ${INK}; transition: height .14s ease-out; }
    .meter.idle i { background: rgba(255,255,255,.28); height: 3px !important; }
    .meter.guess i { animation: guess 1.1s ease-in-out infinite; }
    .meter.guess i:nth-child(2) { animation-delay: .15s; } .meter.guess i:nth-child(3) { animation-delay: .3s; }
    .meter.guess i:nth-child(4) { animation-delay: .45s; } .meter.guess i:nth-child(5) { animation-delay: .6s; }
    @keyframes guess { 50% { height: 12px; } }
    /* Above the strip, centred: messages, then the live subtitle — your words,
       as in macOS Live Captions. Newest words stay in view; older ones fade off left. */
    .above { position: absolute; left: 0; right: 0; bottom: calc(100% + 10px); pointer-events: none;
             display: flex; flex-direction: column; align-items: center; gap: 8px; }
    .subtitle { display: none; max-width: min(720px, 100%); box-sizing: border-box; padding: 9px 18px; border-radius: 16px;
                background: rgba(30,30,32,.82); -webkit-backdrop-filter: blur(24px) saturate(180%); backdrop-filter: blur(24px) saturate(180%);
                box-shadow: inset 0 0 0 .5px rgba(255,255,255,.14), 0 10px 30px rgba(0,0,0,.25); }
    .subtitle.show { display: flex; }
    .subtitle .line { display: flex; justify-content: flex-end; overflow: hidden; white-space: nowrap; min-width: 0;
                      font-size: 15px; line-height: 1.35; letter-spacing: -.005em;
                      -webkit-mask-image: linear-gradient(to right, transparent, #000 40px);
                      mask-image: linear-gradient(to right, transparent, #000 40px); }
    .subtitle .line > span { flex: none; }
    .subtitle .final { color: rgba(255,255,255,.95); }
    .subtitle .interim { color: rgba(255,255,255,.48); }
    .note { all: unset; display: none; flex: 1; min-width: 0; height: 32px; padding: 0 12px; box-sizing: border-box;
            border-radius: 10px; background: rgba(255,255,255,.10); color: #fff; font-size: 13.5px;
            box-shadow: inset 0 0 0 1px rgba(200,245,60,.55); }
    .note::placeholder { color: rgba(255,255,255,.40); }
    .say.typing .note { display: block; }
    .say.typing .status, .say.typing .meter { display: none; }

    .toast { max-width: calc(100% - 40px); width: max-content; display: none; padding: 8px 14px; border-radius: 14px;
             font-size: 12.5px; line-height: 1.35; text-align: center; color: #fff; background: rgba(30,30,32,.90);
             -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px);
             box-shadow: inset 0 0 0 .5px rgba(255,255,255,.14), 0 8px 24px rgba(0,0,0,.25); }
    .toast.show { display: block; }
    .toast.warn { background: rgba(255,214,10,.96); color: #1d1d1f; box-shadow: 0 8px 24px rgba(0,0,0,.25); }
    .toast.err { background: rgba(255,69,58,.96); color: #fff; box-shadow: 0 8px 24px rgba(0,0,0,.25); }

    .tick { width: 32px; height: 32px; border-radius: 50%; background: ${INK}; color: ${EDGE}; flex: none;
            display: inline-flex; align-items: center; justify-content: center; }
    .tick svg { width: 18px; height: 18px; fill: none; stroke: currentColor; stroke-width: 2.2;
                stroke-linecap: round; stroke-linejoin: round; }
    .saved .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
    .saved .title { font-weight: 600; font-size: 13.5px; color: #fff; }
    .saved .sub { font-size: 12px; color: rgba(255,255,255,.55); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  `;

  let host, root, layer, gfx, hov, hovName, hud, toast, elDot, elTime, elCount, elSay, elMeter, elStatus, elSubtitle, elCaption,
      elNote, elOver, elDone, elSavedSub, elCopyAgain;

  function build() {
    host = document.createElement("div");
    host.id = "ui-notes-host";
    host.style.cssText = "position:fixed;inset:0;z-index:2147483600;pointer-events:none;";
    root = host.attachShadow({ mode: "open" });
    // Each tool shows its key beside the icon, so the shortcut is learnt by looking.
    const tool = (t) => `<button class="tool" data-mode="${t.mode}" data-action="${t.action}" aria-label="${t.label}" data-tip="${t.label}">${icon(t.mode)}<kbd data-k="${t.action}"></kbd></button>`;
    root.innerHTML = `
      <style>${CSS}</style>
      <div class="layer">
        <svg xmlns="http://www.w3.org/2000/svg">
          <defs>
            <marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="4.5" markerHeight="4.5" orient="auto-start-reverse">
              <path d="M0,0 L10,5 L0,10 z" fill="${INK}" stroke="${EDGE}" stroke-width="1.4" stroke-linejoin="round"></path>
            </marker>
          </defs>
          <g class="g"></g>
        </svg>
        <div class="hov"><span class="hovname"></span></div>
      </div>
      <div class="hud" role="toolbar" aria-label="Pointy">
        <div class="above">
          <div class="toast" role="status"></div>
          <div class="subtitle" aria-live="polite"><div class="line"><span></span></div></div>
        </div>
        <div class="bar">
          <div class="main">
            <div class="rec" title="Pointy v${VERSION}"><span class="dot"></span><span class="time">0:00</span><span class="count"></span></div>
            <div class="sep"></div>
            ${TOOLS.map(tool).join("")}
            <button class="tool pass" data-action="pass" aria-label="Use the page" data-tip="Use the page">${icon("pass")}<kbd data-k="pass"></kbd></button>
            <div class="sep"></div>
            <div class="say">
              <div class="meter idle"><i></i><i></i><i></i><i></i><i></i></div>
              <span class="status"></span>
              <input class="note" type="text" placeholder="Type a note for the last mark, then Return" />
            </div>
            <div class="sep"></div>
            <button class="tool type" data-action="note" aria-label="Type a note" data-tip="Type a note">${icon("note")}<kbd data-k="note"></kbd></button>
            <button class="tool undo" data-action="undo" aria-label="Undo" data-tip="Undo">${icon("undo")}<kbd data-k="undo"></kbd></button>
            <button class="tool over" data-action="over" aria-label="Start over" data-tip="Start over">${icon("over")}<kbd data-k="over"></kbd></button>
            <button class="done" data-action="done" aria-label="Done">${icon("done")}<span>Done</span><kbd data-k="done"></kbd></button>
          </div>
          <div class="saved">
            <span class="tick">${icon("done")}</span>
            <div class="text"><span class="title">Brief copied</span><span class="sub"></span></div>
            <button class="copy wide">${icon("copy")}<span>Copy again</span></button>
            <button class="close" aria-label="Close" data-tip="Close">${icon("close")}</button>
          </div>
        </div>
      </div>`;
    layer = root.querySelector(".layer");
    gfx = root.querySelector(".g");
    hov = root.querySelector(".hov");
    hovName = root.querySelector(".hovname");
    hud = root.querySelector(".hud");
    toast = root.querySelector(".toast");
    elDot = root.querySelector(".dot");
    elTime = root.querySelector(".time");
    elCount = root.querySelector(".count");
    elSay = root.querySelector(".say");
    elMeter = root.querySelector(".meter");
    elStatus = root.querySelector(".status");
    elSubtitle = root.querySelector(".subtitle");
    elCaption = root.querySelector(".subtitle .line > span");
    elNote = root.querySelector(".note");
    elOver = root.querySelector(".over");
    elDone = root.querySelector(".done");
    elSavedSub = root.querySelector(".saved .sub");
    elCopyAgain = root.querySelector(".copy");
    for (const stale of document.querySelectorAll("#ui-notes-host")) {
      if (stale !== host) stale.remove();
    }
    document.documentElement.appendChild(host);
    applyKeys();

    layer.addEventListener("pointerdown", onDown);
    layer.addEventListener("pointermove", onMove);
    layer.addEventListener("pointerup", onUp);
    layer.addEventListener("pointercancel", onUp);
    layer.addEventListener("contextmenu", (e) => e.preventDefault());
    layer.addEventListener("pointerleave", hideHover);
    for (const b of root.querySelectorAll(".tool[data-mode]")) b.addEventListener("click", () => setMode(b.dataset.mode));
    root.querySelector(".pass").addEventListener("click", togglePass);
    root.querySelector(".type").addEventListener("click", openNote);
    root.querySelector(".undo").addEventListener("click", undo);
    elOver.addEventListener("click", startOver);
    elDone.addEventListener("click", finish);
    elCopyAgain.addEventListener("click", onCopy);
    root.querySelector(".close").addEventListener("click", hide);
    hud.addEventListener("pointerenter", () => clearTimeout(S.hideTimer));
    hud.addEventListener("pointerleave", () => { if (hud.classList.contains("is-saved")) scheduleHide(2500); });
    elNote.addEventListener("keydown", onNoteKey);
    window.addEventListener("scroll", hideHover, { passive: true });
    window.addEventListener("keyup", onKeyUp, true);
    window.addEventListener("scroll", renderMarks, { passive: true });
    window.addEventListener("resize", renderMarks, { passive: true });
    window.addEventListener("keydown", onKey, true);
  }

  /* ---------------------------------------------------- React introspection */

  const fiberKey = (el) => Object.keys(el).find((k) => k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$"));

  /* A production build renames every component to `x`, `f`, `p`. Those names are
     worse than no name: they read as identification and mean nothing, and they
     shadow the tag/aria/text fallback that WOULD have identified the element.
     Real component names are PascalCase and longer than two characters. */
  const REAL_NAME = /^[A-Z][A-Za-z0-9_]{2,}$/;

  /* Framework wrappers by SHAPE, not by name. An exact list always lags:
     HTTPAccessFallbackErrorBoundary walked straight past one that had
     HTTPAccessFallbackBoundary in it. Costs us a user component literally
     called ErrorBoundary or AuthProvider — which is a wrapper anyway, not
     the thing you point a cursor at. `Context$` and `Providers$` because the
     list stopped at RouterContext, and `NavigationPromisesContext` then named
     20 of 20 marks on a server-rendered page ("in Providers › SearchParamsContext"). */
  const FRAMEWORK_SHAPE = /(?:Boundary|Router|Context|Providers?|Consumer|Overlay|Handler|DevTools)$|^(?:Segment|Async|Outer|Inner|Client|Hot|Render)[A-Z]|Fallback|LayoutRouter/;
  /* React wrappers, plus the App Router internals every client component sits
     inside. Without the second half, a real chain reads "StatsBand ›
     HomeAuthGate › SegmentViewNode › LayoutRouterContext › InnerLayoutRouter"
     and the useful part is buried under framework furniture. */
  const SKIP = /^(Fragment|Suspense|SuspenseList|Profiler|StrictMode|Provider|Consumer|ForwardRef|Memo|Portal|Root|_c\d*|Object|Array|AppRouter|OuterLayoutRouter|InnerLayoutRouter|LayoutRouterContext|RenderFromTemplateContext|ScrollAndFocusHandler|SegmentViewNode|SegmentViewStateNode|RedirectBoundary|RedirectErrorBoundary|NotFoundBoundary|NotFoundErrorBoundary|HTTPAccessFallbackBoundary|DevRootHTTPAccessFallbackBoundary|LoadingBoundary|ErrorBoundary|ErrorBoundaryHandler|ClientPageRoot|ClientSegmentRoot|MetadataBoundary|ViewportBoundary|OutletBoundary|AsyncMetadata|AsyncMetadataOutlet|HotReload|ReactDevOverlay|DevOverlay|Router|ServerRoot|AppDevOverlay|AppDevOverlayErrorBoundary|PathnameContextProviderAdapter|TemplateContext|HistoryUpdater|__next_root_layout_boundary__)$/;

  /* Only components someone wrote: functions, forwardRef and memo. A context
     object carries a displayName too — Next sets "NavigationPromisesContext" —
     and accepting any object with a name is how contexts got into the chain. */
  function componentName(t) {
    if (typeof t === "function") return t.displayName || t.name || null;
    if (t && typeof t === "object") {
      if (t.render) return t.displayName || t.render.displayName || t.render.name || null;
      if (t.type) return t.displayName || t.type.displayName || t.type.name || null;
    }
    return null;
  }

  /**
   * chain: the components this element sits inside, nearest first.
   * own:   the component this element IS — set only when no other DOM node lies
   *        between the element and that component, i.e. the element is what the
   *        component renders at its top. A <p> deep inside PortfolioContent is
   *        not PortfolioContent; naming it so made the header, a "Based in" line
   *        and an icon row all read `PortfolioContent` in the same brief.
   */
  function fiberInfo(el) {
    const out = { chain: [], own: null };
    try {
      const k = fiberKey(el);
      if (!k) return out;
      let f = el[k] && el[k].return;
      let crossedDom = false;
      let guard = 0;
      while (f && guard++ < 80 && out.chain.length < 6) {
        if (typeof f.type === "string") crossedDom = true;
        else {
          const n = componentName(f.type || f.elementType);
          if (n && REAL_NAME.test(n) && !SKIP.test(n) && !FRAMEWORK_SHAPE.test(n) && !out.chain.includes(n)) {
            out.chain.push(n);
            if (!crossedDom && !out.own) out.own = n;
          }
        }
        f = f.return;
      }
    } catch {}
    return out;
  }

  const reactChain = (el) => fiberInfo(el).chain;
  const ownComponent = (el) => fiberInfo(el).own;

  function sourceHints(el) {
    try {
      const k = fiberKey(el);
      if (!k) return [];
      let f = el[k];
      const out = [];
      let guard = 0;
      const rx = /((?:webpack-internal:\/\/\/|turbopack:\/\/\/|rsc:\/\/|file:\/\/|https?:\/\/)[^\s()'"]+?\.(?:tsx|jsx|ts|js))(?::(\d+))?/;
      while (f && guard++ < 60 && out.length < 2) {
        const st = f._debugStack;
        if (st && typeof st.stack === "string") {
          for (const line of st.stack.split("\n")) {
            const m = line.match(rx);
            if (!m) continue;
            // Turbopack dev emits ".next/dev/server/chunks/ssr/%5Broot-of-the-
            // server%5D__0~xsiw~._.js" here — a real path to a compiled bundle,
            // which is worse than no path at all because it reads as an answer.
            if (/node_modules|[/.]next\/|\/chunks\/|%5B|%255B/.test(m[1])) continue;
            const s = m[1] + (m[2] ? ":" + m[2] : "");
            if (!out.includes(s)) out.push(s);
            break;
          }
        }
        f = f.return;
      }
      return out;
    } catch { return []; }
  }

  function cssPath(el) {
    const parts = [];
    let cur = el;
    while (cur && cur.nodeType === 1 && parts.length < 7) {
      if (cur.id) { parts.unshift(`#${cur.id}`); break; }
      if (cur === document.body) { parts.unshift("body"); break; }
      const p = cur.parentElement;
      if (!p) { parts.unshift(cur.tagName.toLowerCase()); break; }
      parts.unshift(`${cur.tagName.toLowerCase()}:nth-child(${Array.prototype.indexOf.call(p.children, cur) + 1})`);
      cur = p;
    }
    return parts.join(" > ");
  }

  /* --------------------------------------------------------------- naming */

  const classOf = (el) => (typeof el.className === "string" ? el.className : el.getAttribute("class") || "") || "";
  const textOf = (el, n) => ((el.innerText || el.textContent || "").trim().replace(/\s+/g, " ").slice(0, n) || null);

  const SEMANTIC = /^(button|a|input|select|textarea|img|svg|h1|h2|h3|h4|h5|h6|li|label|p|strong|em|code|td|th|summary|figcaption|blockquote)$/;

  /** What you would CALL this thing out loud. */
  function nameOf(el) {
    const own = ownComponent(el);
    if (own) return own;

    const cls = classOf(el);
    const lucide = /\blucide-([a-z0-9-]+)\b/.exec(cls);
    if (lucide) return `${lucide[1].replace(/-/g, " ")} icon`;

    const aria = el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("alt");
    if (aria) return aria.slice(0, 40);

    const tag = el.tagName.toLowerCase();
    if (tag === "svg") return "icon";
    const role = el.getAttribute("role");
    if (role) return role;
    return tag;
  }

  /** Icons living inside something — this is how you refer to it ("the stats icon"). */
  function iconsIn(el) {
    const out = [];
    const svgs = el.tagName.toLowerCase() === "svg" ? [el] : el.querySelectorAll("svg");
    for (const s of svgs) {
      if (out.length >= 3) break;
      const n = nameOf(s);
      if (n && n !== "svg" && n !== "icon" && !out.includes(n)) out.push(n);
    }
    return out;
  }

  /** Is this a discrete piece of UI, as opposed to a layout wrapper? */
  function nameable(el) {
    const tag = el.tagName.toLowerCase();
    if (SEMANTIC.test(tag)) return true;
    if (el.getAttribute("aria-label") || el.getAttribute("data-testid") || el.getAttribute("role")) return true;
    if (reactChain(el).length) return true;
    for (const n of el.childNodes) if (n.nodeType === 3 && n.textContent.trim()) return true;
    return false;
  }

  const docRect = (el) => {
    const r = el.getBoundingClientRect();
    return { x: r1(r.x + scrollX), y: r1(r.y + scrollY), w: r1(r.width), h: r1(r.height) };
  };

  /**
   * The compact description of one element. Deliberately small: a name, what it
   * says, where it lives. No class soup and no computed-style dump — that is
   * context spent to tell an agent what it can read for itself.
   */
  function compact(el) {
    if (!el || el.nodeType !== 1) return null;
    const react = reactChain(el).slice(0, 3);
    const source = sourceHints(el);
    const out = {
      name: nameOf(el),
      tag: el.tagName.toLowerCase(),
      text: textOf(el, 70),
      icons: iconsIn(el),
      react,
      source,
      testid: el.getAttribute("data-testid") || null,
      rect: docRect(el),
      selector: cssPath(el),
    };
    // The class string is a last resort for finding it — only when there is no
    // component name and no source path to go on.
    if (!react.length && !source.length) {
      const c = classOf(el);
      if (c) out.class = c.slice(0, 90);
    }
    return out;
  }

  /* ---------------------------------------------------------- hit testing */

  function elementAt(dx, dy) {
    const x = dx - scrollX, y = dy - scrollY;
    if (x < 0 || y < 0 || x > innerWidth || y > innerHeight) return null;
    for (const el of document.elementsFromPoint(x, y)) {
      if (el === host || host.contains(el) || el.getRootNode() === root) continue;
      if (el === document.documentElement) continue;
      return el;
    }
    return document.body;
  }

  const contains = (outer, inner, slack = 2) =>
    inner.x >= outer.x - slack && inner.y >= outer.y - slack &&
    inner.x + inner.w <= outer.x + outer.w + slack && inner.y + inner.h <= outer.y + outer.h + slack;

  function smallestContaining(box) {
    let el = elementAt(box.x + box.w / 2, box.y + box.h / 2) || document.body;
    let guard = 0;
    while (el && el !== document.body && guard++ < 30) {
      if (contains(docRect(el), box, 0)) return el;
      el = el.parentElement;
    }
    return document.body;
  }

  /**
   * Everything that sits FULLY inside the shape — outermost only, so you get
   * the four cards you drew around, not the four cards plus every heading,
   * span and svg nested inside them.
   */
  function selectInside(box) {
    const container = smallestContaining(box);
    const inside = [];
    for (const el of container.querySelectorAll("*")) {
      if (el === host || host.contains(el)) continue;
      const r = docRect(el);
      if (r.w < 3 || r.h < 3) continue;
      if (contains(box, r)) inside.push(el);
    }
    const set = new Set(inside);
    const outermost = inside.filter((el) => !set.has(el.parentElement));
    return { container, outermost };
  }

  /** Are these all children of one parent, and how are they laid out today? */
  function groupInfo(els) {
    if (els.length < 2) return null;
    const p = els[0].parentElement;
    if (!p || !els.every((e) => e.parentElement === p)) return null;
    const cs = getComputedStyle(p);
    const column = /column/.test(cs.flexDirection || "");
    const rects = els.map(docRect).sort((a, b) => (column ? a.y - b.y : a.x - b.x));
    const gaps = [];
    for (let i = 1; i < rects.length; i++) {
      const a = rects[i - 1], b = rects[i];
      gaps.push(r1(column ? b.y - (a.y + a.h) : b.x - (a.x + a.w)));
    }
    return {
      parent: nameOf(p),
      parentSource: sourceHints(p)[0] || null,
      display: cs.display,
      flexDirection: cs.flexDirection && cs.flexDirection !== "row" ? cs.flexDirection : null,
      gridTemplateColumns: cs.gridTemplateColumns && cs.gridTemplateColumns !== "none" ? cs.gridTemplateColumns : null,
      gap: cs.gap && cs.gap !== "normal" ? cs.gap : null,
      measuredGaps: gaps,
      childCount: p.children.length,
    };
  }

  /* ------------------------------------------------- arrow ends: thing or space */

  /** The nameable thing at this point, if the point is really ON something. */
  function targetAt(dx, dy) {
    let el = elementAt(dx, dy);
    const viewportArea = innerWidth * innerHeight;
    let guard = 0;
    while (el && el !== document.body && guard++ < 4) {
      const r = docRect(el);
      if (nameable(el) && r.w * r.h < viewportArea * 0.55) return el;
      el = el.parentElement;
    }
    return null;
  }

  /** No element here — so say where "here" is, in terms of what surrounds it. */
  function describeSpace(dx, dy) {
    const isContainer = (el) =>
      reactChain(el).length ||
      /^(section|main|header|footer|nav|article|aside|form|dialog)$/.test(el.tagName.toLowerCase()) ||
      !!el.id;
    let container = elementAt(dx, dy) || document.body;
    let guard = 0;
    while (container && container !== document.body && !isContainer(container) && guard++ < 10) {
      container = container.parentElement;
    }
    container = container || document.body;
    const cr = docRect(container);
    const viewportArea = innerWidth * innerHeight;

    const best = { left: null, right: null, above: null, below: null };
    for (const el of container.querySelectorAll("*")) {
      if (el === host || host.contains(el) || !nameable(el)) continue;
      const r = docRect(el);
      if (r.w < 10 || r.h < 10 || r.w * r.h > viewportArea * 0.5) continue;
      if (dx >= r.x && dx <= r.x + r.w && dy >= r.y && dy <= r.y + r.h) continue;
      const vNear = !(r.y + r.h < dy - 60 || r.y > dy + 60);
      const hNear = !(r.x + r.w < dx - 60 || r.x > dx + 60);
      const put = (k, d) => { if (!best[k] || d < best[k].d) best[k] = { el, r, d: r1(d) }; };
      if (vNear && r.x + r.w <= dx) put("left", dx - (r.x + r.w));
      if (vNear && r.x >= dx) put("right", r.x - dx);
      if (hNear && r.y + r.h <= dy) put("above", dy - (r.y + r.h));
      if (hNear && r.y >= dy) put("below", r.y - dy);
    }

    const neighbours = [];
    for (const dir of ["left", "right", "above", "below"]) {
      const b = best[dir];
      if (!b) continue;
      neighbours.push({ dir, gap: b.d, name: nameOf(b.el), text: textOf(b.el, 46), source: sourceHints(b.el)[0] || null });
    }

    return {
      container: { name: nameOf(container), source: sourceHints(container)[0] || null, rect: cr },
      atPct: { x: cr.w ? Math.round(((dx - cr.x) / cr.w) * 100) : null, y: cr.h ? Math.round(((dy - cr.y) / cr.h) * 100) : null },
      neighbours,
    };
  }

  const endpoint = (dx, dy) => {
    const el = targetAt(dx, dy);
    return el ? { kind: "element", el: compact(el) } : { kind: "space", space: describeSpace(dx, dy) };
  };

  /* ---------------------------------------------------------------- hover */

  function hideHover() {
    S.hoverRaw = null;
    S.hoverEl = null;
    if (hov) hov.classList.remove("show");
  }

  /**
   * Outline what a click would take, before it is taken. Resolving the target
   * walks React fibers, so recompute only when the raw element under the cursor
   * actually changes — a pointermove fires far too often for that work.
   */
  function updateHover(cx, cy, shift) {
    if (!S.on || S.pass || S.drawing || !hov) return hideHover();
    S.lastPt = [cx, cy];
    const dx = cx + scrollX, dy = cy + scrollY;
    const raw = elementAt(dx, dy);
    if (!raw) return hideHover();
    if (raw === S.hoverRaw && shift === S.hoverShift && hov.classList.contains("show")) return;
    S.hoverRaw = raw;
    S.hoverShift = shift;

    let el = targetAt(dx, dy) || raw;
    if (shift && el.parentElement && el.parentElement !== document.body) el = el.parentElement;

    S.hoverEl = el;
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return hideHover();
    hov.style.left = r.x + "px";
    hov.style.top = r.y + "px";
    hov.style.width = r.width + "px";
    hov.style.height = r.height + "px";
    const t = textOf(el, 42);
    hovName.textContent = nameOf(el) + (t ? ` — ${t}` : "") + (shift ? "  ↑parent" : "");
    hov.classList.add("show");
  }

  /* --------------------------------------------------------------- drawing */

  function onDown(e) {
    if (!S.on || S.pass || e.button !== 0) return;
    // A click on a number badge deletes that mark rather than starting a drag.
    const badge = e.target && e.target.closest && e.target.closest(".badge");
    if (badge) {
      e.preventDefault(); e.stopPropagation();
      deleteMark(badge.getAttribute("data-uid"));
      return;
    }
    e.preventDefault();
    // Grab what was outlined before hideHover() drops it — the live preview
    // keeps showing that same element while the pointer is held.
    const picked = S.hoverEl || targetAt(e.clientX + scrollX, e.clientY + scrollY);
    hideHover();
    layer.setPointerCapture(e.pointerId);
    const p = [e.clientX + scrollX, e.clientY + scrollY];
    S.drawing = { a: p, b: [p[0], p[1]], t: now(), shift: e.shiftKey, el: picked };
  }

  function onMove(e) {
    if (!S.drawing) { updateHover(e.clientX, e.clientY, e.shiftKey); return; }
    e.preventDefault();
    S.drawing.b = [e.clientX + scrollX, e.clientY + scrollY];
    renderMarks();
  }

  function onUp(e) {
    if (!S.drawing) return;
    e.preventDefault();
    const d = S.drawing;
    S.drawing = null;
    const drag = Math.hypot(d.b[0] - d.a[0], d.b[1] - d.a[1]);
    // In select mode a stray drag is still a click — that is the point of it.
    commit(S.mode === "select" || drag < CLICK_PX ? "point" : S.mode, d);
  }

  const boxOf = (a, b) => ({
    x: r1(Math.min(a[0], b[0])), y: r1(Math.min(a[1], b[1])),
    w: r1(Math.abs(b[0] - a[0])), h: r1(Math.abs(b[1] - a[1])),
  });

  async function commit(kind, d) {
    const note = {
      v: 2, n: 0, uid: ++S.uidSeq, t: d.t, at: Date.now(), kind,
      url: location.href, title: document.title,
      vw: innerWidth, vh: innerHeight, dpr: devicePixelRatio || 1,
      scroll: { x: ri(scrollX), y: ri(scrollY) },
      typed: null, shot: null, crop: null,
    };

    let markBox;

    if (kind === "arrow") {
      note.arrow = { from: [ri(d.a[0]), ri(d.a[1])], to: [ri(d.b[0]), ri(d.b[1])] };
      note.tail = endpoint(d.a[0], d.a[1]);
      note.head = endpoint(d.b[0], d.b[1]);
      markBox = boxOf(d.a, d.b);
    } else if (kind === "point") {
      let el = targetAt(d.a[0], d.a[1]) || elementAt(d.a[0], d.a[1]);
      // Shift took the parent in the hover preview; take the same thing here,
      // or the outline you committed to is not what gets recorded.
      if (d.shift && el && el.parentElement && el.parentElement !== document.body) el = el.parentElement;
      note.point = [ri(d.a[0]), ri(d.a[1])];
      note.selected = el ? [compact(el)] : [];
      note.container = el && el.parentElement ? compact(el.parentElement) : null;
      markBox = el ? docRect(el) : { x: d.a[0] - 20, y: d.a[1] - 20, w: 40, h: 40 };
    } else {
      const box = boxOf(d.a, d.b);
      const { container, outermost } = selectInside(box);
      // A 25px rectangle that encloses nothing was a click that wobbled. Use the
      // OUTCOME to recover the intent rather than guessing from distance alone.
      if (!outermost.length && Math.hypot(box.w, box.h) < SLIP_PX) {
        return commit("point", d); // nothing was pushed yet; start over as a click
      }
      note.shape = box;
      note.selected = outermost.slice(0, 14).map(compact);
      note.truncated = Math.max(0, outermost.length - 14);
      note.group = groupInfo(outermost);
      // Nothing sits fully inside — you drew inside a single thing, so say which.
      note.container = outermost.length ? null : compact(container);
      markBox = box;
    }

    S.notes.push(note);
    renderMarks();
    paint();

    const pad = 90;
    const cx = Math.max(0, markBox.x - scrollX - pad);
    const cy = Math.max(0, markBox.y - scrollY - pad);
    const crop = {
      x: cx, y: cy,
      w: Math.min(innerWidth - cx, Math.max(340, markBox.w + pad * 2)),
      h: Math.min(innerHeight - cy, Math.max(240, markBox.h + pad * 2)),
    };
    hideHover();
    hud.style.visibility = "hidden";
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    const res = await call("shot", { rect: crop, dpr: note.dpr });
    hud.style.visibility = "";
    if (res && res.ok) { note.n = res.seq; note.shot = res.shot; note.crop = res.crop; }
    renderMarks();
    paint();
    call("note", note).then((r) => { if (r && r.count) S.sessionCount = r.count; });
  }

  /* -------------------------------------------------------------- rendering */

  function svgEl(name, attrs) {
    const e = document.createElementNS("http://www.w3.org/2000/svg", name);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    return e;
  }

  function shapeFor(kind, box, arrow, point) {
    if (kind === "arrow") return ["line", { x1: arrow.from[0], y1: arrow.from[1], x2: arrow.to[0], y2: arrow.to[1] }];
    if (kind === "point") return ["circle", { cx: point[0], cy: point[1], r: 13, fill: "none" }];
    if (kind === "circle") return ["ellipse", { cx: box.x + box.w / 2, cy: box.y + box.h / 2, rx: Math.max(1, box.w / 2), ry: Math.max(1, box.h / 2), fill: "none" }];
    return ["rect", { x: box.x, y: box.y, width: Math.max(1, box.w), height: Math.max(1, box.h), rx: 4, fill: "none" }];
  }

  function renderMarks() {
    if (!gfx) return;
    gfx.setAttribute("transform", `translate(${-scrollX},${-scrollY})`);
    gfx.textContent = "";

    /* Every stroke gets a near-black under-layer: these sit on top of arbitrary
       page backgrounds, and lime alone vanishes on white. */
    const stroke = (name, attrs, color, width, live) => {
      gfx.appendChild(svgEl(name, { ...attrs, fill: "none", stroke: "rgba(17,17,17,.9)",
        "stroke-width": width + 4, "stroke-linecap": "round", "stroke-linejoin": "round" }));
      const ink = svgEl(name, { ...attrs, stroke: color, "stroke-width": width,
        "stroke-linecap": "round", "stroke-linejoin": "round", opacity: live ? 0.85 : 1 });
      gfx.appendChild(ink);
      return ink;
    };

    const badgeAt = (bx, by, label, uid, color) => {
      if (label == null) return;
      const g = svgEl("g", { class: "badge", "data-uid": String(uid) });
      g.appendChild(svgEl("circle", { cx: bx - 4, cy: by - 14, r: 11, fill: color, stroke: EDGE, "stroke-width": 1.5 }));
      const t = svgEl("text", {
        x: bx - 4, y: by - 14, fill: color === INK ? EDGE : "#fff", "text-anchor": "middle", "dominant-baseline": "central",
        "font-size": 13, "font-weight": 700, "font-family": "ui-sans-serif, system-ui, sans-serif",
        "pointer-events": "none",
      });
      t.textContent = String(label);
      g.appendChild(t);
      gfx.appendChild(g);
    };

    const outlineEl = (r, width, fill) =>
      stroke("rect", { x: r.x, y: r.y, width: Math.max(1, r.w), height: Math.max(1, r.h), rx: 4, fill },
        GREEN, width);

    for (const n of S.notes) {
      // A whole element picked as one thing: outline what was actually taken,
      // in green, rather than dropping a circle at the cursor. The outline IS
      // the confirmation that the whole element came along.
      if (n.kind === "point") {
        const r = n.selected && n.selected[0] && n.selected[0].rect;
        if (r) {
          outlineEl(r, 3, "rgba(22,163,74,.10)");
          badgeAt(r.x, r.y, n.n || "•", n.uid, GREEN);
        } else {
          stroke("circle", { cx: n.point[0], cy: n.point[1], r: 13 }, GREEN, 3);
          badgeAt(n.point[0], n.point[1], n.n || "•", n.uid, GREEN);
        }
        continue;
      }

      const box = n.shape || (n.arrow ? boxOf(n.arrow.from, n.arrow.to) : { x: 0, y: 0, w: 0, h: 0 });
      const [name, attrs] = shapeFor(n.kind, box, n.arrow, n.point);
      const ink = stroke(name, attrs, INK, 3);
      if (n.kind === "arrow") ink.setAttribute("marker-end", "url(#ah)");

      // Same idea for a shape that captured elements: show which ones it got.
      for (const el of n.selected || []) if (el && el.rect) outlineEl(el.rect, 2, "none");

      const bx = n.kind === "arrow" ? n.arrow.from[0] : box.x;
      const by = n.kind === "arrow" ? n.arrow.from[1] : box.y;
      badgeAt(bx, by, n.n || "•", n.uid, INK);
    }

    if (S.drawing) {
      const d = S.drawing;
      const drag = Math.hypot(d.b[0] - d.a[0], d.b[1] - d.a[1]);
      const kind = S.mode === "select" || drag < CLICK_PX ? "point" : S.mode;
      if (kind === "point") {
        // Mirror the hover outline so the preview matches what lands.
        const el = d.el;
        if (el) {
          const r = el.getBoundingClientRect();
          outlineEl({ x: r.x + scrollX, y: r.y + scrollY, w: r.width, h: r.height }, 3, "rgba(22,163,74,.10)");
        } else {
          stroke("circle", { cx: d.a[0], cy: d.a[1], r: 13 }, GREEN, 3, true);
        }
      } else {
        const [nm, at] = shapeFor(kind, boxOf(d.a, d.b), { from: d.a, to: d.b }, d.a);
        const ink = stroke(nm, at, INK, 3, true);
        if (kind === "arrow") ink.setAttribute("marker-end", "url(#ah)");
      }
    }
  }

  const escapeHtml = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  /* The strip's status: the state of the microphone in a few words — never a
     blank strip that might be broken. The words themselves go in the subtitle. */
  function statusText() {
    if (S.pass) return "Using the page · H to draw";
    if (S.micOk === false) return "Mic off · T to type";
    if (S.engine !== "browser") {
      if (S.stage === "waiting-for-permission") return "Allow the mic in Pointy";
      if (S.stage === "preparing-model" || S.stage === "starting") return "Getting ready…";
    }
    return S.rec ? "Listening…" : "Not listening · T to type";
  }

  const BARS = [0.45, 0.8, 1, 0.7, 0.5];

  function paint() {
    if (!hud) return;
    const secs = Math.max(0, Math.floor(now() / 1000));
    elDot.classList.toggle("off", !S.rec);
    elTime.textContent = `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, "0")}`;
    const count = Math.max(S.notes.length, S.sessionCount || 0);
    elCount.textContent = count;
    elCount.classList.toggle("show", count > 0);
    elCount.title = `${count} mark${count === 1 ? "" : "s"}`;

    for (const b of root.querySelectorAll(".tool[data-mode]")) b.classList.toggle("on", !S.pass && b.dataset.mode === S.mode);
    root.querySelector(".pass").classList.toggle("on", S.pass);

    // Live subtitle: finished words bright, the phrase still being heard dim.
    // Right-aligned and clipped on the left, so the newest words are always visible.
    const final = (S.tail || "").slice(-300);
    const words = !S.pass && !!(final || S.interim);
    elSubtitle.classList.toggle("show", words);
    if (words) elCaption.innerHTML = `<span class="final">${escapeHtml(final)}</span>${S.interim ? `<span class="interim"> ${escapeHtml(S.interim)}</span>` : ""}`;
    elStatus.textContent = statusText();

    // The meter follows the app's real input level; with browser speech there is
    // no level to read, so it breathes while recognition is on.
    const live = !!S.rec && !S.pass;
    elMeter.classList.toggle("idle", !live);
    elMeter.classList.toggle("guess", live && S.engine === "browser");
    const bars = elMeter.children;
    for (let i = 0; i < bars.length; i++) {
      bars[i].style.height = live && S.engine !== "browser" ? `${3 + Math.round(BARS[i] * (S.level || 0) * 15)}px` : "";
    }

    if (S.micOk !== false && !S.speechCount && S.notes.length && now() > 12000 && !S.warn) {
      S.warn = "No speech heard yet. Check the microphone, or press T to type.";
      S.micOk = false;
    }
    const msg = S.warn || S.banner;
    toast.textContent = msg;
    toast.classList.toggle("show", !!msg);
    toast.classList.toggle("err", !!S.warn && S.micOk === false);
    toast.classList.toggle("warn", !!S.warn && S.micOk !== false);

    const armed = Date.now() - S.confirmAt < 4000;
    elOver.classList.toggle("armed", armed);
    elOver.innerHTML = armed ? `Discard ${count} mark${count === 1 ? "" : "s"}?` : `${icon("over")}<kbd data-k="over">${keyLabel("over")}</kbd>`;
    elDone.classList.toggle("busy", S.saving);
    elDone.querySelector("span").textContent = S.saving ? "Saving…" : "Done";
  }

  /** A short message above the strip that clears itself. */
  function flash(text, ms = 1800) {
    S.banner = text;
    paint();
    setTimeout(() => { if (S.banner === text) { S.banner = ""; paint(); } }, ms);
  }

  /** Drop one mark. Numbers do NOT shift: the screenshots are named by them. */
  function deleteMark(uid) {
    const i = S.notes.findIndex((x) => String(x.uid) === String(uid));
    if (i < 0) return;
    const note = S.notes[i];
    S.notes.splice(i, 1);
    renderMarks();
    call("dropnote", { at: note.at, kind: note.kind, shot: note.shot, crop: note.crop })
      .then((r) => { if (r && typeof r.count === "number") { S.sessionCount = r.count; paint(); } });
    flash(`${note.n ? `Mark ${note.n}` : "Mark"} deleted`);
  }

  /* ----------------------------------------------------------------- speech */

  /* With an on-device engine selected in the Pointy app, the app does the
     listening: no Web Speech, no per-site microphone prompt, nothing sent to the
     browser's speech service. The overlay switches it on and off and polls the
     live text four times a second, which also drives the level meter — and the
     poll is the app's heartbeat, so a tab closed mid-session stops the
     microphone within seconds. */
  function startAppSpeech() {
    S.rec = "app";
    S.stage = "starting";
    call("listen", { on: true });
    clearInterval(S.poll);
    S.poll = setInterval(async () => {
      const st = await call("transcript", {});
      if (S.rec !== "app" || !st) return;
      if (st.error) { S.warn = st.error; S.micOk = false; }
      S.stage = st.stage || "";
      S.level = st.level || 0;
      S.tail = st.tail || "";
      S.interim = st.interim || "";
      S.speechCount = st.count || 0;
      paint();
    }, 250);
  }

  function startSpeech() {
    if (S.engine !== "browser") return startAppSpeech();
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SR) { S.warn = "This browser has no speech recognition. Press T to type notes, or pick an on-device engine in the Pointy app."; return; }
    let rec;
    try { rec = new SR(); } catch { S.warn = "Speech isn't available here. Press T to type notes."; return; }
    rec.continuous = true;
    rec.interimResults = true;
    rec.lang = "en-US";
    // Chrome resets resultIndex to 0 on every restart, so the key carries the
    // restart generation — otherwise each sentence after a pause inherits an
    // old timestamp and attaches to the wrong mark.
    let run = ++S.recRun;
    const seen = new Map();

    rec.onresult = (e) => {
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const key = `${run}:${i}`;
        if (!seen.has(key)) seen.set(key, now());
        const r = e.results[i];
        if (r.isFinal) {
          const text = (r[0].transcript || "").trim();
          if (text) {
            S.tail = (S.tail + " " + text).trim().slice(-220);
            S.interim = "";
            S.speechCount++;
            call("speech", { t: seen.get(key), at: S.t0 + seen.get(key), text, url: location.href });
          }
        } else S.interim = r[0].transcript || "";
      }
      paint();
    };
    rec.onerror = (e) => {
      if (e.error === "not-allowed" || e.error === "service-not-allowed") {
        S.warn = "The microphone is blocked for this site. Allow it, or press T to type.";
        S.rec = null; paint();
      }
    };
    rec.onend = () => { if (S.on && S.rec === rec) { run = ++S.recRun; try { rec.start(); } catch {} } };
    try { rec.start(); S.rec = rec; } catch { S.warn = "Could not start the microphone."; }
  }

  /**
   * Ask for the microphone explicitly rather than letting the speech API ask on
   * our behalf. A denied prompt is then a fact we can report loudly, instead of
   * a session that records four marks and not one word — which is exactly what
   * happened on the first run against a site the mic had never been allowed for.
   */
  async function ensureMic() {
    if (S.engine !== "browser") { S.micOk = true; return true; } // the app holds the mic
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      stream.getTracks().forEach((t) => t.stop()); // the speech API captures its own
      S.micOk = true;
      return true;
    } catch {
      S.micOk = false;
      S.warn = "Mic off: nothing you say is recorded. Allow the microphone for this site (padlock in the address bar), then Start over. Or press T to type.";
      return false;
    }
  }

  function stopSpeech() {
    const rec = S.rec;
    S.rec = null;
    if (rec === "app") {
      clearInterval(S.poll);
      call("listen", { on: false });
      return;
    }
    if (rec) { try { rec.onend = null; rec.stop(); } catch {} }
  }

  /* ------------------------------------------------------------------- keys */

  /* Tools are single keys, as in every drawing app; anything that ends or
     throws away work takes ⌘ by default. All of it comes from the keymap the
     Pointy app sends. Escape is fixed: it only ever cancels — a shape mid-drag,
     the note field, a pending "start over", "use the page". */
  function keyName(e) {
    if (/^Key[A-Z]$/.test(e.code)) return e.code.slice(3).toLowerCase();
    if (/^Digit[0-9]$/.test(e.code)) return e.code.slice(5);
    const k = (e.key || "").toLowerCase();
    return k === " " ? "space" : k;
  }
  const matches = (e, c) => !!c && keyName(e) === c.key && !!e.metaKey === !!c.cmd && !!e.ctrlKey === !!c.ctrl
    && !!e.altKey === !!c.alt && !!e.shiftKey === !!c.shift;
  const pressed = (e) => Object.keys(DEFAULT_KEYS).find((a) => matches(e, (S.keys || DEFAULT_KEYS)[a] || DEFAULT_KEYS[a]));

  /** Put the current keys on every keycap and tooltip in the strip. */
  function applyKeys() {
    if (!root) return;
    for (const k of root.querySelectorAll("kbd[data-k]")) k.textContent = keyLabel(k.dataset.k);
    for (const b of root.querySelectorAll("[data-action]")) {
      const name = b.getAttribute("data-tip") || b.getAttribute("aria-label") || "";
      b.setAttribute("aria-label", `${name} (${keyLabel(b.dataset.action)})`);
    }
  }

  const ACTIONS = {
    select: () => setMode("select"), rect: () => setMode("rect"), oval: () => setMode("circle"), arrow: () => setMode("arrow"),
    pass: () => togglePass(), note: () => openNote(), undo: () => undo(), over: () => startOver(), done: () => finish(),
  };

  function onKey(e) {
    if (!S.on) return;
    const t = e.composedPath ? e.composedPath()[0] : e.target;
    const inNote = t === elNote;
    const typing = inNote || (t && ((t.tagName && /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName)) || t.isContentEditable));
    const stop = () => { e.preventDefault(); e.stopPropagation(); };

    if (e.key === "Escape") {
      if (inNote) { stop(); closeNote(); return; }
      if (S.drawing) { stop(); S.drawing = null; renderMarks(); return; }
      if (Date.now() - S.confirmAt < 4000) { stop(); S.confirmAt = 0; paint(); return; }
      if (S.pass) { stop(); togglePass(); return; }
      return; // nothing of ours to cancel — the page keeps its Escape
    }
    if (e.key === "Shift" && S.lastPt && !typing) { updateHover(S.lastPt[0], S.lastPt[1], true); return; }

    const action = pressed(e);
    if (!action) return;
    // While typing, only Done gets through, so letters stay letters.
    if (typing && action !== "done") return;
    stop();
    if (action === "done" && inNote) addNote();
    ACTIONS[action]();
  }

  function setMode(mode) {
    S.mode = mode;
    if (S.pass) togglePass();
    paint();
  }

  /** "Use the page": clicks, hovers and scrolls go to the page until switched back. */
  function togglePass() {
    S.pass = !S.pass;
    layer.classList.toggle("pass", S.pass);
    hideHover();
    paint();
  }

  /** Undo the newest mark — in the session too, not only on screen. */
  function undo() {
    const last = S.notes[S.notes.length - 1];
    if (last) deleteMark(last.uid);
  }

  /**
   * Throw away the session in flight and open a clean one. The first press asks;
   * a second within four seconds does it. Counts marks from the BACKGROUND, not
   * this page — a session that started two pages ago still holds them.
   */
  async function startOver() {
    const pending = Math.max(S.notes.length, S.sessionCount || 0);
    if (pending && Date.now() - S.confirmAt > 4000) {
      S.confirmAt = Date.now();
      paint();
      setTimeout(paint, 4100);
      return;
    }
    S.confirmAt = 0;
    S.warn = "";
    await call("abort", {});
    S.notes = []; S.tail = ""; S.interim = ""; S.brief = ""; S.sessionCount = 0;
    renderMarks();
    const res = await call("start", {});
    S.t0 = Date.now();
    S.engine = (res && res.engine) || "browser";
    S.keys = (res && res.keymap) || S.keys;
    applyKeys();
    if (res && !res.serverUp) S.warn = "The Pointy app isn't running. Open it from Applications.";
    // `seen` in the recogniser holds offsets against the OLD t0, so carrying it
    // over would stamp the next sentences against a clock that no longer exists.
    stopSpeech();
    S.speechCount = 0; S.micOk = null;
    await ensureMic();
    startSpeech();
    flash("Started over", 2000);
  }

  /** Put the whole brief on the clipboard again. */
  async function onCopy() {
    if (!S.brief) return;
    let ok = false;
    try { await navigator.clipboard.writeText(S.brief); ok = true; } catch {}
    if (!ok) {
      try {
        const ta = document.createElement("textarea");
        ta.value = S.brief;
        ta.style.cssText = "position:fixed;left:-9999px;top:0;opacity:0;";
        document.body.appendChild(ta);
        ta.select();
        ok = document.execCommand("copy");
        ta.remove();
      } catch {}
    }
    elCopyAgain.querySelector("span").textContent = ok ? "Copied" : "Copy failed";
    scheduleHide(1600);
  }

  /* Shift changes what the outline targets, so redraw it when Shift is released
     even though the cursor has not moved. */
  function onKeyUp(e) {
    if (!S.on || e.key !== "Shift" || !S.lastPt) return;
    updateHover(S.lastPt[0], S.lastPt[1], false);
  }

  function openNote() {
    elSay.classList.add("typing");
    elNote.value = "";
    elNote.focus();
  }

  function closeNote() {
    elSay.classList.remove("typing");
    elNote.value = "";
    elNote.blur();
  }

  /** A typed note attaches to the newest mark, or stands alone if there is none. */
  function addNote() {
    const text = elNote.value.trim();
    closeNote();
    if (!text) return;
    const last = S.notes[S.notes.length - 1];
    if (last) { last.typed = text; call("note", { ...last, typed: text, amend: true }); }
    else call("speech", { t: now(), at: Date.now(), text, url: location.href });
    if (S.engine === "browser") S.tail = (S.tail + " " + text).trim().slice(-220);
    flash(last ? `Note added to mark ${last.n || ""}`.trim() : "Note added");
  }

  function onNoteKey(e) {
    e.stopPropagation();
    if (e.key === "Enter" && !e.metaKey && !e.ctrlKey) { e.preventDefault(); addNote(); }
  }

  /* -------------------------------------------------------------- lifecycle */

  async function activate() {
    if (!host) build();
    host.style.display = "";
    hud.classList.remove("is-saved");
    hud.style.animation = "none"; void hud.offsetWidth; hud.style.animation = "";
    S.on = true; S.warn = ""; S.banner = "";
    S.t0 = Date.now();
    renderMarks();
    clearInterval(S.timer);
    S.timer = setInterval(paint, 1000);
    paint();

    const res = await call("start", {});
    if (!res || !res.ok) {
      // Returning here used to skip rendering entirely, so the overlay came up
      // blank and marks never appeared — which reads as "the shapes are broken"
      // rather than "this tab is running a stale copy of the extension".
      S.micOk = false; // borrow the loud style
      S.warn = res && res.orphaned
        ? "This tab has an old copy of Pointy. Reload the page (⌘R), then press the pointy shortcut again. Marks drawn now won't save."
        : "Can't reach the Pointy extension. Reload it in your browser's extensions page, then this page.";
      paint();
      return;
    }
    if (!res.serverUp) S.warn = "The Pointy app isn't running. Open it from Applications.";
    S.engine = res.engine || "browser";
    S.keys = res.keymap || null;
    applyKeys();
    S.sessionCount = res.notes || 0;
    if (res.resumed && S.sessionCount) flash(`Continuing · ${S.sessionCount} mark${S.sessionCount === 1 ? "" : "s"} so far`, 3000);
    S.speechCount = 0; S.micOk = null;
    await ensureMic();
    startSpeech();
    renderMarks();
    paint();
  }

  function scheduleHide(ms) {
    clearTimeout(S.hideTimer);
    S.hideTimer = setTimeout(hide, ms);
  }

  function hide() {
    S.on = false;
    stopSpeech();
    clearInterval(S.timer);
    clearTimeout(S.hideTimer);
    if (hud) hud.classList.remove("is-saved");
    if (elSay) closeNote();
    if (host) host.style.display = "none";
  }

  function toggle() { if (S.on) hide(); else activate(); }

  /** Hand the page over cleanly to a newer copy of this script. */
  function teardown() {
    try { stopSpeech(); } catch {}
    clearInterval(S.timer);
    clearTimeout(S.hideTimer);
    window.removeEventListener("scroll", renderMarks);
    window.removeEventListener("resize", renderMarks);
    window.removeEventListener("keydown", onKey, true);
    window.removeEventListener("keyup", onKeyUp, true);
    window.removeEventListener("scroll", hideHover);
    if (host) { try { host.remove(); } catch {} }
    host = null;
    S.on = false;
  }

  /** Done: save, compile, and the brief lands on the clipboard. */
  async function finish() {
    if (S.saving) return;
    S.saving = true;
    stopSpeech();
    paint();
    const res = await call("finish", {});
    S.saving = false;
    if (res && res.ok) {
      const count = res.notes || Math.max(S.notes.length, S.sessionCount || 0);
      S.brief = res.brief || "";
      S.notes = []; S.sessionCount = 0; S.tail = ""; S.interim = ""; S.warn = ""; S.banner = "";
      renderMarks();
      paint();
      if (!S.brief) { flash("Nothing to save", 1600); scheduleHide(1700); return; }
      elSavedSub.textContent = `${count} mark${count === 1 ? "" : "s"} · paste into Claude Code, or run /ui`;
      elCopyAgain.querySelector("span").textContent = "Copy again";
      hud.classList.add("is-saved");
      scheduleHide(6000);
    } else {
      S.warn = (res && res.error) || "Couldn't save. Is the Pointy app running?";
      S.micOk = false;
      startSpeech(); paint();
    }
  }

  /* Resume after a same-session navigation. `hello` only asks whether a session
     is open — unlike `start` it never opens one, so a plain page load does not
     quietly begin recording. */
  (async () => {
    const st = await call("hello", {});
    if (st && st.ok && st.live) activate();
  })();
})();
