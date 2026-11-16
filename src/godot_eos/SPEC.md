# `unified:godot_eos`: EOS online play for a Godot game

Status: signed off 2026-11-16 (#11).

`unified:eos` (src/eos/SPEC.md) as a `godot.Transport` (src/godot/SPEC.md, Transports), so a game gets online play
with one line in its extension:

```odin
godot_eos.transport(game: string) -> ^godot.Transport   // set it before godot.entry
godot.set_transport(godot_eos.transport("survivor"))
```

`game` is the EOS product name and the lobby bucket. The transport initializes EOS on the first host or join (a
failure ends that session with the reason; online play stays off), opens the lobby with the session's build
(`eos.Build{game, compat, godot.app_version}`: a joiner on another build is told which version the host runs),
reports the code and failures from `pump`, closes the lobby at the end of the session, vouches for the host's own
account (`eos.local_account`), pumps the macOS main run loop every frame and shuts EOS down at exit.

A package of its own: `unified:eos` never imports `unified:godot` (the headless binary uses it), and
`unified:godot` never imports a transport (a game without online play carries no EOS). A game that imports it is
an EOS game to `uni` (`extension_uses_eos`): its build stages the SDK library and compiles the IDs in.

Tests: through the games (`uni test --suite godot` builds them; `uni coop` plays one over real EOS). The parts it
wires are tested where they live: `tests/eos` (the session on a fake SDK) and `tests/godot_driver` (a transport's
calls and the compat it gets).
