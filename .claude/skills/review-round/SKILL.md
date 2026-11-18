---
name: review-round
description: How a focused review round of unified runs - two independent reviewers per lens (bloat, API design and structure, game implementation, performance, correctness), the coordinator's verify-and-merge, the developer's decisions, fix batches in parallel where files allow, repeat rounds until a lens is quiet, and the test-game gate before new games. Use when asked to start, continue or coordinate a review round, write a reviewer brief, merge reviewer reports, or file a round's findings.
---

# A review round

The goal: confidence that the foundations are solid before new games are built on them. Lenses are reviewed one at a
time and repeated until reviewers stop finding issues; then a test game proves the foundations the way a new game uses
them.

## Lenses and waves

| Lens | Scope | Starts when |
|---|---|---|
| Correctness | determinism, save/restore and rollback, netcode under loss and hostile input, bounds, threads, untested guarantees | its scope is not being changed by an open batch |
| Performance | sim step and re-sim, snapshots, physics, wire, session loop, view sync; what is unmeasured | same |
| API design and structure | what a game calls, package layout and layering, naming | same |
| Game implementation | each game's sim, Godot project and tests as examples of using unified | the games' batches have merged |
| Bloat | everything | the other lenses' batches have merged |

A lens's scope is the packages or games it covers; split a lens into waves so that a review never reads code an open
batch is rewriting. Different lenses and waves run at the same time.

## One round of one lens

1. **Pin and measure.** Note the `main` commit. When the lens needs numbers, run `./uni bench` (and the view bench for
   the Godot host) once and keep the output with the brief.
2. **Brief.** In `.out/review/<round>/` (local): the lens, the scope, what is out of scope, the ledger (below), the
   report format and the classes. Reviewers only report: no tracked changes, no issues, no PRs.
3. **Reviewers.** Two agents in parallel, each in its own worktree, effort high: Opus and Fable. Fable reviews a lens
   in full the first time; in later rounds of that lens, only what changed since its last round plus the items the
   two disagreed on. Opus reviews the full scope every round. Each writes its report to
   `.out/review/<round>/raw/<lens>-<model>.md` and returns only a summary.
4. **Verify and merge.** The coordinator checks every finding against the code (a repro runs, a trace holds, a number
   reproduces) and drops what does not hold, saying why. Merge into one list: duplicates folded, each item marked
   agree, one reviewer, complementary or conflict, with the coordinator's recommendation.
5. **Decide.** One page per wave for the developer. **clear-fix** items (a bug with a reproduction, a measured
   performance win, dead code, a missing test for a stated guarantee) go to fix batches unless the developer vetoes
   them. **decide** items (an API change, a trade-off, anything the reviewers disagree on) wait for the developer.
6. **File.** One batch issue per area, per `board-work`: a checklist, the decisions, a "Not doing" list, pointers to
   the raw reports.
7. **Fix.** Each batch in its own side session and worktree. Batches whose files do not overlap run at the same time;
   batches touching the same files, or both moving reference runs, run one after another.
8. **Next round** of the lens on the new `main`.

## The ledger

Every brief carries what was decided before, so nothing rejected is proposed again: the previous rounds' merged items
and the developer's decisions (`.out/review/`), the open issues, and the standing principles. A rejection that rests on
a design principle is written as one line in the spec it concerns, so later reviewers read it next to the code.

## When a lens is done

A lens is done when a round of it produces no bug or major finding the developer accepts. Lenses finish independently.

## The gate before new games

When every lens is done, one agent builds a small new game from `uni init`, in a genre the repo does not have yet,
using only the docs, and logs every friction point (a missing API, a doc gap, a template problem, a slow step). The
friction is fixed like a round's findings; then new games start, each in its own `games/<game>/`, in parallel.
