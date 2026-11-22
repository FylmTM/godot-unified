// The test root: `uni test` builds every test package below in one optimised compile and runs them all, beside the
// tooling test root (tests/tooling), which it compiles unoptimised at the same time. One package per module of src/,
// black-box: tests import the library the way a game does, through the `unified` collection. Each game's sim tests
// and end-to-end suite live with the game (examples/<game>/simulation/tests) and are pulled in by games.gen.odin, which
// uni writes before the compile (so by hand: any uni command that compiles the tests, then
// `odin test tests -all-packages -collection:unified=src`); tests/scenarios is the toy game's end-to-end suite. Each
// package also runs on its own: `uni test sim` (a library package), `uni test survivor` (a game's tests).
package tests

@(require) import "dmath"
@(require) import "headless"
@(require) import "lz"
@(require) import "nav"
@(require) import "netcode"
@(require) import "physics"
@(require) import "scenarios"
@(require) import "sim"
@(require) import "wire"
