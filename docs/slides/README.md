# Shipping Infrastructure With a Team of Agents

A 26-slide deck on how `multipass-lab` was built — with [cmux](https://github.com/manaflow-ai/cmux),
the `boss-cmux` / `boss-cmux-team` skills, and multi-agent orchestration. It covers the tools, the
coordination protocol, three case studies (`centralized_k0s`, `docs-fleet`, `triage-logs`), and an
honest act on what broke.

Every number and quote in the deck traces back to something committed in this repo — the boards in
`.team/`, the specs in `specs/`, and the git history. Design rationale and the full slide-by-slide
outline live in [`specs/feature-slides.md`](../../specs/feature-slides.md).

## Open it

```sh
open docs/slides/index.html
```

That's the whole install. `index.html` is a single self-contained file — all CSS and JS inline, no
npm, no build step, no `node_modules`. The only network request is the Google Fonts stylesheet for
JetBrains Mono; everything else, including all six diagrams, is hand-built CSS/SVG.

A PDF export is **not committed** (it's ~2.6 MB of screenshots and would churn on every edit) — it's
gitignored. Generate `agent-orchestration.pdf` yourself with the command under
[Re-export the PDF](#re-export-the-pdf) below.

## Navigate

| Key | Does |
|-----|------|
| `→` `↓` `Space` `PageDown` | Next slide |
| `←` `↑` `PageUp` | Previous slide |
| `Home` / `End` | First / last slide |
| `E` | Toggle **inline edit mode** |
| scroll / swipe | Next / previous slide |

Hovering the bottom-centre of the window reveals a progress pill with prev/next buttons; it stays
hidden otherwise so it never lands in a screenshot.

**Inline editing:** press `E` (or hover the top-left corner and click the ✏️), then click any text
to edit it in place. Changes save to `localStorage`, so they survive a reload but do **not** write
back to `index.html` — fold anything you want to keep into the file itself.

## The fixed stage

Slides are authored at a fixed **1920×1080** canvas and the whole stage is scaled by a single
transform (`Math.min(innerWidth/1920, innerHeight/1080)`). It letterboxes on any other aspect ratio
rather than reflowing — a phone shows the same slide, just smaller. Don't add responsive
breakpoints inside a slide; that breaks the invariant.

## Re-export the PDF

The exporter ships with the `frontend-slides` skill. It pulls Playwright + Chromium into a temp dir,
so nothing lands in this repo:

```sh
bash ~/.claude/plugins/cache/frontend-slides/frontend-slides/2.1.0/skills/frontend-slides/scripts/export-pdf.sh \
  docs/slides/index.html docs/slides/agent-orchestration.pdf
```

The first run downloads Chromium (~150 MB) and takes 30–60s. Add `--compact` to render at 1280×720
for a smaller file. Animations are not preserved — each slide is captured in its final state.

## Customise

Colours are CSS variables at the top of the `<style>` block (`:root`) — the deck is the
**Terminal Green** preset (GitHub dark `#0d1117` + terminal green `#39d353`, all JetBrains Mono).
Change `--green` and the whole deck follows. Reveal animations are the `.reveal` class plus `.d1`–`.d12`
stagger delays.
