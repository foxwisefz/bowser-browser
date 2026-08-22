# Bowser as a personal software runtime

*Vision note, 2026-08-23. Written the night the first native iOS app rendered
a live X feed from a brain-served declaration. Companion to
`vision.md` and ADR 0011.*

## The reframe

Bowser began as "a personalizable browser." What the iOS work revealed is
larger: **Bowser is a personal software runtime.** The desktop browser is
one rendering target; native iOS is another; the brain is the universal
middle layer that (a) acquires data from anywhere the owner is
authenticated, and (b) drives any renderer. The **mod** is the single unit
of personalization across all of them.

## The machine, in three general parts

1. **Data acquisition** — the brain turns any logged-in web session into
   structured data. X was the hardest possible first target (hostile, no
   API) and it fell (`XAdapter`, `XFeed`). Gmail, Instagram, a bank, a niche
   forum: if you can log in through a browser, the brain can adapt it.
2. **The declaration IS the app** — a JSON tree of native components
   (`SDUI`), served over HTTP (`XServer`). Editable, generatable, data not
   code (Apple 2.5.2).
3. **One native runtime renders any declaration** — real SwiftUI, any
   layout (the `ios/` BowserX app).

The load-bearing insight: **both the data adapter and the declaration are
things an agent can write and edit.** New app = a generation problem, not an
engineering one.

## What it unlocks

- **Any service becomes an app you own** — no API, no cooperation, no
  permission. You re-present your own authenticated data.
- **Infinitely malleable** — "media-only timeline", "merge X + Instagram
  into one river", "magazine layout, hide anyone under 5k followers" are
  edits to a declaration + adapter.
- **One app, infinite apps** — inverts the App Store's one-submission model:
  one host runtime, every app is a declaration spun up in seconds.
- **Software by description** — the ModSmith loop, producing native apps.

## Interfaces beyond the feed

The runtime has no idea what a "timeline" is — it renders whatever
declaration it's handed against whatever data. So the same machine produces
interfaces a feed-shaped app never could:

- **Cross-source river** — one native list merging X + Instagram + HN,
  deduped and time-sorted. Data from three adapters, one declaration.
- **Triage deck** — your timeline as a swipeable card stack, not a scroll.
- **Generated briefing** — the agent reads several feeds and synthesizes one
  native "morning briefing" screen (top N, summarized). A *view*, not a
  feed.
- **Entity dashboard** — tap a person → a generated native profile: recent
  posts, stat tiles, a relationship graph.
- **Query interface** — a box you ask ("what did @x say about y") that
  queries sessions and renders a native answer card.

## The honest hard parts

- **Data acquisition is the soft underbelly.** Everything rests on scraping
  logged-in sessions. The native/declaration/agent side is durable; the
  *adapters* are a perpetual maintenance tax, worst against hostile sites.
- **One adapter per service.** Real work per service — exactly where the
  agent must earn its keep (generating and repairing adapters).
- **Reading is the easy half.** Write-back (post, like, reply) needs
  declarations with *interaction* bindings that drive actions back through
  the brain into the live session. The next real frontier, meatier than
  reading.

## The flywheel

Teach ModSmith to generate **declarations + adapters**, not just CSS. The
runtime is built; the moment the agent can produce "a native app for service
X in layout Y" from a sentence, the system becomes self-serving. That is the
highest-leverage next move.
