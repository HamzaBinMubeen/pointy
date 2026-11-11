#!/usr/bin/env node
/* =============================================================================
   Pointy server — receives a session from the extension and compiles it into
   BRIEF.md: the thing you point a coding agent at.

   The brief leads with WHAT each element is, by name. Measurements appear only
   where the mark is actually about size or placement — context spent telling an
   agent something it can read for itself is context taken from the work.

   No dependencies. Node 18+.
       node server/server.mjs
   ========================================================================== */

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFile, spawn } from "node:child_process";
import { createRequire } from "node:module";

const { compile } = createRequire(import.meta.url)("./brief.cjs");

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "..");
const SESSIONS = path.join(ROOT, "sessions");
const PORT = Number(process.env.UI_NOTES_PORT || 7777);

/* ----------------------------------------------------------------- writing */

function writeSession(bundle) {
  const dir = path.join(SESSIONS, bundle.id);
  fs.mkdirSync(dir, { recursive: true });

  for (const [name, dataUrl] of Object.entries(bundle.shots || {})) {
    const m = /^data:([^;]+);base64,(.*)$/s.exec(dataUrl || "");
    if (!m) continue;
    fs.writeFileSync(path.join(dir, path.basename(name)), Buffer.from(m[2], "base64"));
  }

  const slim = { ...bundle, shots: Object.keys(bundle.shots || {}) };
  fs.writeFileSync(path.join(dir, "notes.json"), JSON.stringify(slim, null, 2));

  const brief = compile(bundle);
  fs.writeFileSync(path.join(dir, "BRIEF.md"), brief);

  /* unlink, not rmSync. rmSync refuses a symlink that points at a directory
     (ERR_FS_EISDIR), the catch swallowed that, symlinkSync then hit EEXIST, and
     `latest` stayed on the first session ever written — /ui read nothing for
     every session after 2026-09-12. */
  const link = path.join(SESSIONS, "latest");
  try { fs.unlinkSync(link); } catch {}
  try { fs.symlinkSync(bundle.id, link, "dir"); } catch (e) {
    console.error(`  ! could not point sessions/latest at ${bundle.id}: ${e.message}`);
  }
  return { dir, brief };
}

/**
 * Copy to the macOS clipboard over STDIN.
 *
 * Never through `sh -c`: the brief is full of backticks and `$`, and handing that
 * to a shell is both broken and a command-injection waiting to happen.
 */
function toClipboard(text) {
  try {
    const p = spawn("pbcopy");
    p.on("error", () => {});
    p.stdin.on("error", () => {});
    p.stdin.end(text);
  } catch {}
}

/* ------------------------------------------------------------------ server */

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-methods": "GET,POST,OPTIONS",
  "access-control-allow-headers": "content-type",
};

const server = http.createServer((req, res) => {
  if (req.method === "OPTIONS") { res.writeHead(204, CORS); return res.end(); }

  if (req.url === "/ping") {
    res.writeHead(200, { ...CORS, "content-type": "application/json" });
    return res.end(JSON.stringify({ ok: true }));
  }

  if (req.method === "POST" && req.url === "/session") {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > 300 * 1024 * 1024) { req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => {
      try {
        const bundle = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        const { dir, brief } = writeSession(bundle);
        const rel = path.relative(path.resolve(ROOT, ".."), dir);
        const count = (bundle.notes || []).length;

        // Pasting the text alone loses the screenshots, so say where they are.
        // An agent given this can still go and look at them.
        const payload =
          `<!-- Pointy. Screenshots referenced below are in: ${dir}\n` +
          `     Equivalent: run /ui in Claude Code, which reads the file and the images. -->\n\n` +
          brief;

        console.log(`\n  ✓ ${count} mark${count === 1 ? "" : "s"} → ${rel}/BRIEF.md`);
        console.log(`    the full brief is on your clipboard · or run /ui\n`);

        toClipboard(payload);
        execFile("afplay", ["/System/Library/Sounds/Glass.aiff"], () => {});

        res.writeHead(200, { ...CORS, "content-type": "application/json" });
        res.end(JSON.stringify({ ok: true, dir: rel, notes: count, brief: payload }));
      } catch (e) {
        console.error("  ✗ failed to write session:", e.message);
        res.writeHead(500, { ...CORS, "content-type": "application/json" });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  res.writeHead(404, CORS);
  res.end("not found");
});

export { compile };

// Listen only when run directly, so tests can import compile() without a port.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  fs.mkdirSync(SESSIONS, { recursive: true });
  server.listen(PORT, "127.0.0.1", () => {
    console.log(`\n  Pointy server — http://127.0.0.1:${PORT}`);
    console.log(`  sessions → ${SESSIONS}`);
    console.log(`  waiting. Press Control+Shift+P on your site to start.\n`);
  });
}
