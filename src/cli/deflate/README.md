# `cli/deflate`: Odin's deflater, patched

A copy of Odin's `core:compress/deflate` writer (`deflate.odin`, `common.odin`, as the pinned Odin `dev-2026-11a`
ships them, under Odin's license, run through unified's odinfmt and made `#+private`), with one change, marked
"unified's patch" in `deflate_flush`: a block without a match still gets a distance code. Its package is
`cli_deflate`, since Odin's package names are unique, and its one entry is `deflate_zip_member`, which the CLI's zip
writer (`zip.odin`, `zip_add`) calls. Reading zips still uses `core:compress/deflate`.

Why: the stock deflater gives a block with no matches an empty distance tree (one distance length, zero). DEFLATE
allows it and zlib reads it, but Windows' built-in zip extractor (Explorer's "Extract all") refuses the member with
error 0x80004005. Matchless blocks are what already-compressed data deflates to, so a release zip with a game's
`.pck` failed to unpack in Explorer while every other tool unpacked it. zlib's own deflater never writes an empty
tree.

Drop this copy, and deflate with `core:compress/deflate` in `zip.odin` again, once Odin's deflater writes a distance
code in every dynamic block.
