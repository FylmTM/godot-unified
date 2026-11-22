# `unified:lz`: LZ compression of our own

The codec portable snapshots travel in: the netcode compresses every snapshot it sends (a late joiner's, a resync's,
a typed desync report's) and decompresses what arrives (`src/netcode/README.md`, Late join and rejoin). A snapshot is
mostly zeros and repeated structure, so it shrinks to a fraction of its size and its transfer, most of a late join on
a slow link, with it. A leaf package with no imports, held to the tick rules (`tests/lint`), so anything may use it.

## Why our own

No dependency is the ideal (AGENTS.md). What a snapshot needs is small: repeats found by a hash, written as literals
and back-references, no entropy coding. That is a page of code, tested here byte for byte, where a library would be a
dependency to pin and test for a fraction of what it does. The price is a ratio a little behind a general-purpose
codec's, which `uni bench` shows per game (each game's snapshot, compressed).

## How it works

- **One block, self-describing.** A stream starts with the size it decodes to, so a receiver sizes its buffer once
  (`decoded_size`) and decodes into it (`decode`); no streaming, no frames. A header can claim at most what its bytes
  could stand for, so a hostile one can't make a receiver allocate much more than it sent.
- **Deterministic.** The encoder is integers only and its choices depend on the input alone (the hash table starts
  empty each call), so the same snapshot encodes to the same bytes on every platform: `tests/lz` pins them, and a
  platform or compiler that encodes differently fails there. Nothing needs it today (only the decoded bytes are
  checked), but compressed bytes that differ by platform would make any check over them a false alarm.
- **Matching.** Each position's first four bytes hash into a small table of the last two positions seen there; the
  longer match wins, a match one byte later that is longer is worth a literal (lazy matching), and a run of misses
  steps faster through bytes that don't repeat. Only a match's last positions go into the table, not every one inside
  it: those would push out older positions that match better. A match reaches 64 KiB back, which covers a snapshot's
  repeats: records next to each other in a table.
- **Safe on any input.** The decoder checks every length and offset against the input and the output before it
  copies, so a malformed stream is refused (`decode` returns false), never a read or write out of bounds.
- **Allocation.** `encode` writes into a buffer the caller keeps and reuses (it grows only past its largest input), its
  table on the stack; `decode` writes into the caller's buffer and allocates nothing.
