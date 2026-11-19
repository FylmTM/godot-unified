// The toy game's headless binary: every mode of src/headless/README.md (The binary) on the toy, through
// unified:headless/modes. `uni test --suite net` drives it for the real-UDP, multi-process test (a
// relay and three client processes): a netcode transport test at library level.
package main

import "../../toy"
import "unified:headless/modes"

main :: proc() {
	modes.run(&toy.GAME)
}
