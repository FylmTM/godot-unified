---
name: demo-game
description: The demo game, Crypt Crew (FylmTM/godot-unified-demo), as unified's testing ground - checking a unified change against it before the change is done, and bumping its unified submodule once the change is on main. Use after any change a game can see (src/, tools_godot/, pins.cfg, the shims, odinfmt.json, the unified-* skills, the docs a game reads), before calling the work done, and after it lands.
---

# The demo game, unified's testing ground

Crypt Crew (`FylmTM/godot-unified-demo`) is a game built on unified the way any game is: its own repo, unified as
the `unified/` submodule. A unified change a game can see is done only when the demo builds and passes against it,
and the demo's submodule follows unified's `main`. A change no game can see (unified's own tests, CI, the examples)
needs neither; its bump comes with the next one.

## Before the change is done

Check it in a disposable clone of the demo under this checkout's `.out/`, never in a developer's own checkout (the
check moves its submodule and refreshes its files). The change must be committed: a fetch takes a branch or a full
40-character commit SHA, never an abbreviated one.

```sh
demo=.out/demo-check
[ -d $demo ] || git clone -q --recursive https://github.com/FylmTM/godot-unified-demo $demo
git -C $demo fetch -q origin && git -C $demo reset -q --hard origin/main && git -C $demo clean -fdq -e .out
git -C $demo submodule update -q --init
git -C $demo/unified fetch -q "$(pwd)" <branch or full commit SHA>
git -C $demo/unified checkout -q --detach FETCH_HEAD
(cd $demo && ./uni refresh && ./uni verify)   # uni.cmd on Windows
```

Or in the demo's CI, once the branch is pushed:
`gh workflow run ci.yml -R FylmTM/godot-unified-demo -f unified_ref=<branch or full commit SHA>`.

A failure is the change breaking a game: fix it in unified, in the same change. Only an API change meant to break
games is fixed on the demo's side, in its bump commit (below), and named in the unified commit.

## After the change is on main

In a clean checkout of the demo (the developer keeps one next to unified's main checkout; or the clone above, reset
to `origin/main`):

```sh
git -C unified fetch -q origin main
git -C unified checkout -q --detach FETCH_HEAD
./uni refresh
./uni verify
```

If the demo's reference run or a replay regression moved, the `unified-sim-change` skill says whether that was meant
and how to re-pin. Then one commit of its own: `Update unified: <what changed for the game>`, with the submodule, the
refreshed files and any fix the bump needed. The demo works straight on `main` (its AGENTS.md): push it there. The
demo's nightly canary (its `.github/workflows/ci.yml`) catches a missed bump: it runs the demo against unified's
`main` whenever that differs from the pin.
