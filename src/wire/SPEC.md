# wire

Status: draft, pending #331

Little-endian byte writer and reader for every binary format (`src/wire`, a leaf package): the input log, portable
snapshots, netcode messages.

## API

```odin
Writer { buf: [dynamic]u8 }
writer_make(cap := 256, allocator := context.allocator) -> Writer
w_bytes(^Writer, []u8)    w_u8 / w_u16 / w_u32 / w_u64(^Writer, v)       // appended little-endian

Reader { data: []u8, pos: int, ok: bool }
reader_make([]u8) -> Reader
r_bytes(^Reader, n) -> []u8                // a view into data; nil when fewer than n bytes are left
r_u8 / r_u16 / r_u32 / r_u64(^Reader) -> v // 0 when short
r_remaining(^Reader) -> int                // bytes left after pos
```

## How it works

- **Sticky `ok`:** a read past the end sets `ok = false`, moves `pos` to the end and returns zero or nil; every later
  read fails the same way. A decoder reads a whole message and checks `ok` once, so no decoder ever indexes unchecked
  bytes, and a truncated or hostile datagram can't crash it.
- **Little-endian only:** the reader copies bytes into the integer; big-endian targets fail to compile (`#panic`),
  like `sim`'s `#assert(ODIN_ENDIAN == .Little)`.
