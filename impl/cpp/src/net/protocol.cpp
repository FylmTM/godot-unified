#include "net/protocol.h"

#include "core/bytes.h"

namespace net {

namespace {

using uni::ByteReader;
using uni::ByteWriter;

void put_input(ByteWriter& w, const uni::Input& in) {
    w.put_i8(in.move_x);
    w.put_i8(in.move_z);
    w.put_u8(in.buttons);
    w.put_u8(in.choice);
}

uni::Input get_input(ByteReader& r) {
    uni::Input in;
    in.move_x = r.get_i8();
    in.move_z = r.get_i8();
    in.buttons = r.get_u8();
    in.choice = r.get_u8();
    return in;
}

void put_tick(ByteWriter& w, const uni::TickInputs& t) {
    for (const uni::Input& in : t.players) put_input(w, in);
    w.put_u8(t.replaced);
}

uni::TickInputs get_tick(ByteReader& r) {
    uni::TickInputs t;
    for (uni::Input& in : t.players) in = get_input(r);
    t.replaced = r.get_u8();
    return t;
}

// Reader positioned after the tag, if the tag matches.
bool open(const std::vector<u8>& data, Msg type, ByteReader& r) {
    r = ByteReader(data.data(), data.size());
    return r.get_u8() == (u8)type && r.ok();
}

} // namespace

bool msg_type(const std::vector<u8>& data, Msg& out) {
    if (data.empty()) return false;
    out = (Msg)data[0];
    return true;
}

#define BEGIN(type)                                                                                                   \
    std::vector<u8> out;                                                                                              \
    ByteWriter w(out);                                                                                                \
    w.put_u8((u8)(type))

std::vector<u8> encode(const HelloMsg& m) {
    BEGIN(Msg::Hello);
    w.put_u8(m.player);
    w.put_u8(m.late_join);
    return out;
}

std::vector<u8> encode(const WelcomeMsg& m) {
    BEGIN(Msg::Welcome);
    w.put_u8(m.player);
    w.put_u8(m.initial_players);
    w.put_u64(m.seed);
    w.put_u32(m.ticks);
    w.put_u32(m.join_tick);
    w.put_i64(m.start_us);
    return out;
}

std::vector<u8> encode(const StartMsg& m) {
    BEGIN(Msg::Start);
    w.put_i64(m.start_us);
    return out;
}

std::vector<u8> encode(const InputMsg& m) {
    BEGIN(Msg::Input);
    w.put_u64(m.client_time_us);
    w.put_u32(m.ack_final);
    w.put_u32(m.first_tick);
    w.put_u8((u8)m.inputs.size());
    for (const uni::Input& in : m.inputs) put_input(w, in);
    return out;
}

std::vector<u8> encode(const FinalMsg& m) {
    BEGIN(Msg::Final);
    w.put_i64(m.relay_time_us);
    w.put_u64(m.echo_client_time_us);
    w.put_u32(m.echo_hold_us);
    w.put_u32(m.input_ack);
    w.put_u32(m.first_tick);
    w.put_u8((u8)m.ticks.size());
    for (const uni::TickInputs& t : m.ticks) put_tick(w, t);
    return out;
}

std::vector<u8> encode(const ChecksumMsg& m) {
    BEGIN(Msg::Checksum);
    w.put_u32(m.tick);
    w.put_u64(m.checksum);
    return out;
}

std::vector<u8> encode(const SnapshotRequestMsg& m) {
    BEGIN(Msg::SnapshotRequest);
    w.put_u32(m.min_tick);
    w.put_u8(m.for_player);
    return out;
}

std::vector<u8> encode(const SnapshotMsg& m) {
    BEGIN(Msg::Snapshot);
    w.put_u8(m.for_player);
    w.put_u32(m.tick);
    put_tick(w, m.inputs_at_tick);
    w.put_u32((u32)m.snapshot.size());
    w.put_bytes(m.snapshot.data(), m.snapshot.size());
    return out;
}

std::vector<u8> encode(const DoneMsg& m) {
    BEGIN(Msg::Done);
    w.put_u32(m.final_tick);
    return out;
}

#undef BEGIN

bool decode(const std::vector<u8>& data, HelloMsg& m) {
    ByteReader r(nullptr, 0);
    if (!open(data, Msg::Hello, r)) return false;
    m.player = r.get_u8();
    m.late_join = r.get_u8();
    return r.ok();
}

bool decode(const std::vector<u8>& data, WelcomeMsg& m) {
    ByteReader r(nullptr, 0);
    if (!open(data, Msg::Welcome, r)) return false;
    m.player = r.get_u8();
    m.initial_players = r.get_u8();
    m.seed = r.get_u64();
    m.ticks = r.get_u32();
    m.join_tick = r.get_u32();
    m.start_us = r.get_i64();
    return r.ok();
}

bool decode(const std::vector<u8>& data, StartMsg& m) {
    ByteReader r(nullptr, 0);
    if (!open(data, Msg::Start, r)) return false;
    m.start_us = r.get_i64();
    return r.ok();
}

bool decode(const std::vector<u8>& data, InputMsg& m) {
    ByteReader r(nullptr, 0);
    if (!open(data, Msg::Input, r)) return false;
    m.client_time_us = r.get_u64();
    m.ack_final = r.get_u32();
    m.first_tick = r.get_u32();
    u8 n = r.get_u8();
    m.inputs.clear();
    for (u8 i = 0; i < n && r.ok(); ++i) m.inputs.push_back(get_input(r));
    return r.ok();
}

bool decode(const std::vector<u8>& data, FinalMsg& m) {
    ByteReader r(nullptr, 0);
    if (!open(data, Msg::Final, r)) return false;
    m.relay_time_us = r.get_i64();
    m.echo_client_time_us = r.get_u64();
    m.echo_hold_us = r.get_u32();
    m.input_ack = r.get_u32();
    m.first_tick = r.get_u32();
    u8 n = r.get_u8();
    m.ticks.clear();
    for (u8 i = 0; i < n && r.ok(); ++i) m.ticks.push_back(get_tick(r));
    return r.ok();
}

bool decode(const std::vector<u8>& data, ChecksumMsg& m) {
    ByteReader r(nullptr, 0);
    if (!open(data, Msg::Checksum, r)) return false;
    m.tick = r.get_u32();
    m.checksum = r.get_u64();
    return r.ok();
}

bool decode(const std::vector<u8>& data, SnapshotRequestMsg& m) {
    ByteReader r(nullptr, 0);
    if (!open(data, Msg::SnapshotRequest, r)) return false;
    m.min_tick = r.get_u32();
    m.for_player = r.get_u8();
    return r.ok();
}

bool decode(const std::vector<u8>& data, SnapshotMsg& m) {
    ByteReader r(nullptr, 0);
    if (!open(data, Msg::Snapshot, r)) return false;
    m.for_player = r.get_u8();
    m.tick = r.get_u32();
    m.inputs_at_tick = get_tick(r);
    u32 n = r.get_u32();
    const u8* bytes = r.get_bytes(n);
    if (!bytes) return false;
    m.snapshot.assign(bytes, bytes + n);
    return r.ok();
}

bool decode(const std::vector<u8>& data, DoneMsg& m) {
    ByteReader r(nullptr, 0);
    if (!open(data, Msg::Done, r)) return false;
    m.final_tick = r.get_u32();
    return r.ok();
}

} // namespace net
