// The input log (replay file), spec/CORE.md §1:
//   "UNIL", version u16, seed u64, player count u8, tick count u32, then per tick 4 x input + replaced u8.
// `players` is the number of player slots active at tick 0; later slots join when their input stops being
// absent.
#pragma once

#include <string>
#include <vector>

#include "core/input.h"

namespace uni {

constexpr u16 INPUT_LOG_VERSION = 1;

struct InputLog {
    u64 seed = 1;
    u8 players = 4;
    std::vector<TickInputs> ticks; // ticks[k-1] holds the inputs that produce tick k
};

bool write_input_log(const std::string& path, const InputLog& log);
// On failure returns false and sets `error`.
bool read_input_log(const std::string& path, InputLog& log, std::string& error);

} // namespace uni
