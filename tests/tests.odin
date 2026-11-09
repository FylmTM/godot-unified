// The test root: `odin test tests -all-packages -collection:unified=src` (or `python tools/dev.py
// test`) builds every test package below in one compile and runs them all. One package per module
// of src/, black-box: tests import the library the way a game does, through the `unified`
// collection. Each game's sim tests live with the game (games/<game>/simulation/tests) and are
// pulled in here too. Each package also runs on its own, e.g.
// `odin test tests/sim -collection:unified=src` or
// `odin test games/survivor/simulation/tests -collection:unified=src`.
package tests

@(require) import "box3d"
@(require) import "dmath"
@(require) import "eos"
@(require) import "gdext"
@(require) import "godot_host"
@(require) import "headless"
@(require) import "level"
@(require) import "lint"
@(require) import "netcode"
@(require) import "physics"
@(require) import "sim"
@(require) import "view"
@(require) import "wire"

@(require) import friendslop_tests "../games/friendslop/simulation/tests"
@(require) import survivor_tests "../games/survivor/simulation/tests"
