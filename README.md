<p align="center">
  <img src="site/apple-touch-icon.png" width="96" alt="pointy" />
</p>

<h1 align="center">pointy</h1>

<p align="center"><b>Point at it. Say it. Shipped.</b><br/>
Draw on your UI, talk, and your coding agent knows exactly what to change.</p>

<p align="center">
  <a href="https://github.com/HamzaBinMubeen/pointy/releases/latest/download/Pointy.dmg">Download for Mac</a> ·
  <a href="https://hamzabinmubeen.github.io/pointy/">Website</a> ·
  <a href="SAMPLE-BRIEF.md">Sample brief</a>
</p>

---

You draw a box around three stat cards and say *"these are way too cramped"*. The brief
that comes out names them: `StatCard` "Signups 1,284" with its `UsersIcon`, its two
siblings, the file and line each one lives at, and the fact that they sit in a 3-column
grid with `gap-1.5` today.

Not "a 1055×170 box at (110, 605)". **The elements, by name.** Hand that to Claude Code,
Cursor or Codex and it edits the right component the first time.

Pointy is a small Mac menu-bar app plus a browser extension (Chrome, Edge, Brave). Everything
runs on your Mac: the extension talks to the app on `127.0.0.1`, and speech is
transcribed on-device.

## Install

1. **Download [Pointy.dmg](https://github.com/HamzaBinMubeen/pointy/releases/latest/download/Pointy.dmg)**
   and drag Pointy to Applications.
2. **Open it once from System Settings.** Pointy isn't notarised yet, so macOS blocks
   the first open. Go to System Settings › Privacy & Security, scroll down, and click
   **Open Anyway** next to Pointy. You only do this once.
3. **Follow the checklist on Home.** Pointy lives in the menu bar; its window walks you
   through the rest:
   - **Add the browser extension.** Pointy opens your browser's extensions page and
     copies the extension's folder path. Turn on Developer mode, click **Load
     unpacked**, press ⌘⇧G, paste, Return. Once: after that the app keeps the extension
     up to date by itself.
   - **Turn on the microphone.**
   - **Add `/ui` to Claude Code** (one click).
   - **Make your first note**, and optionally **start with your Mac**.

Requires macOS 14 or later. On-device transcription needs macOS 26; on older versions
Pointy uses the browser's speech recognition.

## Use it

1. Open the page you're working on: your dev server, or any site.
2. Press **⌃⇧P** (Control-Shift-P). A slim toolbar slides up at the bottom and listening
   starts. What you say appears as a live subtitle.
3. Draw and talk. Box things, circle things, point arrows, click elements.
4. Press **⌘↩** (or click **Done**). The brief lands on your clipboard.
5. In Claude Code run **`/ui`**, or paste the brief into any agent.

`/ui` reads the brief *and* looks at the screenshots. A paste is text only, so it starts
with the folder the screenshots are in, and an agent can go and open them.

### Tools and keys

| Key | | |
|---|---|---|
| **V** | select | click an element and talk about it |
| **R** | rectangle | selects every element fully inside it |
| **O** | oval | same, as an ellipse |
| **A** | arrow | points *at* something, or *from* one thing *to* another |
| **H** | use the page | clicks and scrolls go to the page until you press it again |
| **T** | note | type a note for the newest mark instead of saying it |
| **⌘Z** | undo | remove the newest mark |
| **⌘⌫** | start over | throw the session away (asks first) |
| **⌘↩** | done | save, and copy the brief |
| **Esc** | cancel | a shape mid-drag, the note field, start over |

Every key except Esc can be changed in the app's **Shortcuts** tab. The open shortcut
(⌃⇧P) belongs to the browser: change it at `chrome://extensions/shortcuts` or
`edge://extensions/shortcuts`. Edge already uses ⌘⇧E for itself, which is why the default is
⌃⇧P.

**Things worth knowing**

- The element under your cursor is outlined and named before you draw. Hold **Shift**
  to take its parent instead.
- Lime is what you drew; **green is what got selected**. Check the green before you move on.
- Click a mark's number badge to delete just that mark.
- Talk continuously. Marks drawn within seven seconds of each other are grouped into one
  instruction, and the words attach to the group.
- Sessions survive navigation: go from `/` to `/pricing` mid-sentence and keep going.
- Arrows read four ways (element → element, element → space, space → element, space →
  space), and the brief says which one it was.

## What comes out

Each session is a folder in `~/Library/Application Support/Pointy/Sessions/` (stored in
the system temp folder; by default the newest 25 are kept, for 24 hours. Change both in Settings).
`Sessions/latest` always points at the newest one.

| | |
|---|---|
| `BRIEF.md` | the compiled brief: the thing you hand your agent |
| `NN-crop.png` | each mark, in context |
| `NN.jpg` | the full viewport for each mark |
| `notes.json` | everything raw |

The **Sessions** tab keeps your history, with **Copy brief** for when the clipboard got
overwritten. See [SAMPLE-BRIEF.md](SAMPLE-BRIEF.md) for what a brief looks like.

The brief is deliberately terse. Crops are saved at CSS resolution, element detail is
printed the first time an element appears rather than every time, and the reading
instructions live in the `/ui` command rather than in every brief. An 11-mark session
costs about 5,000 tokens.

## Privacy

- Nothing leaves your Mac. The extension only talks to the app on `127.0.0.1:7777`.
- With **Apple Speech** or **Apple Dictation** selected (the default on macOS 26), speech is
  transcribed on-device. **Browser speech**, the fallback, uses your browser's
  recognition service, which for Chrome means Google's servers.
- Screenshots are taken only of the tab you're marking up, only while a session is
  open, and go into the session folder above.
- No analytics, no accounts. The only download is macOS fetching its own speech model
  the first time you use on-device transcription.

## How it works

```
browser tab
 ├── app.js       MAIN world    overlay, gestures, DOM + React inspection
 └── bridge.js    ISOLATED      relays messages ⇄ chrome.runtime
        │
   background.js                session state, screenshots, sends on Done
        │
   Pointy.app  127.0.0.1:7777   on-device transcription, writes the session,
                                compiles BRIEF.md (server/brief.cjs)
```

**Why two content scripts.** React attaches its fiber to the DOM node as an expando
(`__reactFiber$…`), and an isolated-world content script can't see expandos set by the
page. Reading them means running in the page's own world, where there's no `chrome.*`.
Hence the split, and the bridge.

**What's captured per mark.** For every element: the name you'd say out loud (React
component → icon → `aria-label` → role → tag), its visible text, the icons inside it,
the source file and line, and a CSS selector. For a group, how the parent lays them out
and the measured spacing. For whitespace, the container and the nearest named neighbour
in each direction.

**What's deliberately left out.** Class strings (unless there's nothing better), computed
style dumps, and geometry on marks that aren't about size or position. All of it is
context spent telling an agent something it can read for itself.

### Limits

- **Component names exist only in dev builds.** A production bundle renames components
  to `x`, `f`, `p`, so on a live site expect `` `h2` — "the actual words" `` instead of
  `` `StatsBand` ``. Usually still enough to find it.
- **Source paths are best-effort.** React 19 dropped `_debugSource`; Pointy reads
  `_debugStack` instead, which Next dev builds usually fill in. Turbopack often points at
  compiled chunks, which are filtered out, and the component name and a `grep` line
  carry it.
- **A rectangle selects only what fits entirely inside it.** Draw a little wide.
- **Marks scroll with the page**, but nothing re-anchors them if the layout reflows.
- The overlay loads by itself on `localhost`, `127.0.0.1` and `*.localhost`. On any other
  site, the shortcut or the toolbar icon loads it on demand.

## Build from source

```bash
scripts/build-app.sh --install   # universal build → /Applications/Pointy.app
scripts/make-dmg.sh              # → build/Pointy-<version>.dmg
swift scripts/make-icons.swift   # redraw every icon from the mascot
```

Needs Xcode 26 (the on-device transcription uses the macOS 26 SDK). The build signs with your "Apple Development" certificate if
you have one (free: add an Apple ID in Xcode › Settings › Accounts), so macOS keeps the
microphone grant across rebuilds; without one it signs ad-hoc and the grant resets on
every build. Set `POINTY_SIGN_IDENTITY` to pick a specific identity.

The extension version is the app version: bump `extension/manifest.json` and rebuild. The
app carries the extension, and installed copies reload themselves when the app ships a
newer one.

**Without the app** (Linux, or working on the compiler): `node server/server.mjs` serves
the same API from a terminal (Node 18+, no dependencies) and writes sessions to
`sessions/` in this repo.

**Store listing.** If the extension is ever listed in the Chrome Web Store or Edge
Add-ons, put its IDs in `ExtensionInstaller.storeIDs` and the app's **Install** becomes
one click, with the store doing the updates.

The website is `site/`: one self-contained page, deployed to GitHub Pages on every push
to `main`.

## Contributing

Issues and pull requests are welcome. For anything bigger than a fix, open an issue
first so we can talk it through.

## Licence

[MIT](LICENSE) © 2026 Hamza Bin Mubeen. If Pointy saves you time,
[buy me a coffee](https://buymeacoffee.com/hamzabinmubeen).
