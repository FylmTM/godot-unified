// What the CLI's zip writer calls: the copied deflater (README.md) is private to this package, so this is its one
// entry.
package cli_deflate

import "core:compress"

// `input` deflated raw (no zlib or gzip framing) at level 6, appended to `output`: a zip member's data. Fails only
// for an input too large to bound.
deflate_zip_member :: proc(output: ^[dynamic]u8, input: []u8) -> compress.Error {
	return deflate_raw_to_dynamic(output, input, .Level_6)
}
