// The test root: `odin test tests -all-packages -collection:unified=src` (or `python tools/dev.py
// test`) builds every test package below in one compile and runs them all. One package per module
// of src/ (plus the survivor game), black-box: tests import the library the way a game does,
// through the `unified` collection. Each package also runs on its own, e.g.
// `odin test tests/sim -collection:unified=src`.
package tests

@(require) import "dmath"
@(require) import "eos"
@(require) import "lint"
@(require) import "netcode"
@(require) import "physics"
@(require) import "sim"
@(require) import "survivor"
@(require) import "wire"
