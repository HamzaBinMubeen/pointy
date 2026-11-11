---
description: Apply the latest Pointy brief (hand-drawn + spoken UI notes)
---

Read `~/Library/Application Support/Pointy/Sessions/$ARGUMENTS/BRIEF.md` — if `$ARGUMENTS` is
empty, read `~/Library/Application Support/Pointy/Sessions/latest/BRIEF.md`. Screenshots sit next
to it. Sessions are deleted after 24 hours; if the folder is gone, say so rather than guessing.
These instructions cover every brief, so they are not repeated inside each one.

## How a brief is structured

Each `## Marks N–M` section is **one spoken instruction** plus the shapes drawn while
saying it. Several marks under one **Said** are one change described from several
angles — read them together, not as separate jobs.

- A **rectangle** or **circle** selects everything sitting fully inside it.
- An **arrow** points: from a thing, or from nowhere, at a thing, or at a spot. Its
  "Reads as" line states which.
- A **point** is one element, singled out.

Element names come from the running DOM — the React component, the icon, or the
accessible name. The indented line under a name (`src/...`, `in X › Y`, a `grep`, a
`data-testid`) is the fastest way to find it. **Use it. Never guess from the
description.** Detail is given the **first time** an element appears; later mentions
are just the name, so scroll up for its source line.

Measurements appear only where a mark is about size or placement. The geometry is
exact; the spoken words are intent and may be loosely worded or mis-transcribed.
**When they disagree, the words win** — the numbers exist to tell you what the words
meant.

## How to act on it

1. **Look at the crop for each mark** — `NN-crop.png`, in the same folder. It is the
   fastest way to see what was circled. Full-viewport shots are on disk as `NN.jpg`;
   open one only when a crop leaves you genuinely unsure.
2. **Find each target by its source / component / grep line**, then read that file.
3. **Express changes in the styling system the project already uses**, on its existing
   scale (Tailwind: 1 unit = 4px). Use an arbitrary value only when nothing on the
   scale fits.
4. **Implement alignments as alignments.** If a mark resolved to "align right" or
   "centre", use the layout property (`ml-auto`, `justify-end`, `text-center`), never
   the pixel offset that produced it.
5. Work through every mark in order, then report what changed per mark, and flag any
   mark you could not act on and why.

Make the edits only. Do not create a branch, commit, or push.
