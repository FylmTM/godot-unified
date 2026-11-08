# Log

Decisions and work done while the developer was away, newest last. Each decision says what was picked and why; the
developer reviews them here. Settled ones also land in `WORK.md`.

## 2026-11-09 night: goal

A playable survivor prototype: main menu, settings, the game. Players spawn inside a circle; the match starts when
any player walks out of it. Single player, and online with a friend (macOS ↔ Windows). Builds for macOS and Windows
come from CI, only when a tag is pushed. Dev UI is in every build for now.

Developer's answers before leaving: commit and push to main allowed; online via EOS (account exists; SDK and IDs being
set up, steps in `docs/EOS.md`); macOS builds ad-hoc signed; the friend plays on Windows.

## Decisions

- **Online: EOS** (anonymous device-ID login, lobbies joined by a 6-character code, P2P with Epic relays). It needs
  no server of ours and handles NAT. Direct UDP join by `host:port` stays for LAN and dev. UPnP only if EOS fails.
- **Single player = a host with no remote peers** (in-process relay over loopback), so one code path serves both modes.
- **Game flow:** lobby phase (players spawn in a start circle; the match starts when any player's centre leaves it),
  match (waves), over (every present player dead at once → ~5 s → reset to lobby). Late join stays on.
- **Work split into five parallel sessions**, each on its own branch, merged into main by the orchestrator:
  core-lib (generic sim + netcode step API + survivor sim), godot-layer (gdext, godot_host, view, ImGui devui),
  online-eos (EOS bindings, P2P link, lobby codes, SDK for CI), release-ci (tag-triggered macOS + Windows builds),
  game-client (Godot content: menus, settings, arena, views, HUD, with a GDScript mock until the extension lands).
  A GDScript-facing contract (UnifiedSession / SimView / SimBulkView, InputMap actions) was fixed up front so they
  can work in parallel.
- **Python tooling stays for now** (`tools/dev.py` grows game commands); the Odin CLI replacing it comes later.
- **Docs:** OctoEscape references removed; physics-engine comparisons removed from research and archive; AGENTS.md
  rule: don't name products we take ideas from (the one "inspired by" line aside) or the developer's other games.

## Work done

- f313149 Quantum/Photon mentions scrubbed from all repo files except one AGENTS.md line; spike decisions recorded.
- 5f71f4d AGENTS.md naming rule, `docs/EOS.md` (setup steps), this log.
- Docs: OctoEscape and its character names removed everywhere; physics-engine comparisons removed (research/01 now
  states only our decision and rules; `archive/bench/p/` deleted).
