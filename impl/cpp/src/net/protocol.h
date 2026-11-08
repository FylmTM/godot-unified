// Relay <-> client messages. Little-endian, explicit sizes; inputs are packed as 2 x i8 + u8 + u8 per tick.
//
//   client -> relay   Hello (R), Input (U), Checksum (R), Snapshot (R, provider), Done (R)
//   relay -> client   Welcome (R), Start (R), Final (U), SnapshotRequest (R), Snapshot (R, to the joiner)
#pragma once

#include <vector>

#include "core/input.h"

namespace net {

enum class Msg : u8 {
    Hello = 1,
    Welcome = 2,
    Start = 3,
    Input = 4,
    Final = 5,
    Checksum = 6,
    SnapshotRequest = 7,
    Snapshot = 8,
    Done = 9,
};

constexpr u8 ANY_PLAYER = 0xFF;
constexpr int MAX_INPUTS_PER_PACKET = 32; // client -> relay, unacked inputs resent each packet
constexpr int MAX_FINALS_PER_PACKET = 32; // relay -> client, unacked finalized ticks resent each packet

struct HelloMsg {
    u8 player = ANY_PLAYER; // requested slot
    u8 late_join = 0;
};

struct WelcomeMsg {
    u8 player = 0;
    u8 initial_players = 0;
    u64 seed = 1;
    u32 ticks = 0;
    u32 join_tick = 0; // 0: in the game from tick 1; else first active tick J of a late joiner
    i64 start_us = -1; // relay time of tick 0, -1 until the session starts
};

struct StartMsg {
    i64 start_us = 0;
};

struct InputMsg {
    u64 client_time_us = 0;
    u32 ack_final = 0; // highest contiguous finalized tick the client holds
    u32 first_tick = 0;
    std::vector<uni::Input> inputs; // for first_tick, first_tick + 1, ...
};

struct FinalMsg {
    i64 relay_time_us = 0;
    u64 echo_client_time_us = 0; // the newest client_time_us the relay got from this client
    u32 echo_hold_us = 0;        // how long the relay held it before this send
    u32 input_ack = 0;           // relay has this player's inputs (or finalized ticks) up to here
    u32 first_tick = 0;
    std::vector<uni::TickInputs> ticks; // finalized sets for first_tick, first_tick + 1, ...
};

struct ChecksumMsg {
    u32 tick = 0;
    u64 checksum = 0;
};

struct SnapshotRequestMsg {
    u32 min_tick = 0; // send a verified snapshot of a tick >= this
    u8 for_player = 0;
};

struct SnapshotMsg {
    u8 for_player = 0;
    u32 tick = 0;
    uni::TickInputs inputs_at_tick; // the finalized set of `tick` (prediction seed for the joiner)
    std::vector<u8> snapshot;       // portable bytes (sim::Sim::encode_portable)
};

struct DoneMsg {
    u32 final_tick = 0;
};

// Encoders return the message bytes, Msg tag first. Decoders return false on malformed input.
std::vector<u8> encode(const HelloMsg& m);
std::vector<u8> encode(const WelcomeMsg& m);
std::vector<u8> encode(const StartMsg& m);
std::vector<u8> encode(const InputMsg& m);
std::vector<u8> encode(const FinalMsg& m);
std::vector<u8> encode(const ChecksumMsg& m);
std::vector<u8> encode(const SnapshotRequestMsg& m);
std::vector<u8> encode(const SnapshotMsg& m);
std::vector<u8> encode(const DoneMsg& m);

bool msg_type(const std::vector<u8>& data, Msg& out);
bool decode(const std::vector<u8>& data, HelloMsg& m);
bool decode(const std::vector<u8>& data, WelcomeMsg& m);
bool decode(const std::vector<u8>& data, StartMsg& m);
bool decode(const std::vector<u8>& data, InputMsg& m);
bool decode(const std::vector<u8>& data, FinalMsg& m);
bool decode(const std::vector<u8>& data, ChecksumMsg& m);
bool decode(const std::vector<u8>& data, SnapshotRequestMsg& m);
bool decode(const std::vector<u8>& data, SnapshotMsg& m);
bool decode(const std::vector<u8>& data, DoneMsg& m);

} // namespace net
