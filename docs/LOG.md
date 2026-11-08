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

