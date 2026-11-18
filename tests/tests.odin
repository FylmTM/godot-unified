// The test root: `uni test` builds every test package below in one compile and runs them all. One package per module
// of src/, black-box: tests import the library the way a game does, through the `unified` collection. Each game's sim
// tests and end-to-end suite live with the game (games/<game>/simulation/tests) and are pulled in by games.gen.odin,
// which uni writes before the compile (so by hand: any uni command that compiles the tests, then
// `odin test tests -all-packages -collection:unified=src`); tests/scenarios is the toy game's end-to-end suite. Each
// package also runs on its own, e.g. `odin test tests/sim -collection:unified=src` or
// `odin test games/survivor/simulation/tests -collection:unified=src`.
package tests

@(require) import "cli"
@(require) import "dmath"
@(require) import "eos"
@(require) import "gdext"
@(require) import "godot_driver"
@(require) import "headless"
@(require) import "level"
@(require) import "lint"
@(require) import "netcode"
@(require) import "physics"
@(require) import "scenarios"
@(require) import "sim"
@(require) import "wire"
