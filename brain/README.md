# Bowser Brain

Long-term institutional memory for Bowser, per [The Shape of Things to Come](https://yegge.ai/essays/the-shape-of-things-to-come/).
Agents: **pull these files on demand** — don't rediscover decisions that are already made.

## Knowledge layers

| Layer | Where | Lifetime | Delivery |
|---|---|---|---|
| Strategy, decisions-and-why, playbooks, post-mortems | `brain/` | Months–years | Pulled on demand |
| How system X works | `doc/` | Life of the system | Pulled by whoever works on X |
| ≤1-paragraph operational facts & gotchas | `bd remember` | Until wrong | Pushed into every session via `bd prime` |
| Procedures for recurring task types | `.claude/skills/` | Until stale | Auto-loaded on task match |
| Journal of all work that ever happened | beads (`bd`) | Forever | `bd ready`, `bd show` |

## Map

- [`vision.md`](vision.md) — what Bowser is and is not
- [`architecture.md`](architecture.md) — the three-layer system picture
- [`decisions/`](decisions/) — ADRs: every load-bearing choice + why (read before proposing alternatives)

## Rules for agents

- A decision in `decisions/` is settled. Reopen it by filing a bead, not by silently building around it.
- When you finish meaningful research, fold it back: new doc in `doc/`, gotcha via `bd remember`, recurring procedure as a skill.
- New load-bearing choice → new ADR in `decisions/` (next number, same format).
