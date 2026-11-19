// The tooling test root: the test packages that need no optimised code (the CLI, the EOS layer, the binding
// generator's checks, the Godot driver, the level format, the lint). `uni test` compiles them unoptimised, beside
// the optimised compile of the test root (tests/tests.odin), and runs both binaries at once: they are a third of the
// optimised compile and run about as fast without it. Each package also runs on its own: `uni test cli`.
package tooling

@(require) import "../cli"
@(require) import "../eos"
@(require) import "../gdext"
@(require) import "../godot_driver"
@(require) import "../level"
@(require) import "../lint"
