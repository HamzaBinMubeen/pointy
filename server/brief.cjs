/* =============================================================================
   brief.cjs — compiles a recorded session into BRIEF.md.

   One copy, two hosts: the Node server require()s it, and the macOS app runs it
   in JavaScriptCore. So: plain script, no imports, nothing Node-specific — the
   only global it touches is console, which the app provides.
   ========================================================================== */

/* Speech that starts up to this long BEFORE a mark still belongs to it — people
   name the thing, then draw on it. */
const LOOKBEHIND_MS = 3000;
/* A drawn shape this much off the element's own size reads as "resize it". */
const RESIZE_RATIO = 0.1;

/* ------------------------------------------------------------------- utils */

const r1 = (n) => Math.round(n * 10) / 10;
const px = (n) => `${r1(n)}px`;

/** Tailwind v4: one spacing unit is 4px. Only offer the scale where it is used. */
function twHint(n, prefix) {
  const v = Math.abs(n);
  const u = v / 4;
  if (Number.isInteger(u) && u <= 96) return `${prefix}-${u}`;
  return `${prefix}-[${r1(v)}px]`;
}

function fmtTime(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

/** Turn a bundler URL back into something you can open. */
function cleanSource(s) {
  if (!s) return null;
  const out = s
    .replace(/^webpack-internal:\/\/\/\([^)]*\)\/\.?\//, "")
    .replace(/^turbopack:\/\/\/\[project\]\//, "")
    .replace(/^rsc:\/\/[^/]*\/[^/]*\//, "")
    .replace(/^file:\/\//, "")
    .replace(/^https?:\/\/[^/]+\//, "")
    .replace(/\?[^:]*$/, "");
  // Turbopack dev points at compiled bundles under .next/. A real path to
  // something useless is worse than no path: it reads as an answer.
  if (/(^|\/)\.?next\/|^_next\/|\/chunks\/|%5B|%255B/.test(out)) return null;
  return out;
}

/* Mirrored from the capture side so OLD sessions render cleanly too, and so a
   future gap in app.js cannot put framework furniture back in the brief. */
const FRAMEWORK = new Set([
  "AppRouter", "OuterLayoutRouter", "InnerLayoutRouter", "LayoutRouterContext",
  "RenderFromTemplateContext", "ScrollAndFocusHandler", "SegmentViewNode",
  "SegmentViewStateNode", "RedirectBoundary", "RedirectErrorBoundary",
  "NotFoundBoundary", "NotFoundErrorBoundary", "HTTPAccessFallbackBoundary",
  "DevRootHTTPAccessFallbackBoundary", "LoadingBoundary", "ErrorBoundary",
  "ErrorBoundaryHandler", "ClientPageRoot", "ClientSegmentRoot", "MetadataBoundary",
  "ViewportBoundary", "OutletBoundary", "AsyncMetadata", "AsyncMetadataOutlet",
  "HotReload", "ReactDevOverlay", "DevOverlay", "Router", "ServerRoot",
  "AppDevOverlay", "AppDevOverlayErrorBoundary", "HistoryUpdater", "TemplateContext",
  "Fragment", "Suspense", "Provider", "Consumer", "ForwardRef", "Memo",
]);
const FRAMEWORK_SHAPE = /(?:Boundary|Router|Context|Providers?|Consumer|Overlay|Handler|DevTools)$|^(?:Segment|Async|Outer|Inner|Client|Hot|Render)[A-Z]|Fallback|LayoutRouter/;
const realName = (n) => !!n && /^[A-Z][A-Za-z0-9_]{2,}$/.test(n) && !FRAMEWORK.has(n) && !FRAMEWORK_SHAPE.test(n);
const cleanChain = (arr) => (arr || []).filter(realName);

/* Sessions captured before 0.7.0 named elements after framework contexts —
   `NavigationPromisesContext` on every node of a server-rendered page. The tag
   says more than that, so old sessions are renamed here as they are compiled. */
/* A component-shaped identifier. aria-labels ("Save this role") also start with
   a capital, and those are real names that must survive. */
const isIdent = (n) => !!n && /^[A-Z][A-Za-z0-9_]*$/.test(n);

function fixName(d) {
  if (!d || typeof d !== "object") return d;
  if (isIdent(d.name) && !realName(d.name) && (d.react || []).includes(d.name)) {
    d.name = d.tag || "element";
  }
  if (Array.isArray(d.icons)) d.icons = d.icons.filter((n) => !isIdent(n) || realName(n));
  return d;
}

function fixNames(n) {
  for (const d of n.selected || []) fixName(d);
  fixName(n.container);
  if (n.tail && n.tail.el) fixName(n.tail.el);
  if (n.head && n.head.el) fixName(n.head.el);
  return n;
}

/* -------------------------------------------------------- naming elements */

/** One element, as you would say it out loud, plus the shortest way to find it. */
/* Reset per compile. The same element gets marked five times in a session and
   repeating its source path, testid and grep line each time is pure duplication —
   the first mention carries them, later ones are just the name. */
let SEEN = new Set();

function elementLine(d, prefix = "") {
  if (!d) return `${prefix}_(nothing resolved)_\n`;
  let s = `${prefix}\`${d.name}\``;
  if (d.text) s += ` — "${d.text}"`;
  if (d.icons && d.icons.length) s += ` · ${d.icons.join(", ")}`;
  s += `\n`;

  const sig = `${d.name}|${d.selector || ""}|${(d.text || "").slice(0, 40)}`;
  if (SEEN.has(sig)) return s;
  SEEN.add(sig);

  const indent = prefix ? " ".repeat(prefix.length) : "   ";
  const find = [];
  const src = cleanSource((d.source || [])[0]);
  if (src) find.push(src);
  // The chain starts with the element's own name only when it IS that
  // component; a plain <p> inside one gets the whole chain as its context.
  const all = cleanChain(d.react);
  const chain = (all[0] === d.name ? all.slice(1) : all).slice(0, 2);
  if (chain.length) find.push(`in ${chain.join(" › ")}`);
  if (d.testid) find.push(`data-testid="${d.testid}"`);
  if (!src && !all.length) {
    if (d.text && d.text.length >= 6) find.push(`grep "${d.text.split(/\s+/).slice(0, 5).join(" ").replace(/"/g, "")}"`);
    else if (d.class) find.push(`class="${d.class}"`);
  }
  if (find.length) s += `${indent}${find.join(" · ")}\n`;
  return s;
}

/* Space descriptions carry names but no tag or chain, so a pre-0.7.0 context
   name can only be dropped, not replaced with something better. */
const spaceName = (n, fallback) => (isIdent(n) && !realName(n) ? fallback : n);

function spaceLine(sp, prefix = "") {
  if (!sp) return `${prefix}empty space\n`;
  let s = `${prefix}empty space inside \`${spaceName(sp.container.name, "a container")}\``;
  if (sp.atPct && sp.atPct.x != null) s += ` (${sp.atPct.x}% across, ${sp.atPct.y}% down)`;
  s += `\n`;
  const indent = prefix ? " ".repeat(prefix.length) : "   ";
  const src = cleanSource(sp.container.source);
  if (src) s += `${indent}${src}\n`;
  for (const n of sp.neighbours || []) {
    const where = n.dir === "left" || n.dir === "right" ? `${n.dir} of` : n.dir;
    s += `${indent}${px(n.gap)} ${where} \`${spaceName(n.name, "element")}\`${n.text ? ` "${n.text}"` : ""}\n`;
  }
  return s;
}

/* ------------------------------------------------------------ mark bodies */

function selectionBody(note) {
  let s = "";
  const sel = note.selected || [];

  if (!sel.length) {
    s += `**Marked an area** — nothing sits fully inside the shape, so this is a region within:\n\n`;
    s += elementLine(note.container, "");
    if (note.shape && note.container && note.container.rect) {
      s += `\n${r1(note.shape.w)}×${r1(note.shape.h)} area inside a ${r1(note.container.rect.w)}×${r1(note.container.rect.h)} element.\n`;
    }
    return s;
  }

  if (note.kind === "point") {
    s += `**This element**\n\n` + elementLine(sel[0], "");
    return s;
  }

  const verb = note.kind === "circle" ? "Circled" : "Selected";
  s += `**${verb} ${sel.length} element${sel.length === 1 ? "" : "s"}**\n\n`;
  sel.forEach((d, i) => { s += elementLine(d, `${i + 1}. `); });
  if (note.truncated) s += `…and ${note.truncated} more inside the shape.\n`;

  // How the group sits today — the one measurement that "spread them out" needs.
  const g = note.group;
  if (g) {
    // A bare "flex" does not say which way the children run, which is the whole
    // question behind "spread them out". Name the axis explicitly.
    const axis = g.flexDirection || (/flex/.test(g.display || "") ? "row" : null);
    const how = [g.display, axis, g.gridTemplateColumns ? `grid-cols ${g.gridTemplateColumns}` : null]
      .filter(Boolean).join(" ");
    let line = `\nLaid out today: ${how} inside \`${g.parent}\``;
    if (g.gap) line += `, gap ${g.gap} (\`${twHint(parseFloat(g.gap), "gap")}\`)`;
    if (g.measuredGaps && g.measuredGaps.length) {
      const uniq = [...new Set(g.measuredGaps)];
      line += ` · measured spacing ${uniq.map(px).join(", ")}`;
    }
    if (g.childCount > (note.selected || []).length) line += ` · ${g.childCount} children total, you selected ${sel.length}`;
    s += line + `\n`;
  }

  // Size only when the shape you drew disagrees with what you selected — and
  // only when it is PLAUSIBLY a resize of it. A circle drawn inside a 7,851px
  // page wrapper is a region highlight, and calling that "a resize, height
  // -90%" is a confident instruction to do something nobody asked for.
  // Legacy notes are never a resize: their element is whatever sat under the
  // cursor, not what the shape enclosed, so the comparison is meaningless.
  if (sel.length === 1 && note.shape && sel[0].rect && !note.__legacy) {
    const r = sel[0].rect;
    const rw = note.shape.w / r.w, rh = note.shape.h / r.h;
    const plausible = rw > 0.4 && rw < 2.5 && rh > 0.4 && rh < 2.5;
    const dw = rw - 1, dh = rh - 1;
    if (plausible && (Math.abs(dw) > RESIZE_RATIO || Math.abs(dh) > RESIZE_RATIO)) {
      s += `\nYou drew it ${r1(note.shape.w)}×${r1(note.shape.h)}; it is ${r1(r.w)}×${r1(r.h)} today`;
      s += ` (width ${dw >= 0 ? "+" : ""}${Math.round(dw * 100)}%, height ${dh >= 0 ? "+" : ""}${Math.round(dh * 100)}%)`;
      s += ` — read as a resize.\n`;
    }
  }
  return s;
}

function arrowBody(note) {
  const { tail, head, arrow } = note;
  let s = "";
  s += `**From** ` + (tail.kind === "element" ? elementLine(tail.el) : spaceLine(tail.space));
  s += `**Points at** ` + (head.kind === "element" ? elementLine(head.el) : spaceLine(head.space));

  const t = tail.kind, h = head.kind;
  let reads;
  if (t === "element" && h === "element") reads = `move / relate \`${tail.el.name}\` to \`${head.el.name}\``;
  else if (t === "element" && h === "space") reads = `move \`${tail.el.name}\` to that spot`;
  else if (t === "space" && h === "element") reads = `calling attention to \`${head.el.name}\``;
  else reads = `a direction only — take the target from the words`;
  s += `\nReads as: **${reads}**\n`;

  // Placement IS this mark's content, so the geometry earns its place here.
  if (t === "element" && tail.el.rect) {
    const dx = arrow.to[0] - arrow.from[0], dy = arrow.to[1] - arrow.from[1];
    const a = (Math.atan2(dy, dx) * 180) / Math.PI;
    const dir = ["right", "down-right", "down", "down-left", "left", "up-left", "up", "up-right"][(Math.round(a / 45) + 8) % 8];
    s += `Direction ${dir}, ${px(Math.hypot(dx, dy))}.`;
    if (h === "element" && head.el.rect) {
      // Order them before measuring. Subtracting blind gives a negative "gap"
      // whenever the arrow points backwards up the page, which then renders as
      // a confident `gap-[754px]` that means nothing.
      const A = tail.el.rect, B = head.el.rect;
      const horiz = Math.abs(dx) > Math.abs(dy);
      const aS = horiz ? A.x : A.y, aE = horiz ? A.x + A.w : A.y + A.h;
      const bS = horiz ? B.x : B.y, bE = horiz ? B.x + B.w : B.y + B.h;
      const after = horiz ? "to the right of" : "below";
      const before = horiz ? "to the left of" : "above";
      if (bS >= aE) s += ` \`${head.el.name}\` sits ${px(bS - aE)} ${after} \`${tail.el.name}\` today.`;
      else if (aS >= bE) s += ` \`${head.el.name}\` sits ${px(aS - bE)} ${before} \`${tail.el.name}\` today.`;
      else s += ` They overlap on that axis today.`;
    }
    s += `\n`;
  }
  return s;
}

/* ---------------------------------------------------------------- compile */

/* Marks drawn closer together than this are one instruction with several
   gestures, not several instructions. Speech attaches to the GROUP. */
const CLUSTER_GAP_MS = 7000;

/**
 * Notes from before the rewrite carry `from`/`to`/`path` instead of
 * `tail`/`head`/`shape`. Reloading the extension leaves an open tab running the
 * OLD content script, so these keep arriving — and the new renderers destructure
 * `tail`, which on a v1 arrow is undefined. Translate rather than crash: a brief
 * built from an old note is still worth having.
 */
function legacyEl(d) {
  if (!d) return null;
  return {
    name: cleanChain(d.react)[0] || d.tag || "element",
    tag: d.tag, text: d.text, icons: [],
    react: cleanChain(d.react), source: d.source || [],
    testid: d.testid || null, rect: d.rect, selector: d.selector, class: d.class,
  };
}

function normalise(n) {
  if (n.v >= 2) return n;
  // Trust the SHAPE over the version stamp. A note carrying tail/head or a
  // selected[] is already current whatever it says about itself, and rebuilding
  // it as legacy throws away everything it had.
  if (n.tail || n.head || Array.isArray(n.selected)) return n;
  const out = { ...n, __legacy: true };
  if (n.kind === "arrow") {
    out.arrow = { from: n.start || [0, 0], to: n.end || [0, 0] };
    out.tail = n.from ? { kind: "element", el: legacyEl(n.from) } : { kind: "space", space: null };
    out.head = n.to ? { kind: "element", el: legacyEl(n.to) } : { kind: "space", space: null };
  } else {
    out.kind = n.kind === "point" ? "point" : n.kind === "circle" ? "circle" : "rect";
    out.selected = n.from ? [legacyEl(n.from)] : [];
    out.shape = n.rect || n.box || null;
    out.group = null;
    out.container = null;
  }
  return out;
}

function compile(bundle) {
  /* Fold typed amendments into the mark they amend. Everything else is kept:
     two marks CAN share a millisecond (you draw two arrows in one motion), and
     a dedupe keyed on time+kind silently ate one of them. */
  SEEN = new Set();
  const notes = [];
  for (const n of bundle.notes || []) {
    if (n.amend) {
      for (let i = notes.length - 1; i >= 0; i--) {
        if (notes[i].at === n.at && notes[i].kind === n.kind) { notes[i].typed = n.typed; break; }
      }
      continue;
    }
    notes.push(fixNames(normalise(n)));
  }
  notes.sort((a, b) => (a.at || 0) - (b.at || 0));
  notes.forEach((n, i) => { n.__num = n.n || i + 1; });

  /* Cluster. Drawing six arrows in seven seconds while describing ONE change is
     the normal way to use this, and attaching each sentence to the single mark
     that happened to precede it left most marks saying "nothing captured". */
  const clusters = [];
  for (const n of notes) {
    const last = clusters[clusters.length - 1];
    if (last && (n.at || 0) - (last.notes[last.notes.length - 1].at || 0) < CLUSTER_GAP_MS) last.notes.push(n);
    else clusters.push({ notes: [n] });
  }
  for (const c of clusters) {
    c.start = c.notes[0].at || 0;
    c.end = c.notes[c.notes.length - 1].at || 0;
    c.said = [];
  }

  const speech = (bundle.speech || []).slice().sort((a, b) => (a.at || 0) - (b.at || 0));
  const preamble = [];
  for (const seg of speech) {
    let owner = null;
    for (const c of clusters) {
      if (c.start <= (seg.at || 0) + LOOKBEHIND_MS) owner = c;
      else break;
    }
    if (owner) owner.said.push(seg);
    else preamble.push(seg);
  }

  const t0 = bundle.startedAt;
  const pages = [...new Set(notes.map((n) => n.url))];
  const first = notes[0] || {};
  const KINDS = { rect: "rectangle", circle: "circle", arrow: "arrow", point: "point" };

  let md = "";
  md += `# UI change notes — ${new Date(t0).toLocaleString()}\n\n`;
  md += `${notes.length} mark${notes.length === 1 ? "" : "s"} over ${fmtTime((bundle.endedAt || t0) - t0)}`;
  md += ` · viewport ${first.vw || "?"}×${first.vh || "?"} @${first.dpr || 1}x\n\n`;
  for (const u of pages) md += `- \`${u}\`\n`;
  md += `\n`;
  md += [
    `> Each section is one spoken instruction plus the shapes drawn while saying it.`,
    `> Several marks under one **Said** are one change seen from several angles.`,
    `> Element names come from the running DOM; the line under a name is how to find it.`,
    `> Full detail is given the first time an element appears, not on every mention.`,
    `> Full-viewport screenshots are on disk as \`NN.jpg\` if a crop is not enough.`,
    ``,
  ].join("\n");

  if (notes.some((n) => n.__legacy)) {
    md += `\n> ⚠️ **Some marks came from an out-of-date content script** and carry less detail\n`;
    md += `> than the rest. Reload the page (⌘R) after reloading the extension so it\n`;
    md += `> re-injects, then re-record anything that reads thin here.\n`;
  }

  if (preamble.length) md += `\n**Said before the first mark:** ${preamble.map((x) => x.text).join(" ")}\n`;

  let prevUrl = null;
  clusters.forEach((c) => {
    const many = c.notes.length > 1;
    const a = c.notes[0].__num, b = c.notes[c.notes.length - 1].__num;
    const kind0 = KINDS[c.notes[0].kind] || c.notes[0].kind;
    md += `\n---\n\n## ${many ? `Marks ${a}–${b}` : `Mark ${a} · ${kind0}`} · ${fmtTime(c.start - t0)}`;
    if (many && c.end !== c.start) md += `–${fmtTime(c.end - t0)}`;
    md += `\n\n`;

    const said = c.said.map((x) => x.text).join(" ").trim();
    md += `**Said** ${said ? `"${said}"` : "_(nothing captured here — see the full transcript below)_"}\n`;
    if (many) md += `\n_${c.notes.length} marks drawn together; the words above cover all of them._\n`;

    for (const n of c.notes) {
      // A lone mark already said its kind in the ## heading above.
      if (many) md += `\n### ${n.__num} · ${KINDS[n.kind] || n.kind}\n`;
      md += `\n`;
      // Never let one malformed mark take the other nineteen down with it.
      let body;
      try {
        body = n.kind === "arrow" ? arrowBody(n) : selectionBody(n);
      } catch (err) {
        console.error(`  ! mark ${n.__num} (${n.kind}) could not be rendered: ${err.message}`);
        body = `_This mark could not be rendered (${err.message}). Its raw data is in notes.json; the screenshot below still shows what was drawn._\n`;
      }
      md += body;
      if (n.typed) md += `\n**Typed** ${n.typed}\n`;
      // Only the crop is referenced. The full viewport is on disk and was
      // costing as much again for context the crop already carries.
      if (n.crop) md += `\n![mark ${n.__num}](${n.crop})\n`;
      else if (n.shot) md += `\n![mark ${n.__num}](${n.shot})\n`;
      if (n.url !== prevUrl) { md += `\non \`${n.url}\`\n`; prevUrl = n.url; }
    }
  });

  // The transcript is a verbatim copy of what is already quoted above. Keep it
  // only when the split may have gone wrong: something unattached, or a group
  // that ended up with no words at all.
  const orphaned = preamble.length > 0;
  const silent = clusters.some((c) => !c.said.length);
  if (speech.length && (orphaned || silent)) {
    md += `\n---\n\n## Full transcript\n\n`;
    md += speech.map((x) => `\`${fmtTime((x.at || t0) - t0)}\` ${x.text}`).join("\n\n") + "\n";
  } else if (!speech.length) {
    md += `\n---\n\n_No speech was captured in this session._\n`;
  }
  return md;
}

if (typeof module !== "undefined") module.exports = { compile };
