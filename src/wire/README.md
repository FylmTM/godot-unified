# `unified:wire`: little-endian bytes

The byte writer and reader under every binary format `unified` has: the input log and portable snapshots (`sim`),
the netcode's messages. A leaf package: it imports nothing of the collection.

## How it works

- **Sticky `ok`.** A read past the end sets `Reader.ok` to false, moves to the end and returns zero or nil, and every
  later read fails the same way. A decoder reads a whole message and checks `ok` once, so no decoder indexes
  unchecked bytes, and a truncated or hostile datagram can't crash it.
- **Little-endian only.** Values are copied byte for byte; a big-endian target fails to compile, like `sim`.
