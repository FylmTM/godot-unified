#include "core/input_log.h"

#include <cstring>

#include "core/bytes.h"
#include "core/platform.h"

namespace uni {

static constexpr char MAGIC[4] = {'U', 'N', 'I', 'L'};
static constexpr usize HEADER_BYTES = 4 + 2 + 8 + 1 + 4;
static constexpr usize TICK_BYTES = MAX_PLAYERS * 4 + 1;

bool write_input_log(const std::string& path, const InputLog& log) {
    std::vector<u8> buf;
    buf.reserve(HEADER_BYTES + log.ticks.size() * TICK_BYTES);
    ByteWriter w(buf);
    w.put_bytes(MAGIC, 4);
    w.put_u16(INPUT_LOG_VERSION);
    w.put_u64(log.seed);
    w.put_u8(log.players);
    w.put_u32((u32)log.ticks.size());
    for (const TickInputs& t : log.ticks) {
        for (const Input& in : t.players) {
            w.put_i8(in.move_x);
            w.put_i8(in.move_z);
            w.put_u8(in.buttons);
            w.put_u8(in.choice);
        }
        w.put_u8(t.replaced);
    }
    return platform::write_file(path, buf.data(), buf.size());
}

bool read_input_log(const std::string& path, InputLog& log, std::string& error) {
    std::vector<u8> buf;
    if (!platform::read_file(path, buf)) {
        error = "cannot read " + path;
        return false;
    }
    ByteReader r(buf.data(), buf.size());
    const u8* magic = r.get_bytes(4);
    if (!magic || std::memcmp(magic, MAGIC, 4) != 0) {
        error = "bad magic (not an input log)";
        return false;
    }
    u16 version = r.get_u16();
    if (version != INPUT_LOG_VERSION) {
        error = "unsupported input log version " + std::to_string(version);
        return false;
    }
    log.seed = r.get_u64();
    log.players = r.get_u8();
    u32 count = r.get_u32();
    if (!r.ok() || r.remaining() != (usize)count * TICK_BYTES || log.players > MAX_PLAYERS) {
        error = "truncated or inconsistent input log";
        return false;
    }
    log.ticks.assign(count, TickInputs{});
    for (TickInputs& t : log.ticks) {
        for (Input& in : t.players) {
            in.move_x = r.get_i8();
            in.move_z = r.get_i8();
            in.buttons = r.get_u8();
            in.choice = r.get_u8();
        }
        t.replaced = r.get_u8();
    }
    return r.ok();
}

} // namespace uni
