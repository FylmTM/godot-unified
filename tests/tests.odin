// The test root: `odin test tests -all-packages -collection:unified=src` (or `python tools/dev.py
// test`) builds every test package below in one compile and runs them all. One package per module
// of src/, black-box: tests import the library the way a game does, through the `unified`
// collection. Each package also runs on its own, e.g. `odin test tests/game -collection:unified=src`.
package tests

@(require) import "game"
@(require) import "lint"
@(require) import "netcode"
@(require) import "pod"
@(require) import "sim"
@(require) import "view"
@(require) import "wire"
